# =============================================================================
# Script: dns_functions.ps1
# =============================================================================
$IFACE = "Ethernet"

Function Get-DetectedIP {
    # Filtra y obtiene la IP real, ignorando la 169.254.x.x
    $ip = Get-NetIPAddress -InterfaceAlias $IFACE -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "169.254.*" }
    return $ip.IPAddress | Select-Object -First 1
}

Function Install-DnsRole {
    Write-Host "Instalando DNS y abriendo puertos..." -ForegroundColor Yellow
    Install-WindowsFeature DNS -IncludeManagementTools | Out-Null
    Start-Service dns
    Set-Service dns -StartupType Automatic
    
    # Apertura de firewall por puerto (Soluciona error ObjectNotFound)
    New-NetFirewallRule -DisplayName "DNS-TCP-In" -Direction Inbound -LocalPort 53 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "DNS-UDP-In" -Direction Inbound -LocalPort 53 -Protocol UDP -Action Allow -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName "ICMP-In" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow -ErrorAction SilentlyContinue | Out-Null

    # Apuntar el resolver local a sí mismo
    Set-DnsClientServerAddress -InterfaceAlias $IFACE -ServerAddresses "127.0.0.1"
    Write-Host "DNS listo." -ForegroundColor Green
    Read-Host "Enter..."
}

Function New-DnsZoneAction {
    $IP = Get-DetectedIP
    if (!$IP) { Write-Host "Error: No hay IP real. Configura DHCP primero (Opcion 3)." -ForegroundColor Red; return }
    
    $DOM = Read-Host "Nombre del dominio (ej. letisia.com)"
    if (Get-DnsServerZone -Name $DOM -ErrorAction SilentlyContinue) { Remove-DnsServerZone -Name $DOM -Force }
    
    Add-DnsServerPrimaryZone -Name $DOM -ZoneFile "$DOM.dns"
    Add-DnsServerResourceRecordA -Name "@" -ZoneName $DOM -IPv4Address $IP
    Add-DnsServerResourceRecordA -Name "www" -ZoneName $DOM -IPv4Address $IP
    Add-DnsServerResourceRecordA -Name "ns1" -ZoneName $DOM -IPv4Address $IP
    
    Write-Host "Zona $DOM creada apuntando a $IP" -ForegroundColor Green
    Read-Host "Enter..."
}

Function Get-DnsZonesList {
    Get-DnsServerZone | Where-Object { $_.ZoneName -notlike "..*" } | Select-Object ZoneName | Format-Table
    Read-Host "Enter..."
}

Function Test-DnsResolution {
    $DOM = Read-Host "Dominio a probar"
    Resolve-DnsName -Name $DOM -Server 127.0.0.1
    Read-Host "Enter..."
}

Function Remove-DnsZoneAction {
    $DOM = Read-Host "Nombre del dominio a eliminar"
    
    if (Get-DnsServerZone -Name $DOM -ErrorAction SilentlyContinue) {
        # 1. Borrar la zona
        Remove-DnsServerZone -Name $DOM -Force
        
        # 2. LIMPIAR CACHÉ DEL SERVIDOR (Paso nuevo)
        Clear-DnsServerCache -Force
        
        Write-Host "Dominio $DOM eliminado y cache del servidor limpia." -ForegroundColor Yellow
    } else {
        Write-Host "El dominio no existe." -ForegroundColor Red
    }
    Pause-Screen
}