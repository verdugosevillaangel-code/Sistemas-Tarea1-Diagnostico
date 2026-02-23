#!/bin/bash

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DNS_MENU="$BASE_DIR/dns_menu3.sh"

CONF_FILE="/etc/dhcp/dhcpd.conf"
DEFAULT_IF="enp0s8"

pause_screen() {
    read -p "Enter para continuar..."
}

ip_valida() {
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

obtener_mascara() {
    local o1=$(echo $1 | cut -d. -f1)
    if [ $o1 -lt 128 ]; then echo "255.0.0.0 8"
    elif [ $o1 -lt 192 ]; then echo "255.255.0.0 16"
    else echo "255.255.255.0 24"
    fi
}

instalar_servicio() {
    dnf install -y dhcp-server >/dev/null 2>&1
    echo "Paquete instalado."
    pause_screen
}

estado_servicio() {
    rpm -q dhcp-server
    pause_screen
}

configurar_servicio() {

    echo "Interfaces disponibles:"
    nmcli device status | awk 'NR>1 {print $1}'

    read -p "Interfaz [$DEFAULT_IF]: " IFACE
    [ -z "$IFACE" ] && IFACE=$DEFAULT_IF

    while true; do
        read -p "IP del servidor: " IP_SERVER
        ip_valida "$IP_SERVER" && break
        echo "IP invalida."
    done

    read MASK CIDR <<< $(obtener_mascara $IP_SERVER)

    IFS='.' read -r i1 i2 i3 i4 <<< "$IP_SERVER"
    if [ "$CIDR" = "8" ]; then NET="$i1.0.0.0"
    elif [ "$CIDR" = "16" ]; then NET="$i1.$i2.0.0"
    else NET="$i1.$i2.$i3.0"
    fi

    RANGE_START="$i1.$i2.$i3.$((i4+1))"

    while true; do
        read -p "IP final del rango: " RANGE_END
        ip_valida "$RANGE_END" && break
        echo "IP invalida."
    done

    read -p "Tiempo lease (segundos): " TIME_LEASE
    read -p "Gateway (opcional): " GW
    read -p "DNS (opcional): " DNS

    CON=$(nmcli -t -f NAME,DEVICE con show --active | grep $IFACE | cut -d: -f1)
    [ -z "$CON" ] && CON=$IFACE

    nmcli con mod "$CON" ipv4.addresses "$IP_SERVER/$CIDR" ipv4.method manual >/dev/null 2>&1
    [ -n "$GW" ] && nmcli con mod "$CON" ipv4.gateway "$GW" >/dev/null 2>&1
    nmcli con down "$CON" >/dev/null 2>&1
    nmcli con up "$CON" >/dev/null 2>&1

cat > $CONF_FILE <<EOF
default-lease-time $TIME_LEASE;
max-lease-time $TIME_LEASE;
authoritative;

subnet $NET netmask $MASK {
  range $RANGE_START $RANGE_END;
EOF

    [ -n "$GW" ] && echo "  option routers $GW;" >> $CONF_FILE
    [ -n "$DNS" ] && echo "  option domain-name-servers $DNS;" >> $CONF_FILE

    echo "}" >> $CONF_FILE

    systemctl enable dhcpd >/dev/null 2>&1
    systemctl restart dhcpd

    firewall-cmd --add-service=dhcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

    echo "DHCP configurado."
    pause_screen
}

ver_clientes() {
    systemctl status dhcpd --no-pager | grep Active
    [ -f /var/lib/dhcpd/dhcpd.leases ] && grep lease /var/lib/dhcpd/dhcpd.leases
    pause_screen
}

while true; do
    clear
    echo "MENU DHCP"
    echo "1 Instalar"
    echo "2 Verificar"
    echo "3 Configurar"
    echo "4 Ver leases"
    echo "5 Ir a DNS"
    echo "6 Salir"
    read -p "Opcion: " op

    case $op in
        1) instalar_servicio ;;
        2) estado_servicio ;;
        3) configurar_servicio ;;
        4) ver_clientes ;;
        5) bash "$DNS_MENU" ;;
        6) exit ;;
    esac
done