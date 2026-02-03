#!/bin/bash

echo "=========================================="
echo "      REPORTE DE ESTADO DEL SISTEMA       "
echo "=========================================="

echo "Nombre del equipo : $(hostname)"

IP_INTERNA=$(ip -4 addr show enp0s8 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "IP Red Interna    : ${IP_INTERNA:-'No asignada'}"
echo "Espacio en disco  :"
df -h / | awk 'NR==2 {printf "   Total: %s | Usado: %s | Disponible: %s\n", $2, $3, $4}'
echo "=========================================="
