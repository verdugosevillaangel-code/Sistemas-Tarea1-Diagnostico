$ErrorActionPreference = "Stop"

# --- UTILIDADES DE SISTEMA ---

function Invocar-Pausa {
    Write-Host ""
    Read-Host "Presione la tecla Enter para continuar..."
}

function Obtener-Mascara {
    param([string]$DireccionIP)
    $octeto = [int]($DireccionIP.Split('.')[0])
    if ($octeto -lt 128) { return "255.0.0.0" }
    if ($octeto -lt 192) { return "255.255.0.0" }
    return "255.255.255.0"
}

function Incrementar-IP {
    param([string]$IP)
    try {
        $bloques = $IP.Split('.')
        $ultimo = [int]$bloques[3] + 1
        if ($ultimo -gt 254) { throw "Limite de segmento alcanzado" }
        return "$($bloques[0]).$($bloques[1]).$($bloques[2]).$ultimo"
    } catch {
        return $null
    }
}

function Test-FormatoIP {
    param([string]$IP, [bool]$VacioPermitido = $false)
    
    $IP = $IP.Trim()
    if ([string]::IsNullOrWhiteSpace($IP)) { return $VacioPermitido }
    
    $prohibidas = @("0.0.0.0", "127.0.0.1", "255.255.255.255")
    if ($prohibidas -contains $IP) { 
        Write-Host "Error: La IP $IP es una direccion reservada."
        return $false 
    }

    if ($IP -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        $segmentos = $IP.Split('.')
        foreach ($s in $segmentos) { 
            if ([int]$s -lt 0 -or [int]$s -gt 255) { return $false } 
        }
        return $true
    }
    return $false
}

# --- LOGICA ---

function Tarea-Instalar {
    Write-Host "--- GESTION DE ROL DHCP ---"
    $estado = Get-WindowsFeature -Name DHCP
    
    if ($estado.Installed) {
        Write-Host "El servidor ya cuenta con el rol DHCP."
        $confirmar = Read-Host "Desea realizar una REINSTALACION completa? (S/N)"
        if ($confirmar.ToUpper() -eq 'S') {
            Write-Host "Removiendo caracteristicas..."
            Uninstall-WindowsFeature -Name DHCP -Remove -IncludeManagementTools
            Write-Host "Instalando caracteristicas nuevamente..."
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
        } else {
            return
        }
    } else {
        Write-Host "Iniciando instalacion de DHCP..."
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
    }
    
    Write-Host "Configurando grupos de seguridad y reiniciando servicio..."
    Add-DhcpServerSecurityGroup
    Restart-Service dhcpserver
    Write-Host "Operacion finalizada correctamente."
    Invocar-Pausa
}

function Tarea-Verificar {
    Write-Host "--- ESTADO DEL ROL ---"
    $check = Get-WindowsFeature -Name DHCP
    $status = if ($check.Installed) { "INSTALADO" } else { "NO ENCONTRADO" }
    Write-Host "Resultado: $status"
    Write-Host "Detalle de instalacion: $($check.InstallState)"
    Invocar-Pausa
}

function Tarea-Configurar {
    Write-Host "--- PARAMETRIZACION DE AMBITO ---"
    
    $red = Get-NetAdapter | Where-Object Status -eq 'Up'
    $red | Select-Object Name, InterfaceDescription, LinkSpeed | Format-Table
    $nombreIface = (Read-Host "Escriba el nombre de la interfaz").Trim()
    
    if (-not (Get-NetAdapter -Name $nombreIface -ErrorAction SilentlyContinue)) {
        Write-Host "Error: Interfaz no valida."; Invocar-Pausa; return
    }

    $idAmbito = Read-Host "Descripcion del ambito"
    
    do { 
        $ipBase = (Read-Host "IP del Servidor").Trim()
    } while (-not (Test-FormatoIP $ipBase))

    $mascara = Obtener-Mascara $ipBase
    $inicioRango = Incrementar-IP $ipBase
    
    Write-Host "Informacion automatica:"
    Write-Host "Mascara: $mascara | Inicio de pool: $inicioRango"

    do {
        $finRango = (Read-Host "IP Final del pool").Trim()
        $esValido = (Test-FormatoIP $finRango) -and ([version]$finRango -ge [version]$inicioRango)
    } while (-not $esValido)

    do {
        $segundosLease = Read-Host "Segundos de concesion"
    } while ($segundosLease -notmatch "^\d+$")

    do { 
        $puertaEnlace = (Read-Host "Puerta de enlace (Opcional)").Trim()
    } while (-not (Test-FormatoIP $puertaEnlace $true))
    
    do { 
        $servidorDns = (Read-Host "Servidor DNS (Opcional)").Trim()
    } while (-not (Test-FormatoIP $servidorDns $true))

    try {
        Write-Host "Paso 1: Asignando direccion estática a $nombreIface..."
        $prefijo = switch ($mascara) { "255.0.0.0" {8} "255.255.0.0" {16} Default {24} }
        
        Remove-NetIPAddress -InterfaceAlias $nombreIface -Confirm:$false -ErrorAction SilentlyContinue
        
        $configIP = @{
            InterfaceAlias = $nombreIface
            IPAddress      = $ipBase
            PrefixLength   = $prefijo
        }
        if ($puertaEnlace) { $configIP.Add("DefaultGateway", $puertaEnlace) }
        New-NetIPAddress @configIP -ErrorAction Stop
        
        Write-Host "Paso 2: Generando nuevo ambito DHCP..."
        Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
        
        Add-DhcpServerv4Scope -Name $idAmbito -StartRange $inicioRango -EndRange $finRango -SubnetMask $mascara -LeaseDuration (New-TimeSpan -Seconds $segundosLease) -State Active

        Write-Host "Paso 3: Estableciendo opciones globales..."
        if ($puertaEnlace) { Set-DhcpServerv4OptionValue -OptionId 3 -Value $puertaEnlace }
        if ($servidorDns) { Set-DhcpServerv4OptionValue -OptionId 6 -Value $servidorDns }

        Restart-Service dhcpserver
        Write-Host "La configuracion se ha aplicado exitosamente."
    } catch {
        Write-Host "Fallo en el despliegue: $($_.Exception.Message)"
    }
    Invocar-Pausa
}

function Tarea-Diagnostico {
    Write-Host "--- MONITOR DE SERVICIOS Y CONCESIONES ---"
    
    Write-Host "[Servicio Windows]"
    Get-Service dhcpserver | Format-List Status, Name

    Write-Host "[Ambitos Configurados]"
    Get-DhcpServerv4Scope | Select-Object ScopeId, State, StartRange, EndRange | Format-Table

    Write-Host "[Clientes Conectados]"
    try {
        $actualScope = Get-DhcpServerv4Scope -ErrorAction Stop
        $concesiones = Get-DhcpServerv4Lease -ScopeId $actualScope.ScopeId
        if ($concesiones) {
            $concesiones | Select-Object IPAddress, HostName, LeaseExpiryTime | Format-Table
        } else {
            Write-Host "No se encuentran clientes con IP asignada."
        }
    } catch {
        Write-Host "Sin datos de ambitos activos."
    }
    Invocar-Pausa
}

# --- FLUJO PRINCIPAL ---

do {
    Write-Host "------------------------------------------"
    Write-Host "    ADMINISTRADOR DHCP SERVER CORE"
    Write-Host "------------------------------------------"
    Write-Host "1. Instalar o reinstalar rol"
    Write-Host "2. Ver estado de instalacion"
    Write-Host "3. Definir nueva configuracion"
    Write-Host "4. Ver clientes y estado"
    Write-Host "5. Salir"
    Write-Host "------------------------------------------"
    
    $seleccion = Read-Host "Elija una opcion"
    switch ($seleccion) {
        '1' { Tarea-Instalar }
        '2' { Tarea-Verificar }
        '3' { Tarea-Configurar }
        '4' { Tarea-Diagnostico }
        '5' { Write-Host "Cerrando programa..." }
        Default { Write-Host "Entrada no reconocida." ; Start-Sleep -Seconds 1 }
    }
} until ($seleccion -eq '5')