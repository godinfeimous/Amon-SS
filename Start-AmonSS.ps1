#Requires -Version 5.1
<#
.SYNOPSIS
    ✦ AMON SS ✦ - Advanced Minecraft Forensic Suite.

.DESCRIPTION
    Herramienta forense de solo lectura para revisiones SS (ScreenShare) de Minecraft Java
    Edition. Analiza instancias y mods, firmas de clientes modificados, procesos, Prefetch,
    papelera, USN Journal, Recent, UserAssist y eventos de Windows, y correlaciona las
    evidencias en una línea temporal y un reporte verificable.

    Al abrirse lo hace todo solo: escanea, muestra el resultado y guarda el reporte. El
    revisor solo pulsa una tecla al final. El consentimiento lo cubren los términos de la SS
    del servidor; el reporte deja constancia de quién y cuándo ejecutó la revisión.

    No envía datos a ningún sitio, no modifica el sistema, no finaliza procesos y no emite
    sanciones: la conclusión es siempre para revisión humana.

.PARAMETER Scan
    Modo no interactivo: 'Full' o un módulo concreto.
.PARAMETER Modules
    Limita los módulos del escaneo completo (Minecraft, Signatures, Processes, Memory, Prefetch, BAM, PCA,
    ShimCache, Recent, UserAssist, Events, Tamper, Temp, RecycleBin, USNJournal).
.PARAMETER Consent
    Obsoleto: se acepta por compatibilidad y no hace nada.
.PARAMETER ConsentNote
    Texto libre que se guarda en el reporte (p. ej. referencia del ticket o nick del jugador).
.PARAMETER Days
    Ventana de análisis en días (por defecto, la de los ajustes: 7).
.PARAMETER Report
    Formatos a exportar en modo no interactivo: txt, json, html.
.PARAMETER OutputPath
    Carpeta de reportes (por defecto %LOCALAPPDATA%\AmonSS\reports).
.PARAMETER NoElevate
    No ofrece reiniciar como administrador.
.PARAMETER VerifyManifest
    Verifica la integridad de un reporte a partir de su manifiesto .sha256 y termina
    (código 0 si está íntegro, 1 si algún archivo falta o fue alterado).
.PARAMETER VerifyPackage
    Compara cada archivo de esta instalación con Integrity.psd1 y termina (código 0 si el
    paquete está íntegro, 1 si hay archivos alterados, ausentes o añadidos).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
.EXAMPLE
    powershell -NoProfile -File .\Start-AmonSS.ps1 -Scan Full -ConsentNote "Ticket #123" -Report json,html
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Minecraft', 'Signatures', 'Processes', 'Memory', 'Prefetch', 'BAM', 'PCA', 'ShimCache', 'Recent', 'UserAssist', 'Events', 'Tamper', 'Temp', 'RecycleBin', 'USNJournal')]
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
    [switch]$VerifyPackage,
    [switch]$NoElevate,
    # Interno: lo pasa la copia reabierta como administrador para no volver a ofrecerlo.
    [switch]$Elevated
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
if ($Modules) { $Modules = Split-AmonListArgument -Value $Modules -Allowed @('Minecraft', 'Signatures', 'Processes', 'Memory', 'Prefetch', 'BAM', 'PCA', 'ShimCache', 'Recent', 'UserAssist', 'Events', 'Tamper', 'Temp', 'RecycleBin', 'USNJournal') -Name 'Modules' }

$script:Root = $PSScriptRoot
# Orden de dependencias: cada módulo reutiliza la instancia ya cargada de los anteriores.
foreach ($m in 'Core', 'UI', 'Jar', 'Minecraft', 'Signatures', 'Processes', 'Memory', 'Prefetch', 'ExecutionArtifacts', 'Recent', 'UserAssist', 'Events', 'Tamper',
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
$script:LastExport = $null
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
    param([int]$WindowDays, [string]$Note)
    $d = if ($WindowDays -gt 0) { $WindowDays } else { [int]$script:Settings.defaultDays }
    if ($d -le 0) { $d = 7 }
    $ctx = New-AmonContext -Days $d -Settings $script:Settings
    $ctx.OnProgress = {
        param($pct, $detail, $count)
        $overall = 100.0 * ($script:Prog.Index + [Math]::Min(100, [Math]::Max(0, $pct)) / 100.0) / [Math]::Max(1, $script:Prog.Total)
        Write-AmonProgress -Percent $overall -Activity ("{0}/{1}  {2}" -f ($script:Prog.Index + 1), $script:Prog.Total, $script:Prog.Name) -Detail $detail -Count $count
    }
    # Sin pregunta de consentimiento (lo cubren los términos de la SS del servidor): el reporte
    # deja constancia de quién, dónde y cuándo se ejecutó la revisión.
    $ctx.AuthorizedScope.Add(("Revisión SS ejecutada por el usuario {0} en {1} el {2}{3}; el consentimiento se rige por los términos de la SS del servidor." -f `
                $env:USERNAME, $env:COMPUTERNAME, (Format-AmonTimestamp ([datetime]::UtcNow)), $(if ($ctx.IsAdmin) { ' (como administrador)' } else { '' })))
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

#region Revisión automática y menús de una tecla

function Start-AmonElevated {
    # Reabre Amon SS como administrador (aviso de UAC de Windows). Si se rechaza, se sigue igual.
    # La copia elevada recibe las mismas opciones (entre comillas: pueden llevar espacios).
    $q = { param($v) '"{0}"' -f ([string]$v).Replace('"', '') }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', (& $q $PSCommandPath), '-Elevated')
    if ($Days -gt 0) { $argList += @('-Days', [string]$Days) }
    if ($NoAnimation) { $argList += '-NoAnimation' }
    if ($Modules) { $argList += @('-Modules', (& $q ($Modules -join ','))) }
    if ($OutputPath) { $argList += @('-OutputPath', (& $q $OutputPath)) }
    if ($ConsentNote) { $argList += @('-ConsentNote', (& $q $ConsentNote)) }
    if ($Theme) { $argList += @('-Theme', $Theme) }
    if ($Glyphs) { $argList += @('-Glyphs', $Glyphs) }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -ErrorAction Stop | Out-Null
        Write-AmonStatus -Label 'Administrador' -Value 'NUEVA VENTANA' -State Ok -Detail 'la revisión continúa en la ventana de administrador'
        return $true
    } catch {
        Write-AmonWarning -Message 'No se concedió el permiso de administrador: la revisión sigue sin él.'
        return $false
    }
}

function Invoke-AmonFullReview {
    # Escaneo completo + veredicto + reporte, sin preguntar nada.
    param([string[]]$Modules)
    $ctx = $script:Session
    $ctx.CancelRequested = $false
    $mods = if ($Modules) { $Modules } else { Get-AmonDefaultModuleSelection -Settings $script:Settings }
    $script:LastScan = Invoke-AmonScanWithProgress -Context $ctx -Modules $mods
    Show-AmonScanSummary -Scan $script:LastScan
    $script:LastExport = Export-AmonSessionReport
}

function Invoke-AmonAutoReview {
    # Flujo por defecto: todo automático; el revisor solo pulsa una tecla al final.
    Show-AmonHeader -Clear
    if (-not $script:Session.IsAdmin -and -not $Elevated -and -not $NoElevate) {
        $k = Read-AmonKey -Prompt 'Sin administrador no se leen Prefetch, USN Journal ni el registro de Seguridad.  [A] reabrir como administrador  ·  [Enter] seguir así' `
            -Keys @('a', 'enter', 'esc') -Default 'enter' -TimeoutSeconds 10
        if ($k -eq 'a' -and (Start-AmonElevated)) { return }
    }
    Write-AmonStatus -Label 'Revisión' -Value $script:Session.ReviewId -State Info -Detail ("periodo de {0} días · {1}" -f $script:Session.Days, (Get-AmonTimeZoneLabel))
    Invoke-AmonFullReview -Modules $Modules
    Invoke-AmonFinalMenu
}

function Invoke-AmonFinalMenu {
    while ($true) {
        Show-AmonMenu -Title 'REVISIÓN TERMINADA' -Items @(
            @{ Key = 'H'; Label = 'ABRIR EL REPORTE'; Description = 'versión HTML en el navegador' },
            @{ Key = 'D'; Label = 'DETALLE'; Description = 'resultados de cada módulo' },
            @{ Key = 'T'; Label = 'LÍNEA TEMPORAL'; Description = "últimos $($script:Session.Days) días" },
            @{ Key = 'R'; Label = 'REPETIR'; Description = 'volver a escanear todo' },
            @{ Key = 'M'; Label = 'MÁS OPCIONES'; Description = 'módulos sueltos, verificación y ajustes' },
            @{ Separator = $true },
            @{ Key = 'Q'; Label = 'SALIR'; Hollow = $true })
        # Enter no hace nada a propósito: un Enter sin querer no puede cerrar la revisión.
        $k = Read-AmonKey -Prompt 'Pulsa una tecla' -Keys @('h', 'd', 't', 'r', 'm', 'q', 'esc') -Default 'q'
        switch ($k) {
            'h' { Open-AmonReport }
            'd' { foreach ($r in @($script:Session.Results.Values | Where-Object { $_.Module -ne 'Correlation' })) { Show-AmonResultView -Result $r -Context $script:Session } }
            't' { Show-AmonSessionTimeline }
            'r' { Invoke-AmonFullReview -Modules $Modules }
            'm' { Invoke-AmonMoreMenu }
            default { return }
        }
    }
}

function Open-AmonReport {
    # Abre el HTML con el programa predeterminado (un archivo local: no hay red de por medio).
    $html = @($script:LastExport.Files | Where-Object Format -EQ 'html' | Select-Object -First 1)
    if (-not $html.Count) { Write-AmonWarning -Message 'Esta revisión no exportó un reporte HTML (revisa reportFormats en los ajustes).'; return }
    if ([Console]::IsInputRedirected) { Write-AmonStatus -Label 'Reporte' -Value 'HTML' -State Info -Detail $html[0].Path; return }
    try { Start-Process -FilePath $html[0].Path | Out-Null; Write-AmonStatus -Label 'Reporte' -Value 'ABIERTO' -State Ok -Detail $html[0].Path }
    catch { Write-AmonWarning -Message "No se pudo abrir el reporte: $($_.Exception.Message)" }
}

function Invoke-AmonMoreMenu {
    while ($true) {
        Show-AmonMenu -Title 'MÁS OPCIONES' -Items @(
            @{ Key = '1'; Label = 'MINECRAFT'; Description = 'instancias, loaders, mods instalados y cargados' },
            @{ Key = '2'; Label = 'FIRMAS'; Description = 'clientes en JAR, configuración y logs' },
            @{ Key = '3'; Label = 'PROCESOS'; Description = 'Java y launchers en ejecución' },
            @{ Key = 'J'; Label = 'MEMORIA DE JAVA'; Description = 'firmas cargadas ahora en Minecraft (inyectados)' },
            @{ Key = '4'; Label = 'PREFETCH'; Description = 'ejecuciones registradas (administrador)' },
            @{ Key = '5'; Label = 'PAPELERA'; Description = 'metadatos $I/$R y actividad reciente' },
            @{ Key = '6'; Label = 'USN JOURNAL'; Description = 'creación, borrado y renombrado (administrador)' },
            @{ Key = '7'; Label = 'RECENT Y USERASSIST'; Description = 'accesos recientes y programas iniciados' },
            @{ Key = '8'; Label = 'EVENTOS DE WINDOWS'; Description = '4688, 1102, 104, Defender e inicio automático' },
            @{ Key = '9'; Label = 'BAM, PCA Y SHIMCACHE'; Description = 'programas ejecutados según Windows' },
            @{ Key = 'B'; Label = 'EVASIÓN'; Description = 'servicios forenses detenidos y cambios de hora' },
            @{ Key = 'X'; Label = 'ESCANEAR RUTA EXTRA'; Description = 'una carpeta o archivo concreto con las firmas' },
            @{ Key = 'E'; Label = 'EXPORTAR DE NUEVO'; Description = 'reporte con los resultados actuales' },
            @{ Key = 'V'; Label = 'VERIFICAR UN REPORTE'; Description = 'comprobar su manifiesto .sha256' },
            @{ Key = 'S'; Label = 'AJUSTES'; Description = 'tema, periodo, carpetas y actualizaciones' },
            @{ Separator = $true },
            @{ Key = 'Q'; Label = 'VOLVER'; Hollow = $true })
        $k = Read-AmonKey -Prompt 'Pulsa una tecla' -Keys @('1', '2', '3', 'j', '4', '5', '6', '7', '8', '9', 'b', 'x', 'e', 'v', 's', 'q', 'esc') -Default 'q'
        $script:Session.CancelRequested = $false
        switch ($k) {
            '1' { Invoke-AmonSingleModule -Key 'Minecraft' }
            '2' { Invoke-AmonSingleModule -Key 'Signatures' }
            '3' { Invoke-AmonSingleModule -Key 'Processes' }
            'j' { Invoke-AmonSingleModule -Key 'Memory' }
            '4' { Invoke-AmonSingleModule -Key 'Prefetch' }
            '5' {
                if (-not $script:Session.Results['USNJournal'] -and $script:Session.IsAdmin) { Invoke-AmonSingleModule -Key 'USNJournal' }
                Invoke-AmonSingleModule -Key 'RecycleBin'
            }
            '6' { Invoke-AmonSingleModule -Key 'USNJournal' }
            '7' { Invoke-AmonSingleModule -Key 'Recent'; Invoke-AmonSingleModule -Key 'UserAssist' }
            '8' { Invoke-AmonSingleModule -Key 'Events' }
            '9' { Invoke-AmonSingleModule -Key 'BAM'; Invoke-AmonSingleModule -Key 'PCA'; Invoke-AmonSingleModule -Key 'ShimCache' }
            'b' { Invoke-AmonSingleModule -Key 'Tamper' }
            'x' {
                $extra = Read-AmonInput -Prompt 'Ruta de la carpeta o archivo (Enter para cancelar)'
                if ($extra -and (Test-Path -LiteralPath $extra.Trim('"'))) {
                    # La ruta viaja como dato en el contexto, nunca como texto de código.
                    $p = $extra.Trim('"'); $script:Session.AuthorizedScope.Add("Ruta adicional revisada con firmas: $p")
                    if (-not $script:Session.ExtraScanPaths.Contains($p)) { $script:Session.ExtraScanPaths.Add($p) }
                    Invoke-AmonSingleModule -Key 'Signatures'
                } elseif ($extra) { Write-AmonWarning -Message 'Esa ruta no existe.' }
            }
            'e' { $script:LastExport = Export-AmonSessionReport }
            'v' {
                $p = Read-AmonInput -Prompt 'Ruta del manifiesto .sha256 (Enter para cancelar)'
                if ($p -and (Test-Path -LiteralPath $p.Trim('"'))) { $null = Show-AmonIntegrity -Manifest $p.Trim('"') } elseif ($p) { Write-AmonWarning -Message 'No existe ese archivo.' }
            }
            's' { Invoke-AmonMenuSettings }
            default { return }
        }
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
    Write-AmonCountUp -Label 'Hallazgos INCONCLUSIVE' -Value @($all | Where-Object { $_.Status -eq 'INCONCLUSIVE' -and $_.Category -ne 'KeywordName' }).Count -Token 'warning'
    $names = @($all | Where-Object Category -EQ 'KeywordName').Count
    if ($names) { Write-AmonCountUp -Label 'Solo coincidencias de nombre' -Value $names -Token 'muted' }
    $info = @($all | Where-Object Status -EQ 'INFO').Count
    if ($info) { Write-AmonCountUp -Label 'Información para revisar' -Value $info -Token 'secondary' }
    Write-AmonCountUp -Label 'Eventos en la línea temporal' -Value @($Scan.Timeline).Count -Token 'secondary'
    $reviewed = 0; foreach ($r in @($script:Session.Results.Values)) { $reviewed += [int]$r.ArtifactsReviewed }
    Write-AmonCountUp -Label 'Artefactos revisados' -Value $reviewed -Token 'secondary'
}

function Show-AmonSessionTimeline {
    $ctx = $script:Session
    $rows = @(New-AmonTimeline -Context $ctx -SinceUtc $ctx.SinceUtc -UntilUtc ([datetime]::UtcNow.AddMinutes(5)))
    Show-AmonTimelineView -Rows $rows -Context $ctx -Range "Últimos $($ctx.Days) días"
}

function Export-AmonSessionReport {
    param([string[]]$Formats, [string]$Directory)
    $ctx = $script:Session
    $corr = Invoke-AmonCorrelation -Context $ctx
    $timeline = @(New-AmonTimeline -Context $ctx)
    $model = New-AmonReportModel -Context $ctx -Correlation $corr -Timeline $timeline
    if (-not $Formats) { $Formats = @($script:Settings.reportFormats) }
    if (-not $Directory) { $Directory = if ($OutputPath) { $OutputPath } else { Expand-AmonPath ([string]$script:Settings.reportDirectory) } }
    $exp = Export-AmonReport -Model $model -Directory $Directory -Formats $Formats
    $lines = @()
    foreach ($f in $exp.Files) { $lines += (Format-AmonColor $f.Format.ToUpperInvariant().PadRight(5) 'title' -Bold) + ' ' + $f.Path; $lines += '      SHA-256 ' + (Format-AmonColor $f.Sha256 'secondary') }
    $lines += '---'
    $lines += 'Manifiesto: ' + $exp.Manifest
    $lines += (Format-AmonColor 'Anota el SHA-256 del reporte en el ticket: permite comprobar después que no se alteró.' 'muted')
    Write-AmonBox -Title "REPORTE $($model.ReviewId)" -Lines $lines
    return $exp
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
    # Cada opción es una tecla: las de varios valores avanzan al siguiente en cada pulsación.
    while ($true) {
        $s = $script:Settings
        Show-AmonMenu -Title 'AJUSTES' -Items @(
            @{ Key = '1'; Label = 'FULL PURPLE'; Description = $(if ($s.theme -eq 'FullPurple') { 'tema actual' } else { 'degradado, bordes dobles, animación' }) },
            @{ Key = '2'; Label = 'MINIMAL PURPLE'; Description = $(if ($s.theme -eq 'MinimalPurple') { 'tema actual' } else { 'bordes simples, sin animación' }) },
            @{ Key = '3'; Label = 'CLASSIC TERMINAL'; Description = $(if ($s.theme -eq 'ClassicTerminal') { 'tema actual' } else { '16 colores, máxima compatibilidad' }) },
            @{ Separator = $true },
            @{ Key = 'G'; Label = 'GLIFOS'; Description = "$($s.glyphs) (pulsa para cambiar: auto, full, safe, ascii)" },
            @{ Key = 'P'; Label = 'PERIODO'; Description = "$($s.defaultDays) días (pulsa para cambiar: 3, 7, 14, 30)" },
            @{ Key = 'A'; Label = 'ANIMACIONES'; Description = $(if ($s.animations) { 'activadas' } else { 'desactivadas' }) },
            @{ Key = 'C'; Label = 'CARPETA DE REPORTES'; Description = (Expand-AmonPath $s.reportDirectory) },
            @{ Key = 'I'; Label = 'RUTA EXTRA DE INSTANCIA'; Description = 'launchers portables (MultiMC, ATLauncher...)' },
            @{ Key = 'U'; Label = 'BUSCAR ACTUALIZACIONES'; Description = $(if ($s.updates.repository) { $s.updates.repository } else { 'repositorio no configurado' }) },
            @{ Separator = $true }, @{ Key = 'Q'; Label = 'VOLVER'; Hollow = $true })
        $k = Read-AmonKey -Prompt 'Pulsa una tecla' -Keys @('1', '2', '3', 'g', 'p', 'a', 'c', 'i', 'u', 'q', 'esc') -Default 'q'
        switch ($k) {
            { $_ -in '1', '2', '3' } {
                Set-AmonSetting -Name 'theme' -Value (@{ '1' = 'FullPurple'; '2' = 'MinimalPurple'; '3' = 'ClassicTerminal' }[$k]) -Persist
                Initialize-AmonTheme
                Show-AmonHeader -Clear
            }
            'g' {
                $order = @('auto', 'full', 'safe', 'ascii'); $next = $order[([array]::IndexOf($order, [string]$s.glyphs) + 1) % $order.Count]
                Set-AmonSetting -Name 'glyphs' -Value $next -Persist; Initialize-AmonTheme
            }
            'p' {
                $order = @(3, 7, 14, 30); $i = [array]::IndexOf($order, [int]$s.defaultDays); $next = $order[($i + 1) % $order.Count]
                Set-AmonSetting -Name 'defaultDays' -Value $next -Persist
                Write-AmonStatus -Label 'Periodo' -Value "$next días" -State Ok -Detail 'se aplica a la próxima revisión'
            }
            'a' { Set-AmonSetting -Name 'animations' -Value (-not $s.animations) -Persist; Initialize-AmonTheme }
            'c' {
                $p = Read-AmonInput -Prompt 'Carpeta para los reportes (Enter para cancelar)'
                if ($p) { Set-AmonSetting -Name 'reportDirectory' -Value $p.Trim('"') -Persist }
            }
            'i' {
                $p = Read-AmonInput -Prompt 'Directorio de juego de la instancia (Enter para cancelar)'
                if ($p -and (Test-Path -LiteralPath $p.Trim('"'))) {
                    $paths = @($s.minecraft.extraInstancePaths) + @($p.Trim('"'))
                    Set-AmonSetting -Name 'minecraft.extraInstancePaths' -Value ($paths | Select-Object -Unique) -Persist
                } elseif ($p) { Write-AmonWarning -Message 'La ruta no existe.' }
            }
            'u' { Invoke-AmonMenuUpdate }
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

#endregion

#region Modo no interactivo

function Invoke-AmonCli {
    $script:Session = New-AmonSession -WindowDays $Days -Note $ConsentNote
    Show-AmonHeader
    # Un módulo suelto lleva delante Minecraft; Temp además necesita Firmas, que es quien
    # registra los indicadores concretos que busca.
    $mods = if ($Scan -eq 'Full' -or -not $Scan) { if ($Modules) { $Modules } else { Get-AmonDefaultModuleSelection -Settings $script:Settings } }
    elseif ($Scan -eq 'Temp') { @('Minecraft', 'Signatures', 'Temp') }
    else { @('Minecraft', $Scan) | Select-Object -Unique }
    $script:Session.AuthorizedScope.Add("Módulos ejecutados: $($mods -join ', ')")
    $script:LastScan = Invoke-AmonScanWithProgress -Context $script:Session -Modules $mods
    Show-AmonScanSummary -Scan $script:LastScan
    if ($Report) { $null = Export-AmonSessionReport -Formats $Report -Directory $(if ($OutputPath) { $OutputPath } else { $null }) }
    Write-AmonFooter -Version $script:Version.Version -Text "Revisión $($script:Session.ReviewId) finalizada"
}

#endregion

try {
    Initialize-AmonTheme -ThemeName $Theme -GlyphName $Glyphs
    if ($VerifyManifest) { $ok = Show-AmonIntegrity -Manifest $VerifyManifest; if ($ok) { exit 0 } else { exit 1 } }
    if ($Scan) { Invoke-AmonCli; return }
    $script:Session = New-AmonSession -WindowDays $Days -Note $ConsentNote
    Invoke-AmonAutoReview
    Write-AmonFooter -Version $script:Version.Version -Text 'Sesión cerrada. Ningún archivo del sistema fue modificado.'
} finally {
    Restore-AmonConsole
}
