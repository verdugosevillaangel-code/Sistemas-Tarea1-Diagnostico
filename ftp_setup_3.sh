#!/bin/bash

# ════════════════════════════════════════════════════════════════════════════
#  ftp_setup.sh  —  Automatización del Servidor FTP con vsftpd
#  Plataforma : Alma Linux 9 (sin GUI)
#  Ejecución  : sudo bash ftp_setup.sh
#
#  Características:
#   • Instalación idempotente de vsftpd y dependencias (acl, policycoreutils)
#   • Acceso anónimo de solo lectura a /general
#   • Usuarios autenticados con chroot jail individual
#   • Grupos: reprobados / recursadores
#   • Estructura visible al login FTP:
#       /  (jail del usuario)
#       ├── general/          ← escritura permitida (bind-mount compartido)
#       ├── reprobados/ ó
#       │   recursadores/     ← escritura según grupo  (bind-mount compartido)
#       └── <usuario>/        ← directorio personal, sólo del usuario
#   • Cambio de grupo con reestructuración automática de jail y ACLs
#   • Gestión de permisos con chown, chmod, setgid y ACLs (setfacl)
#   • Configuración de SELinux y firewalld
#   • Log en /var/log/ftp_setup.log
# ════════════════════════════════════════════════════════════════════════════

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   BOLD='\033[1m';  NC='\033[0m'

# ── Constantes de rutas ───────────────────────────────────────────────────────
readonly FTP_BASE="/srv/ftp"
readonly GENERAL_DIR="${FTP_BASE}/general"
readonly REPROBADOS_DIR="${FTP_BASE}/reprobados"
readonly RECURSADORES_DIR="${FTP_BASE}/recursadores"
readonly ANON_ROOT="${FTP_BASE}/anon_root"
readonly USERS_ROOT="${FTP_BASE}/users"
readonly VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
readonly LOG_FILE="/var/log/ftp_setup.log"

# ── Nombres de grupos ─────────────────────────────────────────────────────────
readonly GRP_FTP="ftp_users"
readonly GRP_REPROBADOS="reprobados"
readonly GRP_RECURSADORES="recursadores"

# ════════════════════════════════════════════════════════════════════════════
# UTILIDADES GENERALES
# ════════════════════════════════════════════════════════════════════════════

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts][$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    case "$level" in
        INFO)  echo -e "  ${BLUE}[INFO]${NC}   $msg" ;;
        WARN)  echo -e "  ${YELLOW}[AVISO]${NC}  $msg" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC}  $msg" ;;
        OK)    echo -e "  ${GREEN}[ OK ]${NC}   $msg" ;;
    esac
}

sep()   { echo -e "${BLUE}  ══════════════════════════════════════════════════════════${NC}"; }
line()  { echo -e "${BLUE}  ──────────────────────────────────────────────────────────${NC}"; }
pause() { read -rp "$(echo -e "  ${CYAN}[ Presione ENTER para continuar... ]${NC} ")" _; }

check_root() {
    [[ $EUID -eq 0 ]] || {
        echo -e "${RED}[ERROR]${NC} Este script debe ejecutarse como root (sudo bash ftp_setup.sh)."
        exit 1
    }
}

group_exists()  { getent group "$1" &>/dev/null; }
user_exists()   { id "$1" &>/dev/null 2>&1; }
pkg_installed() { rpm -q "$1" &>/dev/null; }

# ── Auto-detección de IP para pasv_address ────────────────────────────────────
# Busca la primera IP que NO sea loopback ni la IP de la red interna de VirtualBox
# (NAT, 10.0.2.x). Prioriza adaptadores Host-Only (192.168.56.x / 192.168.x.x)
# o cualquier IP privada disponible. Si no puede determinarla, solicita al usuario.

detect_pasv_ip() {
    local ip=""

    # 1. Intentar con la IP del adaptador Host-Only (192.168.56.x — VirtualBox default)
    ip=$(ip -4 addr show 2>/dev/null \
        | awk '/inet / {print $2}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | grep -v '^10\.0\.2\.' \
        | grep '^192\.168\.' \
        | head -1)

    # 2. Si no hay 192.168.x.x, tomar cualquier IP privada que no sea NAT
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 addr show 2>/dev/null \
            | awk '/inet / {print $2}' \
            | cut -d/ -f1 \
            | grep -vE '^(127\.|10\.0\.2\.)' \
            | head -1)
    fi

    # 3. Si aún no hay IP, pedirla manualmente
    if [[ -z "$ip" ]]; then
        echo -e "  ${YELLOW}[AVISO]${NC} No se pudo detectar la IP automáticamente."
        echo -e "  IPs disponibles en el sistema:"
        ip -4 addr show 2>/dev/null | awk '/inet / {print "    " $2}' | cut -d/ -f1
        read -rp "  Ingrese la IP a usar para pasv_address (ej: 192.168.56.101): " ip
        [[ -z "$ip" ]] && ip="127.0.0.1"
    fi

    echo "$ip"
}

print_header() {
    clear
    echo -e "${BLUE}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║    AUTOMATIZACIÓN DEL SERVIDOR FTP  ──  vsftpd              ║"
    echo "  ║    Alma Linux 9  │  Grupos: reprobados / recursadores       ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ── Helpers para /etc/fstab y bind mounts ─────────────────────────────────────

add_fstab_entry() {
    # add_fstab_entry <src> <dst> [opciones]
    local src="$1" dst="$2" opts="${3:-defaults,bind}"
    # Idempotente: solo añadir si el destino no está ya en fstab
    if ! grep -qF "$dst" /etc/fstab 2>/dev/null; then
        echo "${src}  ${dst}  none  ${opts}  0  0" >> /etc/fstab
        log INFO "fstab: agregado ${src} → ${dst}"
    fi
}

remove_fstab_entry() {
    # Usar | como delimitador de sed para evitar conflictos con /
    local dst="$1"
    sed -i "\|${dst}|d" /etc/fstab 2>/dev/null || true
    log INFO "fstab: eliminada entrada de ${dst}"
}

mount_bind() {
    local src="$1" dst="$2"
    if mountpoint -q "$dst" 2>/dev/null; then
        log WARN "Ya montado (sin acción): $dst"
    else
        if mount --bind "$src" "$dst" 2>/dev/null; then
            log OK "Bind mount activo: ${src} → ${dst}"
        else
            log ERROR "No se pudo montar: ${src} → ${dst}"
        fi
    fi
}

umount_safe() {
    local dst="$1"
    if mountpoint -q "$dst" 2>/dev/null; then
        # Intento 1: desmontaje normal
        if umount "$dst" 2>/dev/null; then
            log OK "Desmontado: $dst"
        else
            # Intento 2: lazy unmount (-l) desvincula el directorio del filesystem
            # namespace aunque haya procesos con el directorio abierto (sesion FTP activa).
            # El kernel completa el desmontaje fisico en cuanto el ultimo proceso lo libera.
            if umount -l "$dst" 2>/dev/null; then
                log OK "Desmontaje lazy aplicado: $dst"
            else
                log WARN "No se pudo desmontar (ni lazy): $dst"
            fi
        fi
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 1 — INSTALACIÓN IDEMPOTENTE DE vsftpd Y DEPENDENCIAS
# ════════════════════════════════════════════════════════════════════════════

install_vsftpd() {
    sep
    echo -e "${BOLD}  [1/5] Instalación de vsftpd y dependencias${NC}"
    line

    # vsftpd
    if pkg_installed vsftpd; then
        log WARN "vsftpd ya está instalado — se omite la instalación."
    else
        log INFO "Instalando vsftpd..."
        if dnf install -y vsftpd &>/dev/null; then
            log OK "vsftpd instalado correctamente."
        else
            log ERROR "Falló 'dnf install vsftpd'. Verifique conectividad/repositorios."
            return 1
        fi
    fi

    # acl — necesario para setfacl / getfacl
    if pkg_installed acl; then
        log WARN "acl ya instalado."
    else
        dnf install -y acl &>/dev/null && log OK "Paquete acl instalado." \
                                       || log WARN "No se pudo instalar acl."
    fi

    # policycoreutils-python-utils — para el comando semanage (SELinux)
    if command -v semanage &>/dev/null; then
        log WARN "semanage ya disponible."
    else
        dnf install -y policycoreutils-python-utils &>/dev/null \
            && log OK "policycoreutils-python-utils instalado." \
            || log WARN "semanage no disponible; la configuración SELinux será parcial."
    fi

    # Habilitar e iniciar el servicio
    systemctl enable --now vsftpd &>/dev/null \
        && log OK "Servicio vsftpd habilitado e iniciado (systemctl)." \
        || log WARN "No se pudo habilitar vsftpd con systemctl."

    # vsftpd requiere que el shell de los usuarios locales esté en /etc/shells
    if ! grep -qxF "/sbin/nologin" /etc/shells 2>/dev/null; then
        echo "/sbin/nologin" >> /etc/shells
        log OK "/sbin/nologin añadido a /etc/shells (requerido por vsftpd)."
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 2 — CONFIGURACIÓN DE /etc/vsftpd/vsftpd.conf (IDEMPOTENTE)
# ════════════════════════════════════════════════════════════════════════════

configure_vsftpd() {
    sep
    echo -e "${BOLD}  [2/5] Configuración de vsftpd.conf${NC}"
    line

    # Respaldar el archivo original (solo la primera vez)
    if [[ ! -f "${VSFTPD_CONF}.orig" ]]; then
        cp "$VSFTPD_CONF" "${VSFTPD_CONF}.orig" 2>/dev/null \
            && log INFO "Backup original: ${VSFTPD_CONF}.orig"
    fi

    # ── Auto-detectar IP para modo pasivo ────────────────────────────────────
    log INFO "Detectando IP del servidor para pasv_address..."
    local PASV_IP
    PASV_IP=$(detect_pasv_ip)
    log OK "pasv_address detectada: ${PASV_IP}"

    # ── Escribir configuración completa ───────────────────────────────────
    # IMPORTANTE: heredoc con comillas simples 'EOF' para que bash
    # NO expanda $USER  (vsftpd lo sustituye en tiempo de ejecución).
    # pasv_address se añade DESPUÉS del heredoc ya que sí necesita expansión.
    cat > "$VSFTPD_CONF" << 'VSFTPD_EOF'
# ─────────────────────────────────────────────────────────────────────────────
# /etc/vsftpd/vsftpd.conf
# Generado por ftp_setup.sh  —  Alma Linux 9
# ─────────────────────────────────────────────────────────────────────────────

# ── Listener (IPv4 solamente) ─────────────────────────────────────────────
listen=YES
listen_ipv6=NO

# ── Acceso Anónimo (SOLO LECTURA a /general) ─────────────────────────────
# anon_root apunta a /srv/ftp/anon_root, que solo contiene el bind-mount
# de /srv/ftp/general (lectura únicamente).
anonymous_enable=YES
anon_root=/srv/ftp/anon_root
anon_upload_enable=NO
anon_mkdir_write_enable=NO
no_anon_password=YES

# ── Acceso de Usuarios Locales Autenticados ──────────────────────────────
local_enable=YES
write_enable=YES
local_umask=022

# ── Chroot: confinar cada usuario autenticado en su propio jail ──────────
# Directorio del jail = /srv/ftp/users/<usuario>
# vsftpd sustituye $USER por el nombre del usuario que inicia sesión.
chroot_local_user=YES
allow_writeable_chroot=YES
user_sub_token=$USER
local_root=/srv/ftp/users/$USER

# ── Modo Pasivo (necesario para clientes detrás de NAT / VirtualBox) ─────
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
# pasv_address: auto-inyectada por ftp_setup.sh (ver línea siguiente al heredoc)

# ── Lista de usuarios denegados (lista negra de cuentas del sistema) ──────
# userlist_deny=YES  →  los usuarios del archivo son BLOQUEADOS.
# Los usuarios FTP creados por el script NO estarán en esa lista.
userlist_enable=YES
userlist_deny=YES
userlist_file=/etc/vsftpd/user_list

# ── Banner y mensajes de directorio ──────────────────────────────────────
ftpd_banner=Bienvenido al Servidor FTP Institucional. Acceso restringido.
dirmessage_enable=YES

# ── Logging ───────────────────────────────────────────────────────────────
xferlog_enable=YES
xferlog_std_format=YES
xferlog_file=/var/log/vsftpd.log
dual_log_enable=YES
vsftpd_log_file=/var/log/vsftpd_detail.log

# ── PAM ───────────────────────────────────────────────────────────────────
pam_service_name=vsftpd
VSFTPD_EOF

    # Inyectar pasv_address con la IP detectada (requiere expansión de variable)
    echo "pasv_address=${PASV_IP}" >> "$VSFTPD_CONF"
    log OK "vsftpd.conf escrito  |  pasv_address=${PASV_IP}"

    systemctl restart vsftpd 2>/dev/null \
        && log OK "vsftpd reiniciado con la nueva configuración." \
        || log ERROR "No se pudo reiniciar vsftpd."
}

# ════════════════════════════════════════════════════════════════════════════
# ACTUALIZAR pasv_address  (útil si cambia la IP del adaptador Host-Only)
# ════════════════════════════════════════════════════════════════════════════

update_pasv_address() {
    sep
    echo -e "${BOLD}  Actualizar pasv_address en vsftpd.conf${NC}"
    line

    # Mostrar la dirección actual
    local current
    current=$(grep "^pasv_address=" "$VSFTPD_CONF" 2>/dev/null | cut -d= -f2)
    [[ -n "$current" ]] \
        && log INFO "pasv_address actual: ${current}" \
        || log WARN "pasv_address no encontrada en ${VSFTPD_CONF}."

    # Auto-detectar la nueva IP
    log INFO "Detectando IP del servidor..."
    local new_ip
    new_ip=$(detect_pasv_ip)
    echo -e "  IP detectada: ${GREEN}${new_ip}${NC}"

    # Confirmar o ingresar manualmente
    local confirm
    read -rp "$(echo -e "  ¿Usar esta IP? [S/n]: ")" confirm
    if [[ "${confirm,,}" == "n" ]]; then
        read -rp "  Ingrese la IP manualmente: " new_ip
        [[ -z "$new_ip" ]] && { log ERROR "IP vacía. Operación cancelada."; return 1; }
    fi

    # Reemplazar o añadir la línea pasv_address en vsftpd.conf
    if grep -q "^pasv_address=" "$VSFTPD_CONF" 2>/dev/null; then
        sed -i "s/^pasv_address=.*/pasv_address=${new_ip}/" "$VSFTPD_CONF"
    else
        echo "pasv_address=${new_ip}" >> "$VSFTPD_CONF"
    fi

    log OK "pasv_address actualizada a: ${new_ip}"

    systemctl restart vsftpd 2>/dev/null \
        && log OK "vsftpd reiniciado con la nueva pasv_address." \
        || log ERROR "No se pudo reiniciar vsftpd."

    # Mostrar la línea resultante para confirmar
    line
    echo -e "  Verificación en ${VSFTPD_CONF}:"
    grep -E "^pasv" "$VSFTPD_CONF" | sed 's/^/    /'
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 3 — GRUPOS DEL SISTEMA (IDEMPOTENTE)
# ════════════════════════════════════════════════════════════════════════════

create_groups() {
    sep
    echo -e "${BOLD}  [3/5] Creación de grupos del sistema${NC}"
    line

    for grp in "$GRP_FTP" "$GRP_REPROBADOS" "$GRP_RECURSADORES"; do
        if group_exists "$grp"; then
            log WARN "Grupo '$grp' ya existe — omitiendo."
        else
            groupadd "$grp" && log OK "Grupo '$grp' creado." || log ERROR "Error al crear grupo '$grp'."
        fi
    done
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 4 — ESTRUCTURA BASE DE DIRECTORIOS (IDEMPOTENTE)
# ════════════════════════════════════════════════════════════════════════════

# Mapa de permisos planeado:
#
#  /srv/ftp/                      root:root         755
#  /srv/ftp/general/              root:ftp_users    2775  (setgid)
#  /srv/ftp/reprobados/           root:reprobados   2775  (setgid)
#  /srv/ftp/recursadores/         root:recursadores 2775  (setgid)
#  /srv/ftp/anon_root/            root:ftp          755
#  /srv/ftp/anon_root/general/    (bind-mount RO de /srv/ftp/general)
#  /srv/ftp/users/                root:root         755
#  /srv/ftp/users/<u>/            root:root         755   ← chroot jail
#  /srv/ftp/users/<u>/general/    (bind-mount RW de /srv/ftp/general)
#  /srv/ftp/users/<u>/<grupo>/    (bind-mount RW de /srv/ftp/<grupo>)
#  /srv/ftp/users/<u>/<u>/        <u>:<grupo>       755

create_base_dirs() {
    sep
    echo -e "${BOLD}  [4/5] Estructura de directorios FTP${NC}"
    line

    mkdir -p "$GENERAL_DIR" "$REPROBADOS_DIR" "$RECURSADORES_DIR" \
             "$ANON_ROOT"   "$USERS_ROOT"

    # ── /srv/ftp/general ─────────────────────────────────────────────────
    # Todos los usuarios autenticados (miembros de ftp_users) pueden escribir.
    chown root:"$GRP_FTP"       "$GENERAL_DIR"
    chmod 2775                   "$GENERAL_DIR"   # setgid: archivos heredan grupo ftp_users
    log OK "general/  →  root:${GRP_FTP}  2775 (setgid)"

    # ── /srv/ftp/reprobados ───────────────────────────────────────────────
    chown root:"$GRP_REPROBADOS" "$REPROBADOS_DIR"
    chmod 2775                   "$REPROBADOS_DIR"
    log OK "reprobados/  →  root:${GRP_REPROBADOS}  2775 (setgid)"

    # ── /srv/ftp/recursadores ─────────────────────────────────────────────
    chown root:"$GRP_RECURSADORES" "$RECURSADORES_DIR"
    chmod 2775                     "$RECURSADORES_DIR"
    log OK "recursadores/  →  root:${GRP_RECURSADORES}  2775 (setgid)"

    # ── /srv/ftp/anon_root ────────────────────────────────────────────────
    # Raíz del acceso anónimo: solo contiene el punto de montaje de general.
    chown root:ftp "$ANON_ROOT" 2>/dev/null || chown root:root "$ANON_ROOT"
    chmod 755 "$ANON_ROOT"

    mkdir -p "${ANON_ROOT}/general"
    chown root:root "${ANON_ROOT}/general"
    chmod 755       "${ANON_ROOT}/general"

    # Bind-mount de /srv/ftp/general  →  /srv/ftp/anon_root/general
    # Los anónimos ven solo este directorio (sin escritura por configuración vsftpd).
    add_fstab_entry "$GENERAL_DIR" "${ANON_ROOT}/general" "defaults,bind"
    mount_bind      "$GENERAL_DIR" "${ANON_ROOT}/general"

    # ── /srv/ftp/users ────────────────────────────────────────────────────
    chown root:root "$USERS_ROOT"
    chmod 755       "$USERS_ROOT"

    log OK "Estructura base de directorios lista en ${FTP_BASE}."
}

# ════════════════════════════════════════════════════════════════════════════
# PASO 5 — SELinux Y FIREWALL (IDEMPOTENTE)
# ════════════════════════════════════════════════════════════════════════════

configure_security() {
    sep
    echo -e "${BOLD}  [5/5] SELinux y Firewall${NC}"
    line

    # ── SELinux ───────────────────────────────────────────────────────────
    if command -v getenforce &>/dev/null; then
        local se_state; se_state=$(getenforce)
        log INFO "SELinux estado: ${se_state}"
        if [[ "$se_state" != "Disabled" ]]; then
            # Permitir a vsftpd acceso completo (incluye chroot fuera de /var/ftp)
            setsebool -P ftpd_full_access        1 2>/dev/null \
                && log OK "SELinux: ftpd_full_access=on"     || log WARN "setsebool ftpd_full_access falló"
            setsebool -P ftpd_use_passive_mode   1 2>/dev/null \
                && log OK "SELinux: ftpd_use_passive_mode=on" || true

            # Etiquetar /srv/ftp con contexto de escritura pública
            if command -v semanage &>/dev/null; then
                semanage fcontext -a -t public_content_rw_t "${FTP_BASE}(/.*)?" 2>/dev/null \
                || semanage fcontext -m -t public_content_rw_t "${FTP_BASE}(/.*)?" 2>/dev/null \
                || true
                restorecon -Rv "$FTP_BASE" &>/dev/null \
                    && log OK "SELinux: contextos restaurados en ${FTP_BASE}."
            else
                log WARN "semanage no disponible; ejecute manualmente: restorecon -Rv ${FTP_BASE}"
            fi
        fi
    else
        log WARN "SELinux no disponible en este sistema."
    fi

    # ── Firewalld ─────────────────────────────────────────────────────────
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=ftp           &>/dev/null \
            && log OK "Firewall: servicio FTP (puerto 21) abierto."
        firewall-cmd --permanent --add-port=40000-40100/tcp  &>/dev/null \
            && log OK "Firewall: puertos pasivos 40000-40100/tcp abiertos."
        firewall-cmd --reload &>/dev/null \
            && log OK "Firewall: reglas recargadas."
    else
        log WARN "firewalld no está activo. Abra los puertos 21 y 40000-40100/tcp manualmente."
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# GESTIÓN DE USUARIOS FTP
# ════════════════════════════════════════════════════════════════════════════

# ── Crear un usuario FTP individual ──────────────────────────────────────────
# Parámetros: <username> <password> <grupo:reprobados|recursadores>

create_ftp_user() {
    local username="$1"
    local password="$2"
    local group="$3"
    local user_jail="${USERS_ROOT}/${username}"
    local group_dir

    [[ "$group" == "$GRP_REPROBADOS" ]] \
        && group_dir="$REPROBADOS_DIR" \
        || group_dir="$RECURSADORES_DIR"

    line
    echo -e "  Creando usuario ${BOLD}${username}${NC}  |  grupo: ${YELLOW}${group}${NC}"

    # ── 1. Usuario del sistema ────────────────────────────────────────────
    if user_exists "$username"; then
        log WARN "Usuario '$username' ya existe — actualizando contraseña y grupos."
        echo "${username}:${password}" | chpasswd
        usermod -aG "${group},${GRP_FTP}" "$username" 2>/dev/null || true
    else
        # -M: sin home automático   -s: shell nologin (FTP sí, SSH no)
        # -d: directorio home (=jail root, se crea manualmente con permisos root)
        # -G: grupos suplementarios
        useradd -M -s /sbin/nologin \
                -d "$user_jail"     \
                -G "${group},${GRP_FTP}" \
                "$username"
        echo "${username}:${password}" | chpasswd
        log OK "Usuario del sistema '${username}' creado (shell: /sbin/nologin)."
    fi

    # ── 2. Estructura del chroot jail ─────────────────────────────────────
    # La raíz del jail DEBE pertenecer a root y NO ser escribible por el usuario;
    # de lo contrario vsftpd rechaza el login (incluso con allow_writeable_chroot=YES
    # cuando las condiciones no se cumplen).
    mkdir -p "$user_jail"
    chown root:root "$user_jail"
    chmod 755       "$user_jail"

    # Punto de montaje: general  (bind-mount de /srv/ftp/general)
    mkdir -p "${user_jail}/general"
    chown root:"$GRP_FTP" "${user_jail}/general"
    chmod 755             "${user_jail}/general"

    # Punto de montaje: grupo  (bind-mount de /srv/ftp/<grupo>)
    mkdir -p "${user_jail}/${group}"
    chown root:"$group"   "${user_jail}/${group}"
    chmod 755             "${user_jail}/${group}"

    # Directorio personal del usuario  (propietario y escritura exclusivos)
    mkdir -p "${user_jail}/${username}"
    chown "${username}:${group}" "${user_jail}/${username}"
    chmod 755                    "${user_jail}/${username}"

    log OK "Jail creado: ${user_jail}/"

    # ── 3. Bind mounts (registro en fstab + montaje inmediato) ────────────
    # general
    add_fstab_entry "$GENERAL_DIR" "${user_jail}/general"  "defaults,bind"
    mount_bind      "$GENERAL_DIR" "${user_jail}/general"

    # grupo
    add_fstab_entry "$group_dir"   "${user_jail}/${group}" "defaults,bind"
    mount_bind      "$group_dir"   "${user_jail}/${group}"

    # ── 4. ACLs: garantizar escritura independientemente del umask ────────
    # Aunque los permisos de grupo (2775 + setgid) son suficientes,
    # añadimos ACLs individuales como capa extra de seguridad.
    if command -v setfacl &>/dev/null; then
        # Permisos directos (archivos y directorios existentes)
        setfacl -m  "u:${username}:rwx" "$GENERAL_DIR"  2>/dev/null || true
        setfacl -m  "u:${username}:rwx" "$group_dir"    2>/dev/null || true
        # Permisos predeterminados (archivos y directorios futuros)
        setfacl -dm "u:${username}:rwx" "$GENERAL_DIR"  2>/dev/null || true
        setfacl -dm "u:${username}:rwx" "$group_dir"    2>/dev/null || true
        log OK "ACLs configuradas para '${username}'."
    else
        log WARN "setfacl no disponible — los permisos de grupo (2775) son suficientes."
    fi

    log OK "Usuario FTP '${username}' listo."
    echo -e ""
    echo -e "  ${CYAN}Estructura visible al conectarse por FTP:${NC}"
    echo -e "  ${BOLD}/${NC}  (raíz del jail: ${user_jail}/)"
    echo -e "  ├── ${GREEN}general/${NC}       ← escritura R/W  (compartido)"
    echo -e "  ├── ${YELLOW}${group}/${NC}    ← escritura R/W  (su grupo)"
    echo -e "  └── ${CYAN}${username}/${NC}     ← directorio personal R/W"
    echo -e ""
}

# ── Creación masiva de usuarios (interactivo) ─────────────────────────────────

create_bulk_users() {
    sep
    echo -e "${BOLD}  Creación Masiva de Usuarios FTP${NC}"
    line

    # Validar que la estructura base exista
    if [[ ! -d "$USERS_ROOT" ]]; then
        log ERROR "La estructura base no está creada. Ejecute primero la opción 1 (Inicialización)."
        return 1
    fi

    local n
    while true; do
        read -rp "  ¿Cuántos usuarios desea crear? " n
        [[ "$n" =~ ^[1-9][0-9]*$ ]] && break
        echo -e "  ${RED}Ingrese un número entero positivo.${NC}"
    done

    for ((i = 1; i <= n; i++)); do
        line
        echo -e "  ${BOLD}── Usuario $i de $n ──${NC}"

        # Nombre de usuario
        local username
        while true; do
            read -rp "  Nombre de usuario      : " username
            [[ -z "$username" ]] \
                && { echo -e "  ${RED}El nombre no puede estar vacío.${NC}"; continue; }
            [[ "$username" =~ [^a-zA-Z0-9_-] ]] \
                && { echo -e "  ${RED}Solo se permiten: letras, números, guión bajo (_) y guión (-).${NC}"; continue; }
            user_exists "$username" \
                && { echo -e "  ${YELLOW}El usuario '$username' ya existe. Ingrese otro.${NC}"; continue; }
            break
        done

        # Contraseña (sin confirmación, según especificación)
        local password
        read -rsp "  Contraseña             : " password; echo

        # Grupo
        local group
        while true; do
            echo -e "  Asignar grupo:"
            echo -e "    ${CYAN}1${NC}) reprobados"
            echo -e "    ${CYAN}2${NC}) recursadores"
            read -rp "  Selección [1/2]: " gc
            case "$gc" in
                1) group="$GRP_REPROBADOS";  break ;;
                2) group="$GRP_RECURSADORES"; break ;;
                *) echo -e "  ${RED}Opción inválida. Elija 1 o 2.${NC}" ;;
            esac
        done

        create_ftp_user "$username" "$password" "$group"
    done

    systemctl restart vsftpd 2>/dev/null \
        && log OK "vsftpd reiniciado tras la creación de usuarios." \
        || log WARN "No se pudo reiniciar vsftpd automáticamente."
}

# ── Terminar sesiones FTP activas de un usuario ──────────────────────────────
# vsftpd genera un proceso hijo por cada sesión autenticada.
# Matarlo libera el bind-mount del directorio de grupo para poder desmontarlo.

kill_user_ftp_sessions() {
    local username="$1"
    # Buscar PIDs de vsftpd cuyo usuario efectivo (euid) sea el indicado
    local pids
    pids=$(ps -eo pid,euser,comm 2>/dev/null \
           | awk -v u="$username" '$2==u && $3~/vsftpd/{print $1}')

    if [[ -z "$pids" ]]; then
        log INFO "No hay sesiones FTP activas para '${username}'."
        return 0
    fi

    log WARN "Sesión FTP activa detectada para '${username}' — terminando proceso(s): ${pids}"
    # SIGTERM primero; si sigue vivo tras 2 s, SIGKILL
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    done
    log OK "Sesiones FTP de '${username}' terminadas."
}

change_user_group() {
    sep
    echo -e "${BOLD}  Cambio de Grupo de Usuario FTP${NC}"
    line
    list_ftp_users

    local username
    read -rp "  Usuario a reasignar de grupo: " username
    if ! user_exists "$username"; then
        log ERROR "El usuario '$username' no existe."; return 1
    fi

    # Detectar grupo actual (reprobados o recursadores)
    local old_group=""
    if id -nG "$username" 2>/dev/null | grep -qw "$GRP_REPROBADOS"; then
        old_group="$GRP_REPROBADOS"
    elif id -nG "$username" 2>/dev/null | grep -qw "$GRP_RECURSADORES"; then
        old_group="$GRP_RECURSADORES"
    fi

    if [[ -z "$old_group" ]]; then
        log ERROR "No se pudo determinar el grupo FTP actual de '$username'."; return 1
    fi

    echo -e "  Grupo actual: ${YELLOW}${old_group}${NC}"

    local new_group
    while true; do
        echo -e "  Nuevo grupo:"
        echo -e "    ${CYAN}1${NC}) reprobados"
        echo -e "    ${CYAN}2${NC}) recursadores"
        read -rp "  Selección [1/2]: " gc
        case "$gc" in
            1) new_group="$GRP_REPROBADOS";  break ;;
            2) new_group="$GRP_RECURSADORES"; break ;;
            *) echo -e "  ${RED}Opción inválida.${NC}" ;;
        esac
    done

    if [[ "$old_group" == "$new_group" ]]; then
        log WARN "El usuario '$username' ya pertenece a '$new_group'. Sin cambios."
        return
    fi

    local old_dir new_dir user_jail="${USERS_ROOT}/${username}"
    [[ "$old_group" == "$GRP_REPROBADOS" ]] && old_dir="$REPROBADOS_DIR" || old_dir="$RECURSADORES_DIR"
    [[ "$new_group" == "$GRP_REPROBADOS" ]] && new_dir="$REPROBADOS_DIR" || new_dir="$RECURSADORES_DIR"

    log INFO "Cambiando '${username}': ${old_group} → ${new_group}"

    # 1. Terminar sesiones FTP activas del usuario para liberar el bind-mount
    kill_user_ftp_sessions "$username"

    # 2. Desmontar y eliminar el bind-mount del grupo anterior
    umount_safe "${user_jail}/${old_group}"
    remove_fstab_entry "${user_jail}/${old_group}"
    # Forzar eliminación del directorio (rm -rf) incluso si rmdir falla por
    # algún archivo residual; el bind-mount ya fue desmontado en el paso anterior.
    if [[ -d "${user_jail}/${old_group}" ]]; then
        rm -rf "${user_jail}/${old_group}" \
            && log OK "Directorio '${old_group}' eliminado del jail." \
            || log WARN "No se pudo eliminar ${user_jail}/${old_group}."
    fi

    # 3. Actualizar membresía de grupos en el sistema
    gpasswd -d "$username" "$old_group" &>/dev/null \
        && log OK "Usuario removido del grupo '$old_group'." \
        || log WARN "No se pudo remover de '$old_group' (¿ya no era miembro?)."
    usermod -aG "$new_group" "$username" \
        && log OK "Usuario añadido al grupo '$new_group'."

    # 4. Crear punto de montaje del nuevo grupo y montar
    mkdir -p "${user_jail}/${new_group}"
    chown root:"$new_group" "${user_jail}/${new_group}"
    chmod 755               "${user_jail}/${new_group}"

    add_fstab_entry "$new_dir" "${user_jail}/${new_group}" "defaults,bind"
    mount_bind      "$new_dir" "${user_jail}/${new_group}"

    # 5. Actualizar ACLs: remover del directorio anterior, añadir al nuevo
    if command -v setfacl &>/dev/null; then
        setfacl -x "u:${username}"       "$old_dir"  2>/dev/null || true
        setfacl -m  "u:${username}:rwx"  "$new_dir"  2>/dev/null || true
        setfacl -dm "u:${username}:rwx"  "$new_dir"  2>/dev/null || true
        log OK "ACLs actualizadas."
    fi

    # 6. Actualizar grupo propietario del directorio personal
    chown "${username}:${new_group}" "${user_jail}/${username}" 2>/dev/null \
        && log OK "Propietario del directorio personal actualizado." \
        || true

    systemctl restart vsftpd 2>/dev/null || true
    log OK "Usuario '${username}' movido a '${new_group}' exitosamente."

    echo -e ""
    echo -e "  ${CYAN}Nueva estructura FTP de '${username}':${NC}"
    echo -e "  ├── general/"
    echo -e "  ├── ${new_group}/"
    echo -e "  └── ${username}/"
}

# ── Eliminar un usuario FTP ───────────────────────────────────────────────────

delete_ftp_user() {
    sep
    echo -e "${BOLD}  Eliminar Usuario FTP${NC}"
    line
    list_ftp_users

    local username
    read -rp "  Usuario a eliminar: " username
    if ! user_exists "$username"; then
        log ERROR "El usuario '$username' no existe."; return 1
    fi

    local confirm
    read -rp "$(echo -e "  ${RED}¿Confirmar eliminación de '${username}'? [s/N]: ${NC}")" confirm
    [[ "${confirm,,}" != "s" ]] && { log INFO "Operación cancelada."; return; }

    local user_jail="${USERS_ROOT}/${username}"

    # Desmontar todos los posibles bind-mounts del usuario
    for mnt in "general" "$GRP_REPROBADOS" "$GRP_RECURSADORES"; do
        umount_safe     "${user_jail}/${mnt}"
        remove_fstab_entry "${user_jail}/${mnt}"
    done

    # Eliminar usuario del sistema (sin borrar home; lo borramos manualmente)
    userdel "$username" 2>/dev/null \
        && log OK "Usuario del sistema '$username' eliminado." \
        || log WARN "userdel falló para '$username'."

    # Eliminar el jail completo
    rm -rf "$user_jail" \
        && log OK "Jail '${user_jail}' eliminado."

    # Limpiar ACLs en directorios compartidos
    if command -v setfacl &>/dev/null; then
        setfacl -x "u:${username}" "$GENERAL_DIR"      2>/dev/null || true
        setfacl -x "u:${username}" "$REPROBADOS_DIR"   2>/dev/null || true
        setfacl -x "u:${username}" "$RECURSADORES_DIR" 2>/dev/null || true
        log OK "ACLs del usuario '${username}' eliminadas."
    fi

    systemctl restart vsftpd 2>/dev/null || true
    log OK "Usuario FTP '${username}' eliminado completamente."
}

# ── Listar usuarios FTP registrados ──────────────────────────────────────────

list_ftp_users() {
    line
    echo -e "  ${BOLD}${CYAN}Usuarios FTP registrados${NC}"
    printf "  ${BOLD}%-22s %-18s %-12s${NC}\n" "Usuario" "Grupo FTP" "Shell"
    line

    local count=0

    if [[ -d "$USERS_ROOT" ]]; then
        for dir in "${USERS_ROOT}"/*/; do
            [[ -d "$dir" ]] || continue
            local uname; uname=$(basename "$dir")
            user_exists "$uname" || continue

            # Determinar grupo FTP
            local grp="(sin grupo)"
            id -nG "$uname" 2>/dev/null | grep -qw "$GRP_REPROBADOS"  && grp="$GRP_REPROBADOS"
            id -nG "$uname" 2>/dev/null | grep -qw "$GRP_RECURSADORES" && grp="$GRP_RECURSADORES"

            local shell; shell=$(getent passwd "$uname" | cut -d: -f7)
            printf "  ${GREEN}%-22s${NC} ${YELLOW}%-18s${NC} %-12s\n" "$uname" "$grp" "$shell"
            ((count++))
        done
    fi

    line
    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}No hay usuarios FTP registrados aún.${NC}"
    else
        echo -e "  Total: ${BOLD}${count}${NC} usuario(s)"
    fi
}

# ── Ver permisos y ACLs de los directorios compartidos ───────────────────────

show_permissions() {
    sep
    echo -e "${BOLD}  Permisos de directorios compartidos FTP${NC}"
    line

    for dir in "$GENERAL_DIR" "$REPROBADOS_DIR" "$RECURSADORES_DIR"; do
        [[ -d "$dir" ]] || continue
        echo -e "  ${CYAN}${dir}${NC}"
        ls -lad "$dir"
        if command -v getfacl &>/dev/null; then
            getfacl --omit-header "$dir" 2>/dev/null | sed 's/^/    /'
        fi
        echo
    done
}

# ════════════════════════════════════════════════════════════════════════════
# MENÚ PRINCIPAL
# ════════════════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        print_header
        echo -e "  ${BOLD}MENÚ PRINCIPAL${NC}"
        sep
        echo -e "  ${GREEN}1)${NC} Inicialización completa del servidor FTP"
        echo -e "     ${CYAN}↳ Instala vsftpd, crea grupos, directorios, configura SELinux y firewall${NC}"
        echo ""
        echo -e "  ${GREEN}2)${NC} Crear usuarios FTP  ${CYAN}(modo interactivo, creación masiva)${NC}"
        echo -e "  ${GREEN}3)${NC} Cambiar grupo de un usuario"
        echo -e "  ${GREEN}4)${NC} Listar usuarios FTP"
        echo -e "  ${GREEN}5)${NC} Eliminar usuario FTP"
        echo ""
        echo -e "  ${GREEN}6)${NC} Reiniciar servicio vsftpd"
        echo -e "  ${GREEN}7)${NC} Estado del servicio vsftpd"
        echo -e "  ${GREEN}8)${NC} Ver permisos y ACLs de directorios compartidos"
        echo -e "  ${GREEN}9)${NC} Actualizar pasv_address  ${CYAN}(cambió la IP del servidor)${NC}"
        echo ""
        echo -e "  ${RED}0)${NC} Salir"
        sep
        read -rp "  Selección: " opt

        case "$opt" in
            1)
                install_vsftpd
                create_groups
                create_base_dirs
                configure_vsftpd
                configure_security
                echo ""
                sep
                log OK "══ Servidor FTP inicializado correctamente ══"
                echo -e "  Próximo paso: use la opción 2 para crear usuarios."
                sep
                pause
                ;;
            2) create_bulk_users;   pause ;;
            3) change_user_group;   pause ;;
            4) list_ftp_users;      pause ;;
            5) delete_ftp_user;     pause ;;
            6)
                sep
                systemctl restart vsftpd 2>/dev/null \
                    && log OK "vsftpd reiniciado." \
                    || log ERROR "No se pudo reiniciar vsftpd."
                pause
                ;;
            7)
                sep
                echo -e "${BOLD}  systemctl status vsftpd${NC}"
                line
                systemctl status vsftpd --no-pager || true
                sep
                pause
                ;;
            8) show_permissions;     pause ;;
            9) update_pasv_address;  pause ;;
            0)
                echo -e "${GREEN}  Saliendo...${NC}"
                exit 0
                ;;
            *)
                echo -e "  ${RED}Opción inválida. Elija un número del menú.${NC}"
                sleep 1
                ;;
        esac
    done
}

# ════════════════════════════════════════════════════════════════════════════
# PUNTO DE ENTRADA
# ════════════════════════════════════════════════════════════════════════════

check_root
touch "$LOG_FILE" 2>/dev/null || true
main_menu
