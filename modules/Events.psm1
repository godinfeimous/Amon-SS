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
    $res.Scope.Add('Registros Security (4688, 1102), System (104), Windows Defender (1116/1117); claves Run/RunOnce.')
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
