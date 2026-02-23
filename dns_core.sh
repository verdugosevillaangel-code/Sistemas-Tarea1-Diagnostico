#!/bin/bash

IFACE="enp0s8"
MAIN_CONF="/etc/named.conf"
ZONES_FILE="/etc/named.extra.conf"
DIR_ZONES="/var/named"
SERVER_IP=""

pause_screen() {
    read -p "Enter para continuar..."
}

detectar_ip_actual() {
    SERVER_IP=$(nmcli -g IP4.ADDRESS device show $IFACE | head -n1 | cut -d/ -f1)
}

validar_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r a b c d <<< "$ip"
    for n in $a $b $c $d; do
        [ "$n" -le 255 ] || return 1
    done
    case "$ip" in
        0.0.0.0|127.0.0.1|255.255.255.255) return 1 ;;
    esac
    return 0
}

instalar_dns() {

    clear
    echo "Instalando o verificando Bind..."

    if ! rpm -q bind >/dev/null 2>&1; then
        dnf install -y bind bind-utils >/dev/null 2>&1
    fi

    if [ ! -f "${MAIN_CONF}.bak" ]; then
        cp $MAIN_CONF "${MAIN_CONF}.bak"
    fi

    sed -i 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/' $MAIN_CONF
    sed -i 's/allow-query     { localhost; };/allow-query     { any; };/' $MAIN_CONF

    if [ ! -f "$ZONES_FILE" ]; then
        touch $ZONES_FILE
        chown root:named $ZONES_FILE
        chmod 640 $ZONES_FILE
    fi

    grep -q "$ZONES_FILE" $MAIN_CONF || echo "include \"$ZONES_FILE\";" >> $MAIN_CONF

    systemctl enable named --now >/dev/null 2>&1

    firewall-cmd --add-service=dns --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

    detectar_ip_actual

    if [ -z "$SERVER_IP" ]; then
        echo "No se detecto IP en la interfaz."
        pause_screen
        return
    fi

    echo ""
    echo "Forzando DNS local como unico nameserver: $SERVER_IP"

    nmcli con mod "$IFACE" ipv4.ignore-auto-dns yes >/dev/null 2>&1
    nmcli con mod "$IFACE" ipv4.dns "$SERVER_IP" >/dev/null 2>&1
    nmcli con mod "$IFACE" ipv4.method manual >/dev/null 2>&1

    nmcli con down "$IFACE" >/dev/null 2>&1
    nmcli con up "$IFACE" >/dev/null 2>&1

    sleep 2

    echo ""
    echo "Contenido actual de /etc/resolv.conf:"
    cat /etc/resolv.conf

    pause_screen
}

crear_zona() {

    clear
    detectar_ip_actual

    if [ -z "$SERVER_IP" ]; then
        echo "No hay IP detectada."
        pause_screen
        return
    fi

    read -p "Dominio: " DOM

    if grep -q "zone \"$DOM\"" $ZONES_FILE; then
        echo "El dominio ya existe."
        pause_screen
        return
    fi

    FILE="$DIR_ZONES/db.$DOM"

cat <<EOF > $FILE
\$TTL 60
@ IN SOA ns1.$DOM. root.$DOM. (
1 1D 1H 1W 3H )
@ IN NS ns1.$DOM.
@ IN A $SERVER_IP
ns1 IN A $SERVER_IP
www IN A $SERVER_IP
EOF

    chown root:named $FILE

cat <<EOF >> $ZONES_FILE
zone "$DOM" IN {
type master;
file "$FILE";
};
EOF

    if named-checkconf >/dev/null 2>&1; then
        systemctl reload named
        echo "Dominio agregado correctamente."
    else
        echo "Error en configuracion de Bind."
    fi

    pause_screen
}

borrar_zona() {

    clear
    read -p "Dominio a eliminar: " DOM

    if ! grep -q "zone \"$DOM\"" $ZONES_FILE; then
        echo "No existe ese dominio."
        pause_screen
        return
    fi

    sed -i "/zone \"$DOM\"/,/};/d" $ZONES_FILE
    rm -f "$DIR_ZONES/db.$DOM"

    # Limpiar cache del servidor DNS
    rndc flush >/dev/null 2>&1

    if named-checkconf >/dev/null 2>&1; then
        systemctl reload named
        echo "Dominio eliminado."
    else
        echo "Error al actualizar configuracion."
    fi

    pause_screen
}

mostrar_zonas() {

    clear
    if [ -f "$ZONES_FILE" ]; then
        grep zone $ZONES_FILE | cut -d\" -f2
    else
        echo "No hay dominios creados."
    fi

    pause_screen
}

test_dns() {

    clear
    detectar_ip_actual

    read -p "Dominio a probar: " DOM

    echo ""
    echo "Consulta directa contra el DNS local ($SERVER_IP)"
    echo ""

    nslookup $DOM $SERVER_IP

    echo ""
    echo "Ping contra el dominio configurado localmente"
    ping -c 2 $DOM

    pause_screen
}