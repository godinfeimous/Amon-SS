#Requires -Version 5.1
<#
    Amon SS - modules/Events.psm1
    Eventos de Windows e inicio automático (solo lectura).

      * Security 4688 (creación de procesos) filtrado a Java/launchers/indicadores, indicando si
        la auditoría necesaria está habilitada (AuditQuerySystemPolicy) y si incluye la línea
        de comandos.
      * Security 1102: se borró el registro de Seguridad. No tiene relación con la papelera.
      * System 104: se borró otro registro de eventos (Application, System...).
      * Defender 1116/1117 cuyas rutas o amenazas están relacionadas con la revisión.
      * Claves Run/RunOnce de HKCU y HKLM (incluida WOW6432Node).

    No modifica el registro, la auditoría ni los registros de eventos.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:ProcessCreationGuid = [guid]'0CCE922B-69AE-11D9-BED3-505054503030'
$script:RunKeys = @(
    @('HKCU', 'Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'),
    @('HKCU', 'RunOnce', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'),
    @('HKLM', 'Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'),
    @('HKLM', 'RunOnce', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'),
    @('HKLM', 'Run (WOW6432Node)', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')
)

function Get-AmonRunValueExecutable {
    # Ejecutable de un comando de inicio automático (con o sin comillas).
    param([AllowEmptyString()][string]$Value)
    if (-not $Value) { return $null }
    $v = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if ($v.StartsWith('"')) {
        $end = $v.IndexOf('"', 1)
        if ($end -gt 1) { return $v.Substring(1, $end - 1) }
    }
    $m = [regex]::Match($v, '^(.+?\.(exe|bat|cmd|com|vbs|ps1|jar|dll|scr))(\s|$)', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($v -split '\s+')[0]
}

function Get-AmonAuditProcessCreation {
    # ¿Está habilitada la auditoría "Creación del proceso" (4688)? ¿Incluye la línea de comandos?
    $cmd = $null
    try {
        $key = Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit' -ErrorAction Stop
        $cmd = ($key.GetValue('ProcessCreationIncludeCmdLine_Enabled') -eq 1)
    } catch [System.Management.Automation.ItemNotFoundException] { $cmd = $false } catch { $cmd = $null }
    $flags = -1; $err = 0
    try { Import-AmonNative; $flags = [AmonSS.Native.AuditPolicy]::QuerySubcategory($script:ProcessCreationGuid, [ref]$err) } catch { $flags = -1 }
    if ($flags -ge 0) {
        return [pscustomobject]@{ Enabled = (($flags -band 1) -ne 0); Failure = (($flags -band 2) -ne 0); Source = 'AuditQuerySystemPolicy'; CommandLineIncluded = $cmd }
    }
    return [pscustomobject]@{ Enabled = $null; Failure = $null; Source = "sin acceso (código $err)"; CommandLineIncluded = $cmd }
}

function Get-AmonEventDataValue {
    # Valor de un campo de EventData/UserData por nombre (independiente del idioma del sistema).
    param([xml]$Xml, [string]$Name)
    $node = $Xml.SelectSingleNode("//*[local-name()='Data' and @Name='$Name']")
    if ($node) { return $node.InnerText }
    $node = $Xml.SelectSingleNode("//*[local-name()='$Name']")
    if ($node) { return $node.InnerText }
    return $null
}

function Test-AmonNoEvents {
    param($ErrorRecord)
    return ($ErrorRecord.FullyQualifiedErrorId -like 'NoMatchingEventsFound*')
}

function Get-AmonEventSources {
    <#
    .SYNOPSIS
        Lee las fuentes reales (registros de eventos y claves Run). Cada fuente falla por separado.
    #>
    param([Parameter(Mandatory = $true)]$Context)
    $src = @{
        SecurityAccessible = $false; SecurityOldestUtc = $null; Audit = (Get-AmonAuditProcessCreation)
        Security4688 = @(); Security1102 = @(); System104 = @(); Defender = @(); RunEntries = @(); Truncated4688 = $false
        System7045 = @(); Ntfs501 = @(); DefenderConfig = @(); AppCrash = @()
        Errors = [System.Collections.Generic.List[string]]::new()
    }
    $since = $Context.SinceUtc.ToLocalTime()
    try {
        $o = Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction Stop
        $src.SecurityAccessible = $true
        $src.SecurityOldestUtc = $o.TimeCreated.ToUniversalTime()
    } catch {
        if (Test-AmonNoEvents $_) { $src.SecurityAccessible = $true } else { $src.Errors.Add("Security: $($_.Exception.Message)") }
    }
    if ($src.SecurityAccessible) {
        try {
            $max = 30000
            $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4688; StartTime = $since } -MaxEvents $max -ErrorAction Stop)
            $src.Truncated4688 = ($evs.Count -ge $max)
            $src.Security4688 = @($evs | ForEach-Object {
                    $p = $_.Properties
                    [pscustomobject]@{
                        TimeCreated = $_.TimeCreated.ToUniversalTime()
                        NewProcessName = $(if ($p.Count -gt 5) { [string]$p[5].Value } else { $null })
                        CommandLine = $(if ($p.Count -gt 8) { [string]$p[8].Value } else { $null })
                        ParentProcessName = $(if ($p.Count -gt 13) { [string]$p[13].Value } else { $null })
                        SubjectUserName = $(if ($p.Count -gt 1) { [string]$p[1].Value } else { $null })
                    }
                })
        } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("4688: $($_.Exception.Message)") } }
        try {
            $src.Security1102 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 1102 } -MaxEvents 50 -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); SubjectUserName = (Get-AmonEventDataValue -Xml ([xml]$_.ToXml()) -Name 'SubjectUserName') }
                })
        } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("1102: $($_.Exception.Message)") } }
    }
    try {
        $src.System104 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 104 } -MaxEvents 50 -ErrorAction Stop | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Eventlog' } | ForEach-Object {
                $x = [xml]$_.ToXml()
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); Channel = (Get-AmonEventDataValue -Xml $x -Name 'Channel'); SubjectUserName = (Get-AmonEventDataValue -Xml $x -Name 'SubjectUserName') }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("System 104: $($_.Exception.Message)") } }
    try {
        $src.Defender = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117; StartTime = $since } -MaxEvents 500 -ErrorAction Stop | ForEach-Object {
                $x = [xml]$_.ToXml()
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); EventId = $_.Id; Threat = (Get-AmonEventDataValue -Xml $x -Name 'Threat Name'); Path = (Get-AmonEventDataValue -Xml $x -Name 'Path'); Action = (Get-AmonEventDataValue -Xml $x -Name 'Action Name') }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("Defender: $($_.Exception.Message)") } }
    # Eventos activados por defecto que delatan preparación o evasión (sin administrador).
    $named = { param($ev) $x = [xml]$ev.ToXml(); $m = @{}; foreach ($d in @($x.Event.EventData.Data)) { if ($d -and $d.Name) { $m[$d.Name] = [string]$d.'#text' } }; $m }
    try {
        $src.System7045 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7045; StartTime = $since } -MaxEvents 500 -ErrorAction Stop | ForEach-Object {
                $d = & $named $_
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); ServiceName = $d['ServiceName']; ImagePath = $d['ImagePath']; ServiceType = $d['ServiceType']; StartType = $d['StartType'] }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("7045: $($_.Exception.Message)") } }
    try {
        $src.Ntfs501 = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Ntfs/Operational'; Id = 501; StartTime = $since } -MaxEvents 2000 -ErrorAction Stop | ForEach-Object {
                $d = & $named $_
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); ProcessName = $d['ProcessName']; VolumeName = $d['VolumeName']; JournalId = $d['JournalId'] }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("Ntfs 501: $($_.Exception.Message)") } }
    try {
        $src.DefenderConfig = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 5001, 5007; StartTime = $since } -MaxEvents 500 -ErrorAction Stop | ForEach-Object {
                $d = & $named $_
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); EventId = $_.Id; NewValue = $d['New Value']; OldValue = $d['Old Value'] }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("Defender 5001/5007: $($_.Exception.Message)") } }
    try {
        $src.AppCrash = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -MaxEvents 500 -ErrorAction Stop | ForEach-Object {
                $d = & $named $_
                [pscustomobject]@{ TimeCreated = $_.TimeCreated.ToUniversalTime(); AppName = $d['AppName']; AppPath = $d['AppPath']; ModuleName = $d['ModuleName']; ModulePath = $d['ModulePath']; ExceptionCode = $d['ExceptionCode'] }
            })
    } catch { if (-not (Test-AmonNoEvents $_)) { $src.Errors.Add("Application Error 1000: $($_.Exception.Message)") } }
    $runs = [System.Collections.Generic.List[object]]::new()
    foreach ($rk in $script:RunKeys) {
        try {
            $key = Get-Item -LiteralPath $rk[2] -ErrorAction Stop
            foreach ($n in $key.GetValueNames()) { if ($n) { $runs.Add([pscustomobject]@{ Hive = $rk[0]; Key = $rk[1]; Name = $n; Value = [string]$key.GetValue($n) }) } }
        } catch { }
    }
    $src.RunEntries = $runs.ToArray()
    return $src
}

function Invoke-AmonEventAnalysis {
    <#
    .SYNOPSIS
        Analiza eventos de Windows e inicio automático. -Injected permite pruebas sin el sistema real.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [hashtable]$Injected)
    $res = New-AmonModuleResult -Module 'Events' -DisplayName 'Windows Event Analysis'
    $res.Scope.Add('Registros Security (4688, 1102), System (104, 7045), Ntfs/Operational (501), Application (1000), Windows Defender (1116/1117, 5001, 5007); claves Run/RunOnce.')
    $src = if ($Injected) { $Injected } else { Get-AmonEventSources -Context $Context }
    foreach ($e in @($src.Errors)) { $res.Warnings.Add($e) }
    $res.Data['Audit'] = $src.Audit
    $res.Data['SecurityAccessible'] = $src.SecurityAccessible
    $launchers = @($Context.Settings.launcherProcessNames)
    $keywords = @($Context.Keywords); $indicators = @($Context.IndicatorNames)
    $clientKeywords = if ($Context.Signatures) { @($Context.Signatures.Keywords) } else { @() }
    $partial = $false

    if (-not $src.SecurityAccessible) {
        $partial = $true
        $res.RequiresAdmin = $true
        $res.Warnings.Add('El registro de Seguridad (4688, 1102) solo pueden leerlo administradores o el grupo "Lectores del registro de eventos". Ejecuta Amon SS como administrador para incluirlo.')
    } else {
        if ($src.SecurityOldestUtc -and $src.SecurityOldestUtc -gt $Context.SinceUtc) {
            $res.Limitations.Add("El registro de Seguridad solo conserva eventos desde $(Format-AmonTimestamp $src.SecurityOldestUtc) (tamaño máximo alcanzado o registro borrado).")
        }
        if ($src.Audit.Enabled -eq $false) {
            $res.Limitations.Add('La auditoría de creación de procesos (evento 4688) no está habilitada: la ausencia de eventos 4688 no es evidencia de nada.')
        } elseif ($null -eq $src.Audit.Enabled) {
            $res.Limitations.Add('No se pudo comprobar si la auditoría de creación de procesos (4688) está habilitada.')
        }
        if ($src.Audit.CommandLineIncluded -eq $false) { $res.Limitations.Add('Los eventos 4688 no incluyen la línea de comandos (directiva no habilitada).') }
        if ($src.Truncated4688) { $res.Limitations.Add('Se revisaron solo los 30000 eventos 4688 más recientes del periodo.') }

        foreach ($e in @($src.Security4688)) {
            $res.ArtifactsReviewed++
            $name = [string]$e.NewProcessName
            $leaf = [IO.Path]::GetFileName($name)
            $reason = $null
            if ($indicators | Where-Object { $_ -ieq $leaf -or ([string]$e.CommandLine).IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) { $reason = 'indicador' }
            elseif ($launchers -contains $leaf) { $reason = 'Java o launcher' }
            elseif ($k = Test-AmonKeywordMatch -Text $name -Keywords $keywords) { $reason = "palabra clave '$k'" }
            if (-not $reason) { continue }
            $res.Artifacts.Add([pscustomobject]@{
                    EventId = 4688; TimeUtc = $e.TimeCreated; Process = $name; Parent = $e.ParentProcessName; User = $e.SubjectUserName
                    CommandLine = (Protect-AmonCommandLine ([string]$e.CommandLine)); Relevance = $reason; Description = 'Proceso creado'
                })
            $res.Events.Add((New-AmonEvent -TimestampUtc $e.TimeCreated -Type 'Proceso creado (evento 4688)' -Kind Execution -Source 'Security 4688' -Path $name -Confidence High -Description "Padre: $($e.ParentProcessName)"))
            if ($reason -eq 'indicador') {
                $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'ExecutionEvidence' -Title "Evento 4688 relacionado con un indicador: $leaf" -Status DETECTED -Severity Medium -Confidence High `
                            -Path $name -TimestampUtc $e.TimeCreated -Indicator $leaf -IndicatorType 'process' -Justification 'El registro de Seguridad documenta la creación de este proceso, relacionado por nombre o línea de comandos con un indicador de otro módulo.' `
                            -FalsePositives @('Coincidencia por nombre.') -Data @{ Execution = $true }))
            } elseif ($clientKeywords | Where-Object { $name.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) {
                $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'KeywordName' -Title "Proceso con nombre relacionado (4688): $leaf" -Status INCONCLUSIVE -Severity Low -Confidence Low -Path $name -TimestampUtc $e.TimeCreated -Indicator $reason -IndicatorType 'keyword' -Justification 'Coincidencia de nombre con un cliente.' -FalsePositives @('Coincidencia casual.')))
            }
        }
        foreach ($e in @($src.Security1102)) {
            $res.ArtifactsReviewed++
            $res.Artifacts.Add([pscustomobject]@{ EventId = 1102; TimeUtc = $e.TimeCreated; Process = $null; Parent = $null; User = $e.SubjectUserName; CommandLine = $null; Relevance = 'Integridad de registros'; Description = 'Registro de Seguridad borrado' })
            $res.Events.Add((New-AmonEvent -TimestampUtc $e.TimeCreated -Type 'Registro de Seguridad borrado (1102)' -Kind System -Source 'Security 1102' -Confidence High -Description "Usuario: $($e.SubjectUserName)"))
            $inWin = Test-AmonInWindow -Context $Context -Utc $e.TimeCreated
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'SecurityLogCleared' -Title 'Se borró el registro de Seguridad de Windows (evento 1102)' -Status $(if ($inWin) { 'DETECTED' } else { 'INFO' }) -Severity $(if ($inWin) { 'Medium' } else { 'Info' }) -Confidence High `
                        -TimestampUtc $e.TimeCreated -Indicator 'Evento 1102' -IndicatorType 'event' `
                        -Justification ("El evento 1102 indica que el registro de Seguridad se vació el {0} (cuenta: {1}). No guarda relación con la papelera de reciclaje y no revela qué contenía el registro borrado." -f (Format-AmonTimestamp $e.TimeCreated), $e.SubjectUserName) `
                        -FalsePositives @('Mantenimiento del sistema o políticas corporativas que vacían el registro.')))
        }
    }
    foreach ($e in @($src.System104)) {
        $res.ArtifactsReviewed++
        $res.Artifacts.Add([pscustomobject]@{ EventId = 104; TimeUtc = $e.TimeCreated; Process = $null; Parent = $null; User = $e.SubjectUserName; CommandLine = $null; Relevance = 'Integridad de registros'; Description = "Registro '$($e.Channel)' borrado" })
        $res.Events.Add((New-AmonEvent -TimestampUtc $e.TimeCreated -Type "Registro de eventos '$($e.Channel)' borrado (104)" -Kind System -Source 'System 104' -Confidence High -Description "Usuario: $($e.SubjectUserName)"))
        if (Test-AmonInWindow -Context $Context -Utc $e.TimeCreated) {
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'EventLogCleared' -Title "Se borró el registro de eventos '$($e.Channel)' (evento 104)" -Status DETECTED -Severity Low -Confidence High `
                        -TimestampUtc $e.TimeCreated -Indicator 'Evento 104' -IndicatorType 'event' -Justification "Windows registró el vaciado del registro '$($e.Channel)' por la cuenta $($e.SubjectUserName). Describe el hecho, no el motivo." `
                        -FalsePositives @('Herramientas de limpieza, instaladores o mantenimiento del sistema.')))
        }
    }
    foreach ($d in @($src.Defender)) {
        $res.ArtifactsReviewed++
        $text = "$($d.Threat) $($d.Path)"
        $rel = (Test-AmonKeywordMatch -Text $text -Keywords (@($keywords) + @($indicators))) -or ([string]$d.Path -match '(?i)\.jar\b')
        if (-not $rel) { continue }
        $res.Artifacts.Add([pscustomobject]@{ EventId = $d.EventId; TimeUtc = $d.TimeCreated; Process = $d.Path; Parent = $null; User = $null; CommandLine = $null; Relevance = 'Windows Defender'; Description = "$($d.Threat) - $($d.Action)" })
        $res.Events.Add((New-AmonEvent -TimestampUtc $d.TimeCreated -Type "Windows Defender: detección ($($d.EventId))" -Kind Presence -Source 'Defender' -Path $d.Path -Indicator $d.Threat -Confidence High))
        $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'DefenderDetection' -Title "Windows Defender detectó '$($d.Threat)'" -Status DETECTED -Severity Medium -Confidence High `
                    -Path $d.Path -TimestampUtc $d.TimeCreated -Indicator $d.Threat -IndicatorType 'defender' -Justification "Defender registró una detección relacionada con la revisión (acción: $($d.Action))." `
                    -FalsePositives @('Defender clasifica como HackTool algunas herramientas legítimas (inyectores de mods, autoclickers de accesibilidad).')))
    }
    # Servicios y drivers instalados en el periodo (7045): un driver desde una carpeta de usuario
    # es raro y es la forma de cargar herramientas a nivel de núcleo.
    foreach ($s in @($src.System7045)) {
        $res.ArtifactsReviewed++
        $img = [string]$s.ImagePath
        if ($img -match '^\\\?\?\\') { $img = $img.Substring(4) }
        $img = [Environment]::ExpandEnvironmentVariables($img.Trim('"'))
        $userFolder = Test-AmonUserWritablePath -Path $img
        $kw = Test-AmonKeywordMatch -Text "$($s.ServiceName) $img" -Keywords (@($indicators) + @($clientKeywords))
        if (-not $userFolder -and -not $kw) { continue }
        $res.Artifacts.Add([pscustomobject]@{ EventId = 7045; TimeUtc = $s.TimeCreated; Process = $img; Parent = $null; User = $null; CommandLine = $null; Relevance = $(if ($kw) { "palabra clave '$kw'" } else { 'desde carpeta de usuario' }); Description = "Servicio o driver instalado: $($s.ServiceName) ($($s.ServiceType))" })
        $res.Events.Add((New-AmonEvent -TimestampUtc $s.TimeCreated -Type 'Servicio o driver instalado (7045)' -Kind Creation -Source 'System 7045' -Path $img -Confidence High -Description "$($s.ServiceName); $($s.ServiceType)"))
        if ($tool = Get-AmonScreenshareTool -Context $Context -Text "$($s.ServiceName) $img") {
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'ScreenshareTool' -Title "Driver de la herramienta de SS $($tool): $($s.ServiceName)" -Status INFO -Severity Info -Confidence High `
                        -Path $img -TimestampUtc $s.TimeCreated -Indicator $tool -IndicatorType 'event 7045' -Justification 'Coincide con una herramienta de SS conocida (knownScreenshareTools): es un rastro del propio staff, no del jugador.'))
            continue
        }
        $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'DriverInstalled' -Title "Servicio o driver instalado desde una carpeta de usuario: $($s.ServiceName)" -Status INCONCLUSIVE -Severity Medium -Confidence Medium `
                    -Path $img -TimestampUtc $s.TimeCreated -Indicator "$($s.ServiceType); $($s.StartType)" -IndicatorType 'event 7045' `
                    -Justification ("Windows registró la instalación del servicio '{0}' el {1} con el binario en {2}. Los drivers permiten ocultar o manipular procesos y memoria." -f $s.ServiceName, (Format-AmonTimestamp $s.TimeCreated), $img) `
                    -FalsePositives @('Las herramientas de SS (Ocean, Echo...) y algunos antitrampas o utilidades de hardware instalan su propio driver: comprueba si es la que usó el staff.')))
        if ((Test-AmonLocalPath -Path $img) -and [IO.File]::Exists($img)) { Add-AmonEvidencePath -Context $Context -Path $img -Source 'Events (7045)' -Reason 'driver instalado' }
    }
    # USN Journal eliminado (Ntfs/Operational 501). SearchIndexer lo registra a menudo sin borrar nada.
    foreach ($u in @($src.Ntfs501)) {
        $res.ArtifactsReviewed++
        if ([string]$u.ProcessName -match '^(?i)SearchIndexer' -or -not (Test-AmonInWindow -Context $Context -Utc $u.TimeCreated)) { continue }
        $res.Events.Add((New-AmonEvent -TimestampUtc $u.TimeCreated -Type 'USN Journal eliminado (Ntfs 501)' -Kind Deletion -Source 'Ntfs 501' -Path $u.ProcessName -Confidence High -Description "Volumen $($u.VolumeName)"))
        $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'UsnJournalDeleted' -Title "USN Journal de $($u.VolumeName) eliminado por $($u.ProcessName)" -Status DETECTED -Severity High -Confidence High `
                    -TimestampUtc $u.TimeCreated -Indicator "$($u.ProcessName) - Journal $($u.JournalId)" -IndicatorType 'event Ntfs 501' `
                    -Justification ("NTFS registró que {0} eliminó el USN Journal de {1} el {2}. Borrar el journal destruye el historial de creación, borrado y renombrado de archivos." -f $u.ProcessName, $u.VolumeName, (Format-AmonTimestamp $u.TimeCreated)) `
                    -FalsePositives @('Herramientas de mantenimiento de disco o de optimización que recrean el journal.')))
    }
    # Defender: exclusiones añadidas (5007) y protección en tiempo real desactivada (5001).
    foreach ($d in @($src.DefenderConfig)) {
        $res.ArtifactsReviewed++
        if (-not (Test-AmonInWindow -Context $Context -Utc $d.TimeCreated)) { continue }
        if ($d.EventId -eq 5007 -and [string]$d.NewValue -match '\\Exclusions\\(Paths|Processes|Extensions)\\(.+?)\s*=') {
            $what = $Matches[2]
            $res.Events.Add((New-AmonEvent -TimestampUtc $d.TimeCreated -Type 'Exclusión añadida a Windows Defender' -Kind System -Source 'Defender 5007' -Path $what -Confidence High))
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'DefenderExclusion' -Title "Exclusión añadida a Windows Defender ($($Matches[1]))" -Status INCONCLUSIVE -Severity Medium -Confidence High `
                        -Path $(if ($Matches[1] -eq 'Paths') { $what } else { $null }) -TimestampUtc $d.TimeCreated -Indicator $what -IndicatorType 'event 5007' `
                        -Justification "Defender dejó de vigilar '$what' desde el $(Format-AmonTimestamp $d.TimeCreated). Es habitual para que el antivirus no borre clientes, inyectores o autoclickers." `
                        -FalsePositives @('Exclusiones legítimas de juegos, herramientas de desarrollo o software que el antivirus bloquea por error.')))
        } elseif ($d.EventId -eq 5001) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $d.TimeCreated -Type 'Protección en tiempo real de Defender desactivada' -Kind System -Source 'Defender 5001' -Confidence High))
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'DefenderDisabled' -Title 'Se desactivó la protección en tiempo real de Windows Defender' -Status INCONCLUSIVE -Severity Low -Confidence High `
                        -TimestampUtc $d.TimeCreated -Indicator 'evento 5001' -IndicatorType 'event' `
                        -Justification "Defender registró la desactivación el $(Format-AmonTimestamp $d.TimeCreated)." `
                        -FalsePositives @('Otro antivirus instalado desactiva Defender.', 'Desactivación temporal para instalar un programa.')))
        }
    }
    # Caídas de Java o de launchers causadas por una DLL ajena al runtime y a Windows.
    $sysDirs = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\').ToUpperInvariant() + '\' }
    foreach ($c in @($src.AppCrash)) {
        $res.ArtifactsReviewed++
        if ([string]$c.AppName -notin $launchers -or -not (Test-AmonInWindow -Context $Context -Utc $c.TimeCreated)) { continue }
        $mod = [string]$c.ModulePath
        $appHome = if ($c.AppPath) { (Split-Path -Parent (Split-Path -Parent ([string]$c.AppPath))).ToUpperInvariant() + '\' } else { $null }
        $foreign = $mod -and -not ($sysDirs | Where-Object { $mod.ToUpperInvariant().StartsWith($_) }) -and -not ($appHome -and $mod.ToUpperInvariant().StartsWith($appHome))
        $res.Events.Add((New-AmonEvent -TimestampUtc $c.TimeCreated -Type "$($c.AppName) se cerró por un error" -Kind System -Source 'Application 1000' -Path $c.AppPath -Confidence High -Description "Módulo: $($c.ModuleName); excepción $($c.ExceptionCode)"))
        if (-not $foreign) { continue }
        $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'JavaCrashForeignModule' -Title "$($c.AppName) se cerró por un fallo en una DLL ajena: $($c.ModuleName)" -Status INCONCLUSIVE -Severity Medium -Confidence Medium `
                    -Path $mod -TimestampUtc $c.TimeCreated -Indicator "$($c.ModuleName) (excepción $($c.ExceptionCode))" -IndicatorType 'event 1000' `
                    -Justification ("Windows registró que {0} se cerró el {1} por un fallo dentro de {2}, que no es del runtime de Java ni de Windows. Las DLL inyectadas en el juego suelen provocar estos cierres." -f $c.AppName, (Format-AmonTimestamp $c.TimeCreated), $mod) `
                    -FalsePositives @('Nativas de mods (chat de voz, grabación) o superposiciones (Discord, OBS, RivaTuner) también pueden fallar.')))
        if ((Test-AmonLocalPath -Path $mod) -and [IO.File]::Exists($mod)) { Add-AmonEvidencePath -Context $Context -Path $mod -Source 'Events (1000)' -Reason 'DLL que hizo caer a Java' }
    }
    foreach ($r in @($src.RunEntries)) {
        $exe = Get-AmonRunValueExecutable $r.Value
        # Solo los nombres de clientes o indicadores concretos generan hallazgo; los launchers
        # (Lunar, Badlion...) que arrancan con Windows son normales y solo se listan.
        $why = $null; $related = $null
        if ($k = Test-AmonKeywordMatch -Text "$($r.Name) $($r.Value)" -Keywords (@($indicators) + @($clientKeywords))) { $why = "palabra clave '$k'" }
        elseif ($k = Test-AmonKeywordMatch -Text "$($r.Name) $($r.Value)" -Keywords $keywords) { $related = "relacionado ('$k')" }
        $res.Artifacts.Add([pscustomobject]@{ EventId = 'Run'; TimeUtc = $null; Process = $exe; Parent = "$($r.Hive)\$($r.Key)"; User = $null; CommandLine = $r.Value; Relevance = $(if ($why) { $why } elseif ($related) { $related } else { 'Inicio automático' }); Description = $r.Name })
        if ($why) {
            $res.Findings.Add((New-AmonFinding -Module 'Events' -Category 'AutorunRelated' -Title "Inicio automático relacionado: $($r.Name)" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -Path $exe -Indicator $why -IndicatorType 'autorun' -Justification "La clave $($r.Hive)\$($r.Key) arranca '$($r.Value)' al iniciar sesión y contiene una palabra clave de la revisión." `
                        -FalsePositives @('Launchers legítimos (Lunar, Badlion, CurseForge) se registran para iniciar con Windows.')))
            if ($exe -and (Test-Path -LiteralPath $exe -PathType Leaf)) { Add-AmonEvidencePath -Context $Context -Path $exe -Source 'Events (Run)' -Reason $why }
        }
    }
    $res.Data['RunEntries'] = @($src.RunEntries).Count
    if ($partial) { return Complete-AmonModuleResult -Result $res -Status Partial }
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('Get-AmonRunValueExecutable', 'Get-AmonAuditProcessCreation', 'Get-AmonEventSources', 'Invoke-AmonEventAnalysis')
