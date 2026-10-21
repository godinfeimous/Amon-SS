#Requires -Version 5.1
<#
    Amon SS - modules/Views.psm1
    Vistas de terminal de cada módulo (tablas, paneles y tarjetas) construidas con UI.psm1.
    Solo presentan resultados ya calculados: no analizan ni modifican nada.
#>

Import-Module (Join-Path $PSScriptRoot 'UI.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Timeline.psm1') -DisableNameChecking

$script:StatusToken = @{ 'CORRELATED' = 'finding'; 'DETECTED' = 'finding'; 'INCONCLUSIVE' = 'warning'; 'NOT DETECTED' = 'success'; 'INFO' = 'secondary' }
$script:ModuleState = @{ Completed = 'Ok'; Partial = 'Warn'; NoAccess = 'Warn'; Skipped = 'Skip'; Failed = 'Error'; Cancelled = 'Warn' }
$script:ModuleStateEs = @{ Completed = 'COMPLETADO'; Partial = 'PARCIAL'; NoAccess = 'SIN ACCESO'; Skipped = 'OMITIDO'; Failed = 'ERROR'; Cancelled = 'CANCELADO' }
$script:ConfEs = @{ High = 'Alta'; Medium = 'Media'; Low = 'Baja' }

function Get-AmonMaxRows {
    param($Context)
    $n = 40
    if ($Context -and $Context.Settings.limits.maxTableRows) { $n = [int]$Context.Settings.limits.maxTableRows }
    return $n
}

function Show-AmonModuleStatus {
    # Una línea de estado por módulo con duración, artefactos y hallazgos.
    param([Parameter(Mandatory = $true)]$Result)
    $state = $script:ModuleState[[string]$Result.Status]; if (-not $state) { $state = 'Info' }
    $label = $script:ModuleStateEs[[string]$Result.Status]; if (-not $label) { $label = [string]$Result.Status }
    $detail = '{0:n1} s · {1} artefactos · {2} hallazgos' -f ($Result.DurationMs / 1000.0), $Result.ArtifactsReviewed, $Result.Findings.Count
    Write-AmonStatus -Label $Result.DisplayName -Value $label -State $state -Detail $detail
}

function Show-AmonModuleNotes {
    # Advertencias, errores y limitaciones de un módulo.
    param([Parameter(Mandatory = $true)]$Result, [int]$Max = 6)
    foreach ($e in @($Result.Errors | Select-Object -First $Max)) { Write-AmonWarning -Label 'ERROR' -Message $e }
    foreach ($w in @($Result.Warnings | Select-Object -First $Max)) { Write-AmonWarning -Message $w }
    if ($Result.Warnings.Count -gt $Max) { Write-AmonWarning -Message "$($Result.Warnings.Count - $Max) advertencia(s) más en el reporte." }
    foreach ($l in @($Result.Limitations | Select-Object -First $Max)) { Write-AmonWarning -Label 'LÍMITE' -Message $l }
}

function Show-AmonFindingList {
    # Tarjetas de hallazgos, ordenadas por estado y severidad (INFO al final).
    param([object[]]$Findings = @(), [int]$Max = 12, [switch]$IncludeInfo)
    $order = @{ 'CORRELATED' = 0; 'DETECTED' = 1; 'INCONCLUSIVE' = 2; 'INFO' = 3 }
    $sev = @{ High = 0; Medium = 1; Low = 2; Info = 3 }
    $list = @($Findings | Where-Object { $IncludeInfo -or $_.Status -ne 'INFO' } | Sort-Object { $order[[string]$_.Status] }, { $sev[[string]$_.Severity] })
    foreach ($f in ($list | Select-Object -First $Max)) { Write-AmonFinding -Finding $f }
    if ($list.Count -gt $Max) { Write-AmonWarning -Label 'MÁS' -Message "$($list.Count - $Max) hallazgo(s) adicionales en el reporte exportado." }
}

function Show-AmonMinecraftView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    $max = Get-AmonMaxRows $Context
    Write-AmonSection -Title 'MINECRAFT ANALYSIS' -Subtitle 'Instalado = JAR presente en la carpeta mods. Cargado = el log de una sesión lo menciona.'
    Write-AmonTable -Title 'INSTANCIAS' -Rows @($Result.Data['Instances']) -Columns @(
        @{ Header = 'INSTANCIA'; Property = 'Name' },
        @{ Header = 'LAUNCHER'; Property = 'Launcher' },
        @{ Header = 'LOADER'; Property = { param($r) (@($r.Loader, $r.LoaderVersion) | Where-Object { $_ }) -join ' ' } },
        @{ Header = 'MC'; Property = 'MinecraftVersion' },
        @{ Header = 'MODS'; Property = { param($r) "$($r.LoadedMods)/$($r.Mods)" }; Align = 'Right' },
        @{ Header = 'LOGS'; Property = 'Logs'; Align = 'Right' },
        @{ Header = 'RUTA'; Property = 'GameDir'; IsPath = $true }
    ) -EmptyText 'No se encontraron instancias de Minecraft Java.'
    if ($Result.Artifacts.Count) {
        Write-AmonTable -Title 'MODS INSTALADOS / CARGADOS' -MaxRows $max -Rows @($Result.Artifacts | Sort-Object @{ e = { if ($_.Loaded -eq 'Sí') { 0 } else { 1 } } }, Instance, FileName) -Columns @(
            @{ Header = 'ARCHIVO'; Property = 'FileName'; MinWidth = 12 },
            @{ Header = 'MOD ID'; Property = 'ModId' },
            @{ Header = 'VERSIÓN'; Property = 'Version' },
            @{ Header = 'CARGADO'; Property = 'Loaded'; Token = { param($r) switch ($r.Loaded) { 'Sí' { 'success' } 'Sin logs' { 'warning' } default { 'muted' } } } },
            @{ Header = 'MODIFICADO'; Property = { param($r) if ($r.ModifiedUtc) { $r.ModifiedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
            @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true }
        )
    }
    $versions = @($Result.Data['Versions'])
    if ($versions.Count) {
        $hs = @{ Verified = 'Verificado'; Mismatch = 'NO COINCIDE'; NotDeclared = 'Sin hash declarado'; NoJar = 'Sin JAR'; Unreadable = 'Ilegible' }
        Write-AmonTable -Title 'PERFILES DE VERSIÓN' -MaxRows $max -Rows $versions -Columns @(
            @{ Header = 'INSTANCIA'; Property = 'Instance' },
            @{ Header = 'ID'; Property = 'Id' },
            @{ Header = 'LOADER'; Property = 'Loader' },
            @{ Header = 'SHA-1 DEL JAR'; Property = { param($r) $hs[[string]$r.HashStatus] }; Token = { param($r) switch ($r.HashStatus) { 'Verified' { 'success' } 'Mismatch' { 'finding' } default { 'muted' } } } },
            @{ Header = 'CLASE PRINCIPAL'; Property = { param($r) if ($r.MainClassKnown) { 'reconocida' } elseif ($r.MainClass) { $r.MainClass } else { '-' } }; Token = { param($r) if ($r.MainClassKnown) { 'muted' } else { 'warning' } } }
        )
    }
    $sessions = @($Result.Data['Sessions'] | Sort-Object StartUtc -Descending)
    if ($sessions.Count) {
        Write-AmonTable -Title 'SESIONES REGISTRADAS EN LOGS' -MaxRows ([Math]::Min($max, 15)) -Rows $sessions -Columns @(
            @{ Header = 'INSTANCIA'; Property = 'Instance' },
            @{ Header = 'INICIO'; Property = { param($r) if ($r.StartUtc) { $r.StartUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
            @{ Header = 'LOADER'; Property = { param($r) (@($r.Loader, $r.LoaderVersion) | Where-Object { $_ }) -join ' ' } },
            @{ Header = 'MC'; Property = 'MinecraftVersion' },
            @{ Header = 'USUARIO'; Property = 'Username' },
            @{ Header = 'CLIENTE'; Property = 'ClientBrand' },
            @{ Header = 'MODS'; Property = 'ModCount'; Align = 'Right' }
        )
    }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonSignatureView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'CHEAT SIGNATURE SCANNER' -Subtitle 'Firmas con fuente citada. Las aportadas por el usuario o secundarias se limitan a confianza media.'
    $det = @($Result.Artifacts | Where-Object Result -EQ 'Detección').Count
    $inc = @($Result.Artifacts | Where-Object Result -EQ 'No concluyente').Count
    $lines = @(
        "Archivos escaneados : $($Result.ArtifactsReviewed)",
        "Con detección       : $det",
        "No concluyentes     : $inc",
        "Firmas cargadas     : $($Result.Data['Clients']) clientes, $($Result.Data['Indicators']) indicadores"
    )
    if ($Result.Data['ClientsWithoutSignatures']) { $lines += 'Sin firmas verificables: ' + (@($Result.Data['ClientsWithoutSignatures']) -join ', ') }
    Write-AmonBox -Title 'RESUMEN' -Lines $lines
    if (-not $Result.Findings.Count) { Write-AmonStatus -Label 'Coincidencias de firmas' -Value 'NINGUNA' -State Ok -Detail 'en el alcance analizado' }
    Show-AmonFindingList -Findings @($Result.Findings) -Max 15
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonProcessView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'PROCESS INSPECTOR' -Subtitle 'Solo lectura: no se finalizan procesos ni se lee su memoria.'
    Write-AmonTable -Title 'PROCESOS RELEVANTES' -Rows @($Result.Artifacts) -Columns @(
        @{ Header = 'PROCESO'; Property = 'Name' },
        @{ Header = 'PID'; Property = 'ProcessId'; Align = 'Right' },
        @{ Header = 'PADRE'; Property = { param($r) "$($r.ParentName) ($($r.ParentProcessId))" } },
        @{ Header = 'TIPO'; Property = 'Kind' },
        @{ Header = 'FIRMA'; Property = { param($r) if ($r.Signer) { $r.Signer } else { $r.SignatureStatus } }; Token = { param($r) if ($r.SignatureStatus -eq 'Valid') { 'success' } else { 'warning' } } },
        @{ Header = 'INICIO'; Property = { param($r) if ($r.StartUtc) { $r.StartUtc.ToLocalTime().ToString('MM-dd HH:mm') } } },
        @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true }
    ) -EmptyText 'No hay Java, launchers ni procesos relacionados en ejecución.'
    foreach ($j in @($Result.Artifacts | Where-Object Kind -EQ 'Java')) {
        $lines = @()
        if ($j.Details) { foreach ($d in ($j.Details -split ' \| ')) { $lines += (Get-AmonGlyph 'Arrow') + ' ' + (ConvertTo-AmonSafeText $d) } }
        if ($j.Username) { $lines += (Get-AmonGlyph 'Arrow') + " usuario: $(ConvertTo-AmonSafeText $j.Username)" }
        if ($j.CommandLine) { $lines += '---'; foreach ($c in (Split-AmonWrap -Text $j.CommandLine -Width ((Get-AmonPanelWidth) - 6) | Select-Object -First 6)) { $lines += $c } }
        Write-AmonBox -Title "JAVA PID $($j.ProcessId)" -Lines $lines -Style Single
    }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonPrefetchView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'PREFETCH ANALYZER' -Subtitle 'Prefetch prueba ejecución de un programa; por sí solo no demuestra el uso de trampas.'
    if ($Result.Status -eq 'NoAccess') { Show-AmonModuleNotes -Result $Result; return }
    Write-AmonTable -Title "PREFETCH RELEVANTES ($($Result.Artifacts.Count) de $($Result.Data['Total']))" -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object LastRunUtc -Descending) -Columns @(
        @{ Header = 'EJECUTABLE'; Property = 'ExecutableName' },
        @{ Header = 'EJEC.'; Property = 'RunCount'; Align = 'Right' },
        @{ Header = 'ÚLTIMA EJECUCIÓN'; Property = { param($r) if ($r.LastRunUtc) { $r.LastRunUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } } },
        @{ Header = 'JAR'; Property = { param($r) @($r.ReferencedJars).Count }; Align = 'Right' },
        @{ Header = 'RUTA'; Property = { param($r) if ($r.ExecutablePath) { $r.ExecutablePath } else { $r.PrefetchFile } }; IsPath = $true }
    )
    foreach ($a in @($Result.Artifacts | Where-Object { @($_.ReferencedJars).Count })) {
        $lines = @($a.ReferencedJars | Select-Object -First 15 | ForEach-Object { (Get-AmonGlyph 'Arrow') + ' ' + (ConvertTo-AmonSafeText $_) })
        if (@($a.ReferencedJars).Count -gt 15) { $lines += "... y $(@($a.ReferencedJars).Count - 15) más" }
        Write-AmonBox -Title "JAR CARGADOS POR $($a.ExecutableName)" -Lines $lines -Style Single
    }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonRecycleView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'RECYCLE BIN FORENSICS' -Subtitle 'Solo lectura: no se restaura, mueve ni elimina nada. Los artefactos describen operaciones, no intenciones.'
    $activity = @($Result.Data['Activity'])
    $cats = @('Eliminación registrada', 'Inconsistencia de metadatos', 'Archivo asociado ausente', 'Actividad correlacionada', 'Evidencia insuficiente')
    $tok = @{ 'Eliminación registrada' = 'accent'; 'Inconsistencia de metadatos' = 'warning'; 'Archivo asociado ausente' = 'warning'; 'Actividad correlacionada' = 'finding'; 'Evidencia insuficiente' = 'muted' }
    $lines = @()
    foreach ($c in $cats) {
        $n = @($activity | Where-Object Category -EQ $c).Count
        $lines += (Format-AmonColor (Get-AmonGlyph 'Diamond') $tok[$c]) + ' ' + (Format-AmonColor $c.PadRight(30) 'primary') + (Format-AmonColor ([string]$n) $tok[$c] -Bold)
    }
    $lines += '---'
    $w = (Get-AmonPanelWidth) - 6
    foreach ($a in @($activity | Sort-Object TimestampUtc -Descending | Select-Object -First 25)) {
        $when = if ($a.TimestampUtc) { $a.TimestampUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '----------------' }
        $lines += (Format-AmonColor (Get-AmonGlyph 'Arrow') $tok[$a.Category]) + ' ' + (Format-AmonColor $when 'secondary') + '  ' + (Format-AmonColor (Format-AmonText -Text $a.Category -Width 27) $tok[$a.Category]) + ' ' + (Format-AmonColor (Format-AmonPath -Path ([string]$a.Path) -Width ([Math]::Max(10, $w - 48))) 'primary')
        foreach ($d in (Split-AmonWrap -Text $a.Description -Width ($w - 4) | Select-Object -First 3)) { $lines += '    ' + (Format-AmonColor $d 'muted') }
    }
    Write-AmonBox -Title 'RECYCLE BIN ACTIVITY' -Lines $lines -RightLabel "$($Context.Days) DÍAS"
    if ($Result.Artifacts.Count) {
        Write-AmonTable -Title 'ELEMENTOS RELEVANTES EN LA PAPELERA' -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object DeletedUtc -Descending) -Columns @(
            @{ Header = 'NOMBRE ORIGINAL'; Property = 'OriginalName' },
            @{ Header = 'ELIMINADO'; Property = { param($r) if ($r.DeletedUtc) { $r.DeletedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
            @{ Header = '$R'; Property = { param($r) if ($r.DataExists) { 'presente' } else { 'AUSENTE' } }; Token = { param($r) if ($r.DataExists) { 'success' } else { 'warning' } } },
            @{ Header = 'INCIDENCIAS'; Property = { param($r) @($r.Issues) -join ', ' }; Token = 'warning' },
            @{ Header = 'RUTA ORIGINAL'; Property = 'OriginalPath'; IsPath = $true }
        )
    }
    if ($Result.Data['UnrelatedCount']) { Write-AmonStatus -Label 'Elementos no relacionados' -Value ([string]$Result.Data['UnrelatedCount']) -State Info -Detail 'contados, no mostrados (privacidad)' }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonUsnView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'NTFS / USN JOURNAL' -Subtitle 'Solo lectura. Rutas reconstruidas con la ubicación actual del directorio padre.'
    if ($Result.Status -eq 'NoAccess') { Show-AmonModuleNotes -Result $Result; return }
    Write-AmonTable -Title 'JOURNALS' -Rows @($Result.Data['Journals']) -Columns @(
        @{ Header = 'UNIDAD'; Property = 'Drive' },
        @{ Header = 'REGISTROS'; Property = 'TotalRecords'; Align = 'Right' },
        @{ Header = 'RELEVANTES'; Property = 'Matched'; Align = 'Right' },
        @{ Header = 'DESDE'; Property = { param($r) if ($r.FirstRecordUtc) { $r.FirstRecordUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
        @{ Header = 'HASTA'; Property = { param($r) if ($r.LastRecordUtc) { $r.LastRecordUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
        @{ Header = 'MÁX. MB'; Property = 'MaximumSizeMB'; Align = 'Right' }
    )
    $ra = @($Result.Data['RecycleActivity'])
    if ($ra.Count) {
        Write-AmonTable -Title 'ACTIVIDAD DE PAPELERA SEGÚN EL JOURNAL' -MaxRows 25 -Rows @($ra | Sort-Object TimestampUtc -Descending) -Columns @(
            @{ Header = 'FECHA'; Property = { param($r) $r.TimestampUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } },
            @{ Header = 'OPERACIÓN'; Property = 'Operation' },
            @{ Header = 'NOMBRE ORIGINAL'; Property = { param($r) if ($r.OriginalName) { $r.OriginalName } else { '(no relevante u oculto)' } } },
            @{ Header = 'CARPETA ORIGINAL'; Property = 'OriginalFolder'; IsPath = $true }
        )
    }
    Write-AmonTable -Title 'REGISTROS RELEVANTES' -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object TimestampUtc -Descending) -Columns @(
        @{ Header = 'FECHA'; Property = { param($r) $r.TimestampUtc.ToLocalTime().ToString('MM-dd HH:mm:ss') } },
        @{ Header = 'OPERACIÓN'; Property = 'Operation'; Token = { param($r) if ($r.Operation -eq 'Eliminación') { 'warning' } else { 'secondary' } } },
        @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true },
        @{ Header = 'FIABILIDAD'; Property = { param($r) if ($r.ParentPath) { 'ruta reconstruida' } else { 'solo nombre' } } }
    )
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonRecentView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'RECENT FILES' -Subtitle 'Solo accesos relacionados con la revisión; el resto se cuenta por privacidad.'
    Write-AmonTable -Title 'ACCESOS RECIENTES RELEVANTES' -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object LastOpenedUtc -Descending) -Columns @(
        @{ Header = 'ÚLTIMA APERTURA'; Property = { param($r) $r.LastOpenedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } },
        @{ Header = 'PRIMERA'; Property = { param($r) $r.FirstOpenedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } },
        @{ Header = 'EXISTE'; Property = { param($r) if ($r.TargetExists) { 'sí' } else { 'no' } } },
        @{ Header = 'MOTIVO'; Property = 'Relevance' },
        @{ Header = 'DESTINO'; Property = 'TargetPath'; IsPath = $true }
    )
    if ($Result.Data['UnrelatedCount']) { Write-AmonStatus -Label 'Accesos no relacionados' -Value ([string]$Result.Data['UnrelatedCount']) -State Info -Detail 'contados, no mostrados' }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonUserAssistView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'USERASSIST' -Subtitle 'Programas iniciados desde el Explorador (nombres decodificados de ROT13).'
    Write-AmonTable -Title 'ENTRADAS RELEVANTES' -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object LastRunUtc -Descending) -Columns @(
        @{ Header = 'ÚLTIMA EJECUCIÓN'; Property = { param($r) if ($r.LastRunUtc) { $r.LastRunUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } },
        @{ Header = 'EJEC.'; Property = 'RunCount'; Align = 'Right' },
        @{ Header = 'FOCO (s)'; Property = 'FocusSeconds'; Align = 'Right' },
        @{ Header = 'TIPO'; Property = 'Category' },
        @{ Header = 'PROGRAMA'; Property = 'ResolvedPath'; IsPath = $true }
    )
    if ($Result.Data['UnrelatedCount']) { Write-AmonStatus -Label 'Entradas no relacionadas' -Value ([string]$Result.Data['UnrelatedCount']) -State Info -Detail 'contadas, no mostradas' }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonEventView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'WINDOWS EVENT ANALYSIS' -Subtitle 'El evento 1102 es la limpieza del registro de Seguridad; no tiene relación con la papelera.'
    $a = $Result.Data['Audit']
    $auditText = if ($null -eq $a -or $null -eq $a.Enabled) { 'no verificable (requiere privilegios)' } elseif ($a.Enabled) { 'HABILITADA' } else { 'DESHABILITADA' }
    $cmdText = if ($null -eq $a -or $null -eq $a.CommandLineIncluded) { 'desconocido' } elseif ($a.CommandLineIncluded) { 'sí' } else { 'no' }
    Write-AmonBox -Title 'AUDITORÍA' -Lines @(
        "Creación de procesos (4688) : $auditText",
        "Incluye línea de comandos   : $cmdText",
        "Registro de Seguridad       : $(if ($Result.Data['SecurityAccessible']) { 'accesible' } else { 'sin acceso' })",
        "Entradas de inicio (Run)    : $($Result.Data['RunEntries'])"
    )
    Write-AmonTable -Title 'EVENTOS Y ENTRADAS RELEVANTES' -MaxRows (Get-AmonMaxRows $Context) -Rows @($Result.Artifacts | Sort-Object { if ($_.TimeUtc) { $_.TimeUtc } else { [datetime]::MinValue } } -Descending) -Columns @(
        @{ Header = 'ID'; Property = 'EventId' },
        @{ Header = 'FECHA'; Property = { param($r) if ($r.TimeUtc) { $r.TimeUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '-' } } },
        @{ Header = 'DETALLE'; Property = 'Description' },
        @{ Header = 'MOTIVO'; Property = 'Relevance' },
        @{ Header = 'PROCESO / VALOR'; Property = { param($r) if ($r.Process) { $r.Process } else { $r.CommandLine } }; IsPath = $true }
    )
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonTempView {
    param([Parameter(Mandatory = $true)]$Result, $Context)
    Write-AmonSection -Title 'TEMP INDICATOR SWEEP'
    if ($Result.Artifacts.Count) {
        Write-AmonTable -Title 'COINCIDENCIAS EN TEMP' -Rows @($Result.Artifacts) -Columns @(
            @{ Header = 'COINCIDENCIA'; Property = 'Match' },
            @{ Header = 'CREADO'; Property = { param($r) $r.CreatedUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } },
            @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true }
        )
    }
    Show-AmonFindingList -Findings @($Result.Findings)
    Show-AmonModuleNotes -Result $Result
}

function Show-AmonTimelineView {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows, $Context, [string]$Range)
    Write-AmonSection -Title 'FORENSIC TIMELINE' -Subtitle $(if ($Range) { $Range } else { 'Cada fila procede de un artefacto concreto; no se interpolan tiempos.' })
    $sum = Get-AmonTimelineSummary -Rows $Rows
    Write-AmonTable -Title 'RESUMEN POR DÍA' -Rows @($sum.ByDay) -Columns @(
        @{ Header = 'FECHA'; Property = 'Date' },
        @{ Header = 'EVENTOS'; Property = 'Events'; Align = 'Right' },
        @{ Header = 'LIGADOS A INDICADORES'; Property = 'Highlighted'; Align = 'Right'; Token = { param($r) if ($r.Highlighted) { 'finding' } else { 'muted' } } }
    ) -EmptyText 'No hay eventos en el intervalo.'
    $max = [Math]::Max(30, (Get-AmonMaxRows $Context) * 2)
    Write-AmonTable -Title 'EVENTOS' -MaxRows $max -Rows @($Rows | Sort-Object TimestampUtc -Descending) -Columns @(
        @{ Header = 'FECHA'; Property = 'Date' },
        @{ Header = 'HORA'; Property = 'Time' },
        @{ Header = 'ZONA'; Property = 'TimeZone' },
        @{ Header = 'TIPO'; Property = 'Type'; Token = { param($r) if ($r.Highlight) { 'finding' } else { 'primary' } } },
        @{ Header = 'FUENTE'; Property = 'Source' },
        @{ Header = 'CONF.'; Property = { param($r) $script:ConfEs[[string]$r.Confidence] } },
        @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true }
    ) -EmptyText 'No hay eventos en el intervalo.'
}

function Show-AmonVerdictView {
    param([Parameter(Mandatory = $true)]$Correlation, $Context)
    Write-AmonSection -Title 'DETECTION & CORRELATION' -Subtitle 'DETECTED = indicador presente · CORRELATED = varias fuentes independientes · INCONCLUSIVE = información insuficiente.'
    $relevant = @($Correlation.ClientVerdicts | Where-Object { $_.Status -ne 'NOT DETECTED' })
    $clean = @($Correlation.ClientVerdicts | Where-Object Status -EQ 'NOT DETECTED')
    Write-AmonTable -Title 'VEREDICTO POR CLIENTE' -Rows $relevant -Columns @(
        @{ Header = 'CLIENTE'; Property = 'Client' },
        @{ Header = 'ESTADO'; Property = 'Status'; Token = { param($r) $script:StatusToken[[string]$r.Status] } },
        @{ Header = 'CONF.'; Property = { param($r) $script:ConfEs[[string]$r.Confidence] } },
        @{ Header = 'JUSTIFICACIÓN'; Property = 'Justification' }
    ) -EmptyText 'Ningún cliente con indicadores.'
    if ($clean.Count) {
        Write-AmonStatus -Label 'NOT DETECTED' -Value "$($clean.Count) clientes" -State Ok -Detail ((@($clean | ForEach-Object Client) -join ', '))
    }
    Show-AmonFindingList -Findings @($Correlation.Correlated) -Max 8
    $w = (Get-AmonPanelWidth) - 4
    Write-AmonBox -Title 'CONCLUSIÓN PARA REVISIÓN HUMANA' -Lines @(Split-AmonWrap -Text $Correlation.Conclusion -Width $w)
}

function Show-AmonResultView {
    # Elige la vista adecuada para un resultado de módulo.
    param([Parameter(Mandatory = $true)]$Result, $Context)
    switch ($Result.Module) {
        'Minecraft' { Show-AmonMinecraftView -Result $Result -Context $Context }
        'Signatures' { Show-AmonSignatureView -Result $Result -Context $Context }
        'SignaturesEvidence' { Show-AmonSignatureView -Result $Result -Context $Context }
        'Processes' { Show-AmonProcessView -Result $Result -Context $Context }
        'Prefetch' { Show-AmonPrefetchView -Result $Result -Context $Context }
        'RecycleBin' { Show-AmonRecycleView -Result $Result -Context $Context }
        'USNJournal' { Show-AmonUsnView -Result $Result -Context $Context }
        'Recent' { Show-AmonRecentView -Result $Result -Context $Context }
        'UserAssist' { Show-AmonUserAssistView -Result $Result -Context $Context }
        'Events' { Show-AmonEventView -Result $Result -Context $Context }
        'Temp' { Show-AmonTempView -Result $Result -Context $Context }
        default { Show-AmonFindingList -Findings @($Result.Findings); Show-AmonModuleNotes -Result $Result }
    }
}

Export-ModuleMember -Function @(
    'Show-AmonModuleStatus', 'Show-AmonModuleNotes', 'Show-AmonFindingList', 'Show-AmonResultView', 'Show-AmonTimelineView', 'Show-AmonVerdictView',
    'Show-AmonMinecraftView', 'Show-AmonSignatureView', 'Show-AmonProcessView', 'Show-AmonPrefetchView', 'Show-AmonRecycleView',
    'Show-AmonUsnView', 'Show-AmonRecentView', 'Show-AmonUserAssistView', 'Show-AmonEventView', 'Show-AmonTempView'
)
