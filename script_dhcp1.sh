#!/bin/bash

# --- UTILIDADES DE SISTEMA ---

invocar_pausa() {
    echo ""
    read -p "Presione la tecla Enter para continuar..."
}

obtener_mascara() {
    local ip=$1
    local primer_octeto=$(echo $ip | cut -d. -f1)
    if [ $primer_octeto -lt 128 ]; then echo "255.0.0.0";
    elif [ $primer_octeto -lt 192 ]; then echo "255.255.0.0";
    else echo "255.255.255.0"; fi
}

test_formato_ip() {
    local ip=$1
    local vacio_permitido=$2
    
    if [[ -z "$ip" ]]; then
        [ "$vacio_permitido" = true ] && return 0 || return 1
    fi

    # Validacion de formato x.x.x.x
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# --- LOGICA ---

tarea_instalar() {
    echo "--- GESTION DE SERVICIO DHCP ---"
    if rpm -q dhcp-server &> /dev/null; then
        echo "El sistema ya cuenta con dhcp-server."
        read -p "Desea REINSTALAR el servicio? (s/n): " confirmar
        if [[ $confirmar == "s" || $confirmar == "S" ]]; then
            dnf remove -y dhcp-server
            dnf install -y dhcp-server
        else
            return
        fi
    else
        echo "Instalando dhcp-server..."
        dnf install -y dhcp-server
    fi
    echo "Operacion finalizada correctamente."
    invocar_pausa
}

tarea_verificar() {
    echo "--- ESTADO DEL ROL ---"
    if rpm -q dhcp-server &> /dev/null; then
        echo "Resultado: INSTALADO"
        systemctl is-active dhcpd &> /dev/null && echo "Estado: Activo" || echo "Estado: Inactivo"
    else
        echo "Resultado: NO ENCONTRADO"
    fi
    invocar_pausa
}

tarea_configurar() {
    echo "--- PARAMETRIZACION DE AMBITO ---"
    
    nmcli device status
    read -p "Escriba el nombre de la interfaz (ej. eth0): " nombre_iface
    
    read -p "Descripcion del ambito: " id_ambito
    
    while true; do
        read -p "IP del Servidor: " ip_base
        test_formato_ip "$ip_base" false && break
    done

    mascara=$(obtener_mascara "$ip_base")
    red=$(echo $ip_base | cut -d. -f1-3).0
    
    echo "Informacion automatica:"
    echo "Red: $red | Mascara: $mascara"

    while true; do
        read -p "IP Inicio del pool: " inicio_rango
        test_formato_ip "$inicio_rango" false && break
    done

    while true; do
        read -p "IP Final del pool: " fin_rango
        test_formato_ip "$fin_rango" false && break
    done

    read -p "Segundos de concesion (default 600): " segundos_lease
    segundos_lease=${segundos_lease:-600}

    read -p "Puerta de enlace (Opcional): " puerta_enlace
    read -p "Servidor DNS (Opcional): " servidor_dns

    echo "Aplicando configuracion..."
    
    # 1. Configurar IP Estatica mediante nmcli
    nmcli con modify "$nombre_iface" ipv4.addresses "$ip_base/24" ipv4.method manual
    nmcli con up "$nombre_iface"

    # 2. Generar archivo dhcpd.conf
    cat <<EOF > /etc/dhcp/dhcpd.conf
# Ambito: $id_ambito
subnet $red netmask $mascara {
  range $inicio_rango $fin_rango;
  default-lease-time $segundos_lease;
  max-lease-time 7200;
EOF

    [[ -n "$puerta_enlace" ]] && echo "  option routers $puerta_enlace;" >> /etc/dhcp/dhcpd.conf
    [[ -n "$servidor_dns" ]] && echo "  option domain-name-servers $servidor_dns;" >> /etc/dhcp/dhcpd.conf
    echo "}" >> /etc/dhcp/dhcpd.conf

    # 3. Reiniciar servicio y abrir firewall
    systemctl enable dhcpd
    systemctl restart dhcpd
    firewall-cmd --add-service=dhcp --permanent &> /dev/null
    firewall-cmd --reload &> /dev/null

    echo "La configuracion se ha aplicado exitosamente."
    invocar_pausa
}

tarea_diagnostico() {
    echo "--- MONITOR DE SERVICIOS Y CONCESIONES ---"
    echo "[Servicio DHCP]"
    systemctl status dhcpd | grep "Active:"
    
    echo -e "\n[Concesiones Activas]"
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        grep "lease" /var/lib/dhcpd/dhcpd.leases | sort | uniq
    else
        echo "No hay registro de concesiones aun."
    fi
    invocar_pausa
}

# --- FLUJO PRINCIPAL ---

while true; do
    clear
    echo "------------------------------------------"
    echo "    ADMINISTRADOR DHCP ALMALINUX 9"
    echo "------------------------------------------"
    echo "1. Instalar o reinstalar rol"
    echo "2. Ver estado de instalacion"
    echo "3. Definir nueva configuracion"
    echo "4. Ver clientes y estado"
    echo "5. Salir"
    echo "------------------------------------------"
    
    read -p "Elija una opcion: " seleccion
    case $seleccion in
        1) tarea_instalar ;;
        2) tarea_verificar ;;
        3) tarea_configurar ;;
        4) tarea_diagnostico ;;
        5) echo "Cerrando programa..."; exit 0 ;;
        *) echo "Entrada no reconocida."; sleep 1 ;;
    esac
done