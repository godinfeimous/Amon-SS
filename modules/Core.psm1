#Requires -Version 5.1
<#
    Amon SS - modules/Core.psm1
    Núcleo compartido por todos los módulos forenses:
      * versión, ajustes (config/settings.json + %LOCALAPPDATA%\AmonSS\settings.json)
      * contrato de datos: hallazgos (Finding), eventos de timeline (Event), resultados de módulo
      * contexto de revisión (ventana temporal, indicadores, caché de hashes, cancelación)
      * lectura de archivos en modo solo lectura y compartido, hashes, conversión de FILETIME
      * redacción de secretos en líneas de comando
      * compilación bajo demanda del código nativo (modules/Native/AmonNative.cs)

    Regla de oro: ninguna función de este módulo escribe, mueve ni borra artefactos del
    sistema analizado. Las únicas escrituras son los ajustes del propio Amon SS y los reportes.
#>

$script:AmonVersion = '1.1.0'
$script:AmonBuildDate = '2026-10-21'
# tools\Build-Release.ps1 lo cambia a $true en el paquete: una release exige Integrity.psd1.
$script:AmonReleaseBuild = $false
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:IntegrityManifest = $null
$script:IntegrityLoaded = $false
$script:Settings = $null
$script:SettingsUserPath = $null
$script:HashCache = @{}

#region Versión, rutas y ajustes

function Get-AmonVersionInfo {
    [pscustomobject]@{
        Name      = 'AMON SS'
        Subtitle  = 'ADVANCED MINECRAFT FORENSIC SUITE'
        Version   = $script:AmonVersion
        BuildDate = $script:AmonBuildDate
        Root      = $script:RepoRoot
        PSVersion = $PSVersionTable.PSVersion.ToString()
        PSEdition = [string]$PSVersionTable.PSEdition
    }
}

function Get-AmonRoot { $script:RepoRoot }

function Get-AmonDataDirectory {
    # Carpeta de datos del usuario (ajustes y reportes). No se crea hasta que haga falta escribir.
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [IO.Path]::GetTempPath() }
    Join-Path $base 'AmonSS'
}

function ConvertTo-AmonHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-AmonHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-AmonHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return , @($InputObject | ForEach-Object { ConvertTo-AmonHashtable $_ })
    }
    return $InputObject
}

function Merge-AmonHashtable {
    # Combina $Override sobre $Base de forma recursiva (las listas se reemplazan).
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    if ($Override) {
        foreach ($k in $Override.Keys) {
            if ($result[$k] -is [hashtable] -and $Override[$k] -is [hashtable]) { $result[$k] = Merge-AmonHashtable $result[$k] $Override[$k] }
            else { $result[$k] = $Override[$k] }
        }
    }
    return $result
}

#region Integridad del paquete

function Get-AmonIntegrityManifest {
    # Integrity.psd1 (lo genera Build-Release y se firma con la release) fija el SHA-256 de cada
    # archivo del paquete. En una copia de desarrollo no existe; en una release es obligatorio.
    if (-not $script:IntegrityLoaded) {
        $p = Join-Path $script:RepoRoot 'Integrity.psd1'
        if (Test-Path -LiteralPath $p) {
            $raw = Import-PowerShellDataFile -LiteralPath $p
            $m = @{}
            foreach ($k in $raw.Keys) { $m[([string]$k).Replace('\', '/')] = [string]$raw[$k] }
            $script:IntegrityManifest = $m
        } elseif ($script:AmonReleaseBuild) {
            throw 'Paquete incompleto: falta Integrity.psd1. Borra esta copia y vuelve a instalar una versión verificada.'
        }
        $script:IntegrityLoaded = $true
    }
    return $script:IntegrityManifest
}

function Get-AmonPackagePath {
    # Ruta relativa al paquete con barras '/', o $null si el archivo está fuera (datos del usuario).
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Root = $script:RepoRoot)
    $full = [IO.Path]::GetFullPath($Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full.Substring($base.Length).Replace('\', '/')
}

function Get-AmonBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

function Read-AmonVerifiedBytes {
    # Lee el archivo UNA vez y comprueba el hash de esos mismos bytes: lo que se usa es
    # exactamente lo verificado (sin carrera entre comprobar y usar).
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $manifest = Get-AmonIntegrityManifest
    $rel = if ($manifest) { Get-AmonPackagePath -Path $Path } else { $null }
    if ($rel) {
        $expected = $manifest[$rel]
        if (-not $expected) { throw "Integridad del paquete comprometida: $rel no figura en Integrity.psd1." }
        if ((Get-AmonBytesSha256 -Bytes $bytes) -ne $expected) { throw "Integridad del paquete comprometida: $rel no coincide con Integrity.psd1." }
    }
    return , $bytes
}

function Read-AmonVerifiedText {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [Text.Encoding]::UTF8.GetString((Read-AmonVerifiedBytes -Path $Path))
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function Assert-AmonPackageFolder {
    # Comprueba que no falta ningún archivo del manifiesto en una carpeta del paquete (p. ej. una
    # firma borrada cambiaría los veredictos sin dar error).
    param([Parameter(Mandatory = $true)][string]$Folder, [string]$Filter = '*')
    $manifest = Get-AmonIntegrityManifest
    if (-not $manifest) { return }
    $prefix = (Get-AmonPackagePath -Path $Folder) + '/'
    foreach ($k in $manifest.Keys) {
        if ($k.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $k.Substring($prefix.Length) -like $Filter -and $k.Substring($prefix.Length) -notmatch '/') {
            if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $k))) { throw "Integridad del paquete comprometida: falta $k." }
        }
    }
}

function New-AmonIntegrityManifest {
    <#
    .SYNOPSIS
        Genera Integrity.psd1 en la raíz de un paquete con el SHA-256 de todos sus archivos.
        Lo usa tools\Build-Release.ps1 después de firmar los scripts.
    #>
    param([Parameter(Mandatory = $true)][string]$Root)
    $lines = @('# Amon SS - SHA-256 de cada archivo del paquete (generado por tools\Build-Release.ps1).', '@{')
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
        $rel = Get-AmonPackagePath -Path $f.FullName -Root $Root
        if ($rel -eq 'Integrity.psd1') { continue }
        $lines += "    '$($rel.Replace("'", "''"))' = '$(Get-AmonBytesSha256 -Bytes ([IO.File]::ReadAllBytes($f.FullName)))'"
    }
    $lines += '}'
    $path = Join-Path $Root 'Integrity.psd1'
    [IO.File]::WriteAllText($path, ($lines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($true))
    return $path
}

function Test-AmonPackageIntegrity {
    <#
    .SYNOPSIS
        Compara todos los archivos del paquete con Integrity.psd1: alterados, ausentes y añadidos.
    #>
    param([string]$Root = $script:RepoRoot)
    $p = Join-Path $Root 'Integrity.psd1'
    if (-not (Test-Path -LiteralPath $p)) { throw 'Esta copia no tiene Integrity.psd1 (copia de desarrollo): no hay nada con qué comparar.' }
    $raw = Import-PowerShellDataFile -LiteralPath $p
    $listed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($raw.Keys | Sort-Object)) {
        $rel = ([string]$k).Replace('\', '/'); [void]$listed.Add($rel)
        $full = Join-Path $Root $rel
        $actual = if (Test-Path -LiteralPath $full) { Get-AmonBytesSha256 -Bytes ([IO.File]::ReadAllBytes($full)) } else { $null }
        [pscustomobject]@{ File = $rel; Valid = ($actual -eq $raw[$k]); State = $(if (-not $actual) { 'AUSENTE' } elseif ($actual -eq $raw[$k]) { 'ÍNTEGRO' } else { 'ALTERADO' }); Expected = $raw[$k]; Actual = $actual }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        $rel = Get-AmonPackagePath -Path $f.FullName -Root $Root
        if ($rel -eq 'Integrity.psd1' -or $listed.Contains($rel)) { continue }
        [pscustomobject]@{ File = $rel; Valid = $false; State = 'NO INCLUIDO'; Expected = $null; Actual = (Get-AmonBytesSha256 -Bytes ([IO.File]::ReadAllBytes($f.FullName))) }
    }
}

#endregion

function Read-AmonJsonFile {
    # Los JSON del paquete (configuración) se verifican contra Integrity.psd1 si existe.
    param([Parameter(Mandatory = $true)][string]$Path)
    $raw = Read-AmonVerifiedText -Path $Path
    return ConvertTo-AmonHashtable ($raw | ConvertFrom-Json)
}

function Get-AmonSettings {
    <#
    .SYNOPSIS
        Devuelve los ajustes efectivos (predeterminados + overrides del usuario) como hashtable.
    #>
    [CmdletBinding()]
    param(
        [switch]$Reload,
        [string]$DefaultPath = (Join-Path $script:RepoRoot 'config\settings.json'),
        [string]$UserPath
    )
    if ($UserPath) { $script:SettingsUserPath = $UserPath }
    if (-not $script:SettingsUserPath) { $script:SettingsUserPath = Join-Path (Get-AmonDataDirectory) 'settings.json' }
    if ($script:Settings -and -not $Reload) { return $script:Settings }

    $defaults = Read-AmonJsonFile -Path $DefaultPath
    $user = $null
    if (Test-Path -LiteralPath $script:SettingsUserPath) {
        try { $user = Read-AmonJsonFile -Path $script:SettingsUserPath } catch { $user = $null }
    }
    $script:Settings = Merge-AmonHashtable $defaults $user
    $script:Settings['__userPath'] = $script:SettingsUserPath
    return $script:Settings
}

function Set-AmonSetting {
    <#
    .SYNOPSIS
        Cambia un ajuste (ruta con puntos, p. ej. 'limits.maxJarSizeMB'). -Persist lo guarda
        en el archivo del usuario, nunca en config\settings.json.
    #>
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Value, [switch]$Persist)
    $s = Get-AmonSettings
    $parts = $Name -split '\.'
    $node = $s
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not ($node[$parts[$i]] -is [hashtable])) { $node[$parts[$i]] = @{} }
        $node = $node[$parts[$i]]
    }
    $node[$parts[-1]] = $Value
    if ($Persist) {
        $userPath = $script:SettingsUserPath
        $user = @{}
        if (Test-Path -LiteralPath $userPath) { try { $user = Read-AmonJsonFile -Path $userPath } catch { $user = @{} } }
        if (-not $user) { $user = @{} }
        $unode = $user
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not ($unode[$parts[$i]] -is [hashtable])) { $unode[$parts[$i]] = @{} }
            $unode = $unode[$parts[$i]]
        }
        $unode[$parts[-1]] = $Value
        $dir = Split-Path -Parent $userPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($userPath, ($user | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Expand-AmonPath {
    # Expande %VARIABLES% de una ruta de configuración.
    param([string]$Path)
    if (-not $Path) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

#endregion

#region Identidad y privilegios

function Test-AmonAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-AmonCurrentUserSid {
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { return $null }
}

function New-AmonReviewId {
    $bytes = New-Object byte[] 3
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ('AMON-{0}-{1}' -f [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss'), ([BitConverter]::ToString($bytes) -replace '-', ''))
}

#endregion

#region Tiempo

function ConvertFrom-AmonFileTime {
    # FILETIME (100 ns desde 1601) -> DateTime UTC, o $null si es nulo / absurdo.
    param([Parameter(Mandatory = $true)][long]$FileTime)
    if ($FileTime -le 0) { return $null }
    try { $d = [DateTime]::FromFileTimeUtc($FileTime) } catch { return $null }
    if ($d.Year -lt 1990 -or $d.Year -gt 2100) { return $null }
    return $d
}

function ConvertTo-AmonUtc {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [string]) {
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
        return $null
    }
    $d = [datetime]$Value
    switch ($d.Kind) {
        'Utc' { return $d }
        'Local' { return $d.ToUniversalTime() }
        default { return [datetime]::SpecifyKind($d, [DateTimeKind]::Utc) }
    }
}

function Format-AmonTimestamp {
    # Fecha local legible con desplazamiento UTC; -Iso devuelve ISO 8601 en UTC.
    param([AllowNull()]$Utc, [switch]$Iso)
    $d = ConvertTo-AmonUtc $Utc
    if ($null -eq $d) { return '' }
    if ($Iso) { return $d.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    $local = $d.ToLocalTime()
    $off = [TimeZoneInfo]::Local.GetUtcOffset($local)
    $sign = '+'; if ($off.Ticks -lt 0) { $sign = '-' }
    return ('{0} UTC{1}{2:hh\:mm}' -f $local.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), $sign, $off.Duration())
}

function Get-AmonTimeZoneLabel {
    try { return [TimeZoneInfo]::Local.DisplayName } catch { return 'UTC' }
}

function Test-AmonInWindow {
    param($Context, [AllowNull()]$Utc)
    if ($null -eq $Utc) { return $false }
    $d = ConvertTo-AmonUtc $Utc
    return ($d -ge $Context.SinceUtc -and $d -le $Context.UntilUtc)
}

#endregion

#region Contrato de datos

function New-AmonEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$Path, $TimestampUtc,
        [ValidateSet('Execution', 'Presence', 'Deletion', 'Modification', 'Creation', 'Rename', 'LogLoaded', 'Configuration', 'Signature', 'System', 'Other')]
        [string]$Kind = 'Other'
    )
    [pscustomobject]@{
        PSTypeName   = 'AmonSS.Evidence'
        Source       = $Source
        Kind         = $Kind
        Description  = $Description
        Path         = $Path
        TimestampUtc = (ConvertTo-AmonUtc $TimestampUtc)
    }
}

function New-AmonFinding {
    <#
    .SYNOPSIS
        Crea un hallazgo. Estados: DETECTED (indicador presente), CORRELATED (varias fuentes
        independientes compatibles), INCONCLUSIVE (información insuficiente), NOT DETECTED,
        INFO (dato contextual sin valor acusatorio).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Category = 'General',
        [ValidateSet('DETECTED', 'CORRELATED', 'INCONCLUSIVE', 'NOT DETECTED', 'INFO')][string]$Status = 'DETECTED',
        [ValidateSet('Info', 'Low', 'Medium', 'High')][string]$Severity = 'Low',
        [ValidateSet('Low', 'Medium', 'High')][string]$Confidence = 'Low',
        [string]$Path,
        [string]$Sha256,
        $TimestampUtc,
        [string]$Indicator,
        [string]$IndicatorType,
        [string]$Client,
        [string]$ClientId,
        [string]$Source,
        [string]$Justification,
        [string[]]$FalsePositives = @(),
        [object[]]$Evidence = @(),
        [hashtable]$Data = @{}
    )
    $ev = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Evidence) { if ($null -ne $e) { $ev.Add($e) } }
    [pscustomobject]@{
        PSTypeName     = 'AmonSS.Finding'
        Id             = 'F-' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        Module         = $Module
        Category       = $Category
        Title          = $Title
        Status         = $Status
        Severity       = $Severity
        Confidence     = $Confidence
        Path           = $Path
        Sha256         = $(if ($Sha256) { $Sha256.ToLowerInvariant() } else { $null })
        TimestampUtc   = (ConvertTo-AmonUtc $TimestampUtc)
        Indicator      = $Indicator
        IndicatorType  = $IndicatorType
        Client         = $Client
        ClientId       = $ClientId
        Source         = $(if ($Source) { $Source } else { $Module })
        Justification  = $Justification
        FalsePositives = @($FalsePositives)
        Evidence       = $ev
        Data           = $Data
    }
}

function New-AmonEvent {
    <#
    .SYNOPSIS
        Evento para la línea temporal. Solo debe crearse a partir de un artefacto real.
    #>
    param(
        [Parameter(Mandatory = $true)]$TimestampUtc,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Path,
        [string]$Indicator,
        [ValidateSet('Low', 'Medium', 'High')][string]$Confidence = 'Medium',
        [ValidateSet('Execution', 'Presence', 'Deletion', 'Modification', 'Creation', 'Rename', 'LogLoaded', 'Configuration', 'Signature', 'System', 'Other')]
        [string]$Kind = 'Other',
        [string]$Description,
        [string]$Sha256,
        [hashtable]$Data = @{}
    )
    $utc = ConvertTo-AmonUtc $TimestampUtc
    if ($null -eq $utc) { throw 'Un evento de timeline necesita una fecha respaldada por un artefacto.' }
    [pscustomobject]@{
        PSTypeName   = 'AmonSS.Event'
        TimestampUtc = $utc
        Type         = $Type
        Kind         = $Kind
        Source       = $Source
        Path         = $Path
        Indicator    = $Indicator
        Confidence   = $Confidence
        Description  = $Description
        Sha256       = $(if ($Sha256) { $Sha256.ToLowerInvariant() } else { $null })
        Data         = $Data
    }
}

function New-AmonModuleResult {
    param([Parameter(Mandatory = $true)][string]$Module, [string]$DisplayName)
    [pscustomobject]@{
        PSTypeName        = 'AmonSS.ModuleResult'
        Module            = $Module
        DisplayName       = $(if ($DisplayName) { $DisplayName } else { $Module })
        Status            = 'Running'
        StartedUtc        = [datetime]::UtcNow
        FinishedUtc       = $null
        DurationMs        = 0
        ArtifactsReviewed = 0
        RequiresAdmin     = $false
        Findings          = [System.Collections.Generic.List[object]]::new()
        Events            = [System.Collections.Generic.List[object]]::new()
        Artifacts         = [System.Collections.Generic.List[object]]::new()
        Warnings          = [System.Collections.Generic.List[string]]::new()
        Limitations       = [System.Collections.Generic.List[string]]::new()
        Errors            = [System.Collections.Generic.List[string]]::new()
        Scope             = [System.Collections.Generic.List[string]]::new()
        Data              = @{}
    }
}

function Complete-AmonModuleResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [ValidateSet('Completed', 'Partial', 'NoAccess', 'Skipped', 'Failed', 'Cancelled')][string]$Status = 'Completed'
    )
    if ($Result.Status -eq 'Running' -or $Status -ne 'Completed') { $Result.Status = $Status }
    $Result.FinishedUtc = [datetime]::UtcNow
    $Result.DurationMs = [int]($Result.FinishedUtc - $Result.StartedUtc).TotalMilliseconds
    return $Result
}

#endregion

#region Contexto de revisión

function New-AmonContext {
    <#
    .SYNOPSIS
        Estado compartido de una revisión: ventana temporal, indicadores descubiertos,
        rutas de evidencia, caché de hashes y control de cancelación.
    #>
    param(
        [int]$Days = 7,
        $SinceUtc,
        $UntilUtc,
        [hashtable]$Settings = (Get-AmonSettings),
        [scriptblock]$OnProgress,
        [string[]]$AuthorizedScope = @()
    )
    $until = ConvertTo-AmonUtc $UntilUtc
    if (-not $until) { $until = [datetime]::UtcNow }
    $since = ConvertTo-AmonUtc $SinceUtc
    if (-not $since) { $since = $until.AddDays(-1 * [Math]::Max(1, $Days)) }

    $keywords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in @($Settings.keywords)) { if ($k) { [void]$keywords.Add([string]$k) } }

    [pscustomobject]@{
        PSTypeName      = 'AmonSS.Context'
        ReviewId        = New-AmonReviewId
        StartedUtc      = [datetime]::UtcNow
        SinceUtc        = $since
        UntilUtc        = $until
        # Sin fin explícito, Invoke-AmonModule lo adelanta a "ahora": lo que ocurra durante la
        # revisión (el juego abierto a petición, un borrado mientras se habla) sigue dentro.
        FixedUntil      = [bool]$UntilUtc
        Days            = [int][Math]::Round(($until - $since).TotalDays)
        IsAdmin         = (Test-AmonAdmin)
        UserName        = $env:USERNAME
        UserSid         = (Get-AmonCurrentUserSid)
        ComputerName    = $env:COMPUTERNAME
        TimeZone        = (Get-AmonTimeZoneLabel)
        Settings        = $Settings
        AuthorizedScope = [System.Collections.Generic.List[string]]::new([string[]]$AuthorizedScope)
        Keywords        = $keywords
        IndicatorNames  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        IndicatorHashes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        EvidencePaths   = [System.Collections.Generic.List[object]]::new()
        # Rutas que el revisor autoriza durante la sesión para el escaneo de firmas (menú 03).
        ExtraScanPaths  = [System.Collections.Generic.List[string]]::new()
        ScannedPaths    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Instances       = [System.Collections.Generic.List[object]]::new()
        Signatures      = $null
        Results         = [ordered]@{}
        HashCache       = @{}
        Deadline        = $null
        ModuleTimedOut  = $false
        CancelRequested = $false
        OnProgress      = $OnProgress
        Log             = [System.Collections.Generic.List[string]]::new()
    }
}

function Add-AmonIndicator {
    # Registra un indicador concreto descubierto (nombre de archivo y/o hash) para filtrar
    # y correlacionar los módulos posteriores.
    param([Parameter(Mandatory = $true)]$Context, [string]$FileName, [string]$Sha256, [string]$Keyword, [string]$Source)
    if ($FileName) {
        [void]$Context.IndicatorNames.Add($FileName)
        [void]$Context.Keywords.Add($FileName)
    }
    if ($Sha256) { [void]$Context.IndicatorHashes.Add($Sha256.ToLowerInvariant()) }
    if ($Keyword) { [void]$Context.Keywords.Add($Keyword) }
    if ($Source) { Write-AmonLog -Context $Context -Message "Indicador añadido por ${Source}: $FileName $Sha256 $Keyword" }
}

$script:DriveTypes = @{}

function Test-AmonLocalPath {
    # Las rutas sacadas de artefactos (accesos directos, -javaagent, perfiles, --gameDir) pueden
    # apuntar a \\servidor\recurso o a una unidad de red: tocarlas generaría tráfico SMB/WebDAV
    # (y autenticación NTLM). Solo se aceptan rutas absolutas de unidades locales.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\') { return $false }
    $root = $Path.Substring(0, 3).ToUpperInvariant()
    if (-not $script:DriveTypes.ContainsKey($root)) {
        $t = 'Unknown'; try { $t = ([IO.DriveInfo]::new($root)).DriveType.ToString() } catch { }
        $script:DriveTypes[$root] = $t
    }
    return $script:DriveTypes[$root] -in @('Fixed', 'Removable')
}

function Test-AmonUserWritablePath {
    # Carpetas del usuario o de otras unidades: donde suelen acabar las descargas y las
    # herramientas portables (no Windows, Program Files ni ProgramData).
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\') { return $false }
    $sys = ($env:SystemDrive + '\').ToUpperInvariant()
    $p = $Path.ToUpperInvariant()
    if (-not $p.StartsWith($sys)) { return $true }
    foreach ($ex in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432, $env:ProgramData)) {
        if ($ex -and $p.StartsWith($ex.TrimEnd('\').ToUpperInvariant() + '\')) { return $false }
    }
    return $p.StartsWith($sys + 'USERS\')
}

function Get-AmonScreenshareTool {
    # Nombre de la herramienta de SS conocida (knownScreenshareTools en los ajustes) a la que
    # pertenece un texto (ruta, servicio...), o $null. Sus rastros son del propio staff.
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyString()][string]$Text)
    if (-not $Text) { return $null }
    foreach ($t in @($Context.Settings.knownScreenshareTools)) {
        foreach ($p in @($t.patterns)) { if ($p -and $Text.IndexOf([string]$p, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$t.name } }
    }
    return $null
}

function Get-AmonToolByFileName {
    # Indicador de tipo filename (autoclicker, inyector, macro...) que coincide con un nombre de
    # ejecutable. Prefetch trunca el nombre a 29 caracteres: entonces vale el prefijo.
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyString()][string]$Name)
    if (-not $Name -or -not $Context.Signatures -or -not $Context.Signatures.PSObject.Properties['FileNames'] -or -not $Context.Signatures.FileNames) { return $null }
    $low = [IO.Path]::GetFileName($Name).ToLowerInvariant()
    $hit = $Context.Signatures.FileNames[$low]
    if (-not $hit -and $low.Length -ge 29) {
        $k = @($Context.Signatures.FileNames.Keys | Where-Object { $_.StartsWith($low) }) | Select-Object -First 1
        if ($k) { $hit = $Context.Signatures.FileNames[$k] }
    }
    if ($hit) { return $hit[0] }
    return $null
}

function New-AmonToolFinding {
    # Hallazgo por el nombre exacto de una herramienta conocida. Un nombre concreto y público
    # (fuerza media o alta) basta para afirmar que esa herramienta estuvo ahí; uno débil, no.
    param([string]$Module, [Parameter(Mandatory = $true)]$Indicator, [string]$Path, $TimestampUtc, [string]$What, [string]$Detail, [string]$Category = 'ToolExecution', [switch]$NotExecution)
    $solid = $Indicator.Validated -or $Indicator.Strength -in @('strong', 'medium')
    New-AmonFinding -Module $Module -Category $Category -Title $What -Status $(if ($solid) { 'DETECTED' } else { 'INCONCLUSIVE' }) -Severity Medium -Confidence $(if ($solid) { 'Medium' } else { 'Low' }) `
        -Path $Path -TimestampUtc $TimestampUtc -Indicator $Indicator.Value -IndicatorType 'filename' -Client $Indicator.ClientName -ClientId $Indicator.ClientId `
        -Source "$Module; firma: $($Indicator.Source)" `
        -Justification ("{0} El nombre '{1}' es el de {2} ({3}{4}). {5}" -f $Detail, $Indicator.Value, $Indicator.ClientName, $Indicator.Provenance, $(if ($Indicator.Validated) { ', validada' } else { ', sin validar' }), $(if ($Indicator.Note) { $Indicator.Note } else { '' })).Trim() `
        -FalsePositives @('Otro programa con el mismo nombre de archivo.') -Data @{ Execution = (-not $NotExecution) }
}

function Add-AmonEvidencePath {
    # Ruta mencionada por un artefacto (Prefetch, Recent, proceso...) que puede merecer
    # un escaneo de firmas si todavía existe. Las rutas de red se descartan.
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Path, [string]$Source, [string]$Reason)
    if (-not (Test-AmonLocalPath -Path $Path)) { return }
    foreach ($e in $Context.EvidencePaths) { if ($e.Path -ieq $Path) { return } }
    $Context.EvidencePaths.Add([pscustomobject]@{ Path = $Path; Source = $Source; Reason = $Reason })
}

function Test-AmonKeywordMatch {
    # Devuelve la primera palabra clave contenida en el texto (sin distinguir mayúsculas).
    param([AllowNull()][AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][AllowEmptyCollection()][object]$Keywords)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    foreach ($k in $Keywords) {
        if ($k -and $Text.IndexOf([string]$k, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$k }
    }
    return $null
}

function Write-AmonLog {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info')
    $Context.Log.Add(('{0} [{1}] {2}' -f [datetime]::UtcNow.ToString('HH:mm:ss.fff'), $Level, $Message))
}

function Update-AmonProgress {
    # Notifica progreso al orquestador (si escucha). Los módulos lo llaman periódicamente.
    param([Parameter(Mandatory = $true)]$Context, [double]$Percent, [string]$Detail, [int]$Count = -1)
    if ($Context.OnProgress) {
        try { & $Context.OnProgress $Percent $Detail $Count } catch { }
    }
}

function Test-AmonCancel {
    <#
    .SYNOPSIS
        Comprobación cooperativa de cancelación: Ctrl+C (si la consola lo entrega como
        entrada) o límite de tiempo del módulo. Los bucles largos deben consultarla.
    #>
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.CancelRequested) { return $true }
    if ($Context.Deadline -and [datetime]::UtcNow -gt $Context.Deadline) { $Context.ModuleTimedOut = $true; return $true }
    try {
        if ([Console]::TreatControlCAsInput -and -not [Console]::IsInputRedirected) {
            while ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ((($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -and $k.Key -eq [ConsoleKey]::C) {
                    $Context.CancelRequested = $true
                    return $true
                }
            }
        }
    } catch { }
    return $false
}

function Invoke-AmonModule {
    <#
    .SYNOPSIS
        Ejecuta un módulo con límite de tiempo cooperativo y aislamiento de errores: un módulo
        que falla queda registrado como Failed y el escaneo continúa.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]$Context,
        [int]$TimeoutSeconds = 0
    )
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = [int]$Context.Settings.moduleTimeoutSeconds }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 180 }
    if (-not $Context.FixedUntil) { $Context.UntilUtc = [datetime]::UtcNow }
    $Context.Deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $Context.ModuleTimedOut = $false
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $out = @(& $ScriptBlock $Context)
        $result = $out | Where-Object { $_ -and $_.PSObject.TypeNames -contains 'AmonSS.ModuleResult' } | Select-Object -Last 1
        if (-not $result) {
            $result = New-AmonModuleResult -Module $Name
            $result.Errors.Add('El módulo no devolvió un resultado.')
            $result.Status = 'Failed'
        }
    } catch {
        $result = New-AmonModuleResult -Module $Name
        $result.Errors.Add(('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message))
        $result.Status = 'Failed'
        Write-AmonLog -Context $Context -Level Error -Message "Módulo $Name falló: $($_.Exception.Message)"
    } finally {
        $Context.Deadline = $null
    }
    $sw.Stop()
    if ($Context.ModuleTimedOut -and $result.Status -in @('Completed', 'Running')) {
        $result.Status = 'Partial'
        $result.Limitations.Add("El módulo alcanzó su límite de tiempo ($TimeoutSeconds s); los resultados son parciales.")
    }
    if ($Context.CancelRequested -and $result.Status -in @('Completed', 'Running', 'Partial')) {
        $result.Status = 'Cancelled'
        $result.Limitations.Add('Revisión cancelada por el operador (Ctrl+C); resultados parciales.')
    }
    if ($result.Status -eq 'Running') { $result.Status = 'Completed' }
    if (-not $result.FinishedUtc) { $result.FinishedUtc = [datetime]::UtcNow }
    $result.DurationMs = [int]$sw.Elapsed.TotalMilliseconds
    $Context.Results[$Name] = $result
    return $result
}

#endregion

#region Archivos (solo lectura)

function Open-AmonReadStream {
    # Abre un archivo en solo lectura permitiendo que otros procesos lo sigan usando.
    param([Parameter(Mandatory = $true)][string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    return New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 65536, [IO.FileOptions]::SequentialScan)
}

function Read-AmonFileBytes {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaxBytes = 16MB)
    $fs = Open-AmonReadStream -Path $Path
    try {
        $len = [Math]::Min($fs.Length, $MaxBytes)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $fs.Read($buf, $read, [int]($len - $read))
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -lt $len) { [Array]::Resize([ref]$buf, $read) }
        return , $buf
    } finally { $fs.Dispose() }
}

function Get-AmonFileHash {
    <#
    .SYNOPSIS
        Hash de un archivo con caché por (ruta, tamaño, fecha de modificación).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('SHA256', 'SHA1')][string]$Algorithm = 'SHA256',
        $Context,
        [long]$MaxBytes = 0
    )
    try { $fi = New-Object IO.FileInfo($Path) } catch { return $null }
    if (-not $fi.Exists) { return $null }
    if ($MaxBytes -gt 0 -and $fi.Length -gt $MaxBytes) { return $null }
    $key = '{0}|{1}|{2}|{3}' -f $Algorithm, $fi.FullName, $fi.Length, $fi.LastWriteTimeUtc.Ticks
    $cache = if ($Context) { $Context.HashCache } else { $script:HashCache }
    if ($cache.ContainsKey($key)) { return $cache[$key] }
    $alg = if ($Algorithm -eq 'SHA1') { [Security.Cryptography.SHA1]::Create() } else { [Security.Cryptography.SHA256]::Create() }
    try {
        $fs = Open-AmonReadStream -Path $fi.FullName
        try { $hash = $alg.ComputeHash($fs) } finally { $fs.Dispose() }
    } catch { return $null } finally { $alg.Dispose() }
    $hex = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    $cache[$key] = $hex
    return $hex
}

function Get-AmonFileFacts {
    # Metadatos básicos de un archivo para hallazgos y timeline.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fi = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        [pscustomobject]@{
            Path        = $fi.FullName
            Name        = $fi.Name
            Length      = $(if ($fi.PSIsContainer) { $null } else { $fi.Length })
            CreatedUtc  = $fi.CreationTimeUtc
            ModifiedUtc = $fi.LastWriteTimeUtc
            AccessedUtc = $fi.LastAccessTimeUtc
            IsDirectory = [bool]$fi.PSIsContainer
            Attributes  = [string]$fi.Attributes
        }
    } catch { return $null }
}

function Get-AmonChildItemSafe {
    <#
    .SYNOPSIS
        Enumeración acotada (profundidad, número de archivos) que no sigue puntos de
        reanálisis para no salirse del alcance ni entrar en bucles.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Include = @('*'),
        [int]$Depth = 2,
        [int]$MaxItems = 5000,
        [switch]$Directories
    )
    $results = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    try { $root = New-Object IO.DirectoryInfo($Path) } catch { return @() }
    if (-not $root.Exists) { return @() }
    $queue.Enqueue(@($root, 0))
    while ($queue.Count -gt 0 -and $results.Count -lt $MaxItems) {
        $item = $queue.Dequeue()
        $dir = $item[0]; $level = $item[1]
        try {
            foreach ($pattern in $Include) {
                $entries = if ($Directories) { $dir.GetDirectories($pattern) } else { $dir.GetFiles($pattern) }
                foreach ($e in $entries) {
                    if ($results.Count -ge $MaxItems) { break }
                    $results.Add($e)
                }
            }
            if ($level -lt $Depth) {
                foreach ($sub in $dir.GetDirectories()) {
                    if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $queue.Enqueue(@($sub, ($level + 1)))
                }
            }
        } catch { }
    }
    return $results.ToArray()
}

#endregion

#region Privacidad

function Protect-AmonCommandLine {
    <#
    .SYNOPSIS
        Oculta valores sensibles de una línea de comando (tokens de sesión de Minecraft,
        contraseñas, JWT) antes de mostrarla o exportarla.
    #>
    param([AllowNull()][AllowEmptyString()][string]$CommandLine)
    if ([string]::IsNullOrEmpty($CommandLine)) { return $CommandLine }
    $s = $CommandLine
    $s = [regex]::Replace($s, '(?i)(--(?:accessToken|session|clientId|xuid|password|token|refreshToken|userProperties)\s+)("[^"]*"|\S+)', '$1[REDACTADO]')
    $s = [regex]::Replace($s, '(?i)(-D[^=\s]*(?:token|password|passwd|secret|session|auth)[^=\s]*=)("[^"]*"|\S+)', '$1[REDACTADO]')
    $s = [regex]::Replace($s, 'eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{4,}', '[REDACTADO-JWT]')
    return $s
}

#endregion

#region Código nativo

function Import-AmonNative {
    <#
    .SYNOPSIS
        Compila (una vez por proceso) modules\Native\AmonNative.cs: motor Aho-Corasick,
        descompresión MAM de Prefetch, lectura del USN Journal y consulta de auditoría.
    #>
    if ('AmonSS.Native.PatternMatcher' -as [type]) { return }
    $nativeDir = Join-Path $PSScriptRoot 'Native'
    # En una release, Integrity.psd1 fija el SHA-256 de cada .cs: si alguien modifica el código
    # C# después de publicarlo, no se compila. Se compila el mismo texto que se verificó.
    $core = Read-AmonVerifiedText -Path (Join-Path $nativeDir 'AmonNative.cs')
    $zip = Read-AmonVerifiedText -Path (Join-Path $nativeDir 'AmonZip.cs')
    # Una sola unidad de compilación: el escáner ZIP necesita System.IO.Compression. Se prueba con
    # las referencias por defecto (PowerShell 7 ya la incluye) y con la referencia explícita
    # (Windows PowerShell 5.1). Si nada funciona, se compila solo el núcleo y Signatures.psm1
    # usa su respaldo en PowerShell.
    $script:ZipNativeError = $null
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }
    $attempts = @(
        @{ Refs = $null },
        @{ Refs = @('System.IO.Compression', 'System.dll') },
        @{ Refs = @(([IO.Compression.ZipArchive].Assembly.Location), 'System.dll') }
    )
    foreach ($a in $attempts) {
        try {
            if ($a.Refs) { Add-Type -TypeDefinition ($core + "`n" + $zip) -Language CSharp -ReferencedAssemblies $a.Refs -ErrorAction Stop }
            else { Add-Type -TypeDefinition ($core + "`n" + $zip) -Language CSharp -ErrorAction Stop }
            return
        } catch { $script:ZipNativeError = $_.Exception.Message }
    }
    Add-Type -TypeDefinition $core -Language CSharp -ErrorAction Stop
}

function Test-AmonNativeZip {
    # $true si el escáner de ZIP en C# está disponible (si no, se usa el respaldo en PowerShell).
    return [bool]('AmonSS.Native.ZipContentScanner' -as [type])
}

#endregion

Export-ModuleMember -Function @(
    'Get-AmonVersionInfo', 'Get-AmonRoot', 'Get-AmonDataDirectory', 'ConvertTo-AmonHashtable', 'Merge-AmonHashtable',
    'Read-AmonJsonFile', 'Get-AmonSettings', 'Set-AmonSetting', 'Expand-AmonPath',
    'Get-AmonIntegrityManifest', 'Read-AmonVerifiedText', 'Assert-AmonPackageFolder', 'New-AmonIntegrityManifest', 'Test-AmonPackageIntegrity',
    'Test-AmonAdmin', 'Get-AmonCurrentUserSid', 'New-AmonReviewId',
    'ConvertFrom-AmonFileTime', 'ConvertTo-AmonUtc', 'Format-AmonTimestamp', 'Get-AmonTimeZoneLabel', 'Test-AmonInWindow',
    'New-AmonEvidence', 'New-AmonFinding', 'New-AmonEvent', 'New-AmonModuleResult', 'Complete-AmonModuleResult',
    'New-AmonContext', 'Add-AmonIndicator', 'Add-AmonEvidencePath', 'Test-AmonLocalPath', 'Test-AmonUserWritablePath', 'Get-AmonScreenshareTool', 'Get-AmonToolByFileName', 'New-AmonToolFinding', 'Test-AmonKeywordMatch', 'Write-AmonLog',
    'Update-AmonProgress', 'Test-AmonCancel', 'Invoke-AmonModule',
    'Open-AmonReadStream', 'Read-AmonFileBytes', 'Get-AmonFileHash', 'Get-AmonFileFacts', 'Get-AmonChildItemSafe',
    'Protect-AmonCommandLine', 'Import-AmonNative', 'Test-AmonNativeZip'
)
