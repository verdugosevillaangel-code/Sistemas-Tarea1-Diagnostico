#!/bin/bash

DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$DIR/dns_core.sh"

[ -f "$LIB" ] || { echo "No se encontro la libreria DNS."; exit 1; }

source "$LIB"

[ "$EUID" -ne 0 ] && { echo "Ejecutar como root."; exit 1; }

while true; do
    clear
    echo "MENU DNS"
    echo "1 Instalar Bind"
    echo "2 Crear dominio"
    echo "3 Borrar dominio"
    echo "4 Listar dominios"
    echo "5 Probar resolucion"
    echo "6 Regresar"
    read -p "Opcion: " op

    case $op in
        1) instalar_dns ;;
        2) crear_zona ;;
        3) borrar_zona ;;
        4) mostrar_zonas ;;
        5) test_dns ;;
        6) exit ;;
    esac
done