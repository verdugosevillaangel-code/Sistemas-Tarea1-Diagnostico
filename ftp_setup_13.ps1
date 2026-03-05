#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ftp_setup.ps1 -- Automatizacion del Servidor FTP con IIS / FTP Service
    Plataforma : Windows Server 2019 Core
    Ejecucion  : powershell -ExecutionPolicy Bypass -File ftp_setup.ps1

.DESCRIPTION
    Equivalente PowerShell de ftp_setup.sh (vsftpd / Alma Linux 9).

    Caracteristicas:
      * Instalacion idempotente de Web-Server (IIS) + Web-FTP-Service
      * Acceso anonimo de solo lectura a /general  (IUSR, IIS_IUSRS)
      * Aislamiento de usuarios: cada usuario ve su propio "jail" via
        IIS FTP User Isolation  (LocalUser\<usuario>)
      * Grupos locales: ftp_users, reprobados, recursadores
      * Estructura visible al login FTP (equivalente al chroot jail Linux):
            /  (raiz del jail)
            +-- general\       <- R/W  (Virtual Directory -> C:\FTP\general)
            +-- reprobados\ o
            |   recursadores\  <- R/W  (Virtual Directory -> C:\FTP\<grupo>)
            +-- <usuario>\     <- R/W  (directorio personal)
      * Cambio de grupo: remueve Virtual Directory anterior, crea el nuevo,
        actualiza membresias y permisos NTFS (icacls / Set-Acl)
      * Reglas de autorizacion FTP via WebAdministration
      * Firewall de Windows: puerto 21 y rango pasivo 40000-40100
      * Log en C:\FTP\logs\ftp_setup.log
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
#  CONSTANTES
# ==============================================================================

$FTP_BASE         = 'C:\FTP'
$GENERAL_DIR      = "$FTP_BASE\general"
$REPROBADOS_DIR   = "$FTP_BASE\reprobados"
$RECURSADORES_DIR = "$FTP_BASE\recursadores"
$USERS_ROOT       = "$FTP_BASE\LocalUser"          # Ruta requerida por IIS FTP User Isolation
$LOG_FILE         = "$FTP_BASE\logs\ftp_setup.log"

$GRP_FTP          = 'ftp_users'
$GRP_REPROBADOS   = 'reprobados'
$GRP_RECURSADORES = 'recursadores'

$FTP_SITE_NAME    = 'FTPSite'
$FTP_SITE_PORT    = 21
$FTP_PASV_MIN     = 40000
$FTP_PASV_MAX     = 40100

# ==============================================================================
#  UTILIDADES: LOG, COLORES, SEPARADORES
# ==============================================================================

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR','OK')] [string]$Level,
        [string]$Message
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"

    # Escribir en archivo de log (no lanzar excepcion si el directorio no existe aun)
    try {
        if (-not (Test-Path (Split-Path $LOG_FILE))) {
            New-Item -ItemType Directory -Path (Split-Path $LOG_FILE) -Force | Out-Null
        }
        Add-Content -Path $LOG_FILE -Value $line -Encoding UTF8
    } catch { }

    # Mostrar en consola con color
    switch ($Level) {
        'INFO'  { Write-Host "  [INFO]  " -ForegroundColor Cyan    -NoNewline; Write-Host $Message }
        'WARN'  { Write-Host "  [AVISO] " -ForegroundColor Yellow  -NoNewline; Write-Host $Message }
        'ERROR' { Write-Host "  [ERROR] " -ForegroundColor Red     -NoNewline; Write-Host $Message }
        'OK'    { Write-Host "  [ OK ]  " -ForegroundColor Green   -NoNewline; Write-Host $Message }
    }
}

function Write-Sep  { Write-Host ("  " + ("=" * 58)) -ForegroundColor Blue }
function Write-Line { Write-Host ("  " + ("-" * 58)) -ForegroundColor Blue }

function Pause-Continue {
    Write-Host ""
    Write-Host "  [ Presione ENTER para continuar... ]" -ForegroundColor Cyan -NoNewline
    $null = Read-Host
}

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host "  |    AUTOMATIZACION DEL SERVIDOR FTP  --  IIS FTP Service      |" -ForegroundColor Blue
    Write-Host "  |    Windows Server 2019 Core  |  reprobados / recursadores    |" -ForegroundColor Blue
    Write-Host "  +--------------------------------------------------------------+" -ForegroundColor Blue
    Write-Host ""
}

# ==============================================================================
#  HELPERS: COMPROBACIONES IDEMPOTENTES
# ==============================================================================

function Test-LocalGroupExists([string]$Name) {
    return [bool](Get-LocalGroup -Name $Name -ErrorAction SilentlyContinue)
}

function Test-LocalUserExists([string]$Name) {
    return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
}

function Test-WindowsFeatureInstalled([string]$Name) {
    $f = Get-WindowsFeature -Name $Name -ErrorAction SilentlyContinue
    return ($f -and $f.InstallState -eq 'Installed')
}

function Test-FtpSiteExists([string]$SiteName) {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    return [bool](Get-Website -Name $SiteName -ErrorAction SilentlyContinue)
}

# ==============================================================================
#  HELPER: PERMISOS NTFS  (equivalente a chown + chmod + setfacl)
# ==============================================================================
# Grant-NtfsPermission   -> setfacl -m  /  chmod g+rwx
# Revoke-NtfsPermission  -> setfacl -x
# Set-NtfsOwner          -> chown

# Resolve-NtfsIdentity: convierte cualquier formato de identidad a NTAccount
# que .NET pueda resolver sin ambiguedad:
#   ".\grupo"      -> "COMPUTERNAME\grupo"   (grupo/usuario local)
#   "IUSR"         -> "NT AUTHORITY\..." o busca por SID conocido
#   "IIS_IUSRS"    -> "BUILTIN\IIS_IUSRS"
#   "BUILTIN\X"    -> sin cambio
#   "DOMAIN\X"     -> sin cambio
function Resolve-NtfsIdentity([string]$Identity) {
    # Reemplazar "." por el nombre real del equipo
    if ($Identity -match '^\.(\\|\/)') {
        $Identity = "$env:COMPUTERNAME\" + $Identity.Substring(2)
    }
    # Intentar resolver para validar que existe; si falla devolver tal cual
    try {
        $acct = New-Object System.Security.Principal.NTAccount($Identity)
        $null = $acct.Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
        # Intentar como cuenta BUILTIN (util para IIS_IUSRS, IUSR, etc.)
        $candidates = @("BUILTIN\$Identity", "NT AUTHORITY\$Identity",
                        "NT SERVICE\$Identity", "$env:COMPUTERNAME\$Identity")
        $resolved = $false
        foreach ($c in $candidates) {
            try {
                $acct = New-Object System.Security.Principal.NTAccount($c)
                $null = $acct.Translate([System.Security.Principal.SecurityIdentifier])
                $Identity = $c
                $resolved = $true
                break
            } catch { }
        }
        if (-not $resolved) {
            Write-Log WARN "No se pudo resolver la identidad '$Identity' -- se usara tal cual."
        }
    }
    return $Identity
}

function Grant-NtfsPermission {
    param(
        [string]$Path,
        [string]$Identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        [System.Security.AccessControl.InheritanceFlags]$Inheritance =
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
        [System.Security.AccessControl.PropagationFlags]$Propagation =
            [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]$Type =
            [System.Security.AccessControl.AccessControlType]::Allow
    )
    $Identity = Resolve-NtfsIdentity $Identity
    $acl  = Get-Acl -Path $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Identity, $Rights, $Inheritance, $Propagation, $Type)
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function Revoke-NtfsPermission {
    param(
        [string]$Path,
        [string]$Identity
    )
    try {
        $acl = Get-Acl -Path $Path
        $rules = $acl.Access | Where-Object { $_.IdentityReference -like "*$Identity*" }
        foreach ($r in $rules) { $acl.RemoveAccessRule($r) | Out-Null }
        Set-Acl -Path $Path -AclObject $acl
    } catch {
        Write-Log WARN "No se pudieron revocar permisos de '$Identity' en '$Path': $_"
    }
}

function Set-NtfsOwner {
    param([string]$Path, [string]$Identity)
    $acl = Get-Acl -Path $Path
    $owner = New-Object System.Security.Principal.NTAccount($Identity)
    $acl.SetOwner($owner)
    Set-Acl -Path $Path -AclObject $acl
}

# ==============================================================================
#  HELPER: DETECTAR IP DEL ADAPTADOR HOST-ONLY (VirtualBox)
#  Equivalente a detect_pasv_ip() del script bash
# ==============================================================================

function Get-FtpServerIp {
    # Prioridad 1: IP 192.168.x.x que NO sea 192.168.56.1 (gateway NAT VirtualBox)
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object {
              $_.IPAddress -notlike '127.*'    -and
              $_.IPAddress -notlike '10.0.2.*' -and
              $_.IPAddress -like   '192.168.*'
          } |
          Select-Object -First 1 -ExpandProperty IPAddress

    # Prioridad 2: Cualquier IP privada disponible (excluyendo loopback y NAT)
    if (-not $ip) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object {
                  $_.IPAddress -notlike '127.*' -and
                  $_.IPAddress -notlike '10.0.2.*'
              } |
              Select-Object -First 1 -ExpandProperty IPAddress
    }

    # Prioridad 3: Pedir manualmente
    if (-not $ip) {
        Write-Log WARN "No se pudo detectar la IP automaticamente."
        Write-Host "  IPs disponibles:" -ForegroundColor Yellow
        Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object {
            Write-Host "    $($_.IPAddress)" -ForegroundColor Cyan
        }
        $ip = Read-Host "  Ingrese la IP del servidor (ej: 192.168.56.102)"
        if (-not $ip) { $ip = '127.0.0.1' }
    }

    return $ip
}

# ==============================================================================
#  HELPER: VIRTUAL DIRECTORIES IIS FTP
#  Equivalente a mount_bind / umount_safe del script bash
# ==============================================================================

function Add-FtpVirtualDirectory {
    param(
        [string]$SiteName,
        [string]$VdirPath,       # ej: "LocalUser/a1/general"
        [string]$PhysicalPath
    )
    Import-Module WebAdministration -ErrorAction Stop
    $iisPath = "IIS:\Sites\$SiteName\$VdirPath"

    if (Test-Path $iisPath) {
        Write-Log WARN "Virtual Directory ya existe: $VdirPath"
        return
    }
    # Asegurar que el directorio fisico exista
    if (-not (Test-Path $PhysicalPath)) {
        New-Item -ItemType Directory -Path $PhysicalPath -Force | Out-Null
    }
    New-Item -Path $iisPath -PhysicalPath $PhysicalPath -Type VirtualDirectory | Out-Null
    Write-Log OK "Virtual Directory creado: $VdirPath  ->  $PhysicalPath"
}

function Remove-FtpVirtualDirectory {
    param(
        [string]$SiteName,
        [string]$VdirPath       # ej: "LocalUser/a1/reprobados"
    )
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $iisPath = "IIS:\Sites\$SiteName\$VdirPath"

    if (Test-Path $iisPath) {
        Remove-Item -Path $iisPath -Recurse -Force
        Write-Log OK "Virtual Directory eliminado: $VdirPath"
    }
}

# ==============================================================================
#  HELPER: PERMISOS NTFS CON SIDs CONOCIDOS
#  Usa SIDs absolutos para evitar errores de traduccion de nombres en WS2019.
#  Crea ACL limpia (deshabilita herencia) igual que Set-FolderPermissions de referencia.
# ==============================================================================

$KNOWN_SIDS = @{
    "Administrators"  = "S-1-5-32-544"
    "Users"           = "S-1-5-32-545"
    "Everyone"        = "S-1-1-0"
    "SYSTEM"          = "S-1-5-18"
    "IUSR"            = "S-1-5-17"
    "NETWORK SERVICE" = "S-1-5-20"
    "LOCAL SERVICE"   = "S-1-5-19"
}

function Set-FolderPermissions {
    param(
        [string]$Path,
        [array]$Rules
    )
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagation = [System.Security.AccessControl.PropagationFlags]"None"
    foreach ($rule in $Rules) {
        $identity = $rule.Identity
        try {
            if ($KNOWN_SIDS.ContainsKey($identity)) {
                $sid      = New-Object System.Security.Principal.SecurityIdentifier($KNOWN_SIDS[$identity])
                $resolved = $sid.Translate([System.Security.Principal.NTAccount])
            } else {
                $resolved = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$identity")
                $resolved.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
            }
        } catch {
            Write-Log WARN "No se pudo resolver identidad '$identity': $_"
            continue
        }
        $rights = [System.Security.AccessControl.FileSystemRights]$rule.Rights
        $type   = [System.Security.AccessControl.AccessControlType]$rule.Type
        $ace    = New-Object System.Security.AccessControl.FileSystemAccessRule(
                      $resolved, $rights, $inheritance, $propagation, $type)
        $acl.AddAccessRule($ace)
    }
    Set-Acl -Path $Path -AclObject $acl
    Write-Log OK "Permisos aplicados en: $Path"
}

# ==============================================================================
#  HELPER: REGLAS DE AUTORIZACION FTP VIA NODOS <location> EN XML
#  Evita el error 0x80070021 de Clear/Add-WebConfiguration y el "locked" de appcmd.
#  Escribe directamente en applicationHost.config con overrideMode="Allow".
# ==============================================================================

function Set-FtpAuthRules {
    param(
        [string]$SiteName,
        [array]$Rules,
        [string]$Location = ""
    )
    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath -Encoding UTF8
    $locationAttr = if ($Location -eq "") { $SiteName } else { "$SiteName/$Location" }

    $locationNode = $config.configuration.SelectSingleNode("location[@path='$locationAttr']")
    if (-not $locationNode) {
        $locationNode = $config.CreateElement("location")
        $locationNode.SetAttribute("path", $locationAttr)
        $locationNode.SetAttribute("overrideMode", "Allow")
        $config.configuration.AppendChild($locationNode) | Out-Null
    } else {
        $locationNode.SetAttribute("overrideMode", "Allow")
    }
    $ftpNode = $locationNode.SelectSingleNode("system.ftpServer")
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("system.ftpServer")
        $locationNode.AppendChild($ftpNode) | Out-Null
    }
    $secNode = $ftpNode.SelectSingleNode("security")
    if (-not $secNode) {
        $secNode = $config.CreateElement("security")
        $ftpNode.AppendChild($secNode) | Out-Null
    }
    $authNode = $secNode.SelectSingleNode("authorization")
    if (-not $authNode) {
        $authNode = $config.CreateElement("authorization")
        $secNode.AppendChild($authNode) | Out-Null
    }
    $authNode.RemoveAll()
    foreach ($rule in $Rules) {
        $addNode = $config.CreateElement("add")
        $addNode.SetAttribute("accessType", "Allow")
        $addNode.SetAttribute("users",       $rule.users)
        $addNode.SetAttribute("roles",       $rule.roles)
        $addNode.SetAttribute("permissions", $rule.permissions)
        $authNode.AppendChild($addNode) | Out-Null
    }
    $config.Save($configPath)
    Write-Log OK "Reglas de autorizacion guardadas para: $locationAttr"

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# ==============================================================================
#  HELPER: AISLAMIENTO DE USUARIOS VIA XML
#  Set-ItemProperty -Name 'ftpServer.userIsolation.mode' NO aplica de forma
#  confiable en WS2019; hay que escribir el nodo <userIsolation> en el XML.
# ==============================================================================

function Set-FtpUserIsolation {
    param([string]$SiteName, [string]$Mode)
    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath -Encoding UTF8
    $site = $config.configuration.'system.applicationHost'.sites.site |
            Where-Object { $_.name -eq $SiteName }
    $ftpNode = $site.SelectSingleNode("ftpServer")
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("ftpServer")
        $site.AppendChild($ftpNode) | Out-Null
    }
    $isoNode = $ftpNode.SelectSingleNode("userIsolation")
    if (-not $isoNode) {
        $isoNode = $config.CreateElement("userIsolation")
        $ftpNode.AppendChild($isoNode) | Out-Null
    }
    $isoNode.SetAttribute("mode", $Mode)
    $config.Save($configPath)
    Write-Log OK "Aislamiento de usuarios configurado via XML: $Mode"

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# ==============================================================================
#  HELPER: JUNCTION POINTS  (equivalente a bind mounts de Linux)
#  mklink /J es mas confiable que IIS Virtual Directories con User Isolation.
# ==============================================================================

function New-FtpJunction {
    param([string]$LinkPath, [string]$TargetPath)
    if (Test-Path $LinkPath) {
        $item = Get-Item $LinkPath -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -match "ReparsePoint")) {
            Write-Log WARN "Junction ya existe: $LinkPath"
            return
        }
        Remove-Item $LinkPath -Force -Recurse -ErrorAction SilentlyContinue
    }
    cmd /c "mklink /J `"$LinkPath`" `"$TargetPath`"" | Out-Null
    Write-Log OK "Junction: $LinkPath -> $TargetPath"
}

function Remove-FtpJunction {
    param([string]$LinkPath)
    if (Test-Path $LinkPath) {
        $item = Get-Item $LinkPath -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -match "ReparsePoint")) {
            cmd /c "rmdir `"$LinkPath`"" | Out-Null
            Write-Log OK "Junction eliminado: $LinkPath"
        } else {
            Remove-Item $LinkPath -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

# ==============================================================================
#  PASO 1 -- INSTALACION IDEMPOTENTE DE IIS + FTP SERVICE
#  Equivalente a install_vsftpd()
# ==============================================================================

function Install-IisFtp {
    Write-Sep
    Write-Host "  [1/5] Instalacion de IIS + FTP Service (WebAdministration)" -ForegroundColor White
    Write-Line

    # Features criticas: si fallan, se aborta la instalacion
    $requiredFeatures = @(
        'Web-Server',         # IIS Web Server (base requerida)
        'Web-Ftp-Server',     # FTP Server (rol contenedor)
        'Web-Ftp-Service',    # FTP Service (demonio principal)
        'Web-Scripting-Tools' # Modulo WebAdministration para PowerShell
    )

    # Features opcionales: nombre puede variar segun la edicion/build de WS2019
    # Web-Ftp-Ext  (en algunas ediciones se llama Web-Ftp-Extensibility)
    $optionalFeatures = @(
        'Web-Ftp-Ext'         # FTP Extensibility (para IIS Manager auth -- opcional)
    )

    foreach ($feat in $requiredFeatures) {
        if (Test-WindowsFeatureInstalled $feat) {
            Write-Log WARN "'$feat' ya instalado -- omitiendo."
        } else {
            Write-Log INFO "Instalando '$feat'..."
            try {
                Install-WindowsFeature -Name $feat -IncludeManagementTools | Out-Null
                Write-Log OK "'$feat' instalado correctamente."
            } catch {
                Write-Log ERROR "Fallo la instalacion de '$feat': $_"
                return $false
            }
        }
    }

    foreach ($feat in $optionalFeatures) {
        if (Test-WindowsFeatureInstalled $feat) {
            Write-Log WARN "'$feat' ya instalado -- omitiendo."
        } else {
            Write-Log INFO "Instalando '$feat' (opcional)..."
            try {
                Install-WindowsFeature -Name $feat | Out-Null
                Write-Log OK "'$feat' instalado correctamente."
            } catch {
                Write-Log WARN "'$feat' no disponible en esta edicion -- se omite sin error."
            }
        }
    }

    # Importar el modulo WebAdministration (equivalente al binario vsftpd)
    Import-Module WebAdministration -ErrorAction Stop
    Write-Log OK "Modulo WebAdministration cargado."

    # Habilitar e iniciar el servicio FTPSVC
    $svc = Get-Service -Name 'FTPSVC' -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name 'FTPSVC' -StartupType Automatic
        if ($svc.Status -ne 'Running') {
            Start-Service -Name 'FTPSVC'
            Write-Log OK "Servicio FTPSVC iniciado."
        } else {
            Write-Log WARN "Servicio FTPSVC ya estaba en ejecucion."
        }
    } else {
        Write-Log WARN "Servicio FTPSVC no encontrado tras la instalacion. Reinicie y vuelva a ejecutar."
    }

    return $true
}

# ==============================================================================
#  PASO 2 -- GRUPOS DEL SISTEMA
#  Equivalente a create_groups()
# ==============================================================================

function New-FtpGroups {
    Write-Sep
    Write-Host "  [2/5] Creacion de grupos locales" -ForegroundColor White
    Write-Line

    $groups = @{
        $GRP_FTP          = 'Usuarios con acceso FTP autenticado'
        $GRP_REPROBADOS   = 'Grupo FTP: reprobados'
        $GRP_RECURSADORES = 'Grupo FTP: recursadores'
    }

    foreach ($g in $groups.GetEnumerator()) {
        if (Test-LocalGroupExists $g.Key) {
            Write-Log WARN "Grupo '$($g.Key)' ya existe -- omitiendo."
        } else {
            New-LocalGroup -Name $g.Key -Description $g.Value | Out-Null
            Write-Log OK "Grupo '$($g.Key)' creado."
        }
    }
}

# ==============================================================================
#  PASO 3 -- ESTRUCTURA DE DIRECTORIOS + PERMISOS NTFS
#  Equivalente a create_base_dirs()
#
#  Mapa NTFS:
#   C:\FTP\                         SYSTEM:F, Administrators:F
#   C:\FTP\general\                 ftp_users:M(setgid(equiv.)heredable), IUSR:R
#   C:\FTP\reprobados\              reprobados:M(heredable)
#   C:\FTP\recursadores\            recursadores:M(heredable)
#   C:\FTP\LocalUser\               SYSTEM:F, Administrators:F
#   C:\FTP\LocalUser\Public\        IUSR:R, IIS_IUSRS:R  <- raiz anonimo
#   C:\FTP\LocalUser\Public\general (Virtual Directory -> C:\FTP\general)
#   C:\FTP\LocalUser\<u>\           Administrators:F  (jail root -- no escribible por usuario)
#   C:\FTP\LocalUser\<u>\general    (Virtual Directory -> C:\FTP\general)
#   C:\FTP\LocalUser\<u>\<grupo>\   (Virtual Directory -> C:\FTP\<grupo>)
#   C:\FTP\LocalUser\<u>\<u>\       <u>:M  (directorio personal)
# ==============================================================================

function New-FtpBaseDirectories {
    Write-Sep
    Write-Host "  [3/5] Estructura de directorios FTP + permisos NTFS" -ForegroundColor White
    Write-Line

    # Crear directorios base
    foreach ($d in @($GENERAL_DIR, $REPROBADOS_DIR, $RECURSADORES_DIR,
                     $USERS_ROOT, "$USERS_ROOT\Public", "$FTP_BASE\logs")) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Log OK "Directorio creado: $d"
        }
    }

    # C:\FTP\general  --  ftp_users:Modify, IUSR:Read
    Set-FolderPermissions -Path $GENERAL_DIR -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
        @{ Identity = $GRP_FTP;         Rights = "Modify";         Type = "Allow" },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute"; Type = "Allow" }
    )

    # C:\FTP\reprobados
    Set-FolderPermissions -Path $REPROBADOS_DIR -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
        @{ Identity = $GRP_REPROBADOS;  Rights = "Modify";      Type = "Allow" }
    )

    # C:\FTP\recursadores
    Set-FolderPermissions -Path $RECURSADORES_DIR -Rules @(
        @{ Identity = "SYSTEM";          Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators";  Rights = "FullControl"; Type = "Allow" },
        @{ Identity = $GRP_RECURSADORES; Rights = "Modify";      Type = "Allow" }
    )

    # C:\FTP\LocalUser  --  solo SYSTEM y Admins (IUSR NO debe listar jails de otros)
    Set-FolderPermissions -Path $USERS_ROOT -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" }
    )

    # C:\FTP\LocalUser\Public  --  raiz del anonimo: IUSR solo lectura
    $pubDir = "$USERS_ROOT\Public"
    Set-FolderPermissions -Path $pubDir -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute"; Type = "Allow" }
    )

    # Junction anonimo: LocalUser\Public\general -> C:\FTP\general
    New-FtpJunction -LinkPath "$USERS_ROOT\Public\general" -TargetPath $GENERAL_DIR

    Write-Log OK "Estructura base de directorios lista en $FTP_BASE."
}

# ==============================================================================
#  PASO 4 -- CONFIGURAR EL SITIO FTP EN IIS
#  Equivalente a configure_vsftpd()
# ==============================================================================

function Set-FtpSite {
    Write-Sep
    Write-Host "  [4/5] Configuracion del sitio FTP en IIS" -ForegroundColor White
    Write-Line

    Import-Module WebAdministration -ErrorAction Stop

    Write-Log INFO "Detectando IP del servidor..."
    $serverIp = Get-FtpServerIp
    Write-Log OK "IP del servidor: $serverIp"

    # Detener servicios antes de crear/eliminar el sitio
    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (Test-FtpSiteExists $FTP_SITE_NAME) {
        Write-Log WARN "Sitio '$FTP_SITE_NAME' ya existe -- eliminando para reconfigurar."
        Remove-Website -Name $FTP_SITE_NAME
    }

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Raiz del sitio = $FTP_BASE (IIS buscara LocalUser\ dentro)
    New-WebFtpSite -Name $FTP_SITE_NAME -Port $FTP_SITE_PORT -PhysicalPath $FTP_BASE | Out-Null
    Write-Log OK "Sitio FTP '$FTP_SITE_NAME' creado  (raiz: $FTP_BASE  puerto: $FTP_SITE_PORT)."

    $sitePath = "IIS:\Sites\$FTP_SITE_NAME"

    # SSL: deshabilitar requisito (evita error 534)
    Set-ItemProperty $sitePath -Name 'ftpServer.security.ssl.controlChannelPolicy' -Value 0
    Set-ItemProperty $sitePath -Name 'ftpServer.security.ssl.dataChannelPolicy'    -Value 0
    Write-Log OK "SSL: SslAllow (error 534 corregido)."

    # Autenticacion anonima + basica
    # CRITICO: fijar userName a IUSR explicitamente (si queda vacio, anonimo falla con 530)
    Set-ItemProperty $sitePath `
        -Name 'ftpServer.security.authentication.anonymousAuthentication.enabled'  -Value $true
    Set-ItemProperty $sitePath `
        -Name 'ftpServer.security.authentication.anonymousAuthentication.userName' -Value 'IUSR'
    Set-ItemProperty $sitePath `
        -Name 'ftpServer.security.authentication.basicAuthentication.enabled'      -Value $true
    Write-Log OK "Autenticacion: Anonima (IUSR) + Basica habilitadas."

    # Modo pasivo
    Set-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
        -PSPath 'MACHINE/WEBROOT/APPHOST' -Name 'lowDataChannelPort'  -Value $FTP_PASV_MIN
    Set-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
        -PSPath 'MACHINE/WEBROOT/APPHOST' -Name 'highDataChannelPort' -Value $FTP_PASV_MAX
    try {
        Set-ItemProperty $sitePath `
            -Name 'ftpServer.firewallSupport.externalIp4Address' -Value $serverIp -ErrorAction Stop
    } catch { }
    Write-Log OK "Modo pasivo: puertos ${FTP_PASV_MIN}-${FTP_PASV_MAX}  IP: $serverIp"

    # Aislamiento via XML (Set-ItemProperty no aplica userIsolation.mode en WS2019)
    Write-Log INFO "Configurando aislamiento de usuarios via XML..."
    Set-FtpUserIsolation -SiteName $FTP_SITE_NAME -Mode "IsolateAllDirectories"

    # Reglas de autorizacion globales via nodos <location> en XML
    Write-Log INFO "Configurando reglas de autorizacion globales via XML..."
    Set-FtpAuthRules -SiteName $FTP_SITE_NAME -Rules @(
        @{ users = "";  roles = ""; permissions = "Read"       },
        @{ users = "*"; roles = ""; permissions = "Read,Write" }
    )

    # Banner
    Set-ItemProperty $sitePath -Name 'ftpServer.messages.bannerMessage' `
        -Value 'Bienvenido al Servidor FTP Institucional. Acceso restringido.'
    Set-ItemProperty $sitePath -Name 'ftpServer.messages.suppressDefaultBanner' -Value $false

    # Iniciar el sitio
    $appcmd = "$env:SystemRoot\system32\inetsrv\appcmd.exe"
    & $appcmd start site /site.name:"$FTP_SITE_NAME" 2>&1 | Out-Null
    Restart-Service -Name 'FTPSVC' -Force -ErrorAction SilentlyContinue
    Write-Log OK "Sitio FTP '$FTP_SITE_NAME' iniciado."
}


# ==============================================================================
#  PASO 5 -- FIREWALL DE WINDOWS
#  Equivalente a configure_security() (firewalld / SELinux)
# ==============================================================================

function Set-FtpFirewall {
    Write-Sep
    Write-Host "  [5/5] Reglas de Firewall de Windows" -ForegroundColor White
    Write-Line

    # Puerto FTP control (21)
    $ruleName21 = 'FTP-Server-Control-In'
    if (Get-NetFirewallRule -DisplayName $ruleName21 -ErrorAction SilentlyContinue) {
        Write-Log WARN "Regla '$ruleName21' ya existe -- omitiendo."
    } else {
        New-NetFirewallRule -DisplayName $ruleName21 `
            -Direction Inbound -Protocol TCP -LocalPort 21 `
            -Action Allow -Profile Any | Out-Null
        Write-Log OK "Firewall: TCP 21 abierto ($ruleName21)."
    }

    # Puertos pasivos (40000-40100)
    $rulePasv = 'FTP-Server-Passive-In'
    if (Get-NetFirewallRule -DisplayName $rulePasv -ErrorAction SilentlyContinue) {
        Write-Log WARN "Regla '$rulePasv' ya existe -- omitiendo."
    } else {
        New-NetFirewallRule -DisplayName $rulePasv `
            -Direction Inbound -Protocol TCP -LocalPort "${FTP_PASV_MIN}-${FTP_PASV_MAX}" `
            -Action Allow -Profile Any | Out-Null
        Write-Log OK "Firewall: TCP ${FTP_PASV_MIN}-${FTP_PASV_MAX} abiertos ($rulePasv)."
    }

    # Habilitar el helper de FTP en el firewall (permite conexiones de datos activas)
    netsh advfirewall set global StatefulFTP enable 2>&1 | Out-Null
    Write-Log OK "Firewall: StatefulFTP habilitado (conexiones de datos activas/pasivas)."
}

# ==============================================================================
#  CREAR UN USUARIO FTP INDIVIDUAL
#  Equivalente a create_ftp_user()
# ==============================================================================

function New-FtpUser {
    param(
        [string]$Username,
        [string]$Password,
        [ValidateSet('reprobados','recursadores')] [string]$Group
    )

    $groupDir = if ($Group -eq $GRP_REPROBADOS) { $REPROBADOS_DIR } else { $RECURSADORES_DIR }
    $userJail = "$USERS_ROOT\$Username"
    $userHome = "$userJail\$Username"   # directorio personal (directorio real, no junction)

    Write-Line
    Write-Host "  Creando usuario " -NoNewline
    Write-Host $Username -ForegroundColor Cyan -NoNewline
    Write-Host "  |  grupo: " -NoNewline
    Write-Host $Group -ForegroundColor Yellow

    # -- 1. Cuenta local de Windows -------------------------------------------
    $secPwd = ConvertTo-SecureString $Password -AsPlainText -Force
    if (Test-LocalUserExists $Username) {
        Write-Log WARN "Usuario '$Username' ya existe -- actualizando contrasena."
        Set-LocalUser -Name $Username -Password $secPwd
    } else {
        New-LocalUser -Name $Username -Password $secPwd `
            -Description "Usuario FTP - grupo $Group" `
            -UserMayNotChangePassword -PasswordNeverExpires | Out-Null
        Write-Log OK "Usuario del sistema '$Username' creado."
    }

    # Membresia en ftp_users y en el grupo especifico
    foreach ($g in @($GRP_FTP, $Group)) {
        try   { Add-LocalGroupMember -Group $g -Member $Username -ErrorAction Stop | Out-Null }
        catch { Write-Log WARN "Ya miembro de '$g' o error: $_" }
    }

    # -- 2. Estructura del jail -----------------------------------------------
    foreach ($d in @($userJail, $userHome)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Raiz del jail: usuario ReadAndExecute (necesario para que IIS autentique),
    # SYSTEM y Admins FullControl. Sin escritura en la raiz (equivalente a 755 root:root).
    Set-FolderPermissions -Path $userJail -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl";    Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl";    Type = "Allow" },
        @{ Identity = $Username;        Rights = "ReadAndExecute"; Type = "Allow" }
    )

    # Directorio personal: usuario Modify (puede leer, escribir, crear archivos)
    Set-FolderPermissions -Path $userHome -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"; Type = "Allow" },
        @{ Identity = "Administrators"; Rights = "FullControl"; Type = "Allow" },
        @{ Identity = $Username;        Rights = "Modify";      Type = "Allow" }
    )
    Write-Log OK "Jail y directorio personal creados con permisos correctos."

    # -- 3. Junction points (equivalente a bind mounts de Linux) ---------------
    # CRITICO: IIS Virtual Directories NO funcionan con IsolateAllDirectories.
    # La solucion correcta (igual que el script de referencia) es mklink /J.
    New-FtpJunction -LinkPath "$userJail\general" -TargetPath $GENERAL_DIR
    New-FtpJunction -LinkPath "$userJail\$Group"  -TargetPath $groupDir
    # $userHome ($userJail\$Username) ya existe como directorio real arriba

    # -- 4. Reglas de autorizacion por subdirectorio ---------------------------
    # CRITICO: con IsolateAllDirectories las reglas globales del sitio no son
    # suficientes. Se necesita un nodo <location> por cada subdirectorio del jail.
    foreach ($loc in @("general", $Group, $Username)) {
        Set-FtpAuthRules -SiteName $FTP_SITE_NAME -Location "$Username/$loc" -Rules @(
            @{ users = $Username; roles = ""; permissions = "Read,Write" }
        )
    }
    Write-Log OK "Reglas de autorizacion por subdirectorio aplicadas."

    Write-Log OK "Usuario FTP '$Username' listo."
    Write-Host ""
    Write-Host "  Estructura visible al conectarse por FTP:" -ForegroundColor Cyan
    Write-Host "  /  (jail: $userJail)" -ForegroundColor White
    Write-Host "  +-- general\  <- R/W  (junction -> $GENERAL_DIR)" -ForegroundColor Green
    Write-Host "  +-- $Group\  <- R/W  (junction -> $groupDir)" -ForegroundColor Yellow
    Write-Host "  +-- $Username\  <- R/W  (directorio personal)" -ForegroundColor Cyan
    Write-Host ""
}


# ==============================================================================
#  CREACION MASIVA DE USUARIOS (INTERACTIVO)
#  Equivalente a create_bulk_users()
# ==============================================================================

function New-BulkFtpUsers {
    Write-Sep
    Write-Host "  Creacion Masiva de Usuarios FTP" -ForegroundColor White
    Write-Line

    if (-not (Test-Path $USERS_ROOT)) {
        Write-Log ERROR "La estructura base no existe. Ejecute primero la opcion 1 (Inicializacion)."
        return
    }

    # Validar numero de usuarios
    $n = 0
    do {
        $input = Read-Host "  ?Cuantos usuarios desea crear?"
        if ($input -match '^\d+$' -and [int]$input -gt 0) { $n = [int]$input }
        else { Write-Host "  Ingrese un numero entero positivo." -ForegroundColor Red }
    } while ($n -eq 0)

    for ($i = 1; $i -le $n; $i++) {
        Write-Line
        Write-Host "  -- Usuario $i de $n --" -ForegroundColor White

        # Nombre de usuario
        $username = ''
        do {
            $username = Read-Host "  Nombre de usuario"
            if ([string]::IsNullOrWhiteSpace($username)) {
                Write-Host "  El nombre no puede estar vacio." -ForegroundColor Red
                $username = ''
            } elseif ($username -notmatch '^[a-zA-Z0-9_-]+$') {
                Write-Host "  Solo se permiten: letras, numeros, guion bajo (_) y guion (-)." -ForegroundColor Red
                $username = ''
            } elseif (Test-LocalUserExists $username) {
                Write-Host "  El usuario '$username' ya existe. Ingrese otro." -ForegroundColor Yellow
                $username = ''
            }
        } while ([string]::IsNullOrEmpty($username))

        # Contrasena (sin confirmacion, segun especificacion)
        $password = Read-Host "  Contrasena" -AsSecureString
        $pwPlain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))

        # Grupo
        $group = ''
        do {
            Write-Host "  Asignar grupo:"
            Write-Host "    1) reprobados"   -ForegroundColor Cyan
            Write-Host "    2) recursadores" -ForegroundColor Cyan
            $gc = Read-Host "  Seleccion [1/2]"
            switch ($gc) {
                '1' { $group = $GRP_REPROBADOS;   break }
                '2' { $group = $GRP_RECURSADORES;  break }
                default { Write-Host "  Opcion invalida. Elija 1 o 2." -ForegroundColor Red }
            }
        } while ([string]::IsNullOrEmpty($group))

        New-FtpUser -Username $username -Password $pwPlain -Group $group
    }

    Restart-Service -Name 'FTPSVC' -Force
    Write-Log OK "FTPSVC reiniciado tras la creacion de usuarios."
}

# ==============================================================================
#  CAMBIAR EL GRUPO DE UN USUARIO FTP
#  Equivalente a change_user_group()  (incluye la logica de kill_user_ftp_sessions)
# ==============================================================================

function Set-FtpUserGroup {
    Write-Sep
    Write-Host "  Cambio de Grupo de Usuario FTP" -ForegroundColor White
    Write-Line
    Get-FtpUserList

    $username = Read-Host "  Usuario a reasignar de grupo"
    if (-not (Test-LocalUserExists $username)) {
        Write-Log ERROR "El usuario '$username' no existe."; return
    }

    $oldGroup = ''
    $members = Get-LocalGroupMember -Group $GRP_REPROBADOS -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match "\\$username$" -or $_.Name -eq $username }
    if ($members) { $oldGroup = $GRP_REPROBADOS }
    else {
        $members = Get-LocalGroupMember -Group $GRP_RECURSADORES -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match "\\$username$" -or $_.Name -eq $username }
        if ($members) { $oldGroup = $GRP_RECURSADORES }
    }
    if (-not $oldGroup) {
        Write-Log ERROR "No se pudo determinar el grupo FTP actual de '$username'."; return
    }
    Write-Host "  Grupo actual: " -NoNewline; Write-Host $oldGroup -ForegroundColor Yellow

    $newGroup = ''
    do {
        Write-Host "  Nuevo grupo:"
        Write-Host "    1) reprobados"   -ForegroundColor Cyan
        Write-Host "    2) recursadores" -ForegroundColor Cyan
        $gc = Read-Host "  Seleccion [1/2]"
        switch ($gc) {
            '1' { $newGroup = $GRP_REPROBADOS;   break }
            '2' { $newGroup = $GRP_RECURSADORES;  break }
            default { Write-Host "  Opcion invalida." -ForegroundColor Red }
        }
    } while (-not $newGroup)

    if ($oldGroup -eq $newGroup) {
        Write-Log WARN "El usuario ya pertenece a '$newGroup'. Sin cambios."; return
    }

    $newGroupDir = if ($newGroup -eq $GRP_REPROBADOS) { $REPROBADOS_DIR } else { $RECURSADORES_DIR }
    $userJail    = "$USERS_ROOT\$username"

    Write-Log INFO "Cambiando '$username': $oldGroup -> $newGroup"

    # Reiniciar FTPSVC para liberar sesiones activas
    Write-Log WARN "Reiniciando FTPSVC para liberar sesiones activas..."
    Restart-Service -Name 'FTPSVC' -Force
    Start-Sleep -Seconds 2

    # Eliminar junction del grupo anterior
    Remove-FtpJunction -LinkPath "$userJail\$oldGroup"

    # Actualizar membresia
    try   { Remove-LocalGroupMember -Group $oldGroup -Member $username }
    catch { Write-Log WARN "No se pudo remover de '$oldGroup': $_" }
    try   { Add-LocalGroupMember    -Group $newGroup -Member $username }
    catch { Write-Log WARN "No se pudo anadir a '$newGroup': $_" }
    Write-Log OK "Membresia actualizada: $oldGroup -> $newGroup"

    # Crear junction del nuevo grupo
    New-FtpJunction -LinkPath "$userJail\$newGroup" -TargetPath $newGroupDir

    # Actualizar reglas de autorizacion: borrar old, crear new
    Set-FtpAuthRules -SiteName $FTP_SITE_NAME -Location "$username/$oldGroup" -Rules @()
    Set-FtpAuthRules -SiteName $FTP_SITE_NAME -Location "$username/$newGroup" -Rules @(
        @{ users = $username; roles = ""; permissions = "Read,Write" }
    )
    Write-Log OK "Reglas de autorizacion actualizadas."

    Restart-Service -Name 'FTPSVC' -Force
    Write-Log OK "Usuario '$username' movido a '$newGroup' exitosamente."

    Write-Host ""
    Write-Host "  Nueva estructura FTP de '$username':" -ForegroundColor Cyan
    Write-Host "  +-- general\"    -ForegroundColor Green
    Write-Host "  +-- $newGroup\" -ForegroundColor Yellow
    Write-Host "  +-- $username\" -ForegroundColor Cyan
}


# ==============================================================================
#  ELIMINAR USUARIO FTP
#  Equivalente a delete_ftp_user()
# ==============================================================================

function Remove-FtpUser {
    Write-Sep
    Write-Host "  Eliminar Usuario FTP" -ForegroundColor White
    Write-Line
    Get-FtpUserList

    $username = Read-Host "  Usuario a eliminar"
    if (-not (Test-LocalUserExists $username)) {
        Write-Log ERROR "El usuario '$username' no existe."; return
    }

    $confirm = Read-Host "  Confirmar eliminacion de '$username'? [s/N]"
    if ($confirm -ne 's') { Write-Log INFO "Operacion cancelada."; return }

    $userJail = "$USERS_ROOT\$username"

    # Reiniciar FTPSVC para liberar sesiones
    Restart-Service -Name 'FTPSVC' -Force
    Start-Sleep -Seconds 2

    # Eliminar junctions del usuario (rmdir, no Remove-Item, para no borrar el target)
    foreach ($j in @("general", $GRP_REPROBADOS, $GRP_RECURSADORES, $username)) {
        Remove-FtpJunction -LinkPath "$userJail\$j"
    }

    # Eliminar cuenta local
    try {
        Remove-LocalUser -Name $username
        Write-Log OK "Cuenta de sistema '$username' eliminada."
    } catch {
        Write-Log WARN "Remove-LocalUser fallo: $_"
    }

    # Eliminar jail (solo el directorio personal real, los junctions ya fueron removidos)
    if (Test-Path $userJail) {
        Remove-Item -Path $userJail -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log OK "Jail '$userJail' eliminado."
    }

    # Revocar ACEs NTFS individuales en directorios compartidos
    Revoke-NtfsPermission -Path $GENERAL_DIR      -Identity $username
    Revoke-NtfsPermission -Path $REPROBADOS_DIR   -Identity $username
    Revoke-NtfsPermission -Path $RECURSADORES_DIR -Identity $username
    Write-Log OK "ACEs NTFS del usuario '$username' eliminadas."

    Restart-Service -Name 'FTPSVC' -Force
    Write-Log OK "Usuario FTP '$username' eliminado completamente."
}


# ==============================================================================
#  LISTAR USUARIOS FTP
#  Equivalente a list_ftp_users()
# ==============================================================================

function Get-FtpUserList {
    Write-Line
    Write-Host "  Usuarios FTP registrados" -ForegroundColor Cyan
    Write-Host ("  {0,-22} {1,-18} {2,-12}" -f "Usuario", "Grupo FTP", "Estado") -ForegroundColor White
    Write-Line

    $count = 0

    if (Test-Path $USERS_ROOT) {
        Get-ChildItem -Path $USERS_ROOT -Directory | ForEach-Object {
            $uname = $_.Name
            if ($uname -eq 'Public') { return }           # omitir la raiz anonima
            if (-not (Test-LocalUserExists $uname)) { return }

            # Determinar grupo
            $grp = '(sin grupo)'
            $inRep = Get-LocalGroupMember -Group $GRP_REPROBADOS   -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "*$uname" }
            $inRec = Get-LocalGroupMember -Group $GRP_RECURSADORES -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like "*$uname" }
            if ($inRep) { $grp = $GRP_REPROBADOS }
            elseif ($inRec) { $grp = $GRP_RECURSADORES }

            if ((Get-LocalUser -Name $uname).Enabled) { $status = 'Habilitado' } else { $status = 'Deshabilitado' }

            Write-Host ("  {0,-22}" -f $uname) -ForegroundColor Green   -NoNewline
            Write-Host (" {0,-18}" -f $grp)    -ForegroundColor Yellow  -NoNewline
            Write-Host (" {0,-12}" -f $status)
            $count++
        }
    }

    Write-Line
    if ($count -eq 0) {
        Write-Host "  No hay usuarios FTP registrados aun." -ForegroundColor Yellow
    } else {
        Write-Host "  Total: $count usuario(s)"
    }
}

# ==============================================================================
#  VER PERMISOS NTFS DE LOS DIRECTORIOS COMPARTIDOS
#  Equivalente a show_permissions()
# ==============================================================================

function Show-FtpPermissions {
    Write-Sep
    Write-Host "  Permisos NTFS de directorios compartidos FTP" -ForegroundColor White
    Write-Line

    foreach ($dir in @($GENERAL_DIR, $REPROBADOS_DIR, $RECURSADORES_DIR)) {
        if (-not (Test-Path $dir)) { continue }
        Write-Host "  $dir" -ForegroundColor Cyan
        $acl = Get-Acl -Path $dir
        $acl.Access | ForEach-Object {
            Write-Host ("    {0,-40} {1,-15} {2}" -f $_.IdentityReference,
                                                      $_.FileSystemRights,
                                                      $_.AccessControlType)
        }
        Write-Host ""
    }
}

# ==============================================================================
#  ACTUALIZAR IP DEL SERVIDOR (pasv_address / externalIp4Address)
#  Equivalente a update_pasv_address()
# ==============================================================================

function Update-FtpPassiveIp {
    Write-Sep
    Write-Host "  Actualizar IP del servidor FTP (modo pasivo)" -ForegroundColor White
    Write-Line

    Import-Module WebAdministration -ErrorAction Stop

    # Leer IP actual desde el nodo del sitio
    $sitePath = "IIS:\Sites\$FTP_SITE_NAME"
    $current = ''
    try {
        $current = (Get-ItemProperty $sitePath `
            -Name 'ftpServer.firewallSupport.externalIp4Address').Value
    } catch { }
    Write-Log INFO "IP actual registrada: $(if ($current) { $current } else { '(no configurada)' })"

    Write-Log INFO "Detectando IP del servidor..."
    $newIp = Get-FtpServerIp
    Write-Host "  IP detectada: $newIp" -ForegroundColor Green

    $confirm = Read-Host "  Usar esta IP? [S/n]"
    if ($confirm -eq 'n') {
        $newIp = Read-Host "  Ingrese la IP manualmente"
        if (-not $newIp) { Write-Log ERROR "IP vacia. Operacion cancelada."; return }
    }

    # Detener servicios para evitar bloqueo del config
    Stop-Service -Name 'FTPSVC' -Force -ErrorAction SilentlyContinue
    Stop-Service -Name 'W3SVC'  -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    # Actualizar IP via Set-ItemProperty en el nodo del sitio
    try {
        Set-ItemProperty $sitePath `
            -Name 'ftpServer.firewallSupport.externalIp4Address' `
            -Value $newIp -ErrorAction Stop
    } catch {
        # Fallback via appcmd
        & "$env:SystemRoot\system32\inetsrv\appcmd.exe" set config `
            -section:system.ftpServer/firewallSupport `
            /externalIp4Address:$newIp 2>&1 | Out-Null
    }
    Write-Log OK "externalIp4Address actualizada a: $newIp"

    # Tambien actualizar puertos pasivos (por si acaso)
    Set-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Name 'lowDataChannelPort'  -Value $FTP_PASV_MIN
    Set-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
        -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Name 'highDataChannelPort' -Value $FTP_PASV_MAX

    Start-Service -Name 'W3SVC'  -ErrorAction SilentlyContinue
    Start-Service -Name 'FTPSVC' -ErrorAction SilentlyContinue
    Write-Log OK "Servicios reiniciados con la nueva configuracion pasiva."

    Write-Line
    Write-Host "  Verificacion en applicationHost.config:" -ForegroundColor Cyan
    $lo = (Get-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
           -PSPath 'MACHINE/WEBROOT/APPHOST' -Name 'lowDataChannelPort').Value
    $hi = (Get-WebConfigurationProperty -Filter 'system.ftpServer/firewallSupport' `
           -PSPath 'MACHINE/WEBROOT/APPHOST' -Name 'highDataChannelPort').Value
    Write-Host "    lowDataChannelPort  = $lo" -ForegroundColor Green
    Write-Host "    highDataChannelPort = $hi" -ForegroundColor Green
    Write-Host "    externalIp4Address  = $newIp" -ForegroundColor Green
}

# ==============================================================================
#  MENU PRINCIPAL
# ==============================================================================

function Show-MainMenu {
    while ($true) {
        Write-Header
        Write-Host "  MENU PRINCIPAL" -ForegroundColor White
        Write-Sep
        Write-Host "  " -NoNewline
        Write-Host "1)" -ForegroundColor Green -NoNewline
        Write-Host " Inicializacion completa del servidor FTP"
        Write-Host "     " -NoNewline
        Write-Host "-> Instala IIS+FTP, crea grupos, directorios, configura firewall" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "2)" -ForegroundColor Green -NoNewline
        Write-Host " Crear usuarios FTP  " -NoNewline
        Write-Host "(modo interactivo, creacion masiva)" -ForegroundColor Cyan
        Write-Host "  " -NoNewline; Write-Host "3)" -ForegroundColor Green -NoNewline
        Write-Host " Cambiar grupo de un usuario"
        Write-Host "  " -NoNewline; Write-Host "4)" -ForegroundColor Green -NoNewline
        Write-Host " Listar usuarios FTP"
        Write-Host "  " -NoNewline; Write-Host "5)" -ForegroundColor Green -NoNewline
        Write-Host " Eliminar usuario FTP"
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "6)" -ForegroundColor Green -NoNewline
        Write-Host " Reiniciar servicio FTPSVC"
        Write-Host "  " -NoNewline; Write-Host "7)" -ForegroundColor Green -NoNewline
        Write-Host " Estado del servicio FTPSVC"
        Write-Host "  " -NoNewline; Write-Host "8)" -ForegroundColor Green -NoNewline
        Write-Host " Ver permisos NTFS de directorios compartidos"
        Write-Host "  " -NoNewline; Write-Host "9)" -ForegroundColor Green -NoNewline
        Write-Host " Actualizar IP del servidor  " -NoNewline
        Write-Host "(cambio la IP del adaptador Host-Only)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  " -NoNewline; Write-Host "0)" -ForegroundColor Red -NoNewline
        Write-Host " Salir"
        Write-Sep

        $opt = Read-Host "  Seleccion"

        switch ($opt) {
            '1' {
                $ok = Install-IisFtp
                if ($ok) {
                    New-FtpGroups
                    New-FtpBaseDirectories
                    Set-FtpSite
                    Set-FtpFirewall
                    Write-Host ""
                    Write-Sep
                    Write-Log OK "== Servidor FTP inicializado correctamente =="
                    Write-Host "  Proximo paso: use la opcion 2 para crear usuarios." -ForegroundColor Cyan
                    Write-Sep
                }
                Pause-Continue
            }
            '2' { New-BulkFtpUsers;    Pause-Continue }
            '3' { Set-FtpUserGroup;    Pause-Continue }
            '4' { Get-FtpUserList;     Pause-Continue }
            '5' { Remove-FtpUser;      Pause-Continue }
            '6' {
                Write-Sep
                try {
                    Restart-Service -Name 'FTPSVC' -Force
                    Write-Log OK "FTPSVC reiniciado."
                } catch {
                    Write-Log ERROR "No se pudo reiniciar FTPSVC: $_"
                }
                Pause-Continue
            }
            '7' {
                Write-Sep
                Write-Host "  Get-Service FTPSVC" -ForegroundColor White
                Write-Line
                Get-Service -Name 'FTPSVC' | Format-List Name, DisplayName, Status, StartType
                Write-Sep
                Pause-Continue
            }
            '8' { Show-FtpPermissions;   Pause-Continue }
            '9' { Update-FtpPassiveIp;   Pause-Continue }
            '0' {
                Write-Host "  Saliendo..." -ForegroundColor Green
                exit 0
            }
            default {
                Write-Host "  Opcion invalida. Elija un numero del menu." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ==============================================================================
#  PUNTO DE ENTRADA
# ==============================================================================

# Verificar privilegios de administrador (equivalente a check_root)
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] Este script debe ejecutarse como Administrador." -ForegroundColor Red
    Write-Host "        Abra PowerShell con 'Ejecutar como administrador'." -ForegroundColor Yellow
    exit 1
}

# Crear directorio de logs si no existe
if (-not (Test-Path (Split-Path $LOG_FILE))) {
    New-Item -ItemType Directory -Path (Split-Path $LOG_FILE) -Force | Out-Null
}

Show-MainMenu
