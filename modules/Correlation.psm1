#Requires -Version 5.1
<#
    Amon SS - modules/Correlation.psm1
    Motor de correlación de evidencias.

    Estados:
      DETECTED      indicador presente.
      CORRELATED    dos o más fuentes INDEPENDIENTES contienen información compatible.
      INCONCLUSIVE  información insuficiente (firmas débiles/no validadas, solo nombres,
                    o clientes sin firmas verificables).
      NOT DETECTED  no se encontraron indicadores dentro del alcance analizado.

    Solo se relacionan hallazgos que comparten una clave concreta: el mismo cliente (por id de
    firma), la misma ruta, el mismo nombre de archivo o el mismo SHA-256. Nunca se crean
    relaciones por cercanía temporal sola ni se emiten sanciones.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:ClientCategories = @('CheatSignature', 'ClientLog', 'ClientConfig', 'ClientVersionProfile', 'ClientProcess', 'ClientMemory', 'ExecutionEvidence', 'ShimCacheEntry', 'ToolExecution')
$script:ExecutionKinds = @('Log de Minecraft', 'Prefetch', 'BAM', 'PCA', 'UserAssist', 'Eventos de Windows', 'Proceso en ejecución', 'Recent', 'Memoria de Java')
$script:CategoryKind = @{
    'Signatures:CheatSignature' = 'Archivo con firma'; 'SignaturesEvidence:CheatSignature' = 'Archivo con firma'
    'Signatures:ClientLog' = 'Log de Minecraft'; 'Signatures:ClientConfig' = 'Configuración del cliente'
    'Signatures:ClientVersionProfile' = 'Perfil de versión'; 'Signatures:KeywordName' = 'Nombre de archivo'
    'SignaturesEvidence:KeywordName' = 'Nombre de archivo'
}
$script:ModuleKind = @{
    Minecraft = 'Minecraft'; Prefetch = 'Prefetch'; Recent = 'Recent'; UserAssist = 'UserAssist'; Events = 'Eventos de Windows'
    Processes = 'Proceso en ejecución'; RecycleBin = 'Papelera'; USNJournal = 'USN Journal'
    BAM = 'BAM'; PCA = 'PCA'; ShimCache = 'ShimCache'; Tamper = 'Evasión'; Memory = 'Memoria de Java'
}
$script:StatusRank = @{ 'CORRELATED' = 0; 'DETECTED' = 1; 'INCONCLUSIVE' = 2; 'INFO' = 3; 'NOT DETECTED' = 4; 'NOT COVERED' = 5 }
$script:ConfRank = @{ 'High' = 3; 'Medium' = 2; 'Low' = 1 }

function Get-AmonSourceKind {
    param($Finding)
    $k = "$($Finding.Module):$($Finding.Category)"
    if ($script:CategoryKind.ContainsKey($k)) { return $script:CategoryKind[$k] }
    if ($script:ModuleKind.ContainsKey([string]$Finding.Module)) { return $script:ModuleKind[[string]$Finding.Module] }
    return [string]$Finding.Module
}

function Get-AmonEventKind {
    # El tipo de fuente sale del módulo que produjo el evento: así 'USN Journal (C:)' y
    # 'USN Journal (D:)' son una sola fuente, y la sesión del log cuenta como el propio log.
    param([string]$Module, [string]$Source)
    if ($Module -eq 'Minecraft' -and $Source -like 'Minecraft (log)*') { return 'Log de Minecraft' }
    if ($script:ModuleKind.ContainsKey($Module)) { return $script:ModuleKind[$Module] }
    return $Module
}

# Nombres que comparten todas las instalaciones: coincidir solo en ellos no relaciona nada.
$script:GenericLeaves = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
        'java.exe', 'javaw.exe', 'javaws.exe', 'jp2launcher.exe', 'latest.log', 'debug.log', 'client.jar', 'minecraft.jar',
        'launcher_profiles.json', 'options.txt', 'minecraftlauncher.exe', 'minecraft.exe'), [StringComparer]::OrdinalIgnoreCase)

function Test-AmonGenericLeaf {
    param([string]$Leaf)
    if (-not $Leaf) { return $true }
    if ($script:GenericLeaves.Contains($Leaf)) { return $true }
    # Logs rotados (2026-10-19-1.log.gz) y JAR de versión (1.20.1.jar)
    return ($Leaf -match '\.log(\.gz)?$' -or $Leaf -match '^\d+(\.\d+)+(-[\w.]+)?\.jar$')
}

function ConvertTo-AmonPathKey {
    param([string]$Path)
    if (-not $Path) { return $null }
    return $Path.Trim().Replace('/', '\').ToLowerInvariant()
}

function Get-AmonLeaf {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $leaf = [IO.Path]::GetFileName($Path.Trim().TrimEnd('\')) } catch { $leaf = $null }
    if ($leaf) { return $leaf.ToLowerInvariant() }
    return $null
}

function Get-AmonAllFindings {
    param([Parameter(Mandatory = $true)]$Context)
    foreach ($r in @($Context.Results.Values)) {
        if ($r.Module -eq 'Correlation') { continue }
        foreach ($f in $r.Findings) { $f }
    }
}

function Get-AmonMaxConfidence {
    param([object[]]$Findings)
    $best = 'Low'
    foreach ($f in $Findings) { if ($script:ConfRank[[string]$f.Confidence] -gt $script:ConfRank[$best]) { $best = [string]$f.Confidence } }
    return $best
}

function Test-AmonNameRelevant {
    param($Context, [string]$Name, [string]$Folder)
    if (-not $Name) { return $false }
    $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
    if (@($Context.Settings.interestingExtensions) -contains $ext) { return $true }
    if ($Context.IndicatorNames.Contains($Name)) { return $true }
    return [bool](Test-AmonKeywordMatch -Text "$Folder\$Name" -Keywords @($Context.Keywords))
}

function Add-AmonRecycleCorrelation {
    # Cruza la papelera ($I/$R) con la actividad de papelera reconstruida desde el USN Journal.
    param([Parameter(Mandatory = $true)]$Context)
    $rb = $Context.Results['RecycleBin']; $usn = $Context.Results['USNJournal']
    if (-not $rb -or -not $usn -or -not $usn.Data['RecycleActivity']) { return }
    $activity = $rb.Data['Activity']
    if ($null -eq $activity) { $activity = [System.Collections.Generic.List[object]]::new(); $rb.Data['Activity'] = $activity }
    # La correlación se repite (tras cada módulo y al exportar): se rehacen las filas propias.
    [void]$activity.RemoveAll([Predicate[object]] { param($x) $x.Category -eq 'Actividad correlacionada' })
    $purges = @($usn.Data['RecycleActivity'] | Where-Object Operation -EQ 'Purgado de la papelera')
    foreach ($ua in @($usn.Data['RecycleActivity'])) {
        if ($ua.Operation -eq 'Enviado a la papelera' -and $ua.OriginalName) {
            if (-not (Test-AmonNameRelevant -Context $Context -Name $ua.OriginalName -Folder $ua.OriginalFolder)) { continue }
            $match = @($rb.Artifacts | Where-Object { $_.OriginalName -ieq $ua.OriginalName }) | Select-Object -First 1
            if ($match) {
                $activity.Add([pscustomobject]@{ Category = 'Actividad correlacionada'; TimestampUtc = $ua.TimestampUtc; Path = $match.OriginalPath; Confidence = 'High'; Source = 'RecycleBin + USN Journal'
                        Description = ("El USN Journal confirma el envío a la papelera (renombrado a {0}) el {1}." -f $ua.RecycledAs, (Format-AmonTimestamp $ua.TimestampUtc)) })
            } elseif (Test-AmonInWindow -Context $Context -Utc $ua.TimestampUtc) {
                $orig = if ($ua.OriginalFolder) { Join-Path $ua.OriginalFolder $ua.OriginalName } else { $ua.OriginalName }
                $activity.Add([pscustomobject]@{ Category = 'Actividad correlacionada'; TimestampUtc = $ua.TimestampUtc; Path = $orig; Confidence = 'Medium'; Source = 'USN Journal'
                        Description = ("El journal registra el envío a la papelera el {0}, pero el elemento ya no figura en ella (se restauró o se eliminó después)." -f (Format-AmonTimestamp $ua.TimestampUtc)) })
            }
        } elseif ($ua.Operation -eq 'Purgado de la papelera' -and (Test-AmonInWindow -Context $Context -Utc $ua.TimestampUtc)) {
            $label = if ($ua.OriginalName -and (Test-AmonNameRelevant -Context $Context -Name $ua.OriginalName -Folder $ua.OriginalFolder)) { $ua.OriginalName } else { [IO.Path]::GetFileName($ua.RecycledAs) }
            $activity.Add([pscustomobject]@{ Category = 'Actividad correlacionada'; TimestampUtc = $ua.TimestampUtc; Path = $label; Confidence = 'Medium'; Source = 'USN Journal'
                    Description = ("El journal registra la eliminación definitiva de '{0}' de la papelera el {1}." -f $label, (Format-AmonTimestamp $ua.TimestampUtc)) })
        }
    }
    foreach ($c in @($activity | Where-Object { $_.Category -eq 'Evidencia insuficiente' -and $_.Description -match 'contenedor' -and $_.TimestampUtc })) {
        $near = @($purges | Where-Object { [Math]::Abs(($_.TimestampUtc - $c.TimestampUtc).TotalMinutes) -le 10 })
        if ($near.Count) {
            $activity.Add([pscustomobject]@{ Category = 'Actividad correlacionada'; TimestampUtc = $c.TimestampUtc; Path = $c.Path; Confidence = 'Medium'; Source = 'RecycleBin + USN Journal'
                    Description = ("La modificación del contenedor ({0}) coincide con {1} eliminación(es) definitiva(s) registradas por el USN Journal. Los artefactos no indican quién ni por qué." -f (Format-AmonTimestamp $c.TimestampUtc), $near.Count) })
        }
    }
}

function Invoke-AmonCorrelation {
    <#
    .SYNOPSIS
        Correlaciona los hallazgos de todos los módulos y calcula el veredicto por cliente.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context)
    if ($Context.Results.Contains('Correlation')) { $Context.Results.Remove('Correlation') }
    if (-not $Context.FixedUntil) { $Context.UntilUtc = [datetime]::UtcNow }
    $res = New-AmonModuleResult -Module 'Correlation' -DisplayName 'Detection & Correlation Engine'
    $all = @(Get-AmonAllFindings -Context $Context)
    $events = @(foreach ($r in @($Context.Results.Values)) { foreach ($e in $r.Events) { [pscustomobject]@{ Event = $e; Module = $r.Module } } })
    $mods = @(); if ($Context.Results['Minecraft']) { $mods = @($Context.Results['Minecraft'].Artifacts) }
    $clientIndex = if ($Context.Signatures) { $Context.Signatures.ClientIndex } else { @{} }
    $usedByClient = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($g in @($all | Where-Object { $_.ClientId -and $_.Category -ne 'KeywordName' } | Group-Object ClientId)) {
        $clientId = $g.Name
        $anchors = @($g.Group | Where-Object { $_.Status -in @('DETECTED', 'INCONCLUSIVE') -and $_.Category -in $script:ClientCategories })
        if (-not $anchors.Count) { continue }
        $parts = [System.Collections.Generic.List[object]]::new()
        foreach ($a in $g.Group) { $parts.Add([pscustomobject]@{ Kind = (Get-AmonSourceKind $a); Finding = $a; Text = "$($a.Title)$(if ($a.Path) { ' - ' + $a.Path })"; Path = $a.Path; Time = $a.TimestampUtc; Execution = [bool]($a.Data -and $a.Data['Execution']) }) }
        foreach ($a in @($anchors | Where-Object Path)) {
            # Un nombre genérico (javaw.exe, latest.log...) no identifica el artefacto: con él solo
            # vale el SHA-256. El resto se une por ruta completa o por nombre de archivo.
            $pk = ConvertTo-AmonPathKey $a.Path; $leaf = Get-AmonLeaf $a.Path; $sha = $a.Sha256
            if (Test-AmonGenericLeaf $leaf) { $pk = $null; $leaf = $null }
            foreach ($f in $all) {
                if ($f.Id -eq $a.Id -or ($f.ClientId -and $f.ClientId -ne $clientId) -or $f.Category -eq 'KeywordName') { continue }
                $same = ($f.Path -and $leaf -and ((ConvertTo-AmonPathKey $f.Path) -eq $pk -or (Get-AmonLeaf $f.Path) -eq $leaf)) -or ($sha -and $f.Sha256 -eq $sha)
                if (-not $same -or ($parts | Where-Object { $_.Finding -and $_.Finding.Id -eq $f.Id })) { continue }
                $parts.Add([pscustomobject]@{ Kind = (Get-AmonSourceKind $f); Finding = $f; Text = "$($f.Title) - $($f.Path)"; Path = $f.Path; Time = $f.TimestampUtc; Execution = ((Get-AmonSourceKind $f) -in $script:ExecutionKinds) })
                [void]$usedByClient.Add($f.Id)
            }
            foreach ($pe in $events) {
                $e = $pe.Event
                if ($pe.Module -in @('Signatures', 'SignaturesEvidence', 'Correlation') -or -not $e.Path -or -not $leaf) { continue }
                if ((Get-AmonLeaf $e.Path) -ne $leaf) { continue }
                if ($e.Kind -notin @('Execution', 'Deletion', 'Rename', 'Presence', 'LogLoaded')) { continue }
                $kind = Get-AmonEventKind -Module $pe.Module -Source $e.Source
                if ($parts | Where-Object { $_.Kind -eq $kind -and $_.Path -eq $e.Path -and $_.Time -eq $e.TimestampUtc }) { continue }
                $parts.Add([pscustomobject]@{ Kind = $kind; Finding = $null; Text = "$($e.Type) - $($e.Path)"; Path = $e.Path; Time = $e.TimestampUtc; Execution = ($e.Kind -in @('Execution', 'LogLoaded')) })
            }
            foreach ($m in @($mods | Where-Object { $_.Path -and (ConvertTo-AmonPathKey $_.Path) -eq $pk -and $_.Loaded -eq 'Sí' })) {
                $parts.Add([pscustomobject]@{ Kind = 'Log de Minecraft'; Finding = $null; Text = "Mod cargado según logs ($(@($m.LoadEvidence) -join '; '))"; Path = $m.Path; Time = $m.LastLoadedUtc; Execution = $true })
            }
        }
        $kinds = @($parts | ForEach-Object Kind | Select-Object -Unique)
        $hasDetected = [bool]($anchors | Where-Object Status -EQ 'DETECTED')
        if ($kinds.Count -lt 2 -or -not $hasDetected) { continue }
        $client = $clientIndex[$clientId]
        $clientName = if ($client) { $client.Name } else { $anchors[0].Client }
        $anchorConf = Get-AmonMaxConfidence $anchors
        $execution = [bool]($parts | Where-Object Execution)
        $conf = if ($anchorConf -eq 'High') { 'High' } else { 'Medium' }
        $sev = if ($client -and $client.Category -eq 'dual-use') { 'Low' } elseif ($conf -eq 'High') { 'High' } else { 'Medium' }
        $main = ($anchors | Where-Object Category -EQ 'CheatSignature' | Select-Object -First 1); if (-not $main) { $main = $anchors[0] }
        $latest = @($parts | Where-Object Time | Sort-Object Time -Descending | Select-Object -First 1)
        $j = "Fuentes independientes compatibles ($($kinds.Count)): " + (($kinds | ForEach-Object { $k = $_; "$k (" + (@($parts | Where-Object Kind -EQ $k | Select-Object -First 2 | ForEach-Object Text) -join '; ') + ')' }) -join ' | ') + '.'
        if ($execution) { $j += ' Hay evidencia de carga o ejecución, no solo de presencia.' } else { $j += ' No hay evidencia directa de ejecución: solo de presencia o configuración.' }
        if ($anchorConf -ne 'High') { $j += ' La identificación del cliente se apoya en firmas no validadas o débiles: la confianza se limita a media.' }
        $ev = @($parts | ForEach-Object { New-AmonEvidence -Source $_.Kind -Kind $(if ($_.Execution) { 'Execution' } else { 'Other' }) -Path $_.Path -TimestampUtc $_.Time -Description $_.Text })
        $res.Findings.Add((New-AmonFinding -Module 'Correlation' -Category 'ClientCorrelation' -Title "$($clientName): evidencias correlacionadas" -Status CORRELATED -Severity $sev -Confidence $conf `
                    -Path $main.Path -Sha256 $main.Sha256 -TimestampUtc $(if ($latest) { $latest[0].Time } else { $main.TimestampUtc }) -Indicator ($kinds -join ' + ') -IndicatorType 'correlation' `
                    -Client $clientName -ClientId $clientId -Source 'Correlation' -Justification $j -FalsePositives $(if ($client) { $client.FalsePositives } else { @() }) -Evidence $ev `
                    -Data @{ Kinds = $kinds; Execution = $execution; SourceFindings = @($parts | Where-Object Finding | ForEach-Object { $_.Finding.Id }) }))
    }

    # Actividad sobre un mismo archivo sin cliente identificado (p. ej. borrado + Prefetch + USN)
    $generic = @($all | Where-Object { -not $_.ClientId -and $_.Path -and $_.Category -ne 'KeywordName' -and -not $usedByClient.Contains($_.Id) })
    foreach ($g in @($generic | Group-Object { Get-AmonLeaf $_.Path } | Where-Object { $_.Name -match '\.(jar|exe|dll)$' -and -not (Test-AmonGenericLeaf $_.Name) })) {
        $kinds = @($g.Group | ForEach-Object { Get-AmonSourceKind $_ } | Select-Object -Unique)
        if ($kinds.Count -lt 2 -or -not ($g.Group | Where-Object Status -EQ 'DETECTED')) { continue }
        $ev = @($g.Group | ForEach-Object { New-AmonEvidence -Source (Get-AmonSourceKind $_) -Path $_.Path -TimestampUtc $_.TimestampUtc -Description "$($_.Title) - $($_.Path)" })
        $res.Findings.Add((New-AmonFinding -Module 'Correlation' -Category 'FileActivityCorrelation' -Title "Actividad correlacionada sobre $($g.Group[0].Path | Split-Path -Leaf)" -Status CORRELATED -Severity Low -Confidence Medium `
                    -Path $g.Group[0].Path -TimestampUtc (@($g.Group | Where-Object TimestampUtc | Sort-Object TimestampUtc -Descending | Select-Object -First 1).TimestampUtc) -Indicator ($kinds -join ' + ') -IndicatorType 'correlation' `
                    -Justification ("Varias fuentes independientes registran actividad sobre el mismo archivo: {0}. No hay firma de cliente asociada; describe actividad, no identifica software." -f ($kinds -join ', ')) -Evidence $ev))
    }

    Add-AmonRecycleCorrelation -Context $Context

    # Veredicto por cliente
    $verdicts = [System.Collections.Generic.List[object]]::new()
    $scanned = if ($Context.Results['Signatures']) { $Context.Results['Signatures'].ArtifactsReviewed } else { 0 }
    $noAccess = @($Context.Results.Values | Where-Object { $_.Status -eq 'NoAccess' } | ForEach-Object DisplayName)
    # El software de macros no entra en el veredicto: solo deja hallazgos INFO para revisar.
    $clients = if ($Context.Signatures) { @($Context.Signatures.Clients | Where-Object { $_.Category -ne 'macro' }) } else { @() }
    foreach ($c in $clients) {
        $fs = @($all | Where-Object { $_.ClientId -eq $c.Id })
        $strong = @($fs | Where-Object Category -NE 'KeywordName')
        $corr = @($res.Findings | Where-Object { $_.ClientId -eq $c.Id })
        $status = 'NOT DETECTED'; $just = ''
        if ($corr.Count) { $status = 'CORRELATED'; $just = $corr[0].Justification }
        elseif ($strong | Where-Object Status -EQ 'DETECTED') {
            $status = 'DETECTED'
            $just = 'Indicador presente (' + (@($strong | Where-Object Status -EQ 'DETECTED' | Select-Object -First 3 | ForEach-Object { "$($_.Title): $($_.Path)" }) -join '; ') + ') sin fuentes independientes adicionales dentro del alcance analizado.'
        } elseif ($strong | Where-Object Status -EQ 'INCONCLUSIVE') {
            $status = 'INCONCLUSIVE'
            $just = 'Solo indicadores débiles o no validados (' + (@($strong | Where-Object Status -EQ 'INCONCLUSIVE' | Select-Object -First 3 | ForEach-Object { $_.Title }) -join '; ') + '). Requiere revisión manual.'
        } elseif ($c.Indicators.Count -eq 0) {
            # Sin firmas no hay nada que buscar: no es sospecha ni descarte, es falta de cobertura.
            $status = 'NOT COVERED'
            $just = 'No hay indicadores verificables para este cliente: el escaneo de archivos no puede confirmarlo ni descartarlo.'
        } else {
            $just = "No se encontraron indicadores de $($c.Name) dentro del alcance analizado ($scanned archivo(s) escaneados en $($Context.Instances.Count) instancia(s))."
            if ($noAccess.Count) { $just += ' Módulos sin acceso: ' + ($noAccess -join ', ') + '.' }
        }
        # Una coincidencia solo de nombre ("wurst-rezepte.exe") no prueba nada: se menciona, pero
        # no cambia el veredicto ni el resultado global.
        $names = @($fs | Where-Object Category -EQ 'KeywordName')
        if ($names.Count -and $status -in @('NOT DETECTED', 'NOT COVERED')) {
            $just += ' Hay ' + $names.Count + ' coincidencia(s) solo de nombre, que no cuentan como indicio (' + (@($names | Select-Object -First 2 | ForEach-Object { [IO.Path]::GetFileName([string]$_.Path) }) -join '; ') + ').'
        }
        $verdicts.Add([pscustomobject]@{
                ClientId = $c.Id; Client = $c.Name; Category = $c.Category; Status = $status; Justification = $just
                Confidence = $(if ($fs.Count -or $corr.Count) { Get-AmonMaxConfidence (@($fs) + @($corr)) } else { $null })
                Paths = @(@($fs) + @($corr) | ForEach-Object Path | Where-Object { $_ } | Select-Object -Unique)
                FindingIds = @(@($fs) + @($corr) | ForEach-Object Id)
            })
    }
    $verdicts = @($verdicts | Sort-Object { $script:StatusRank[$_.Status] }, Client)

    # Conclusión para revisión humana
    $lines = [System.Collections.Generic.List[string]]::new()
    $cc = @($verdicts | Where-Object { $_.Status -eq 'CORRELATED' -and $_.Category -ne 'dual-use' })
    $dd = @($verdicts | Where-Object { $_.Status -eq 'DETECTED' -and $_.Category -ne 'dual-use' })
    $ii = @($verdicts | Where-Object { $_.Status -eq 'INCONCLUSIVE' -and ($_.FindingIds.Count) })
    if ($cc.Count) { $lines.Add('Se encontraron evidencias correlacionadas compatibles con: ' + (($cc | ForEach-Object Client) -join ', ') + '. Cada evidencia debe revisarse manualmente; la presencia de indicadores no implica por sí sola una infracción.') }
    if ($dd.Count) { $lines.Add('Indicadores presentes sin fuentes independientes que confirmen su uso: ' + (($dd | ForEach-Object Client) -join ', ') + '.') }
    if ($ii.Count) { $lines.Add('Indicadores débiles o no concluyentes: ' + (($ii | ForEach-Object Client) -join ', ') + '.') }
    if (-not ($cc.Count + $dd.Count + $ii.Count)) { $lines.Add('No se encontraron indicadores de clientes conocidos dentro del alcance analizado.') }
    $other = @($all | Where-Object { -not $_.ClientId -and $_.Status -eq 'DETECTED' })
    if ($other.Count) { $lines.Add("Otros hechos registrados que merecen revisión: $($other.Count) (p. ej. " + (@($other | Select-Object -First 3 | ForEach-Object Title) -join '; ') + ').') }
    $dual = @($verdicts | Where-Object { $_.Category -eq 'dual-use' -and $_.Status -in @('CORRELATED', 'DETECTED') })
    if ($dual.Count) { $lines.Add('Herramientas de uso dual presentes (muchos servidores las permiten): ' + (($dual | ForEach-Object Client) -join ', ') + '.') }
    if ($noAccess.Count) { $lines.Add('Módulos sin acceso: ' + ($noAccess -join ', ') + '. Ejecutar como administrador amplía el análisis.') }
    $nosig = @($clients | Where-Object { $_.Indicators.Count -eq 0 } | ForEach-Object Name)
    if ($nosig.Count) { $lines.Add('Cobertura: ' + $nosig.Count + ' cliente(s) sin firmas verificables, que el escaneo de archivos no puede comprobar (' + ($nosig -join ', ') + ').') }
    $lines.Add('Conclusión para revisión humana: Amon SS no emite veredictos ni sanciones automáticas.')
    $conclusion = $lines -join ' '

    # Resumen de una palabra para el revisor (no es una sanción): indicadores firmes de clientes
    # o de otros hechos, solo indicios débiles, o nada.
    $outcome = if ($cc.Count -or $dd.Count -or $other.Count) { 'INDICADORES ENCONTRADOS' }
    elseif ($ii.Count -or @($all | Where-Object { $_.Status -eq 'INCONCLUSIVE' -and $_.Category -ne 'KeywordName' }).Count) { 'REVISAR A MANO' }
    else { 'SIN INDICADORES' }

    $res.Data['ClientVerdicts'] = $verdicts
    $res.Data['Conclusion'] = $conclusion
    $res.Data['Outcome'] = $outcome
    $res.ArtifactsReviewed = $all.Count
    $res = Complete-AmonModuleResult -Result $res
    $Context.Results['Correlation'] = $res
    [pscustomobject]@{
        PSTypeName = 'AmonSS.Correlation'
        ClientVerdicts = $verdicts
        Correlated = @($res.Findings)
        Conclusion = $conclusion
        Outcome = $outcome
        Result = $res
        Summary = [pscustomobject]@{
            Correlated = @($verdicts | Where-Object Status -EQ 'CORRELATED').Count
            Detected = @($verdicts | Where-Object Status -EQ 'DETECTED').Count
            Inconclusive = @($verdicts | Where-Object Status -EQ 'INCONCLUSIVE').Count
            NotDetected = @($verdicts | Where-Object Status -EQ 'NOT DETECTED').Count
            NotCovered = @($verdicts | Where-Object Status -EQ 'NOT COVERED').Count
            Findings = $all.Count
        }
    }
}

Export-ModuleMember -Function @('Invoke-AmonCorrelation', 'Get-AmonAllFindings', 'Get-AmonSourceKind')
