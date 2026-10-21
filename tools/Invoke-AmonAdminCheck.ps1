<#
.SYNOPSIS
    Verificación de los módulos que necesitan administrador sobre el sistema real.
.DESCRIPTION
    Ejecuta Prefetch, USN Journal y eventos de Windows con límite de tiempo y muestra un resumen
    compacto (recuentos, versiones de formato, tiempos y errores de interpretación) para
    comprobar los parsers con datos reales. Solo lectura; no exporta nada.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File A:\01_Proyectos\Minecraft\Amon-SS\tools\Invoke-AmonAdminCheck.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSeconds = 120)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
foreach ($m in 'Core', 'Jar', 'Minecraft', 'Signatures', 'Prefetch', 'USNJournal', 'Events') {
    Import-Module (Join-Path $root "modules\$m.psm1") -Force -DisableNameChecking
}

function Write-Line { param([string]$Text) Write-Host $Text }

$admin = Test-AmonAdmin
Write-Line ("Amon SS {0} | PowerShell {1} | administrador: {2}" -f (Get-AmonVersionInfo).Version, $PSVersionTable.PSVersion, $admin)
if (-not $admin) { Write-Line 'Ejecuta esta comprobación desde una consola de PowerShell abierta como administrador.'; exit 1 }

$ctx = New-AmonContext -Days 7
$ctx.Signatures = Get-AmonSignatureSet
foreach ($k in $ctx.Signatures.Keywords) { [void]$ctx.Keywords.Add($k) }
$null = Invoke-AmonModule -Name 'Minecraft' -Context $ctx -TimeoutSeconds $TimeoutSeconds -ScriptBlock { param($c) Invoke-AmonMinecraftAnalysis -Context $c }
Write-Line ("Instancias de Minecraft: {0}" -f $ctx.Instances.Count)

# --- Prefetch: además del módulo, se interpretan todos los .pf para contar formatos y errores.
Write-Line ''
Write-Line '== PREFETCH'
$pfDir = Join-Path $env:SystemRoot 'Prefetch'
Write-Line ("EnablePrefetcher: {0}" -f (Get-AmonPrefetchStatus))
$files = @([IO.Directory]::GetFiles($pfDir, '*.pf'))
$sw = [Diagnostics.Stopwatch]::StartNew()
$versions = @{}; $compressed = 0; $failed = [System.Collections.Generic.List[string]]::new(); $runs = 0; $withTimes = 0
foreach ($f in $files) {
    try {
        $pf = Read-AmonPrefetchFile -Path $f
        $key = "v$($pf.Version)"; if ($versions.ContainsKey($key)) { $versions[$key]++ } else { $versions[$key] = 1 }
        if ($pf.Compressed) { $compressed++ }
        if ($pf.LastRunTimes.Count) { $withTimes++ }
        $runs += $pf.RunCount
    } catch { $failed.Add(('{0}: {1}' -f [IO.Path]::GetFileName($f), $_.Exception.Message)) }
}
$sw.Stop()
Write-Line ("Archivos: {0} | interpretados: {1} | fallidos: {2} | comprimidos MAM: {3} | con fechas: {4} | {5:n1} s" -f $files.Count, ($files.Count - $failed.Count), $failed.Count, $compressed, $withTimes, $sw.Elapsed.TotalSeconds)
Write-Line ("Versiones de formato: {0}" -f (($versions.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
foreach ($e in ($failed | Select-Object -First 5)) { Write-Line "  Fallo: $e" }
$r = Invoke-AmonModule -Name 'Prefetch' -Context $ctx -TimeoutSeconds $TimeoutSeconds -ScriptBlock { param($c) Invoke-AmonPrefetchAnalysis -Context $c }
Write-Line ("Módulo: estado {0} | relevantes {1} | omitidos por privacidad {2} | hallazgos {3} | {4:n1} s" -f $r.Status, $r.Artifacts.Count, $r.Data['Omitted'], $r.Findings.Count, ($r.DurationMs / 1000))
foreach ($a in ($r.Artifacts | Sort-Object LastRunUtc -Descending | Select-Object -First 8)) {
    Write-Line ("  {0,-28} ejec. {1,4}  última {2}  JAR fuera de librerías: {3}" -f $a.ExecutableName, $a.RunCount, (Format-AmonTimestamp $a.LastRunUtc), @($a.ReferencedJars).Count)
}

# --- USN Journal
Write-Line ''
Write-Line '== USN JOURNAL'
$u = Invoke-AmonModule -Name 'USNJournal' -Context $ctx -TimeoutSeconds $TimeoutSeconds -ScriptBlock { param($c) Invoke-AmonUsnAnalysis -Context $c }
Write-Line ("Módulo: estado {0} | registros relevantes {1} | hallazgos {2} | {3:n1} s" -f $u.Status, $u.Artifacts.Count, $u.Findings.Count, ($u.DurationMs / 1000))
foreach ($j in @($u.Data['Journals'])) {
    Write-Line ("  {0} registros leídos {1} | relevantes {2} | desde {3} | hasta {4} | máx. {5} MB | truncado {6} | límite de tiempo {7}" -f $j.Drive, $j.TotalRecords, $j.Matched, (Format-AmonTimestamp $j.FirstRecordUtc), (Format-AmonTimestamp $j.LastRecordUtc), $j.MaximumSizeMB, $j.Truncated, $j.TimedOut)
}
$ops = @($u.Artifacts | Group-Object Operation | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })
if ($ops.Count) { Write-Line ("  Operaciones: {0}" -f ($ops -join ', ')) }
$reliable = @($u.Artifacts | Where-Object ParentPath).Count
if ($u.Artifacts.Count) { Write-Line ("  Rutas reconstruidas: {0} de {1}" -f $reliable, $u.Artifacts.Count) }
Write-Line ("  Actividad de papelera reconstruida: {0}" -f @($u.Data['RecycleActivity']).Count)
foreach ($w in ($u.Warnings | Select-Object -First 3)) { Write-Line "  Aviso: $w" }
foreach ($l in ($u.Limitations | Select-Object -First 3)) { Write-Line "  Límite: $l" }

# --- Eventos
Write-Line ''
Write-Line '== EVENTOS DE WINDOWS'
$ev = Invoke-AmonModule -Name 'Events' -Context $ctx -TimeoutSeconds $TimeoutSeconds -ScriptBlock { param($c) Invoke-AmonEventAnalysis -Context $c }
$a = $ev.Data['Audit']
Write-Line ("Módulo: estado {0} | registro de Seguridad accesible: {1} | {2:n1} s" -f $ev.Status, $ev.Data['SecurityAccessible'], ($ev.DurationMs / 1000))
Write-Line ("  Auditoría 4688: {0} (fuente: {1}) | línea de comandos incluida: {2}" -f $(if ($null -eq $a.Enabled) { 'desconocida' } else { $a.Enabled }), $a.Source, $a.CommandLineIncluded)
$byId = @($ev.Artifacts | Group-Object EventId | ForEach-Object { "$($_.Name)=$($_.Count)" })
Write-Line ("  Artefactos por tipo: {0}" -f $(if ($byId.Count) { $byId -join ', ' } else { 'ninguno' }))
foreach ($f in ($ev.Findings | Select-Object -First 5)) { Write-Line ("  [{0}] {1}" -f $f.Status, $f.Title) }
foreach ($w in ($ev.Warnings | Select-Object -First 3)) { Write-Line "  Aviso: $w" }
foreach ($l in ($ev.Limitations | Select-Object -First 3)) { Write-Line "  Límite: $l" }
Write-Line ''
Write-Line 'Comprobación terminada (solo lectura; no se exportó ningún reporte).'
