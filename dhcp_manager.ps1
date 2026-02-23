# =============================================================================
# Script: dhcp_manager.ps1
# =============================================================================
$BaseDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
$DnsMenu = Join-Path -Path $BaseDir -ChildPath "dns_manager.ps1"

Function Pause-Screen { Write-Host ""; Read-Host "Presiona Enter para continuar..." }

Function Test-ValidIP {
    param([string]$IP)
    return $IP -match "^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
}

Function Set-ServiceConfig {
    Clear-Host
    $IFACE = "Ethernet 2" # Adaptador para Red Interna
    
    $INPUT_START = Read-Host "IP inicial del rango (El servidor tomara esta IP)"
    if (-not (Test-ValidIP $INPUT_START)) { Write-Host "IP Invalida"; return }
    
    $RANGE_END = Read-Host "IP final del rango"
    $TIME_LEASE_SEC = Read-Host "Tiempo lease (segundos) [3600]"
    if ([string]::IsNullOrWhiteSpace($TIME_LEASE_SEC)) { $TIME_LEASE_SEC = 3600 }
    
    $GW = Read-Host "Gateway (opcional)"
    $DNS = Read-Host "DNS (opcional)"

    # --- LOGICA DE INCREMENTO ---
    # 1. Asignar la IP ingresada al Servidor
    $ServerIP = $INPUT_START
    
    # 2. Calcular el inicio del rango DHCP (ServerIP + 1)
    $octets = $INPUT_START.Split('.')
    $lastOctet = [int]$octets[3]
    $newStartOctet = $lastOctet + 1
    $DHCP_START = "$($octets[0]).$($octets[1]).$($octets[2]).$newStartOctet"
    
    # Red para el Scope
    $NET = "$($octets[0]).$($octets[1]).$($octets[2]).0"
    
    Write-Host "Configurando servidor en $IFACE con IP: $ServerIP..." -ForegroundColor Yellow
    Remove-NetIPAddress -InterfaceAlias $IFACE -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $IFACE -IPAddress $ServerIP -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null

    # Configuración de Ambito DHCP (Empieza en IP+1)
    if (Get-DhcpServerv4Scope -ScopeId $NET -ErrorAction SilentlyContinue) { Remove-DhcpServerv4Scope -ScopeId $NET -Force }
    Add-DhcpServerv4Scope -Name "RedLab" -StartRange $DHCP_START -EndRange $RANGE_END -SubnetMask "255.255.255.0" -State Active
    Set-DhcpServerv4Scope -ScopeId $NET -LeaseDuration (New-TimeSpan -Seconds $TIME_LEASE_SEC)

    # Opciones
    if (![string]::IsNullOrWhiteSpace($GW)) { Set-DhcpServerv4OptionValue -ScopeId $NET -Router $GW }
    $DnsToAssign = if (![string]::IsNullOrWhiteSpace($DNS)) { $DNS } else { $ServerIP }
    Set-DhcpServerv4OptionValue -ScopeId $NET -DnsServer $DnsToAssign

    # Firewall (Por puerto para evitar error de DisplayGroup)
    New-NetFirewallRule -DisplayName "DHCP-In" -Direction Inbound -LocalPort 67,68 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue | Out-Null

    Restart-Service dhcpserver
    Write-Host "LISTO: Servidor es $ServerIP. Los clientes empezaran desde $DHCP_START" -ForegroundColor Green
    Pause-Screen
}

# (Bucle de menú igual al anterior...)
while ($true) {
    Clear-Host
    Write-Host "--- MENU DHCP ---"
    Write-Host "1. Instalar Rol"
    Write-Host "2. Verificar Estado"
    Write-Host "3. Configurar Ambito (Logica IP+1)"
    Write-Host "4. Ver Clientes"
    Write-Host "5. Ir a DNS"
    Write-Host "6. Salir"
    $op = Read-Host "Selecciona"
    switch ($op) {
        '1' { Install-WindowsFeature DHCP -IncludeManagementTools; Pause-Screen }
        '2' { Get-Service dhcpserver; Pause-Screen }
        '3' { Set-ServiceConfig }
        '4' { Get-DhcpServerv4Scope | Get-DhcpServerv4Lease; Pause-Screen }
        '5' { if (Test-Path $DnsMenu) { & $DnsMenu } else { Write-Host "No se encuentra el menu DNS"; Pause-Screen } }
        '6' { exit }
    }
}