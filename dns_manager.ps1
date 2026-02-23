# =============================================================================
# Script: dns_manager.ps1
# =============================================================================
$CurrentDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$LibPath = Join-Path -Path $CurrentDir -ChildPath "dns_functions.ps1"

if (-not (Test-Path $LibPath)) { Write-Host "Falta dns_functions.ps1"; exit }
. $LibPath

while ($true) {
    Clear-Host
    Write-Host "--- MENU DNS ---" -ForegroundColor Green
    Write-Host "1. Instalar DNS"
    Write-Host "2. Crear Dominio (Zona)"
    Write-Host "3. Borrar Dominio"
    Write-Host "4. Listar Dominios"
    Write-Host "5. Probar Resolucion"
    Write-Host "6. Volver a DHCP"
    
    $op = Read-Host "Selecciona"
    switch ($op) {
        '1' { Install-DnsRole }
        '2' { New-DnsZoneAction }
        '3' { Remove-DnsZoneAction }
        '4' { Get-DnsZonesList }
        '5' { Test-DnsResolution }
        '6' { return }
    }
}