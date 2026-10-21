#Requires -Version 5.1
<#
.SYNOPSIS
    ✦ AMON SS ✦ - Advanced Minecraft Forensic Suite.

.DESCRIPTION
    Herramienta forense de solo lectura para revisiones SS (ScreenShare) CONSENTIDAS de
    Minecraft Java Edition. Analiza instancias y mods, firmas de clientes modificados,
    procesos, Prefetch, papelera, USN Journal, Recent, UserAssist y eventos de Windows, y
    correlaciona las evidencias en una línea temporal y un reporte verificable.

    No envía datos a ningún sitio, no modifica el sistema, no finaliza procesos y no emite
    sanciones: la conclusión es siempre para revisión humana.

.PARAMETER Scan
    Modo no interactivo: 'Full' o un módulo concreto. Requiere -Consent.
.PARAMETER Modules
    Con -Scan Full, limita los módulos (Minecraft, Signatures, Processes, Prefetch, Recent,
    UserAssist, Events, Temp, RecycleBin, USNJournal).
.PARAMETER Consent
    Confirma que el propietario del equipo dio su consentimiento explícito (modo no interactivo).
.PARAMETER ConsentNote
    Texto libre que se guarda en el reporte (p. ej. referencia del ticket o nick del jugador).
.PARAMETER Days
    Ventana de análisis en días (por defecto, la de los ajustes: 7).
.PARAMETER Report
    Formatos a exportar en modo no interactivo: txt, json, html.
.PARAMETER OutputPath
    Carpeta de reportes (por defecto %LOCALAPPDATA%\AmonSS\reports).
.PARAMETER VerifyManifest
    Verifica la integridad de un reporte a partir de su manifiesto .sha256 y termina
    (código 0 si está íntegro, 1 si algún archivo falta o fue alterado).
.PARAMETER VerifyPackage
    Compara cada archivo de esta instalación con Integrity.psd1 y termina (código 0 si el
    paquete está íntegro, 1 si hay archivos alterados, ausentes o añadidos).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
.EXAMPLE
    powershell -NoProfile -File .\Start-AmonSS.ps1 -Scan Full -Consent -ConsentNote "Ticket #123" -Report json,html
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Minecraft', 'Signatures', 'Processes', 'Prefetch', 'Recent', 'UserAssist', 'Events', 'Temp', 'RecycleBin', 'USNJournal')]
    [string]$Scan,
    [string[]]$Modules,
    [switch]$Consent,
    [string]$ConsentNote,
    [ValidateRange(0, 365)][int]$Days = 0,
    [string[]]$Report,
    [string]$OutputPath,
    [ValidateSet('FullPurple', 'MinimalPurple', 'ClassicTerminal')][string]$Theme,
    [ValidateSet('Auto', 'Full', 'Safe', 'Ascii')][string]$Glyphs,
    [switch]$NoAnimation,
    [string]$VerifyManifest,
    [switch]$VerifyPackage
)

$ErrorActionPreference = 'Stop'

# Desde CMD (powershell -File) las listas llegan como "a,b,c": se separan y validan aquí.
function Split-AmonListArgument {
    param([string[]]$Value, [string[]]$Allowed, [string]$Name)
    $out = @()
    foreach ($v in $Value) { foreach ($p in ($v -split '[,; ]+')) { if ($p) { $out += $p } } }
    $bad = @($out | Where-Object { $_ -notin $Allowed })
    if ($bad.Count) { throw "Valor no válido para -${Name}: $($bad -join ', '). Permitidos: $($Allowed -join ', ')." }
    return @($out | ForEach-Object { $v = $_; $Allowed | Where-Object { $_ -ieq $v } | Select-Object -First 1 } | Select-Object -Unique)
}
if ($Report) { $Report = Split-AmonListArgument -Value $Report -Allowed @('txt', 'json', 'html') -Name 'Report' }
if ($Modules) { $Modules = Split-AmonListArgument -Value $Modules -Allowed @('Minecraft', 'Signatures', 'Processes', 'Prefetch', 'Recent', 'UserAssist', 'Events', 'Temp', 'RecycleBin', 'USNJournal') -Name 'Modules' }

$script:Root = $PSScriptRoot
# Orden de dependencias: cada módulo reutiliza la instancia ya cargada de los anteriores.
foreach ($m in 'Core', 'UI', 'Jar', 'Minecraft', 'Signatures', 'Processes', 'Prefetch', 'Recent', 'UserAssist', 'Events',
    'TempSweep', 'RecycleBin', 'USNJournal', 'Correlation', 'Timeline', 'Reports', 'Update', 'Views', 'Orchestrator') {
    Import-Module (Join-Path $script:Root "modules\$m.psm1") -Force -DisableNameChecking
}

# Antes de leer configuración o firmas: el paquete completo frente a Integrity.psd1. Va en texto
# plano porque el tema se carga de la propia configuración que se está comprobando.
if ($VerifyPackage) {
    try { $rows = @(Test-AmonPackageIntegrity) } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    $bad = @($rows | Where-Object { -not $_.Valid })
    foreach ($r in $bad) { Write-Host ('  {0,-12} {1}' -f $r.State, $r.File) }
    Write-Host ("Amon SS {0}: {1} archivo(s) comprobados, {2} con problemas." -f (Get-AmonVersionInfo).Version, $rows.Count, $bad.Count)
    if ($bad.Count) { exit 1 } else { exit 0 }
}
# En una release se comprueba todo el paquete antes de empezar: un archivo alterado dentro de un
# módulo solo lo haría fallar a él y la revisión seguiría con resultados incompletos. Fuera de
# modules\, config\ y signatures\ un archivo añadido no se carga, así que no detiene el arranque.
try {
    if (Get-AmonIntegrityManifest) {
        $bad = @(Test-AmonPackageIntegrity | Where-Object { -not $_.Valid -and ($_.State -ne 'NO INCLUIDO' -or $_.File -match '^(modules|config|signatures)/') })
        if ($bad.Count) {
            [Console]::Error.WriteLine('Integridad del paquete comprometida: ' + (($bad | Select-Object -First 5 | ForEach-Object { "$($_.File) ($($_.State))" }) -join ', ') + '. Ejecuta -VerifyPackage para ver el detalle y vuelve a instalar una versión verificada.')
            exit 1
        }
    }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }

$script:Version = Get-AmonVersionInfo
$script:Settings = Get-AmonSettings
$script:Session = $null
$script:LastScan = $null
$script:Prog = @{ Index = 0; Total = 1; Name = '' }

#region Utilidades de sesión

function Initialize-AmonTheme {
    param([string]$ThemeName, [string]$GlyphName)
    $t = if ($ThemeName) { $ThemeName } else { [string]$script:Settings.theme }
    $g = if ($GlyphName) { $GlyphName } else { [string]$script:Settings.glyphs }
    if (-not $g -or $g -eq 'auto') { $g = 'Auto' } else { $g = (Get-Culture).TextInfo.ToTitleCase($g.ToLowerInvariant()) }
    $noAnim = $NoAnimation -or ($script:Settings.animations -eq $false)
    Initialize-AmonUI -Theme $t -GlyphMode $g -NoAnimation:$noAnim
}

function Show-AmonHeader {
    param([switch]$Clear)
    $admin = Test-AmonAdmin
    Show-AmonBanner -Version $script:Version.Version -BuildDate $script:Version.BuildDate -Status 'READY' -Mode 'LOCAL FORENSIC' `
        -Privilege $(if ($admin) { 'ADMINISTRADOR' } else { 'USUARIO ESTÁNDAR' }) -PrivilegeToken $(if ($admin) { 'success' } else { 'warning' }) -Clear:$Clear
}

function New-AmonSession {
    param([int]$WindowDays, [string]$Note, [string]$ConsentText)
    $d = if ($WindowDays -gt 0) { $WindowDays } else { [int]$script:Settings.defaultDays }
    if ($d -le 0) { $d = 7 }
    $ctx = New-AmonContext -Days $d -Settings $script:Settings
    $ctx.OnProgress = {
        param($pct, $detail, $count)
        $overall = 100.0 * ($script:Prog.Index + [Math]::Min(100, [Math]::Max(0, $pct)) / 100.0) / [Math]::Max(1, $script:Prog.Total)
        Write-AmonProgress -Percent $overall -Activity ("{0}/{1}  {2}" -f ($script:Prog.Index + 1), $script:Prog.Total, $script:Prog.Name) -Detail $detail -Count $count
    }
    $ctx.AuthorizedScope.Add($ConsentText)
    if ($Note) { $ctx.AuthorizedScope.Add("Referencia del revisor: $Note") }
    return $ctx
}

function Invoke-AmonWithCancel {
    # Ejecuta un bloque permitiendo cancelar con Ctrl+C de forma cooperativa y devuelve su salida.
    param([scriptblock]$Block)
    $prev = $false; $set = $false
    try {
        if (-not [Console]::IsInputRedirected) { $prev = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true; $set = $true }
    } catch { $set = $false }
    try { return (& $Block) } finally {
        Complete-AmonProgress
        if ($set) { try { [Console]::TreatControlCAsInput = $prev } catch { } }
    }
}

function Invoke-AmonSingleModule {
    # Ejecuta un módulo dentro de la sesión (con sus prerrequisitos) y lo muestra.
    param([Parameter(Mandatory = $true)][string]$Key, [scriptblock]$Run, [string]$Name)
    $ctx = $script:Session
    $catalog = Get-AmonModuleCatalog
    $def = $catalog | Where-Object Key -EQ $Key
    if (-not $Run) { $Run = $def.Run }
    if (-not $Name) { $Name = $def.Name }
    # Las palabras clave de los clientes (instantáneo) sirven a todos los módulos. El escaneo de
    # JAR solo se ejecuta cuando se pide (03) o en el escaneo completo.
    if (-not $ctx.Signatures) {
        $ctx.Signatures = Get-AmonSignatureSet
        foreach ($k in $ctx.Signatures.Keywords) { [void]$ctx.Keywords.Add($k) }
    }
    # Minecraft aporta rutas de instancias donde mejoran el análisis (firmas, papelera, USN).
    $needsMc = $Key -in @('Signatures', 'USNJournal', 'RecycleBin') -and -not $ctx.Results['Minecraft']
    $steps = @()
    if ($needsMc) { $steps += , @('Minecraft', 'Minecraft Analysis (prerrequisito)', ($catalog | Where-Object Key -EQ 'Minecraft').Run) }
    $steps += , @($Key, $Name, $Run)
    Invoke-AmonWithCancel {
        $script:Prog.Total = $steps.Count
        for ($i = 0; $i -lt $steps.Count; $i++) {
            if ($ctx.CancelRequested) { break }
            $script:Prog.Index = $i; $script:Prog.Name = $steps[$i][1]
            Write-AmonProgress -Percent (100.0 * $i / $steps.Count) -Activity $steps[$i][1] -Force
            $r = Invoke-AmonModule -Name $steps[$i][0] -Context $ctx -ScriptBlock $steps[$i][2]
            Complete-AmonProgress
            Show-AmonModuleStatus -Result $r
        }
    }
    $null = Invoke-AmonCorrelation -Context $ctx
    $result = $ctx.Results[$Key]
    if ($result) { Show-AmonResultView -Result $result -Context $ctx }
}

#endregion

#region Pantallas del menú

function Request-AmonConsent {
    $w = (Get-AmonPanelWidth) - 4
    $text = @(
        'Amon SS solo debe usarse con el consentimiento explícito del propietario del equipo.',
        'Todas las operaciones son de solo lectura: no se modifica, restaura ni elimina nada, no se finalizan procesos y no se envía ningún dato fuera del equipo.',
        'Se analizarán carpetas de Minecraft, procesos relevantes y artefactos de Windows relacionados con la revisión. Los archivos personales no relacionados solo se cuentan.',
        'El resultado es una conclusión para revisión humana; Amon SS no emite sanciones.'
    )
    $lines = @(); foreach ($t in $text) { $lines += @(Split-AmonWrap -Text $t -Width $w); $lines += '' }
    Write-AmonBox -Title 'CONSENTIMIENTO' -Lines $lines[0..($lines.Count - 2)]
    if (-not (Read-AmonConfirm -Prompt '¿El propietario del equipo autoriza esta revisión?' -Default $false)) { return $null }
    $note = Read-AmonInput -Prompt 'Referencia opcional (ticket, nick del jugador; Enter para omitir)'
    return [pscustomobject]@{ Note = $note; Text = ("Consentimiento del propietario confirmado por el operador el {0} en {1} (usuario {2})." -f (Format-AmonTimestamp ([datetime]::UtcNow)), $env:COMPUTERNAME, $env:USERNAME) }
}

function Get-AmonMainMenuItems {
    @(
        @{ Key = '01'; Label = 'FULL FORENSIC SCAN'; Description = 'Todos los módulos en orden, correlación y reporte' },
        @{ Key = '02'; Label = 'MINECRAFT ANALYSIS'; Description = 'Instancias, loaders, mods instalados y cargados' },
        @{ Key = '03'; Label = 'CHEAT SIGNATURE SCANNER'; Description = 'Firmas de clientes en JAR, configuración y logs' },
        @{ Key = '04'; Label = 'PROCESS INSPECTOR'; Description = 'Java y launchers en ejecución' },
        @{ Key = '05'; Label = 'PREFETCH ANALYZER'; Description = 'Ejecuciones registradas (requiere administrador)' },
        @{ Key = '06'; Label = 'RECYCLE BIN FORENSICS'; Description = 'Metadatos $I/$R y actividad de 7 días' },
        @{ Key = '07'; Label = 'NTFS / USN JOURNAL'; Description = 'Creación, borrado y renombrado (administrador)' },
        @{ Key = '08'; Label = 'RECENT & USERASSIST'; Description = 'Accesos recientes y programas iniciados' },
        @{ Key = '09'; Label = 'WINDOWS EVENT ANALYSIS'; Description = '4688, 1102, 104, Defender e inicio automático' },
        @{ Key = '10'; Label = 'FORENSIC TIMELINE'; Description = 'Línea temporal unificada de la sesión' },
        @{ Key = '11'; Label = 'EVIDENCE REPORTS'; Description = 'Exportar TXT/JSON/HTML y verificar integridad' },
        @{ Key = '12'; Label = 'SETTINGS'; Description = 'Tema, glifos, periodo, reportes y actualizaciones' },
        @{ Separator = $true },
        @{ Key = '00'; Label = 'EXIT'; Hollow = $true }
    )
}

function Invoke-AmonMenuFullScan {
    $ctx = $script:Session
    $catalog = @(Get-AmonModuleCatalog)
    $sel = [System.Collections.Generic.List[string]]::new()
    foreach ($k in (Get-AmonDefaultModuleSelection -Settings $script:Settings)) { $sel.Add($k) }
    $admin = $ctx.IsAdmin
    while ($true) {
        $lines = @()
        for ($i = 0; $i -lt $catalog.Count; $i++) {
            $m = $catalog[$i]
            $on = $sel.Contains($m.Key)
            $box = if ($on) { Format-AmonColor (Get-AmonGlyph 'Square') 'success' } else { Format-AmonColor (Get-AmonGlyph 'DiamondHollow') 'muted' }
            $req = ''
            if ($m.RequiresAdmin) {
                $noAdmin = if ($m.PSObject.Properties['WithoutAdmin']) { $m.WithoutAdmin } else { 'requiere administrador (se informará SIN ACCESO)' }
                $req = if ($admin) { Format-AmonColor ' admin: sí' 'success' } else { Format-AmonColor " $noAdmin" 'warning' }
            }
            $lines += ('{0} {1} {2}' -f (Format-AmonColor ('[{0:00}]' -f ($i + 1)) 'title' -Bold), $box, (Format-AmonColor $m.Name 'primary')) + $req
        }
        $lines += '---'
        $lines += (Format-AmonColor 'Ubicaciones que se inspeccionarán:' 'secondary')
        foreach ($s in (Get-AmonScanScope -Context $ctx -Modules $sel.ToArray())) { $lines += '  ' + (Get-AmonGlyph 'Arrow') + ' ' + (ConvertTo-AmonSafeText $s) }
        $lines += '---'
        $lines += (Format-AmonColor ("Periodo: últimos {0} días. Tiempo máximo por módulo: {1} s. Ctrl+C cancela de forma segura." -f $ctx.Days, $script:Settings.moduleTimeoutSeconds) 'muted')
        Write-AmonBox -Title 'ALCANCE DE LA REVISIÓN' -Lines $lines
        $ans = Read-AmonInput -Prompt 'Número para activar/desactivar, Enter para comenzar, 0 para volver'
        if ($null -eq $ans -or $ans -eq '0') { return }
        if ($ans -eq '') { break }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $catalog.Count) {
            $k = $catalog[$n - 1].Key
            if ($sel.Contains($k)) { [void]$sel.Remove($k) } else { $sel.Add($k) }
        }
    }
    if (-not $sel.Count) { Write-AmonWarning -Message 'No hay módulos seleccionados.'; return }
    if (-not (Read-AmonConfirm -Prompt '¿Confirmas que el propietario autoriza inspeccionar estas ubicaciones?' -Default $true)) { return }
    $ctx.AuthorizedScope.Add(('Escaneo completo autorizado ({0}): {1}' -f (Format-AmonTimestamp ([datetime]::UtcNow)), ($sel -join ', ')))
    $script:LastScan = Invoke-AmonScanWithProgress -Context $ctx -Modules $sel.ToArray()
    Show-AmonScanSummary -Scan $script:LastScan
    if (Read-AmonConfirm -Prompt '¿Exportar el reporte ahora?' -Default $true) { $null = Export-AmonSessionReport }
    if (Read-AmonConfirm -Prompt '¿Ver el detalle de cada módulo?' -Default $false) {
        foreach ($r in @($ctx.Results.Values | Where-Object { $_.Module -ne 'Correlation' })) { Show-AmonResultView -Result $r -Context $ctx }
    }
}

function Invoke-AmonScanWithProgress {
    param([Parameter(Mandatory = $true)]$Context, [string[]]$Modules)
    Write-AmonSection -Title 'FULL FORENSIC SCAN' -Subtitle 'Progreso en tiempo real. Pulsa Ctrl+C para cancelar; se conservan los resultados parciales.'
    $scan = Invoke-AmonWithCancel {
        Invoke-AmonFullScan -Context $Context -Modules $Modules -OnModule {
            param($i, $total, $def)
            $script:Prog.Index = $i; $script:Prog.Total = $total; $script:Prog.Name = $def.Name
            Write-AmonProgress -Percent (100.0 * $i / $total) -Activity ("{0}/{1}  {2}" -f ($i + 1), $total, $def.Name) -Detail $def.Description -Force
        } -OnModuleDone {
            param($i, $total, $def, $r)
            Complete-AmonProgress
            if ($r) { Show-AmonModuleStatus -Result $r }
        }
    }
    if ($Context.CancelRequested) { Write-AmonWarning -Label 'CANCELADO' -Message 'Revisión cancelada por el operador: los resultados son parciales y así constará en el reporte.' }
    return $scan
}

function Show-AmonScanSummary {
    param([Parameter(Mandatory = $true)]$Scan)
    Show-AmonVerdictView -Correlation $Scan.Correlation -Context $script:Session
    $all = @(Get-AmonAllFindings -Context $script:Session) + @($Scan.Correlation.Correlated)
    Write-AmonSection -Title 'RESUMEN'
    Write-AmonCountUp -Label 'Hallazgos CORRELATED' -Value @($all | Where-Object Status -EQ 'CORRELATED').Count -Token 'finding'
    Write-AmonCountUp -Label 'Hallazgos DETECTED' -Value @($all | Where-Object Status -EQ 'DETECTED').Count -Token 'finding'
    Write-AmonCountUp -Label 'Hallazgos INCONCLUSIVE' -Value @($all | Where-Object Status -EQ 'INCONCLUSIVE').Count -Token 'warning'
    Write-AmonCountUp -Label 'Eventos en la línea temporal' -Value @($Scan.Timeline).Count -Token 'secondary'
    $reviewed = 0; foreach ($r in @($script:Session.Results.Values)) { $reviewed += [int]$r.ArtifactsReviewed }
    Write-AmonCountUp -Label 'Artefactos revisados' -Value $reviewed -Token 'secondary'
}

function Invoke-AmonMenuTimeline {
    $ctx = $script:Session
    if (-not @($ctx.Results.Values | Where-Object { $_.Events.Count }).Count) {
        Write-AmonWarning -Message 'Todavía no hay eventos en esta sesión. Ejecuta primero el escaneo completo (01) o algún módulo.'
        if (Read-AmonConfirm -Prompt '¿Ejecutar ahora el escaneo completo?' -Default $true) { Invoke-AmonMenuFullScan }
        return
    }
    $ans = Read-AmonInput -Prompt "Días a mostrar [$($ctx.Days)] o rango 'AAAA-MM-DD AAAA-MM-DD'"
    $since = $ctx.SinceUtc; $until = [datetime]::UtcNow.AddMinutes(5); $label = "Últimos $($ctx.Days) días"
    if ($ans -match '^\s*(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})\s*$') {
        $since = ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)).ToUniversalTime()
        $until = ([datetime]::ParseExact($Matches[2], 'yyyy-MM-dd', $null)).AddDays(1).ToUniversalTime()
        $label = "Del $($Matches[1]) al $($Matches[2]) (los datos fuera de la ventana de análisis original pueden no estar recopilados)"
    } elseif ($ans -match '^\s*(\d{1,3})\s*$') {
        $since = [datetime]::UtcNow.AddDays(-1 * [int]$Matches[1]); $label = "Últimos $($Matches[1]) días"
    }
    $rows = @(New-AmonTimeline -Context $ctx -SinceUtc $since -UntilUtc $until)
    Show-AmonTimelineView -Rows $rows -Context $ctx -Range $label
}

function Export-AmonSessionReport {
    param([string[]]$Formats, [string]$Directory)
    $ctx = $script:Session
    $corr = Invoke-AmonCorrelation -Context $ctx
    $timeline = @(New-AmonTimeline -Context $ctx)
    $model = New-AmonReportModel -Context $ctx -Correlation $corr -Timeline $timeline
    if (-not $Formats) { $Formats = @($script:Settings.reportFormats) }
    if (-not $Directory) { $Directory = Expand-AmonPath ([string]$script:Settings.reportDirectory) }
    $exp = Export-AmonReport -Model $model -Directory $Directory -Formats $Formats
    $lines = @()
    foreach ($f in $exp.Files) { $lines += (Format-AmonColor $f.Format.ToUpperInvariant().PadRight(5) 'title' -Bold) + ' ' + $f.Path; $lines += '      SHA-256 ' + (Format-AmonColor $f.Sha256 'secondary') }
    $lines += '---'
    $lines += 'Manifiesto: ' + $exp.Manifest
    $lines += (Format-AmonColor 'Anota el SHA-256 del reporte en el ticket: permite comprobar después que no se alteró.' 'muted')
    Write-AmonBox -Title "REPORTE $($model.ReviewId)" -Lines $lines
    return $exp
}

function Invoke-AmonMenuReports {
    while ($true) {
        Show-AmonMenu -Title 'EVIDENCE REPORTS' -Items @(
            @{ Key = '1'; Label = 'EXPORTAR REPORTE DE LA SESIÓN'; Description = ($script:Settings.reportFormats -join ', ').ToUpperInvariant() },
            @{ Key = '2'; Label = 'VERIFICAR INTEGRIDAD'; Description = 'Comprobar un manifiesto .sha256' },
            @{ Separator = $true }, @{ Key = '0'; Label = 'VOLVER'; Hollow = $true })
        switch (Read-AmonInput) {
            '1' {
                if (-not $script:Session.Results.Count) { Write-AmonWarning -Message 'No hay resultados en esta sesión todavía.'; continue }
                $null = Export-AmonSessionReport
            }
            '2' {
                $p = Read-AmonInput -Prompt 'Ruta del manifiesto .sha256'
                if ($p -and (Test-Path -LiteralPath $p.Trim('"'))) { Show-AmonIntegrity -Manifest $p.Trim('"') } else { Write-AmonWarning -Message 'No existe ese archivo.' }
            }
            default { return }
        }
    }
}

function Show-AmonIntegrity {
    param([string]$Manifest)
    $res = @(Test-AmonReportIntegrity -ManifestPath $Manifest)
    Write-AmonTable -Title 'INTEGRIDAD DEL REPORTE' -Rows $res -Columns @(
        @{ Header = 'ARCHIVO'; Property = 'File' },
        @{ Header = 'ESTADO'; Property = { param($r) if ($r.Valid) { 'ÍNTEGRO' } else { 'ALTERADO O AUSENTE' } }; Token = { param($r) if ($r.Valid) { 'success' } else { 'finding' } } },
        @{ Header = 'SHA-256 ACTUAL'; Property = 'Actual' }
    )
    return (-not ($res | Where-Object { -not $_.Valid }) -and $res.Count -gt 0)
}

function Invoke-AmonMenuSettings {
    while ($true) {
        $s = $script:Settings
        Show-AmonMenu -Title 'SETTINGS' -Items @(
            @{ Key = '1'; Label = 'FULL PURPLE'; Description = $(if ($s.theme -eq 'FullPurple') { 'tema actual' } else { 'degradado, bordes dobles, animación' }) },
            @{ Key = '2'; Label = 'MINIMAL PURPLE'; Description = $(if ($s.theme -eq 'MinimalPurple') { 'tema actual' } else { 'bordes simples, sin animación' }) },
            @{ Key = '3'; Label = 'CLASSIC TERMINAL'; Description = $(if ($s.theme -eq 'ClassicTerminal') { 'tema actual' } else { '16 colores, máxima compatibilidad' }) },
            @{ Separator = $true },
            @{ Key = '4'; Label = 'GLIFOS'; Description = "actual: $($s.glyphs) (auto / full / safe / ascii)" },
            @{ Key = '5'; Label = 'PERIODO POR DEFECTO'; Description = "$($s.defaultDays) días" },
            @{ Key = '6'; Label = 'CARPETA DE REPORTES'; Description = (Expand-AmonPath $s.reportDirectory) },
            @{ Key = '7'; Label = 'FORMATOS DE REPORTE'; Description = ($s.reportFormats -join ', ') },
            @{ Key = '8'; Label = 'ANIMACIONES'; Description = $(if ($s.animations) { 'activadas' } else { 'desactivadas' }) },
            @{ Key = '9'; Label = 'RUTA EXTRA DE INSTANCIA'; Description = 'launchers portables (MultiMC, ATLauncher...)' },
            @{ Key = '10'; Label = 'BUSCAR ACTUALIZACIONES'; Description = $(if ($s.updates.repository) { $s.updates.repository } else { 'repositorio no configurado' }) },
            @{ Separator = $true }, @{ Key = '0'; Label = 'VOLVER'; Hollow = $true })
        $c = Read-AmonInput
        switch ($c) {
            { $_ -in '1', '2', '3' } {
                $name = @{ '1' = 'FullPurple'; '2' = 'MinimalPurple'; '3' = 'ClassicTerminal' }[$c]
                Set-AmonSetting -Name 'theme' -Value $name -Persist
                Initialize-AmonTheme
                Show-AmonHeader -Clear
            }
            '4' {
                $g = Read-AmonInput -Prompt 'Glifos (auto/full/safe/ascii)'
                if ($g -in 'auto', 'full', 'safe', 'ascii') { Set-AmonSetting -Name 'glyphs' -Value $g -Persist; Initialize-AmonTheme; Show-AmonHeader -Clear }
            }
            '5' {
                $d = Read-AmonInput -Prompt 'Días (1-365)'; $n = 0
                if ([int]::TryParse($d, [ref]$n) -and $n -ge 1 -and $n -le 365) { Set-AmonSetting -Name 'defaultDays' -Value $n -Persist; Write-AmonStatus -Label 'Periodo' -Value "$n días" -State Ok -Detail 'se aplica a la próxima revisión' }
            }
            '6' {
                $p = Read-AmonInput -Prompt 'Carpeta para los reportes'
                if ($p) { Set-AmonSetting -Name 'reportDirectory' -Value $p.Trim('"') -Persist }
            }
            '7' {
                $f = Read-AmonInput -Prompt 'Formatos separados por coma (txt,json,html)'
                $list = @($f -split '[,; ]+' | Where-Object { $_ -in 'txt', 'json', 'html' })
                if ($list.Count) { Set-AmonSetting -Name 'reportFormats' -Value $list -Persist }
            }
            '8' { Set-AmonSetting -Name 'animations' -Value (-not $s.animations) -Persist; Initialize-AmonTheme }
            '9' {
                $p = Read-AmonInput -Prompt 'Ruta del directorio de juego (.minecraft de la instancia)'
                if ($p -and (Test-Path -LiteralPath $p.Trim('"'))) {
                    $paths = @($s.minecraft.extraInstancePaths) + @($p.Trim('"'))
                    Set-AmonSetting -Name 'minecraft.extraInstancePaths' -Value ($paths | Select-Object -Unique) -Persist
                } else { Write-AmonWarning -Message 'La ruta no existe.' }
            }
            '10' { Invoke-AmonMenuUpdate }
            default { return }
        }
        $script:Settings = Get-AmonSettings -Reload
        $script:Session.Settings = $script:Settings
    }
}

function Invoke-AmonMenuUpdate {
    $repo = [string]$script:Settings.updates.repository
    if (-not (Test-AmonRepositoryName $repo)) {
        # Se valida antes de guardar: un valor inválido guardado bloquearía todas las consultas.
        $repo = Read-AmonInput -Prompt 'Repositorio de GitHub (propietario/Amon-SS)'
        if (-not $repo) { return }
        $repo = $repo.Trim()
        if (-not (Test-AmonRepositoryName $repo)) { Write-AmonWarning -Message 'Formato no válido: escribe propietario/repositorio (p. ej. usuario/Amon-SS).'; return }
        Set-AmonSetting -Name 'updates.repository' -Value $repo -Persist
    }
    Write-AmonWarning -Label 'RED' -Message "Se consultará la API pública de GitHub ($repo). No se envía ningún dato del equipo."
    try {
        $rel = Get-AmonLatestRelease -Repository $repo
        $cmp = Compare-AmonVersion $rel.Tag $script:Version.Version
    } catch { Write-AmonWarning -Label 'ERROR' -Message "No se pudo consultar la última versión: $($_.Exception.Message)"; return }
    # Datos remotos: se sanean antes de mostrarlos.
    Write-AmonBox -Title 'ACTUALIZACIONES' -Lines @("Versión instalada : $($script:Version.Version)", "Última publicada  : $(ConvertTo-AmonSafeText $rel.Tag)  ($(Format-AmonTimestamp $rel.PublishedUtc))", "Página            : $(ConvertTo-AmonSafeText $rel.Url)")
    if ($null -eq $cmp) { Write-AmonWarning -Message 'La etiqueta publicada no es un número de versión; no se ofrece instalarla.'; return }
    if ($cmp -le 0) { Write-AmonStatus -Label 'Estado' -Value 'AL DÍA' -State Ok; return }
    Write-AmonWarning -Message 'Para instalarla necesitas el SHA-256 publicado en el README o en las notas firmadas de la versión. Sin ese valor no se instala nada.'
    $hash = Read-AmonInput -Prompt 'SHA-256 de confianza del ZIP (Enter para cancelar)'
    if (-not $hash) { return }
    try {
        $path = Install-AmonRelease -Repository $repo -Version ($rel.Tag -replace '^v', '') -Sha256 $hash
        Write-AmonStatus -Label 'Versión verificada' -Value 'INSTALADA' -State Ok -Detail $path
        Write-AmonWarning -Label 'SIGUIENTE' -Message "Cierra esta sesión y ejecuta: powershell -NoProfile -ExecutionPolicy RemoteSigned -File `"$path`""
    } catch { Write-AmonWarning -Label 'RECHAZADA' -Message $_.Exception.Message }
}

function Invoke-AmonMainMenu {
    while ($true) {
        Show-AmonMenu -Title 'MAIN MENU' -Items (Get-AmonMainMenuItems)
        $choice = Read-AmonInput
        if ($null -eq $choice) { return }
        # Un Enter sin querer no puede cerrar la sesión ('' se convertiría en '00').
        if (-not $choice.Trim()) { continue }
        $script:Session.CancelRequested = $false
        switch ($choice.PadLeft(2, '0')) {
            '01' { Invoke-AmonMenuFullScan }
            '02' { Invoke-AmonSingleModule -Key 'Minecraft' }
            '03' {
                $extra = Read-AmonInput -Prompt 'Ruta adicional a escanear (archivo o carpeta; Enter para omitir)'
                if ($extra -and (Test-Path -LiteralPath $extra.Trim('"'))) {
                    # La ruta viaja como dato en el contexto, nunca como texto de código.
                    $p = $extra.Trim('"'); $script:Session.AuthorizedScope.Add("Ruta adicional autorizada para firmas: $p")
                    if (-not $script:Session.ExtraScanPaths.Contains($p)) { $script:Session.ExtraScanPaths.Add($p) }
                }
                Invoke-AmonSingleModule -Key 'Signatures'
            }
            '04' { Invoke-AmonSingleModule -Key 'Processes' }
            '05' { Invoke-AmonSingleModule -Key 'Prefetch' }
            '06' {
                if (-not $script:Session.Results['USNJournal'] -and $script:Session.IsAdmin) { Invoke-AmonSingleModule -Key 'USNJournal' }
                Invoke-AmonSingleModule -Key 'RecycleBin'
            }
            '07' { Invoke-AmonSingleModule -Key 'USNJournal' }
            '08' { Invoke-AmonSingleModule -Key 'Recent'; Invoke-AmonSingleModule -Key 'UserAssist' }
            '09' { Invoke-AmonSingleModule -Key 'Events' }
            '10' { Invoke-AmonMenuTimeline }
            '11' { Invoke-AmonMenuReports }
            '12' { Invoke-AmonMenuSettings }
            '00' { return }
            default { Write-AmonWarning -Message 'Opción no válida.' }
        }
        Write-AmonFooter -Version $script:Version.Version -Text "Revisión $($script:Session.ReviewId)"
    }
}

#endregion

#region Modo no interactivo

function Invoke-AmonCli {
    if (-not $Consent) {
        # Write-Error con ErrorActionPreference=Stop terminaría con código 1: se escribe en stderr y se sale con 2.
        [Console]::Error.WriteLine('El modo no interactivo requiere -Consent: confirma así que el propietario del equipo autorizó la revisión.')
        exit 2
    }
    $consentText = "Consentimiento del propietario confirmado por el operador con -Consent el $(Format-AmonTimestamp ([datetime]::UtcNow)) en $env:COMPUTERNAME (usuario $env:USERNAME)."
    $script:Session = New-AmonSession -WindowDays $Days -Note $ConsentNote -ConsentText $consentText
    Show-AmonHeader
    # Un módulo suelto lleva delante Minecraft; Temp además necesita Firmas, que es quien
    # registra los indicadores concretos que busca.
    $mods = if ($Scan -eq 'Full' -or -not $Scan) { if ($Modules) { $Modules } else { Get-AmonDefaultModuleSelection -Settings $script:Settings } }
    elseif ($Scan -eq 'Temp') { @('Minecraft', 'Signatures', 'Temp') }
    else { @('Minecraft', $Scan) | Select-Object -Unique }
    $script:Session.AuthorizedScope.Add("Módulos autorizados: $($mods -join ', ')")
    $script:LastScan = Invoke-AmonScanWithProgress -Context $script:Session -Modules $mods
    Show-AmonScanSummary -Scan $script:LastScan
    if ($Report) { $null = Export-AmonSessionReport -Formats $Report -Directory $(if ($OutputPath) { $OutputPath } else { $null }) }
    Write-AmonFooter -Version $script:Version.Version -Text "Revisión $($script:Session.ReviewId) finalizada"
}

#endregion

try {
    Initialize-AmonTheme -ThemeName $Theme -GlyphName $Glyphs
    if ($VerifyManifest) { $ok = Show-AmonIntegrity -Manifest $VerifyManifest; if ($ok) { exit 0 } else { exit 1 } }
    if ($Scan -or $Consent) { Invoke-AmonCli; return }
    Show-AmonHeader -Clear
    $c = Request-AmonConsent
    if (-not $c) { Write-AmonFooter -Version $script:Version.Version -Text 'Sin consentimiento: no se realizó ningún análisis.'; return }
    $script:Session = New-AmonSession -WindowDays $Days -Note $c.Note -ConsentText $c.Text
    Write-AmonStatus -Label 'Revisión' -Value $script:Session.ReviewId -State Info -Detail ("periodo de {0} días · {1}" -f $script:Session.Days, (Get-AmonTimeZoneLabel))
    Invoke-AmonMainMenu
    Write-AmonFooter -Version $script:Version.Version -Text 'Sesión cerrada. Ningún archivo del sistema fue modificado.'
} finally {
    Restore-AmonConsole
}
