#Requires -Version 5.1
<#
    Amon SS - modules/Orchestrator.psm1
    Catálogo de módulos y ejecución ordenada del escaneo completo.

    Orden de investigación:
      1 Minecraft  2 Firmas  3 Procesos  4 Prefetch  5 Recent  6 UserAssist  7 Eventos
      8 Temp (solo con indicadores)  9 Papelera  10 USN Journal
      11 Firmas sobre evidencias nuevas (JAR citados por Prefetch, Recent, $R de la papelera...)
      12 Correlación final y línea temporal
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
foreach ($m in 'Jar', 'Minecraft', 'Signatures', 'Processes', 'Prefetch', 'Recent', 'UserAssist', 'Events', 'TempSweep', 'RecycleBin', 'USNJournal', 'Correlation', 'Timeline', 'Reports') {
    Import-Module (Join-Path $PSScriptRoot "$m.psm1") -DisableNameChecking
}

function Get-AmonModuleCatalog {
    # Definición de cada módulo: clave de ajustes, nombre visible, requisitos y ejecución.
    @(
        [pscustomobject]@{ Key = 'Minecraft'; Name = 'Minecraft Analysis'; RequiresAdmin = $false; Description = 'Instancias, launchers, loaders, mods instalados y cargados, perfiles de versión.'; Run = { param($c) Invoke-AmonMinecraftAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Signatures'; Name = 'Cheat Signature Scanner'; RequiresAdmin = $false; Description = 'Firmas JSON sobre JAR (paquetes, metadatos, cadenas), configuraciones y logs.'; Run = { param($c) Invoke-AmonSignatureAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Processes'; Name = 'Process Inspector'; RequiresAdmin = $false; Description = 'Java y launchers en ejecución: línea de comandos, agentes, firmas, DLL cargadas.'; Run = { param($c) Invoke-AmonProcessAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Prefetch'; Name = 'Prefetch Analyzer'; RequiresAdmin = $true; Description = 'Ejecuciones registradas por Windows y JAR cargados por Java.'; Run = { param($c) Invoke-AmonPrefetchAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Recent'; Name = 'Recent Files'; RequiresAdmin = $false; Description = 'Accesos recientes del Explorador relacionados con la revisión.'; Run = { param($c) Invoke-AmonRecentAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'UserAssist'; Name = 'UserAssist'; RequiresAdmin = $false; Description = 'Programas iniciados desde el Explorador (ROT13).'; Run = { param($c) Invoke-AmonUserAssistAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Events'; Name = 'Windows Event Analysis'; RequiresAdmin = $true; WithoutAdmin = 'sin administrador: solo System, Defender y claves Run (PARCIAL)'; Description = 'Eventos 4688, 1102, 104, Defender y claves Run.'; Run = { param($c) Invoke-AmonEventAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'Temp'; Name = 'Temp Indicator Sweep'; RequiresAdmin = $false; Description = 'Temp solo con indicadores concretos (nombre o hash).'; Run = { param($c) Invoke-AmonTempSweep -Context $c } }
        [pscustomobject]@{ Key = 'RecycleBin'; Name = 'Recycle Bin Forensics'; RequiresAdmin = $false; Description = 'Metadatos $I/$R de la papelera del usuario y actividad reciente.'; Run = { param($c) Invoke-AmonRecycleBinAnalysis -Context $c } }
        [pscustomobject]@{ Key = 'USNJournal'; Name = 'NTFS / USN Journal'; RequiresAdmin = $true; Description = 'Creación, borrado y renombrado de archivos relevantes (solo lectura).'; Run = { param($c) Invoke-AmonUsnAnalysis -Context $c } }
    )
}

function Get-AmonDefaultModuleSelection {
    param($Settings)
    $sel = @()
    foreach ($m in (Get-AmonModuleCatalog)) {
        $flag = $Settings.modules[$m.Key]
        if ($null -eq $flag -or $flag) { $sel += $m.Key }
    }
    return $sel
}

function Get-AmonScanScope {
    # Lista legible de lo que se inspeccionará (se muestra antes de pedir confirmación).
    param([Parameter(Mandatory = $true)]$Context, [string[]]$Modules)
    $lines = [System.Collections.Generic.List[string]]::new()
    if ('Minecraft' -in $Modules -or 'Signatures' -in $Modules) {
        $inst = @(Find-AmonMinecraftInstance -Context $Context)
        if ($inst.Count) { foreach ($i in $inst) { $lines.Add("Minecraft ($($i.Launcher)): $($i.GameDir)") } }
        else { $lines.Add('Minecraft: no se encontraron instancias en las rutas conocidas.') }
    }
    if ('Processes' -in $Modules) { $lines.Add('Procesos en ejecución (solo Java, launchers e indicadores).') }
    if ('Prefetch' -in $Modules) { $lines.Add("$env:SystemRoot\Prefetch") }
    if ('Recent' -in $Modules) { $lines.Add("$env:APPDATA\Microsoft\Windows\Recent") }
    if ('UserAssist' -in $Modules) { $lines.Add('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist') }
    if ('Events' -in $Modules) { $lines.Add('Registros Security / System / Windows Defender; claves Run de HKCU y HKLM.') }
    if ('Temp' -in $Modules) { $lines.Add("$env:TEMP (solo si hay indicadores concretos)") }
    if ('RecycleBin' -in $Modules) { foreach ($f in (Get-AmonRecycleBinFolders)) { $lines.Add($f) } }
    if ('USNJournal' -in $Modules) { $lines.Add('USN Journal de la unidad del sistema y de las unidades de las instancias.') }
    return $lines.ToArray()
}

function Invoke-AmonFullScan {
    <#
    .SYNOPSIS
        Ejecuta los módulos seleccionados en el orden de investigación y correlaciona.
    .PARAMETER OnModule
        Scriptblock opcional llamado antes de cada módulo (índice, total, definición).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Context,
        [string[]]$Modules = @(),
        [scriptblock]$OnModule,
        [scriptblock]$OnModuleDone
    )
    if (-not $Modules.Count) { $Modules = Get-AmonDefaultModuleSelection -Settings $Context.Settings }
    $catalog = @(Get-AmonModuleCatalog | Where-Object { $_.Key -in $Modules })
    $evidencePass = ($Modules -contains 'Signatures')
    $total = $catalog.Count + $(if ($evidencePass) { 1 } else { 0 }) + 1
    $i = 0
    foreach ($m in $catalog) {
        if ($Context.CancelRequested) { break }
        if ($OnModule) { & $OnModule $i $total $m }
        # Los módulos que necesitan administrador se ejecutan igualmente: informan de la falta de acceso.
        $r = Invoke-AmonModule -Name $m.Key -Context $Context -ScriptBlock $m.Run
        if ($OnModuleDone) { & $OnModuleDone $i $total $m $r }
        $i++
    }
    if ($evidencePass -and -not $Context.CancelRequested) {
        $ev = [pscustomobject]@{ Key = 'SignaturesEvidence'; Name = 'Signature Scan (evidencias)'; RequiresAdmin = $false; Description = 'Firmas sobre archivos citados por otros módulos.'; Run = { param($c) Invoke-AmonSignatureAnalysis -Context $c -EvidenceOnly } }
        if ($OnModule) { & $OnModule $i $total $ev }
        $r = Invoke-AmonModule -Name 'SignaturesEvidence' -Context $Context -ScriptBlock $ev.Run
        if ($OnModuleDone) { & $OnModuleDone $i $total $ev $r }
        $i++
    }
    $corrDef = [pscustomobject]@{ Key = 'Correlation'; Name = 'Detection & Correlation Engine'; RequiresAdmin = $false; Description = 'Correlación de evidencias y línea temporal.' }
    if ($OnModule) { & $OnModule $i $total $corrDef }
    $corr = Invoke-AmonCorrelation -Context $Context
    $timeline = @(New-AmonTimeline -Context $Context)
    if ($OnModuleDone) { & $OnModuleDone $i $total $corrDef $corr.Result }
    [pscustomobject]@{ Correlation = $corr; Timeline = $timeline; Cancelled = [bool]$Context.CancelRequested }
}

Export-ModuleMember -Function @('Get-AmonModuleCatalog', 'Get-AmonDefaultModuleSelection', 'Get-AmonScanScope', 'Invoke-AmonFullScan')
