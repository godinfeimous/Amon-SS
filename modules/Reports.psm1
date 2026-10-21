#Requires -Version 5.1
<#
    Amon SS - modules/Reports.psm1
    Reportes de evidencias exportables: TXT, JSON y HTML (autocontenido, sin recursos externos).

      * Solo metadatos pertinentes y hallazgos: nunca se copia el contenido de archivos.
      * Fechas en ISO 8601 UTC más hora local con desplazamiento.
      * Manifiesto <id>.sha256 (formato sha256sum) para verificar la integridad de lo exportado;
        el hash también se muestra en pantalla para que el revisor lo anote aparte.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:StatusOrder = @{ 'CORRELATED' = 0; 'DETECTED' = 1; 'INCONCLUSIVE' = 2; 'INFO' = 3; 'NOT DETECTED' = 4; 'NOT COVERED' = 5 }
$script:SeverityOrder = @{ 'High' = 0; 'Medium' = 1; 'Low' = 2; 'Info' = 3 }

#region Modelo

function ConvertTo-AmonReportValue {
    # Convierte a tipos serializables: fechas ISO, diccionarios ordenados y listas.
    param($Value, [int]$Depth = 0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 6) { return [string]$Value }
    if ($Value -is [datetime]) { return Format-AmonTimestamp $Value -Iso }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}
        foreach ($k in $Value.Keys) { $o[[string]$k] = ConvertTo-AmonReportValue $Value[$k] ($Depth + 1) }
        return $o
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @($Value | ForEach-Object { ConvertTo-AmonReportValue $_ ($Depth + 1) }) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = ConvertTo-AmonReportValue $p.Value ($Depth + 1) }
        return $o
    }
    return [string]$Value
}

function ConvertTo-AmonReportFinding {
    param([Parameter(Mandatory = $true)]$Finding)
    [ordered]@{
        Id = $Finding.Id; Module = $Finding.Module; Category = $Finding.Category; Title = $Finding.Title
        Status = $Finding.Status; Severity = $Finding.Severity; Confidence = $Finding.Confidence
        Client = $Finding.Client; ClientId = $Finding.ClientId; Path = $Finding.Path; Sha256 = $Finding.Sha256
        TimestampUtc = (Format-AmonTimestamp $Finding.TimestampUtc -Iso); TimestampLocal = (Format-AmonTimestamp $Finding.TimestampUtc)
        Indicator = $Finding.Indicator; IndicatorType = $Finding.IndicatorType; Source = $Finding.Source
        Justification = $Finding.Justification; FalsePositives = @($Finding.FalsePositives)
        Evidence = @($Finding.Evidence | ForEach-Object {
                [ordered]@{ Source = $_.Source; Kind = $_.Kind; Description = $_.Description; Path = $_.Path; TimestampUtc = (Format-AmonTimestamp $_.TimestampUtc -Iso) }
            })
    }
}

function New-AmonReportModel {
    <#
    .SYNOPSIS
        Reúne todo lo necesario para el reporte en una estructura serializable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, $Correlation, [object[]]$Timeline = @())
    $v = Get-AmonVersionInfo
    $results = @($Context.Results.Values)
    $allFindings = @(foreach ($r in $results) { foreach ($f in $r.Findings) { $f } }) |
        Sort-Object { $script:StatusOrder[[string]$_.Status] }, { $script:SeverityOrder[[string]$_.Severity] }, Title
    $files = @()
    foreach ($m in @('Signatures', 'SignaturesEvidence')) {
        if ($Context.Results[$m]) {
            $files += @($Context.Results[$m].Artifacts | ForEach-Object {
                    [ordered]@{ Path = $_.Path; FileName = $_.FileName; Origin = $_.Origin; Sha256 = $_.Sha256; Size = $_.Size; ModifiedUtc = (Format-AmonTimestamp $_.ModifiedUtc -Iso); Result = $_.Result; Clients = $_.Clients }
                })
        }
    }
    $mc = $Context.Results['Minecraft']
    $warnings = [System.Collections.Generic.List[string]]::new()
    $limits = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $results) {
        foreach ($w in $r.Warnings) { $t = "$($r.DisplayName): $w"; if (-not $warnings.Contains($t)) { $warnings.Add($t) } }
        foreach ($l in $r.Limitations) { $t = "$($r.DisplayName): $l"; if (-not $limits.Contains($t)) { $limits.Add($t) } }
    }
    $conclusion = if ($Correlation) { $Correlation.Conclusion } else { 'Correlación no ejecutada. Conclusión para revisión humana: Amon SS no emite veredictos ni sanciones automáticas.' }
    $osLabel = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop | ForEach-Object { "$($_.ProductName) build $($_.CurrentBuildNumber)" }) } catch { [Environment]::OSVersion.VersionString }
    [pscustomobject][ordered]@{
        ReviewId = $Context.ReviewId
        Tool = [ordered]@{ Name = $v.Name; Subtitle = $v.Subtitle; Version = $v.Version; BuildDate = $v.BuildDate; PowerShell = "$($v.PSVersion) ($($v.PSEdition))" }
        GeneratedUtc = (Format-AmonTimestamp ([datetime]::UtcNow) -Iso)
        GeneratedLocal = (Format-AmonTimestamp ([datetime]::UtcNow))
        TimeZone = $Context.TimeZone
        Window = [ordered]@{ SinceUtc = (Format-AmonTimestamp $Context.SinceUtc -Iso); UntilUtc = (Format-AmonTimestamp $Context.UntilUtc -Iso); Days = $Context.Days }
        Subject = [ordered]@{ ComputerName = $Context.ComputerName; UserName = $Context.UserName; UserSid = $Context.UserSid; IsAdmin = $Context.IsAdmin; OperatingSystem = $osLabel }
        AuthorizedScope = @($Context.AuthorizedScope)
        Modules = @($results | ForEach-Object {
                [ordered]@{
                    Module = $_.Module; DisplayName = $_.DisplayName; Status = $_.Status; DurationMs = $_.DurationMs; ArtifactsReviewed = $_.ArtifactsReviewed
                    RequiresAdmin = $_.RequiresAdmin; Findings = $_.Findings.Count; Scope = @($_.Scope); Errors = @($_.Errors)
                }
            })
        ModulesWithoutAccess = @($results | Where-Object { $_.Status -eq 'NoAccess' } | ForEach-Object DisplayName)
        Outcome = $(if ($Correlation) { $Correlation.Outcome } else { $null })
        ClientVerdicts = @(if ($Correlation) { $Correlation.ClientVerdicts | ForEach-Object { ConvertTo-AmonReportValue $_ } })
        Findings = @($allFindings | ForEach-Object { ConvertTo-AmonReportFinding $_ })
        FilesAnalyzed = $files
        Minecraft = [ordered]@{
            Instances = @(if ($mc) { $mc.Data['Instances'] | ForEach-Object { ConvertTo-AmonReportValue $_ } })
            Sessions = @(if ($mc) { $mc.Data['Sessions'] | ForEach-Object { ConvertTo-AmonReportValue $_ } })
            Versions = @(if ($mc) { $mc.Data['Versions'] | ForEach-Object { [ordered]@{ Instance = $_.Instance; Id = $_.Id; Loader = $_.Loader; MainClass = $_.MainClass; HashStatus = $_.HashStatus; JavaAgents = @($_.JavaAgents); JsonPath = $_.JsonPath } } })
            Mods = @(if ($mc) { $mc.Artifacts | ForEach-Object { [ordered]@{ Instance = $_.Instance; FileName = $_.FileName; ModId = $_.ModId; Version = $_.Version; Loader = $_.Loader; Loaded = $_.Loaded; LastLoadedUtc = (Format-AmonTimestamp $_.LastLoadedUtc -Iso); ModifiedUtc = (Format-AmonTimestamp $_.ModifiedUtc -Iso); Sha256 = $_.Sha256; Path = $_.Path } } })
        }
        RecycleBinActivity = @(if ($Context.Results['RecycleBin']) { $Context.Results['RecycleBin'].Data['Activity'] | ForEach-Object { ConvertTo-AmonReportValue $_ } })
        Timeline = @($Timeline | ForEach-Object {
                [ordered]@{ TimestampUtc = (Format-AmonTimestamp $_.TimestampUtc -Iso); Date = $_.Date; Time = $_.Time; TimeZone = $_.TimeZone; Type = $_.Type; Source = $_.Source; Path = $_.Path; Indicator = $_.Indicator; Confidence = $_.Confidence; Description = $_.Description; Highlight = $_.Highlight }
            })
        Warnings = $warnings.ToArray()
        Limitations = $limits.ToArray()
        Conclusion = $conclusion
        Integrity = 'Verificar con el manifiesto .sha256 que acompaña al reporte (Test-AmonReportIntegrity o sha256sum -c).'
    }
}

#endregion

#region Formatos

function ConvertTo-AmonReportText {
    param([Parameter(Mandatory = $true)]$Model)
    $sb = New-Object System.Text.StringBuilder
    $rule = '=' * 100; $thin = '-' * 100
    # Cada línea lleva datos de artefactos: un salto de línea incrustado falsificaría líneas del
    # reporte y un ESC alteraría la terminal de quien lo abra con type/cat. Se neutralizan ambos.
    $line = { param($s) [void]$sb.AppendLine([regex]::Replace(([string]$s -replace '[\r\n]+', ' '), '[\x00-\x08\x0B-\x1F\x7F-\x9F]', '')) }
    $section = { param($t) & $line ''; & $line $rule; & $line ("  " + $t); & $line $rule }
    & $line $rule
    & $line '  AMON SS  -  ADVANCED MINECRAFT FORENSIC SUITE'
    & $line ("  Reporte de revisión {0}" -f $Model.ReviewId)
    & $line $rule
    & $line ("Generado        : {0}  ({1})" -f $Model.GeneratedLocal, $Model.GeneratedUtc)
    & $line ("Zona horaria    : {0}" -f $Model.TimeZone)
    & $line ("Periodo         : {0}  ->  {1}  ({2} días)" -f $Model.Window.SinceUtc, $Model.Window.UntilUtc, $Model.Window.Days)
    & $line ("Equipo / usuario: {0} / {1} ({2})" -f $Model.Subject.ComputerName, $Model.Subject.UserName, $Model.Subject.UserSid)
    & $line ("Sistema         : {0}   Administrador: {1}" -f $Model.Subject.OperatingSystem, $Model.Subject.IsAdmin)
    & $line ("Herramienta     : {0} v{1} ({2}) - PowerShell {3}" -f $Model.Tool.Name, $Model.Tool.Version, $Model.Tool.BuildDate, $Model.Tool.PowerShell)
    if ($Model.Outcome) { & $line ("Resultado       : {0} (para revisión humana)" -f $Model.Outcome) }

    & $section 'ALCANCE AUTORIZADO'
    foreach ($s in $Model.AuthorizedScope) { & $line "  - $s" }

    & $section 'MÓDULOS EJECUTADOS'
    & $line ('  {0,-34} {1,-11} {2,10} {3,10} {4,9}' -f 'Módulo', 'Estado', 'Artefactos', 'Hallazgos', 'ms')
    foreach ($m in $Model.Modules) { & $line ('  {0,-34} {1,-11} {2,10} {3,10} {4,9}' -f $m.DisplayName, $m.Status, $m.ArtifactsReviewed, $m.Findings, $m.DurationMs) }

    & $section 'VEREDICTO POR CLIENTE (para revisión humana)'
    # Solo los clientes con algún indicio llevan justificación; el resto cabe en dos líneas.
    foreach ($v in @($Model.ClientVerdicts | Where-Object { $_.Status -notin @('NOT DETECTED', 'NOT COVERED') })) {
        & $line ('  [{0,-12}] {1}' -f $v.Status, $v.Client)
        & $line ('                 {0}' -f $v.Justification)
    }
    $nd = @($Model.ClientVerdicts | Where-Object Status -EQ 'NOT DETECTED' | ForEach-Object Client)
    $nc = @($Model.ClientVerdicts | Where-Object Status -EQ 'NOT COVERED' | ForEach-Object Client)
    if ($nd.Count) { & $line ("  Sin indicadores ({0}): {1}" -f $nd.Count, ($nd -join ', ')) }
    if ($nc.Count) { & $line ("  Sin firmas verificables, no comprobables por archivo ({0}): {1}" -f $nc.Count, ($nc -join ', ')) }

    & $section ("HALLAZGOS ({0})" -f $Model.Findings.Count)
    foreach ($f in $Model.Findings) {
        & $line ("  [{0}] {1}   (confianza {2}, severidad {3})" -f $f.Status, $f.Title, $f.Confidence, $f.Severity)
        if ($f.Client) { & $line "      Cliente     : $($f.Client)" }
        if ($f.Indicator) { & $line "      Indicador   : $($f.Indicator)" }
        if ($f.Path) { & $line "      Ruta        : $($f.Path)" }
        if ($f.Sha256) { & $line "      SHA-256     : $($f.Sha256)" }
        if ($f.TimestampLocal) { & $line "      Fecha       : $($f.TimestampLocal)" }
        & $line "      Fuente      : $($f.Source)"
        if ($f.Justification) { & $line "      Motivo      : $($f.Justification)" }
        foreach ($e in $f.Evidence) { & $line "      Evidencia   : [$($e.Source)] $($e.Description)" }
        if ($f.FalsePositives.Count) { & $line "      Posibles FP : $($f.FalsePositives -join '; ')" }
        & $line $thin
    }

    & $section 'RECYCLE BIN ACTIVITY'
    foreach ($a in $Model.RecycleBinActivity) { & $line ("  {0,-26} {1,-27} {2}" -f $a.Category, $a.TimestampUtc, $a.Path); & $line ("  {0,-26} {1}" -f '', $a.Description) }

    & $section ("LÍNEA TEMPORAL ({0} eventos)" -f $Model.Timeline.Count)
    foreach ($t in ($Model.Timeline | Select-Object -First 2000)) {
        $mark = if ($t.Highlight) { '*' } else { ' ' }
        & $line ("{0} {1} {2} {3}  {4,-40} {5}" -f $mark, $t.Date, $t.Time, $t.TimeZone, $t.Type, $t.Path)
    }

    & $section ("ARCHIVOS ANALIZADOS ({0})" -f $Model.FilesAnalyzed.Count)
    foreach ($fa in $Model.FilesAnalyzed) { & $line ("  {0,-16} {1}  {2}" -f $fa.Result, $fa.Sha256, $fa.Path) }

    & $section 'ADVERTENCIAS'
    foreach ($w in $Model.Warnings) { & $line "  - $w" }
    & $section 'MÓDULOS SIN ACCESO'
    if ($Model.ModulesWithoutAccess.Count) { foreach ($m in $Model.ModulesWithoutAccess) { & $line "  - $m" } } else { & $line '  (ninguno)' }
    & $section 'LIMITACIONES'
    foreach ($l in $Model.Limitations) { & $line "  - $l" }
    & $section 'CONCLUSIÓN PARA REVISIÓN HUMANA'
    & $line "  $($Model.Conclusion)"
    & $line ''
    & $line "  $($Model.Integrity)"
    return $sb.ToString()
}

function ConvertTo-AmonHtmlText { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }

function ConvertTo-AmonReportHtml {
    param([Parameter(Mandatory = $true)]$Model)
    $e = { param($v) ConvertTo-AmonHtmlText $v }
    $sb = New-Object System.Text.StringBuilder
    $w = { param($s) [void]$sb.Append($s) }
    $badge = { param($s) "<span class=""badge b-$(([string]$s).Replace(' ', '-').ToLowerInvariant())"">$(& $e $s)</span>" }
    $oc = switch ([string]$Model.Outcome) { 'INDICADORES ENCONTRADOS' { 'o-found' } 'REVISAR A MANO' { 'o-review' } default { 'o-clean' } }
    $outcomeHtml = if ($Model.Outcome) { "<div class=""outcome $oc"">$(& $e $Model.Outcome)</div>" } else { '' }
    & $w @"
<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Amon SS - $(& $e $Model.ReviewId)</title>
<style>
:root{--void:#05020b;--panel:#110922;--line:#2e1065;--violet:#a855f7;--lav:#c4b5fd;--text:#f5f3ff;--muted:#8b7fa8;--warn:#facc15;--red:#f43f5e;--green:#4ade80}
*{box-sizing:border-box}body{margin:0;background:var(--void);color:var(--text);font:15px/1.55 "Segoe UI",system-ui,sans-serif}
main{max-width:1180px;margin:0 auto;padding:40px 24px 80px}
header{border:1px solid var(--line);border-radius:14px;padding:28px 32px;background:linear-gradient(135deg,#140a2b,#05020b 70%)}
.brand{font-size:44px;font-weight:800;letter-spacing:.18em;background:linear-gradient(90deg,#5b21b6,#a855f7 55%,#d8b4fe);-webkit-background-clip:text;background-clip:text;color:transparent;margin:0}
.sub{color:var(--lav);letter-spacing:.32em;font-size:12px;margin:4px 0 18px}
.meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:6px 24px;color:var(--muted);font-size:13px}.meta b{color:var(--text);font-weight:600}
h2{font-size:15px;letter-spacing:.12em;color:var(--violet);margin:40px 0 12px;padding-bottom:8px;border-bottom:1px solid var(--line)}
.conclusion{border-left:4px solid var(--violet);background:var(--panel);padding:16px 20px;border-radius:0 10px 10px 0}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden;font-size:13px}
th{text-align:left;color:var(--lav);font-weight:600;background:#180d33;padding:9px 12px;position:sticky;top:0}
td{padding:8px 12px;border-top:1px solid #1d1138;vertical-align:top}
tr.hl td{background:#1e0f2e}
.mono{font-family:ui-monospace,"Cascadia Mono",Consolas,monospace;font-size:12px;word-break:break-all}
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11px;font-weight:700;letter-spacing:.06em;white-space:nowrap}
.b-correlated,.b-detected{background:#3f0a1c;color:var(--red)}.b-inconclusive{background:#3a2e05;color:var(--warn)}
.b-not-detected{background:#08301a;color:var(--green)}.b-info,.b-not-covered{background:#1b1433;color:var(--lav)}
.outcome{display:inline-block;margin-top:18px;padding:8px 16px;border-radius:10px;font-weight:800;letter-spacing:.12em}
.o-found{background:#3f0a1c;color:var(--red)}.o-review{background:#3a2e05;color:var(--warn)}.o-clean{background:#08301a;color:var(--green)}
.b-completed{background:#08301a;color:var(--green)}.b-partial,.b-noaccess,.b-cancelled{background:#3a2e05;color:var(--warn)}.b-failed{background:#3f0a1c;color:var(--red)}
.card{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--muted);border-radius:10px;padding:14px 18px;margin:12px 0}
.card.s-correlated,.card.s-detected{border-left-color:var(--red)}.card.s-inconclusive{border-left-color:var(--warn)}.card.s-info{border-left-color:var(--lav)}
.card h3{margin:0 0 8px;font-size:15px}.kv{display:grid;grid-template-columns:120px 1fr;gap:3px 14px;font-size:13px}.kv span:nth-child(odd){color:var(--muted)}
ul{margin:6px 0 0 18px;padding:0}li{margin:2px 0}.muted{color:var(--muted)}
@media print{body{background:#fff;color:#000}header,.card,table,.conclusion{background:#fff;border-color:#999}.brand{color:#4c1d95;-webkit-text-fill-color:#4c1d95}th{background:#eee;color:#000}}
</style></head><body><main>
<header><p class="brand">AMON SS</p><p class="sub">ADVANCED MINECRAFT FORENSIC SUITE</p>
<div class="meta">
<div>Revisión <b>$(& $e $Model.ReviewId)</b></div><div>Generado <b>$(& $e $Model.GeneratedLocal)</b></div>
<div>Periodo <b>$(& $e $Model.Window.SinceUtc) → $(& $e $Model.Window.UntilUtc)</b></div><div>Zona <b>$(& $e $Model.TimeZone)</b></div>
<div>Equipo <b>$(& $e $Model.Subject.ComputerName)</b> · usuario <b>$(& $e $Model.Subject.UserName)</b></div><div>Administrador <b>$(& $e $Model.Subject.IsAdmin)</b></div>
<div>Herramienta <b>v$(& $e $Model.Tool.Version)</b> ($(& $e $Model.Tool.BuildDate))</div><div>PowerShell <b>$(& $e $Model.Tool.PowerShell)</b></div>
</div>$outcomeHtml</header>
<h2>CONCLUSIÓN PARA REVISIÓN HUMANA</h2><div class="conclusion">$(& $e $Model.Conclusion)</div>
<h2>ALCANCE AUTORIZADO</h2><ul>
"@
    foreach ($s in $Model.AuthorizedScope) { & $w "<li>$(& $e $s)</li>" }
    & $w '</ul><h2>VEREDICTO POR CLIENTE</h2>'
    $flagged = @($Model.ClientVerdicts | Where-Object { $_.Status -notin @('NOT DETECTED', 'NOT COVERED') })
    if ($flagged.Count) {
        & $w '<table><tr><th>Cliente</th><th>Estado</th><th>Justificación</th></tr>'
        foreach ($v in $flagged) { & $w "<tr><td>$(& $e $v.Client)</td><td>$(& $badge $v.Status)</td><td>$(& $e $v.Justification)</td></tr>" }
        & $w '</table>'
    } else { & $w '<p>Ningún cliente con indicadores.</p>' }
    $nd = @($Model.ClientVerdicts | Where-Object Status -EQ 'NOT DETECTED' | ForEach-Object Client)
    $nc = @($Model.ClientVerdicts | Where-Object Status -EQ 'NOT COVERED' | ForEach-Object Client)
    if ($nd.Count) { & $w "<p>$(& $badge 'NOT DETECTED') $(& $e ($nd -join ', '))</p>" }
    if ($nc.Count) { & $w "<p class=""muted"">$(& $badge 'NOT COVERED') Sin firmas verificables, no comprobables por archivo: $(& $e ($nc -join ', '))</p>" }
    & $w "<h2>HALLAZGOS ($($Model.Findings.Count))</h2>"
    foreach ($f in $Model.Findings) {
        $cls = ([string]$f.Status).Replace(' ', '-').ToLowerInvariant()
        & $w "<div class=""card s-$cls""><h3>$(& $badge $f.Status) $(& $e $f.Title)</h3><div class=""kv"">"
        foreach ($pair in @(@('Confianza', $f.Confidence), @('Cliente', $f.Client), @('Indicador', $f.Indicator), @('Ruta', $f.Path), @('SHA-256', $f.Sha256), @('Fecha', $f.TimestampLocal), @('Fuente', $f.Source), @('Motivo', $f.Justification))) {
            if ($pair[1]) {
                $valClass = if ($pair[0] -in @('Ruta', 'SHA-256')) { ' class="mono"' } else { '' }
                & $w "<span>$($pair[0])</span><span$valClass>$(& $e $pair[1])</span>"
            }
        }
        & $w '</div>'
        if ($f.Evidence.Count) { & $w '<ul>'; foreach ($ev in $f.Evidence) { & $w "<li><span class=""muted"">[$(& $e $ev.Source)]</span> $(& $e $ev.Description)</li>" }; & $w '</ul>' }
        if ($f.FalsePositives.Count) { & $w "<p class=""muted"">Posibles falsos positivos: $(& $e ($f.FalsePositives -join '; '))</p>" }
        & $w '</div>'
    }
    & $w '<h2>RECYCLE BIN ACTIVITY</h2><table><tr><th>Categoría</th><th>Fecha (UTC)</th><th>Ruta</th><th>Descripción</th></tr>'
    foreach ($a in $Model.RecycleBinActivity) { & $w "<tr><td>$(& $e $a.Category)</td><td class=""mono"">$(& $e $a.TimestampUtc)</td><td class=""mono"">$(& $e $a.Path)</td><td>$(& $e $a.Description)</td></tr>" }
    & $w "</table><h2>LÍNEA TEMPORAL ($($Model.Timeline.Count))</h2><table><tr><th>Fecha</th><th>Hora</th><th>Zona</th><th>Tipo</th><th>Fuente</th><th>Ruta</th><th>Confianza</th></tr>"
    foreach ($t in ($Model.Timeline | Select-Object -First 3000)) {
        $hl = if ($t.Highlight) { ' class="hl"' } else { '' }
        & $w "<tr$hl><td>$(& $e $t.Date)</td><td>$(& $e $t.Time)</td><td>$(& $e $t.TimeZone)</td><td>$(& $e $t.Type)</td><td>$(& $e $t.Source)</td><td class=""mono"">$(& $e $t.Path)</td><td>$(& $e $t.Confidence)</td></tr>"
    }
    & $w '</table><h2>MÓDULOS</h2><table><tr><th>Módulo</th><th>Estado</th><th>Artefactos</th><th>Hallazgos</th><th>Duración</th></tr>'
    foreach ($m in $Model.Modules) { & $w "<tr><td>$(& $e $m.DisplayName)</td><td>$(& $badge $m.Status)</td><td>$(& $e $m.ArtifactsReviewed)</td><td>$(& $e $m.Findings)</td><td>$(& $e $m.DurationMs) ms</td></tr>" }
    & $w "</table><h2>ARCHIVOS ANALIZADOS ($($Model.FilesAnalyzed.Count))</h2><table><tr><th>Resultado</th><th>Archivo</th><th>SHA-256</th></tr>"
    foreach ($fa in $Model.FilesAnalyzed) { & $w "<tr><td>$(& $e $fa.Result)</td><td class=""mono"">$(& $e $fa.Path)</td><td class=""mono"">$(& $e $fa.Sha256)</td></tr>" }
    & $w '</table><h2>ADVERTENCIAS Y LIMITACIONES</h2><ul>'
    foreach ($x in @($Model.Warnings) + @($Model.Limitations)) { & $w "<li>$(& $e $x)</li>" }
    & $w "</ul><p class=""muted"">$(& $e $Model.Integrity)</p></main></body></html>"
    return $sb.ToString()
}

#endregion

#region Exportación e integridad

function Get-AmonStringSha256 {
    param([string]$Path)
    $alg = [Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($alg.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() } finally { $fs.Dispose() }
    } finally { $alg.Dispose() }
}

function Export-AmonReport {
    <#
    .SYNOPSIS
        Escribe el reporte en los formatos pedidos y el manifiesto SHA-256.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Model, [Parameter(Mandatory = $true)][string]$Directory, [string[]]$Formats = @('txt', 'json', 'html'))
    $dir = Expand-AmonPath $Directory
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $out = [System.Collections.Generic.List[object]]::new()
    # Un reporte exportado no se sobrescribe nunca: su SHA-256 puede estar anotado en un ticket.
    # Exportar otra vez la misma revisión crea <id>-2, <id>-3...
    $base = [string]$Model.ReviewId; $n = 1
    while (Test-Path -LiteralPath (Join-Path $dir "$base.sha256")) { $n++; $base = "$($Model.ReviewId)-$n" }
    foreach ($fmt in $Formats) {
        $f = $fmt.ToLowerInvariant()
        $path = Join-Path $dir "$base.$f"
        $content = switch ($f) {
            'json' { $Model | ConvertTo-Json -Depth 12 }
            'txt' { ConvertTo-AmonReportText -Model $Model }
            'html' { ConvertTo-AmonReportHtml -Model $Model }
            default { throw "Formato de reporte no soportado: $fmt" }
        }
        [IO.File]::WriteAllText($path, $content, $utf8)
        $out.Add([pscustomobject]@{ Format = $f; Path = $path; Sha256 = (Get-AmonStringSha256 -Path $path) })
    }
    $manifest = Join-Path $dir "$base.sha256"
    $lines = @($out | ForEach-Object { '{0} *{1}' -f $_.Sha256, [IO.Path]::GetFileName($_.Path) })
    [IO.File]::WriteAllText($manifest, (($lines -join "`n") + "`n"), $utf8)
    [pscustomobject]@{ Files = $out.ToArray(); Manifest = $manifest; Directory = $dir }
}

function Test-AmonReportIntegrity {
    <#
    .SYNOPSIS
        Verifica los archivos listados en un manifiesto .sha256 (formato sha256sum).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)
    $base = Split-Path -Parent (Resolve-Path -LiteralPath $ManifestPath).Path
    foreach ($line in (Get-Content -LiteralPath $ManifestPath -Encoding UTF8)) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') { continue }
        $expected = $Matches[1].ToLowerInvariant(); $name = $Matches[2]
        $p = Join-Path $base $name
        $actual = if (Test-Path -LiteralPath $p) { Get-AmonStringSha256 -Path $p } else { $null }
        [pscustomobject]@{ File = $name; Expected = $expected; Actual = $actual; Valid = ($actual -eq $expected) }
    }
}

#endregion

Export-ModuleMember -Function @('New-AmonReportModel', 'ConvertTo-AmonReportText', 'ConvertTo-AmonReportHtml', 'Export-AmonReport', 'Test-AmonReportIntegrity', 'ConvertTo-AmonReportValue')
