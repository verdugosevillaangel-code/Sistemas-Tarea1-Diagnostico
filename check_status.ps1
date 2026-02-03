Clear-Host
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      REPORTE DE ESTADO DEL NODO        " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "Nombre del equipo : $env:COMPUTERNAME"

$IP = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.10.*" } | Select-Object -ExpandProperty IPAddress
Write-Host "IP Red Interna    : $($IP -join ', ')"

$Disk = Get-PSDrive C
$FreeGB = [math]::Round($Disk.Free / 1GB, 2)
$UsedGB = [math]::Round($Disk.Used / 1GB, 2)
$TotalGB = [math]::Round(($Disk.Used + $Disk.Free) / 1GB, 2)

Write-Host "Espacio en disco (C:):"
# Aquí estaba el error, ahora está corregido:
Write-Host "   Total: $TotalGB GB | Usado: $UsedGB GB | Libre: $FreeGB GB"
Write-Host "=========================================="
