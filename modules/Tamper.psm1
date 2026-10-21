#Requires -Version 5.1
<#
    Amon SS - modules/Tamper.psm1
    Señales de evasión de una SS, de solo lectura y sin administrador:

      * Servicios que alimentan los artefactos forenses (SysMain para Prefetch, PcaSvc, DPS,
        EventLog y el controlador bam): detenidos o deshabilitados, reiniciados mucho después
        del arranque (el proceso que los aloja es más reciente que el sistema), cambios del tipo
        de inicio (evento 7040) y caídas (7031/7034) dentro del periodo.
      * Cambios grandes de la hora del sistema (System, Microsoft-Windows-Kernel-General id 1):
        el evento guarda la hora nueva, la anterior, la diferencia y el programa que la cambió.
        Mover la hora atrás hace que lo ejecutado parezca antiguo.

    Nada de esto prueba trampas por sí solo: muchos programas de "optimización" desactivan
    SysMain o PcaSvc. Se informa para que el revisor lo valore junto al resto.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Prefetch.psm1') -DisableNameChecking

$script:ForensicServices = [ordered]@{
    SysMain  = @{ Why = 'mantiene los archivos Prefetch'; Severity = 'Low' }
    PcaSvc   = @{ Why = 'alimenta el Asistente de compatibilidad de programas (PCA)'; Severity = 'Low' }
    DPS      = @{ Why = 'su memoria guarda rastros de programas ejecutados que se revisan en las SS'; Severity = 'Low' }
    EventLog = @{ Why = 'escribe los registros de eventos de Windows'; Severity = 'Medium' }
    bam      = @{ Why = 'registra la última ejecución de cada programa (BAM)'; Severity = 'Medium' }
}
# Un servicio cuyo proceso arrancó más tarde que esto tras el inicio de Windows se reinició.
$script:RestartGraceMinutes = 10
# Diferencia mínima para considerar un cambio de hora (los ajustes de sincronización son de ms).
$script:TimeJumpMs = 120000

function Get-AmonServiceSnapshot {
    # Estado de los servicios forenses y la hora de arranque del proceso que los aloja.
    # Tres consultas CIM en total (cada una cuesta cientos de ms): todos los servicios, el
    # controlador bam y los procesos que alojan los servicios forenses.
    $out = [System.Collections.Generic.List[object]]::new()
    $all = @(Get-CimInstance Win32_Service -Property Name, DisplayName, State, StartMode, ProcessId -ErrorAction Stop)
    $perPid = @{}
    foreach ($s in $all) { if ($s.ProcessId) { $perPid[[int]$s.ProcessId] = 1 + [int]$perPid[[int]$s.ProcessId] } }
    $svcs = @($all | Where-Object { $script:ForensicServices.Contains([string]$_.Name) }) + @(Get-CimInstance Win32_SystemDriver -Filter "Name='bam'" -ErrorAction SilentlyContinue)
    $pids = @($svcs | Where-Object { $_.PSObject.Properties['ProcessId'] -and $_.ProcessId } | ForEach-Object { [int]$_.ProcessId } | Select-Object -Unique)
    $starts = @{}
    if ($pids.Count) {
        try {
            foreach ($p in @(Get-CimInstance Win32_Process -Filter (($pids | ForEach-Object { "ProcessId=$_" }) -join ' OR ') -Property ProcessId, CreationDate -ErrorAction Stop)) {
                if ($p.CreationDate) { $starts[[int]$p.ProcessId] = ([datetime]$p.CreationDate).ToUniversalTime() }
            }
        } catch { }
    }
    foreach ($s in $svcs) {
        $procId = if ($s.PSObject.Properties['ProcessId'] -and $s.ProcessId) { [int]$s.ProcessId } else { 0 }
        $out.Add([pscustomobject]@{
                Name = [string]$s.Name; DisplayName = [string]$s.DisplayName; State = [string]$s.State; StartMode = [string]$s.StartMode
                ProcessStartUtc = $(if ($procId) { $starts[$procId] } else { $null }); SharedProcess = ($procId -and [int]$perPid[$procId] -gt 1)
            })
    }
    return $out.ToArray()
}

function Get-AmonEventDataMap {
    # Campos con nombre del EventData de un evento (independientes del idioma del sistema).
    param([Parameter(Mandatory = $true)]$Event)
    $map = @{}
    $x = [xml]$Event.ToXml()
    foreach ($d in @($x.Event.EventData.Data)) { if ($d -and $d.Name) { $map[$d.Name] = $d.'#text' } }
    $bin = $x.Event.EventData.Binary
    if ($bin) {
        # El SCM guarda el nombre interno del servicio en UTF-16 dentro de Binary.
        $bytes = [byte[]]::new([int]($bin.Length / 2))
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($bin.Substring($i * 2, 2), 16) }
        $map['Binary'] = ([Text.Encoding]::Unicode.GetString($bytes)).TrimEnd([char]0)
    }
    return $map
}

function Get-AmonTimeChangeEvents {
    param([Parameter(Mandatory = $true)][datetime]$SinceUtc, [hashtable]$VolumeMap = @{})
    $out = [System.Collections.Generic.List[object]]::new()
    $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 1; StartTime = $SinceUtc.ToLocalTime() } -ErrorAction SilentlyContinue)
    foreach ($e in $evs) {
        $d = Get-AmonEventDataMap -Event $e
        $delta = 0L; [void][long]::TryParse([string]$d['TimeDeltaInMs'], [ref]$delta)
        $new = $null; $old = $null
        try { $new = ([datetime]$d['NewTime']).ToUniversalTime(); $old = ([datetime]$d['OldTime']).ToUniversalTime() } catch { }
        if (-not $d.ContainsKey('TimeDeltaInMs') -and $new -and $old) { $delta = [long]($new - $old).TotalMilliseconds }
        $proc = [string]$d['ProcessName']
        if ($proc) { $proc = Convert-AmonPrefetchPath -Path $proc -VolumeMap $VolumeMap }
        $out.Add([pscustomobject]@{ TimestampUtc = $e.TimeCreated.ToUniversalTime(); NewTimeUtc = $new; OldTimeUtc = $old; DeltaMs = $delta; Process = $proc })
    }
    return $out.ToArray()
}

function Get-AmonServiceControlEvents {
    # 7040 (cambio de tipo de inicio) y 7031/7034 (caída) de los servicios forenses.
    param([Parameter(Mandatory = $true)][datetime]$SinceUtc, [int[]]$Id)
    $out = [System.Collections.Generic.List[object]]::new()
    $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = $Id; StartTime = $SinceUtc.ToLocalTime() } -ErrorAction SilentlyContinue)
    foreach ($e in $evs) {
        $d = Get-AmonEventDataMap -Event $e
        $svc = if ($d['param4'] -and $e.Id -eq 7040) { [string]$d['param4'] } else { [string]$d['Binary'] }
        if (-not $script:ForensicServices.Contains($svc)) { continue }
        $out.Add([pscustomobject]@{ TimestampUtc = $e.TimeCreated.ToUniversalTime(); Id = $e.Id; Service = $svc; OldStart = [string]$d['param2']; NewStart = [string]$d['param3'] })
    }
    return $out.ToArray()
}

function Invoke-AmonTamperAnalysis {
    <#
    .SYNOPSIS
        Revisa servicios forenses y cambios de hora; devuelve un AmonSS.ModuleResult.
    .PARAMETER Services
        Instantánea de servicios ya leída (pruebas). Con -BootUtc, -TimeChanges,
        -StartTypeChanges y -Crashes permite ejecutar el análisis sin consultar Windows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [object[]]$Services, $BootUtc, [object[]]$TimeChanges, [object[]]$StartTypeChanges, [object[]]$Crashes)
    $res = New-AmonModuleResult -Module 'Tamper' -DisplayName 'Bypass & Tamper Check'
    $res.Scope.Add('Servicios SysMain, PcaSvc, DPS, EventLog y bam; registro System (Kernel-General 1, Service Control Manager 7040/7031/7034).')
    $live = $null -eq $Services
    try {
        if ($live) { $Services = @(Get-AmonServiceSnapshot) }
        if (-not $BootUtc) { $BootUtc = ([datetime](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime() }
    } catch { $res.Warnings.Add("No se pudo consultar el estado de los servicios: $($_.Exception.Message)") }
    # Las rutas \Device\... de los cambios de hora se traducen después, solo si hay alguno grande.
    if ($null -eq $TimeChanges) { $TimeChanges = @(Get-AmonTimeChangeEvents -SinceUtc $Context.SinceUtc) }
    $volumeMap = $null
    if ($null -eq $StartTypeChanges) { $StartTypeChanges = @(Get-AmonServiceControlEvents -SinceUtc $Context.SinceUtc -Id 7040) }
    if ($null -eq $Crashes) { $Crashes = @(Get-AmonServiceControlEvents -SinceUtc $Context.SinceUtc -Id 7031, 7034) }
    $res.Data['BootUtc'] = $BootUtc

    foreach ($s in @($Services)) {
        $res.ArtifactsReviewed++
        $def = $script:ForensicServices[$s.Name]
        if (-not $def) { continue }
        $res.Artifacts.Add([pscustomobject]@{ Service = $s.Name; DisplayName = $s.DisplayName; State = $s.State; StartMode = $s.StartMode; ProcessStartUtc = $s.ProcessStartUtc })
        if ($s.StartMode -eq 'Disabled' -or $s.State -ne 'Running') {
            $res.Findings.Add((New-AmonFinding -Module 'Tamper' -Category 'ServiceDisabled' -Title "Servicio forense $(if ($s.StartMode -eq 'Disabled') { 'deshabilitado' } else { 'detenido' }): $($s.Name)" -Status INCONCLUSIVE -Severity $def.Severity -Confidence Low `
                        -Indicator "$($s.Name): $($s.State), inicio $($s.StartMode)" -IndicatorType 'service' `
                        -Justification "$($s.DisplayName) ($($s.Name)) $($def.Why). Con el servicio detenido Windows deja de generar esos rastros." `
                        -FalsePositives @('Muchos programas y guías de optimización desactivan SysMain o PcaSvc para "ganar rendimiento".', 'Algunas ediciones o configuraciones corporativas los desactivan.')))
        } elseif ($s.ProcessStartUtc -and $BootUtc -and -not $s.SharedProcess -and ($s.ProcessStartUtc - [datetime]$BootUtc).TotalMinutes -gt $script:RestartGraceMinutes) {
            $res.Findings.Add((New-AmonFinding -Module 'Tamper' -Category 'ServiceRestarted' -Title "Servicio forense reiniciado después del arranque: $($s.Name)" -Status INCONCLUSIVE -Severity $def.Severity -Confidence Low `
                        -TimestampUtc $s.ProcessStartUtc -Indicator "$($s.Name) arrancó el $(Format-AmonTimestamp $s.ProcessStartUtc); Windows arrancó el $(Format-AmonTimestamp $BootUtc)" -IndicatorType 'service' `
                        -Justification "$($s.DisplayName) ($($s.Name)) $($def.Why). Reiniciarlo borra lo que tenía en memoria; su proceso es más reciente que el arranque de Windows." `
                        -FalsePositives @('Windows reinicia servicios tras actualizaciones o si fallan.', 'Herramientas de optimización o de limpieza.')))
            if (Test-AmonInWindow -Context $Context -Utc $s.ProcessStartUtc) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $s.ProcessStartUtc -Type "Servicio $($s.Name) reiniciado" -Kind System -Source 'Tamper' -Confidence Low -Description $def.Why))
            }
        }
    }
    foreach ($c in @($StartTypeChanges | Where-Object { $_ -and (Test-AmonInWindow -Context $Context -Utc $_.TimestampUtc) })) {
        $def = $script:ForensicServices[$c.Service]
        $res.Findings.Add((New-AmonFinding -Module 'Tamper' -Category 'ServiceStartTypeChanged' -Title "Cambio del tipo de inicio de $($c.Service)" -Status DETECTED -Severity Medium -Confidence Medium `
                    -TimestampUtc $c.TimestampUtc -Indicator "$($c.OldStart) -> $($c.NewStart)" -IndicatorType 'event 7040' `
                    -Justification "El Service Control Manager registró el cambio el $(Format-AmonTimestamp $c.TimestampUtc). El servicio $($def.Why)." `
                    -FalsePositives @('Programas de optimización y actualizaciones de Windows cambian el tipo de inicio de servicios.')))
        $res.Events.Add((New-AmonEvent -TimestampUtc $c.TimestampUtc -Type "Tipo de inicio de $($c.Service) cambiado" -Kind System -Source 'Tamper' -Confidence Medium -Description "$($c.OldStart) -> $($c.NewStart)"))
    }
    foreach ($c in @($Crashes | Where-Object { $_ -and (Test-AmonInWindow -Context $Context -Utc $_.TimestampUtc) })) {
        $res.Findings.Add((New-AmonFinding -Module 'Tamper' -Category 'ServiceCrashed' -Title "El servicio $($c.Service) terminó de forma inesperada" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                    -TimestampUtc $c.TimestampUtc -Indicator "evento $($c.Id)" -IndicatorType 'event' `
                    -Justification "El Service Control Manager registró la caída el $(Format-AmonTimestamp $c.TimestampUtc). Terminar el proceso del servicio es una forma de borrar su memoria." `
                    -FalsePositives @('Fallos reales del servicio o del sistema.')))
    }
    foreach ($t in @($TimeChanges | Where-Object { $_ -and (Test-AmonInWindow -Context $Context -Utc $_.TimestampUtc) })) {
        $res.ArtifactsReviewed++
        if ([Math]::Abs([double]$t.DeltaMs) -lt $script:TimeJumpMs) { continue }
        $minutes = [Math]::Round([double]$t.DeltaMs / 60000, 1)
        if ($t.Process -match '^\\Device\\') {
            if ($null -eq $volumeMap) { $volumeMap = Get-AmonVolumeMap }
            $t.Process = Convert-AmonPrefetchPath -Path $t.Process -VolumeMap $volumeMap
        }
        $proc = if ($t.Process) { $t.Process } else { 'desconocido' }
        $res.Findings.Add((New-AmonFinding -Module 'Tamper' -Category 'SystemTimeChanged' -Title ("Hora del sistema cambiada {0}{1} min" -f $(if ($minutes -gt 0) { '+' } else { '' }), $minutes) -Status DETECTED -Severity Medium -Confidence High `
                    -Path $t.Process -TimestampUtc $t.TimestampUtc -Indicator ("{0} -> {1} por {2}" -f (Format-AmonTimestamp $t.OldTimeUtc), (Format-AmonTimestamp $t.NewTimeUtc), [IO.Path]::GetFileName($proc)) -IndicatorType 'event Kernel-General 1' `
                    -Justification 'Windows registró el cambio de hora y el programa que lo hizo. Mover la hora hace que los archivos y ejecuciones parezcan de otro momento.' `
                    -FalsePositives @('Corrección manual de una hora mal puesta.', 'Pila de la placa base agotada (la hora vuelve atrás al arrancar).')))
        $res.Events.Add((New-AmonEvent -TimestampUtc $t.TimestampUtc -Type 'Hora del sistema cambiada' -Kind System -Source 'Tamper' -Path $t.Process -Confidence High -Description "$minutes min"))
    }
    $res.Limitations.Add('Un servicio detenido o reiniciado, o un cambio de hora, no prueban trampas: indican que los rastros de Windows pueden estar incompletos.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('Get-AmonServiceSnapshot', 'Get-AmonEventDataMap', 'Get-AmonTimeChangeEvents', 'Get-AmonServiceControlEvents', 'Invoke-AmonTamperAnalysis')
