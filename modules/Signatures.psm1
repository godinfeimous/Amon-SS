#Requires -Version 5.1
<#
    Amon SS - modules/Signatures.psm1
    Motor de firmas extensible basado en archivos JSON (signatures\*.json).

    Tipos de indicador:
      package     prefijo de entrada ZIP (paquete Java)          entry      nombre de entrada del JAR
      entrypoint  clase de entrada (Fabric / MANIFEST)           manifest   'Clave: Valor' en MANIFEST.MF
      modid       id en metadatos del JAR o cargado según logs   config/path carpeta o archivo en gameDir / perfil
      log         texto (literal o regex) en logs de Minecraft   string/hex bytes literales (bruto y contenido)
      sha256      hash de archivo                                versionId  regex sobre perfiles de versions\
      jvmArg      argumento JVM en perfiles de versión

    Confianza: las firmas validadas (fuente primaria o muestras) pueden dar confianza ALTA;
    las no validadas (aportadas por el usuario o secundarias) se limitan a MEDIA y necesitan
    al menos dos coincidencias independientes de fuerza media. Una cadena contenida en otra
    cadena coincidente no cuenta dos veces.

    Nunca se ejecuta código de los archivos analizados.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Jar.psm1') -DisableNameChecking

$script:AllowedTypes = @('package', 'entry', 'entrypoint', 'manifest', 'modid', 'config', 'path', 'log', 'string', 'hex', 'sha256', 'versionId', 'jvmArg')
$script:AllowedProvenance = @('primary-source', 'secondary', 'user-provided', 'sample-verified')
$script:MediaExt = @('.png', '.ogg', '.jpg', '.jpeg', '.gif', '.wav', '.mp3', '.ttf', '.otf', '.nbt', '.webp', '.bmp', '.ico', '.psd')
$script:ArchiveExt = @('.jar', '.zip', '.litemod')
$script:TypeLabel = @{
    package = 'paquete Java'; entry = 'entrada del JAR'; entrypoint = 'clase de entrada'; manifest = 'MANIFEST.MF'
    modid = 'id de mod'; config = 'carpeta de configuración'; path = 'ruta'; log = 'línea de log'; string = 'cadena'
    hex = 'firma binaria'; sha256 = 'SHA-256'; versionId = 'perfil de versión'; jvmArg = 'argumento JVM'
}

#region Carga y validación de definiciones

function Get-AmonPropValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) { return $Object.$Name }
    return $Default
}

function ConvertTo-AmonIndicatorBytes {
    param([Parameter(Mandatory = $true)]$Indicator, [string]$Encoding = 'ascii')
    if ($Indicator.Type -eq 'hex') {
        $hex = ($Indicator.Value -replace '\s', '')
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        return , $bytes
    }
    if ($Encoding -eq 'utf16le') { return , [Text.Encoding]::Unicode.GetBytes($Indicator.Value) }
    return , [Text.Encoding]::UTF8.GetBytes($Indicator.Value)
}

function Get-AmonSignatureSet {
    <#
    .SYNOPSIS
        Carga todas las definiciones de signatures\*.json y construye los índices de búsqueda.
    #>
    [CmdletBinding()]
    param([string]$Path = (Join-Path (Get-AmonRoot) 'signatures'))
    Import-AmonNative
    $clients = [System.Collections.Generic.List[object]]::new()
    $inds = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    # En una release, una firma alterada, añadida o borrada detiene la carga (Integrity.psd1):
    # cambiaría los veredictos sin que nadie lo notara.
    Assert-AmonPackageFolder -Folder $Path -Filter '*.json'
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Where-Object Name -NE 'schema.json' | Sort-Object Name)) {
        $text = Read-AmonVerifiedText -Path $file.FullName
        try { $data = $text | ConvertFrom-Json -ErrorAction Stop }
        catch { $errors.Add("$($file.Name): JSON inválido ($($_.Exception.Message))"); continue }
        $defs = if ($data.PSObject.Properties['clients']) { @($data.clients) } else { @($data) }
        foreach ($def in $defs) {
            $client = [pscustomobject]@{
                PSTypeName     = 'AmonSS.SignatureClient'
                Id             = [string](Get-AmonPropValue $def 'id')
                Name           = [string](Get-AmonPropValue $def 'name')
                Category       = [string](Get-AmonPropValue $def 'category' 'cheat-client')
                SchemaVersion  = (Get-AmonPropValue $def 'schemaVersion' 0)
                Description    = [string](Get-AmonPropValue $def 'description')
                OpenSource     = [bool](Get-AmonPropValue $def 'openSource' $false)
                Loaders        = @(Get-AmonPropValue $def 'loaders' @())
                References     = @(Get-AmonPropValue $def 'references' @())
                Keywords       = @(Get-AmonPropValue $def 'keywords' @() | Where-Object { $_ })
                FalsePositives = @(Get-AmonPropValue $def 'falsePositives' @())
                Notes          = [string](Get-AmonPropValue $def 'notes')
                File           = $file.Name
                Indicators     = [System.Collections.Generic.List[object]]::new()
            }
            # Los valores por defecto mantienen el escáner en marcha, pero un campo obligatorio
            # ausente debe verse en la validación (el valor por defecto lo ocultaría).
            foreach ($req in 'category', 'indicators') { if (-not $def.PSObject.Properties[$req]) { $errors.Add("$($file.Name)/$($client.Id): falta '$req'") } }
            foreach ($i in @(Get-AmonPropValue $def 'indicators' @())) {
                if (-not $i.PSObject.Properties['strength']) { $errors.Add("$($file.Name)/$($client.Id)/$([string](Get-AmonPropValue $i 'id')): falta 'strength'") }
                $ind = [pscustomobject]@{
                    PSTypeName = 'AmonSS.SignatureIndicator'
                    Id         = [string](Get-AmonPropValue $i 'id')
                    ClientId   = $client.Id
                    ClientName = $client.Name
                    Category   = $client.Category
                    Type       = [string](Get-AmonPropValue $i 'type')
                    Value      = [string](Get-AmonPropValue $i 'value')
                    Strength   = [string](Get-AmonPropValue $i 'strength' 'weak')
                    Provenance = [string](Get-AmonPropValue $i 'provenance')
                    Validated  = (Get-AmonPropValue $i 'validated' $null)
                    Source     = [string](Get-AmonPropValue $i 'source')
                    Note       = [string](Get-AmonPropValue $i 'note')
                    Group      = [string](Get-AmonPropValue $i 'group')
                    Match      = [string](Get-AmonPropValue $i 'match' 'literal')
                    Encodings  = @(Get-AmonPropValue $i 'encodings' @('ascii'))
                    Scopes     = @(Get-AmonPropValue $i 'scopes' @('raw', 'entries'))
                    RelativeTo = [string](Get-AmonPropValue $i 'relativeTo' 'gameDir')
                    Regex      = $null
                }
                if ($ind.Match -eq 'regex' -or $ind.Type -eq 'versionId') {
                    try { $ind.Regex = [regex]::new($ind.Value, [Text.RegularExpressions.RegexOptions]::Compiled) }
                    catch { $errors.Add("$($file.Name): regex inválida en $($ind.Id): $($_.Exception.Message)") }
                }
                $client.Indicators.Add($ind)
                $inds.Add($ind)
            }
            $clients.Add($client)
        }
    }

    # Autómata para cadenas / firmas binarias
    $patterns = [System.Collections.Generic.List[byte[]]]::new()
    $patternMap = [System.Collections.Generic.List[object]]::new()
    foreach ($ind in $inds) {
        if ($ind.Type -notin @('string', 'hex')) { continue }
        $encs = if ($ind.Type -eq 'hex') { @('binary') } else { $ind.Encodings }
        foreach ($enc in $encs) {
            try {
                $b = ConvertTo-AmonIndicatorBytes -Indicator $ind -Encoding $enc
                if ($b.Length -gt 0) { $patterns.Add($b); $patternMap.Add([pscustomobject]@{ Indicator = $ind; Encoding = $enc }) }
            } catch { $errors.Add("Indicador $($ind.Id): no se pudo convertir a bytes ($($_.Exception.Message))") }
        }
    }
    $matcher = New-Object AmonSS.Native.PatternMatcher (, $patterns.ToArray())

    $packages = @{}; $entries = @{}; $entrypoints = @{}; $entrypointPaths = @{}; $modids = @{}; $sha = @{}
    $manifest = [System.Collections.Generic.List[object]]::new()
    $add = { param($table, $key, $value) if (-not $table.ContainsKey($key)) { $table[$key] = [System.Collections.Generic.List[object]]::new() }; $table[$key].Add($value) }
    foreach ($ind in $inds) {
        switch ($ind.Type) {
            'package' { & $add $packages $ind.Value $ind }
            'entry' { & $add $entries $ind.Value.ToLowerInvariant() $ind }
            'entrypoint' { & $add $entrypoints $ind.Value $ind; & $add $entrypointPaths ($ind.Value.Replace('.', '/') + '.class') $ind }
            'modid' { & $add $modids $ind.Value.ToLowerInvariant() $ind }
            'sha256' { & $add $sha $ind.Value.ToLowerInvariant() $ind }
            'manifest' {
                $idx = $ind.Value.IndexOf(':')
                if ($idx -gt 0) { $manifest.Add([pscustomobject]@{ Key = $ind.Value.Substring(0, $idx).Trim(); Value = $ind.Value.Substring($idx + 1).Trim(); Indicator = $ind }) }
            }
        }
    }
    $clientIndex = @{}
    foreach ($c in $clients) { $clientIndex[$c.Id] = $c }
    $keywords = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in $clients) { foreach ($k in $c.Keywords) { [void]$keywords.Add($k) } }

    [pscustomobject]@{
        PSTypeName      = 'AmonSS.SignatureSet'
        Path            = $Path
        Clients         = $clients.ToArray()
        ClientIndex     = $clientIndex
        Indicators      = $inds.ToArray()
        Errors          = $errors
        Matcher         = $matcher
        PatternMap      = $patternMap.ToArray()
        Packages        = $packages
        Entries         = $entries
        Entrypoints     = $entrypoints
        EntrypointPaths = $entrypointPaths
        ModIds          = $modids
        Sha256          = $sha
        Manifest        = $manifest.ToArray()
        Configs         = @($inds | Where-Object { $_.Type -in @('config', 'path') })
        Logs            = @($inds | Where-Object Type -EQ 'log')
        VersionIds      = @($inds | Where-Object Type -EQ 'versionId')
        JvmArgs         = @($inds | Where-Object Type -EQ 'jvmArg')
        Keywords        = $keywords
    }
}

function Test-AmonSignatureSet {
    <#
    .SYNOPSIS
        Valida las definiciones cargadas. Devuelve una lista de errores (vacía si todo es válido).
    #>
    param([Parameter(Mandatory = $true)]$Set)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Set.Errors) { $errors.Add($e) }
    $seenClients = @{}
    foreach ($c in $Set.Clients) {
        $where = "$($c.File)/$($c.Id)"
        if ($c.Id -notmatch '^[a-z0-9][a-z0-9\-]*$') { $errors.Add("${where}: id de cliente inválido") }
        if ($seenClients.ContainsKey($c.Id)) { $errors.Add("${where}: id de cliente duplicado (también en $($seenClients[$c.Id]))") } else { $seenClients[$c.Id] = $c.File }
        if (-not $c.Name) { $errors.Add("${where}: falta 'name'") }
        if ($c.SchemaVersion -ne 1) { $errors.Add("${where}: schemaVersion debe ser 1") }
        if ($c.Category -notin @('cheat-client', 'dual-use', 'framework')) { $errors.Add("${where}: categoría inválida '$($c.Category)'") }
        $seenInd = @{}
        foreach ($i in $c.Indicators) {
            $iw = "$where/$($i.Id)"
            if (-not $i.Id) { $errors.Add("${where}: indicador sin id") }
            elseif ($seenInd.ContainsKey($i.Id)) { $errors.Add("${iw}: id de indicador duplicado") } else { $seenInd[$i.Id] = $true }
            if ($i.Type -notin $script:AllowedTypes) { $errors.Add("${iw}: tipo '$($i.Type)' no permitido") }
            if (-not $i.Value) { $errors.Add("${iw}: valor vacío") }
            if ($i.Strength -notin @('strong', 'medium', 'weak')) { $errors.Add("${iw}: fuerza inválida '$($i.Strength)'") }
            if ($i.Provenance -notin $script:AllowedProvenance) { $errors.Add("${iw}: procedencia inválida '$($i.Provenance)'") }
            if ($i.Validated -isnot [bool]) { $errors.Add("${iw}: 'validated' debe ser booleano") }
            if (-not $i.Source) { $errors.Add("${iw}: falta la fuente") }
            if ($i.Provenance -eq 'user-provided' -and $i.Validated -eq $true) { $errors.Add("${iw}: una firma aportada por el usuario no puede marcarse como validada sin muestras (usa 'sample-verified')") }
            if ($i.Type -eq 'hex' -and ($i.Value -replace '\s', '') -notmatch '^([0-9A-Fa-f]{2})+$') { $errors.Add("${iw}: valor hexadecimal inválido") }
            if ($i.Type -eq 'sha256' -and $i.Value -notmatch '^[0-9A-Fa-f]{64}$') { $errors.Add("${iw}: SHA-256 inválido") }
            if ($i.Type -in @('config', 'path') -and $i.RelativeTo -notin @('gameDir', 'userHome')) { $errors.Add("${iw}: relativeTo inválido") }
            foreach ($s in $i.Scopes) { if ($s -notin @('raw', 'entries')) { $errors.Add("${iw}: scope inválido '$s'") } }
            foreach ($en in $i.Encodings) { if ($en -notin @('ascii', 'utf8', 'utf16le')) { $errors.Add("${iw}: codificación inválida '$en'") } }
        }
    }
    return $errors.ToArray()
}

#endregion

#region Escaneo de archivos

function Add-AmonSignatureHit {
    param($Hits, $Indicator, [string]$Location, [string]$Scope = '')
    $key = $Indicator.ClientId + '|' + $Indicator.Id
    if ($Hits.Contains($key)) { return }
    $Hits[$key] = [pscustomobject]@{
        ClientId = $Indicator.ClientId; Indicator = $Indicator; Type = $Indicator.Type; Value = $Indicator.Value
        Location = $Location; Scope = $Scope
    }
}

function Add-AmonPatternHits {
    # Traduce índices de patrón del autómata a indicadores, respetando su ámbito (raw/entries).
    param($Set, $Hits, $MatchResult, [string]$Scope, [string]$Location)
    for ($k = 0; $k -lt $MatchResult.Patterns.Length; $k++) {
        $pm = $Set.PatternMap[$MatchResult.Patterns[$k]]
        if ($pm.Indicator.Type -eq 'hex' -or $pm.Indicator.Scopes -contains $Scope) {
            Add-AmonSignatureHit -Hits $Hits -Indicator $pm.Indicator -Scope $Scope -Location ("{0} (offset {1}, {2})" -f $Location, $MatchResult.Offsets[$k], $pm.Encoding)
        }
    }
}

function Get-AmonScanLimits {
    param($Context)
    $l = if ($Context) { $Context.Settings.limits } else { (Get-AmonSettings).limits }
    [pscustomobject]@{
        MaxRaw        = [long]$l.maxRawScanMB * 1MB
        MaxEntry      = [long]$l.maxEntrySizeMB * 1MB
        MaxTotal      = [long]$l.maxDecompressedPerJarMB * 1MB
        MaxEntries    = [int]$l.maxEntriesPerJar
        MaxDepth      = [int]$l.maxNestedJarDepth
        MaxFile       = [long]$l.maxJarSizeMB * 1MB
        MaxExecutable = [long]$l.maxExecutableScanMB * 1MB
    }
}

function Invoke-AmonArchiveScan {
    # Revisa nombres, metadatos y contenido de un ZIP/JAR (recursivo para JAR anidados).
    param($Archive, $Set, $Hits, [string]$Prefix, [int]$Depth, $Limits, $Stats, $Context)
    $ji = Get-AmonJarInfoFromArchive -Archive $Archive -Path $Prefix -MaxEntries $Limits.MaxEntries
    if ($Depth -eq 0) { $Stats.JarInfo = $ji }

    # 1. Nombres de entrada: paquetes, entradas conocidas y clases de entrada
    if (Test-AmonNativeZip) {
        $nm = [AmonSS.Native.JarNames]::Match([string[]]$ji.Entries, [string[]]@($Set.Packages.Keys), [string[]]@($Set.Entries.Keys), [string[]]@($Set.EntrypointPaths.Keys))
        foreach ($m in $nm) {
            $table = switch ($m.Kind) { 'package' { $Set.Packages } 'entry' { $Set.Entries } default { $Set.EntrypointPaths } }
            $label = if ($m.Kind -eq 'class') { 'clase' } else { 'entrada' }
            foreach ($ind in $table[$m.Key]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "$label $Prefix$($m.Entry)" }
        }
    } else {
        Find-AmonEntryNameHitsSlow -Set $Set -Hits $Hits -Names $ji.Entries -Prefix $Prefix
    }
    Find-AmonMetadataHits -Set $Set -Hits $Hits -JarInfo $ji -Prefix $Prefix
    Invoke-AmonArchiveContentScan -Archive $Archive -Set $Set -Hits $Hits -Prefix $Prefix -Depth $Depth -Limits $Limits -Stats $Stats -Context $Context
    return $ji
}

function Find-AmonEntryNameHitsSlow {
    # Respaldo en PowerShell de JarNames.Match.
    param($Set, $Hits, [string[]]$Names, [string]$Prefix)
    $checked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Names) {
        $pos = -1
        for ($seg = 0; $seg -lt 5; $seg++) {
            $pos = $name.IndexOf('/', $pos + 1)
            if ($pos -lt 0) { break }
            # Ojo: PowerShell no distingue mayúsculas; no reutilizar el nombre $Prefix aquí.
            $pkgPrefix = $name.Substring(0, $pos + 1)
            if (-not $checked.Add($pkgPrefix)) { continue }
            if ($Set.Packages.ContainsKey($pkgPrefix)) { foreach ($ind in $Set.Packages[$pkgPrefix]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "entrada $Prefix$name" } }
        }
        $lower = $name.ToLowerInvariant()
        $slash = $lower.LastIndexOf('/')
        $fileOnly = if ($slash -ge 0) { $lower.Substring($slash + 1) } else { $lower }
        foreach ($key in @($lower, $fileOnly)) {
            if ($Set.Entries.ContainsKey($key)) { foreach ($ind in $Set.Entries[$key]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "entrada $Prefix$name" } }
        }
        if ($Set.EntrypointPaths.ContainsKey($name)) { foreach ($ind in $Set.EntrypointPaths[$name]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "clase $Prefix$name" } }
    }
}

function Find-AmonMetadataHits {
    # Metadatos declarados: modid, entrypoints de Fabric y atributos del MANIFEST.
    param($Set, $Hits, $JarInfo, [string]$Prefix)
    $ji = $JarInfo
    foreach ($id in $ji.ModIds) {
        $k = ([string]$id).ToLowerInvariant()
        if ($Set.ModIds.ContainsKey($k)) { foreach ($ind in $Set.ModIds[$k]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "metadatos de mod de $Prefix(id '$id')" } }
    }
    foreach ($ep in $ji.Entrypoints) {
        if ($Set.Entrypoints.ContainsKey($ep)) { foreach ($ind in $Set.Entrypoints[$ep]) { Add-AmonSignatureHit -Hits $Hits -Indicator $ind -Location "entrypoint declarado en $Prefix" } }
    }
    foreach ($m in $Set.Manifest) {
        $v = $ji.Manifest[$m.Key]
        if ($v -and $v.Trim() -eq $m.Value) { Add-AmonSignatureHit -Hits $Hits -Indicator $m.Indicator -Location "$($Prefix)META-INF/MANIFEST.MF" }
    }
}

function Invoke-AmonArchiveContentScan {
    # Contenido de cada entrada (descomprimido) y JAR anidados. El bucle va en C# si está disponible.
    param($Archive, $Set, $Hits, [string]$Prefix, [int]$Depth, $Limits, $Stats, $Context)
    $nested = [System.Collections.Generic.List[string]]::new()
    if (Test-AmonNativeZip) {
        $zr = [AmonSS.Native.ZipContentScanner]::Scan($Set.Matcher, $Archive, $Limits.MaxEntry,
            [Math]::Max(0, $Limits.MaxTotal - $Stats.DecompressedBytes), [Math]::Max(0, $Limits.MaxEntries - $Stats.EntriesScanned),
            [string[]]$script:MediaExt, [string[]]$script:ArchiveExt)
        $Stats.EntriesScanned += $zr.EntriesScanned
        $Stats.DecompressedBytes += $zr.BytesScanned
        $Stats.SkippedLarge += $zr.SkippedLarge
        if ($zr.Truncated) { $Stats.Truncated = $true }
        foreach ($err in $zr.Errors) { $Stats.Errors.Add("Entrada ilegible $Prefix$err") }
        foreach ($h in $zr.Hits) {
            $pm = $Set.PatternMap[$h.Pattern]
            if ($pm.Indicator.Type -eq 'hex' -or $pm.Indicator.Scopes -contains 'entries') {
                Add-AmonSignatureHit -Hits $Hits -Indicator $pm.Indicator -Scope 'entries' -Location ("contenido de {0}{1} (offset {2}, {3})" -f $Prefix, $h.Entry, $h.Offset, $pm.Encoding)
            }
        }
        foreach ($n in $zr.NestedArchives) { $nested.Add($n) }
    } else {
        foreach ($e in $Archive.Entries) {
            if ($Context -and (Test-AmonCancel -Context $Context)) { $Stats.Truncated = $true; break }
            if ($Stats.DecompressedBytes -ge $Limits.MaxTotal -or $Stats.EntriesScanned -ge $Limits.MaxEntries) { $Stats.Truncated = $true; break }
            if ($e.FullName.EndsWith('/')) { continue }
            $ext = [IO.Path]::GetExtension($e.Name).ToLowerInvariant()
            if ($script:MediaExt -contains $ext) { continue }
            if ($script:ArchiveExt -contains $ext) { $nested.Add($e.FullName); continue }
            if ($e.Length -gt $Limits.MaxEntry) { $Stats.SkippedLarge++; continue }
            $s = $null
            try {
                $s = $e.Open()
                $mr = $Set.Matcher.ScanStream($s, $Limits.MaxEntry)
                $Stats.EntriesScanned++
                $Stats.DecompressedBytes += $mr.BytesScanned
                if ($mr.Patterns.Length) { Add-AmonPatternHits -Set $Set -Hits $Hits -MatchResult $mr -Scope 'entries' -Location "contenido de $Prefix$($e.FullName)" }
            } catch { $Stats.Errors.Add("Entrada ilegible $Prefix$($e.FullName): $($_.Exception.Message)") }
            finally { if ($s) { $s.Dispose() } }
        }
    }

    # 4. JAR anidados (Jar-in-Jar): bytes en bruto + recursión acotada
    foreach ($n in $nested) {
        # Mismos límites que el resto del archivo: miles de JAR anidados muy comprimibles no
        # pueden alargar el escaneo más allá del tiempo, la cancelación ni el total descomprimido.
        if ($Context -and (Test-AmonCancel -Context $Context)) { $Stats.Truncated = $true; break }
        if ($Stats.DecompressedBytes -ge $Limits.MaxTotal -or $Stats.EntriesScanned -ge $Limits.MaxEntries) { $Stats.Truncated = $true; break }
        $e = $Archive.GetEntry($n)
        if (-not $e) { continue }
        if ($e.Length -gt $Limits.MaxEntry) { $Stats.SkippedLarge++; continue }
        try { $bytes = Read-AmonZipEntryBytes -Entry $e -MaxBytes ([Math]::Min($Limits.MaxEntry, $Limits.MaxTotal - $Stats.DecompressedBytes)) }
        catch { $Stats.Errors.Add("Entrada ilegible $Prefix${n}: $($_.Exception.Message)"); continue }
        $Stats.DecompressedBytes += $bytes.Length
        $Stats.EntriesScanned++
        Add-AmonPatternHits -Set $Set -Hits $Hits -MatchResult ($Set.Matcher.ScanBytes($bytes)) -Scope 'raw' -Location "bytes de $Prefix$n"
        if ($Depth -ge $Limits.MaxDepth) { continue }
        $ms = New-Object IO.MemoryStream (, $bytes)
        try {
            $inner = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Read, $false)
            try { [void](Invoke-AmonArchiveScan -Archive $inner -Set $Set -Hits $Hits -Prefix "$Prefix$n!/" -Depth ($Depth + 1) -Limits $Limits -Stats $Stats -Context $Context); $Stats.NestedScanned++ }
            finally { $inner.Dispose() }
        } catch { $Stats.Errors.Add("No se pudo abrir el JAR anidado $Prefix${n}: $($_.Exception.Message)") }
        finally { $ms.Dispose() }
    }
}

function Test-AmonZipMagic {
    param([string]$Path)
    try {
        $fs = Open-AmonReadStream -Path $Path
        try { $b = New-Object byte[] 4; $n = $fs.Read($b, 0, 4); return ($n -eq 4 -and $b[0] -eq 0x50 -and $b[1] -eq 0x4B -and $b[2] -eq 3 -and $b[3] -eq 4) }
        finally { $fs.Dispose() }
    } catch { return $false }
}

function Get-AmonSignatureDetections {
    <#
    .SYNOPSIS
        Agrupa coincidencias por cliente y calcula estado, confianza y justificación.
    #>
    param([object[]]$Hits = @(), [Parameter(Mandatory = $true)]$Set)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($g in ($Hits | Group-Object ClientId)) {
        $client = $Set.ClientIndex[$g.Name]
        $all = @($g.Group)
        $bytesHits = @($all | Where-Object { $_.Type -in @('string', 'hex') })
        $keep = @($all | Where-Object {
                $h = $_
                if ($h.Type -notin @('string', 'hex')) { return $true }
                -not ($bytesHits | Where-Object { $_ -ne $h -and $_.Value.Length -gt $h.Value.Length -and $_.Value.Contains($h.Value) })
            })
        $validated = @($keep | Where-Object { $_.Indicator.Validated })
        $unvalidated = @($keep | Where-Object { -not $_.Indicator.Validated })
        $vStrong = @($validated | Where-Object { $_.Indicator.Strength -eq 'strong' }).Count
        $vMedium = @($validated | Where-Object { $_.Indicator.Strength -eq 'medium' }).Count
        $vWeak = @($validated | Where-Object { $_.Indicator.Strength -eq 'weak' }).Count
        $uSolid = @($unvalidated | Where-Object { $_.Indicator.Strength -in @('strong', 'medium') }).Count
        $conf = 'Low'
        if ($vStrong -ge 1 -or $vMedium -ge 2) { $conf = 'High' }
        elseif ($vMedium -ge 1 -or $vWeak -ge 2 -or $uSolid -ge 2) { $conf = 'Medium' }
        $status = if ($conf -eq 'Low') { 'INCONCLUSIVE' } else { 'DETECTED' }
        $severity = 'Low'
        if ($client.Category -ne 'dual-use' -and $status -eq 'DETECTED') { $severity = if ($conf -eq 'High' -and $client.Category -eq 'cheat-client') { 'High' } else { 'Medium' } }
        $groups = @($keep | ForEach-Object { $_.Indicator.Group } | Where-Object { $_ } | Select-Object -Unique)

        $j = "{0} indicador(es) coincidente(s): {1} validado(s) con fuente pública y {2} sin validar." -f $keep.Count, $validated.Count, $unvalidated.Count
        $top = @($keep | Sort-Object { @{ strong = 0; medium = 1; weak = 2 }[$_.Indicator.Strength] } | Select-Object -First 3 | ForEach-Object { "$($script:TypeLabel[$_.Type]) '$($_.Value)'" })
        if ($top.Count) { $j += ' Principales: ' + ($top -join '; ') + '.' }
        if ($validated.Count -eq 0) {
            $j += ' Las firmas aportadas por el usuario o de fuentes secundarias requieren validación con muestras autorizadas: la confianza se limita a media y una coincidencia no demuestra ejecución.'
        }
        if ($client.Category -eq 'dual-use') { $j += ' Herramienta de uso dual: muchos servidores la permiten.' }
        if ($client.Category -eq 'framework') { $j += ' Los indicadores identifican un framework compartido; la atribución al cliente es inferida.' }
        if ($groups.Count) { $j += ' Variante: ' + ($groups -join ', ') + '.' }

        $fps = @($client.FalsePositives)
        $out.Add([pscustomobject]@{
                PSTypeName    = 'AmonSS.SignatureDetection'
                ClientId      = $client.Id
                ClientName    = $client.Name
                Category      = $client.Category
                Status        = $status
                Confidence    = $conf
                Severity      = $severity
                Matches       = $keep
                Groups        = $groups
                Justification = $j
                FalsePositives = $fps
                Sources       = @($keep | ForEach-Object { $_.Indicator.Source } | Select-Object -Unique)
            })
    }
    return $out.ToArray()
}

function Invoke-AmonFileSignatureScan {
    <#
    .SYNOPSIS
        Escanea un archivo (JAR/ZIP o binario) contra el conjunto de firmas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Set, $Context)
    Initialize-AmonZip
    $limits = Get-AmonScanLimits -Context $Context
    $hits = [ordered]@{}
    $stats = [pscustomobject]@{ EntriesScanned = 0; DecompressedBytes = 0; NestedScanned = 0; SkippedLarge = 0; Truncated = $false; JarInfo = $null; Errors = [System.Collections.Generic.List[string]]::new() }
    $result = [ordered]@{
        PSTypeName = 'AmonSS.FileScan'; Path = $Path; Name = [IO.Path]::GetFileName($Path); Exists = $false; Size = $null
        Sha256 = $null; CreatedUtc = $null; ModifiedUtc = $null; Kind = 'binary'; Detections = @(); Hits = @()
        Stats = $stats; Error = $null
    }
    try { $fi = New-Object IO.FileInfo($Path) } catch { $result.Error = $_.Exception.Message; return [pscustomobject]$result }
    if (-not $fi.Exists) { $result.Error = 'El archivo ya no existe.'; return [pscustomobject]$result }
    $result.Exists = $true; $result.Size = $fi.Length; $result.CreatedUtc = $fi.CreationTimeUtc; $result.ModifiedUtc = $fi.LastWriteTimeUtc
    $result.Sha256 = Get-AmonFileHash -Path $fi.FullName -Context $Context -MaxBytes 1GB
    if ($result.Sha256 -and $Set.Sha256.ContainsKey($result.Sha256)) {
        foreach ($ind in $Set.Sha256[$result.Sha256]) { Add-AmonSignatureHit -Hits $hits -Indicator $ind -Location 'hash del archivo' }
    }
    $lowerName = $fi.Name.ToLowerInvariant()
    $isArchive = ($script:ArchiveExt -contains $fi.Extension.ToLowerInvariant()) -or $lowerName.EndsWith('.jar.disabled') -or (Test-AmonZipMagic -Path $fi.FullName)
    try {
        $maxRaw = if ($isArchive) { [Math]::Min($limits.MaxRaw, $limits.MaxFile) } else { $limits.MaxExecutable }
        $raw = $Set.Matcher.ScanFile($fi.FullName, $maxRaw)
        if ($raw.Truncated) { $stats.Truncated = $true }
        Add-AmonPatternHits -Set $Set -Hits $hits -MatchResult $raw -Scope 'raw' -Location 'bytes en bruto'
        if ($isArchive) {
            $result.Kind = 'archive'
            if ($fi.Length -le $limits.MaxFile) {
                $fs = Open-AmonReadStream -Path $fi.FullName
                try {
                    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read, $true)
                    try { [void](Invoke-AmonArchiveScan -Archive $zip -Set $Set -Hits $hits -Prefix '' -Depth 0 -Limits $limits -Stats $stats -Context $Context) }
                    finally { $zip.Dispose() }
                } catch { $stats.Errors.Add("No se pudo leer como ZIP: $($_.Exception.Message)") }
                finally { $fs.Dispose() }
            } else {
                $stats.Truncated = $true
                $stats.Errors.Add("Archivo mayor que el límite ($([int]($limits.MaxFile / 1MB)) MB): solo se revisaron los bytes en bruto.")
            }
        }
    } catch { $result.Error = $_.Exception.Message }
    $result.Hits = @($hits.Values)
    $result.Detections = @(Get-AmonSignatureDetections -Hits $result.Hits -Set $Set)
    return [pscustomobject]$result
}

#endregion

#region Logs, configuración y perfiles

function Read-AmonLogText {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaxChars = 64MB)
    $fs = $null; $gz = $null; $reader = $null
    try {
        $fs = Open-AmonReadStream -Path $Path
        $stream = $fs
        if ($Path.EndsWith('.gz', [StringComparison]::OrdinalIgnoreCase)) { $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress); $stream = $gz }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        $sb = New-Object System.Text.StringBuilder
        $buf = New-Object char[] 65536
        while ($sb.Length -lt $MaxChars) {
            $n = $reader.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$sb.Append($buf, 0, $n)
        }
        return $sb.ToString()
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($gz) { $gz.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

function Get-AmonLineAt {
    # Línea completa y número de línea que contienen la posición indicada.
    param([string]$Text, [int]$Index)
    $start = $Text.LastIndexOf("`n", [Math]::Max(0, $Index - 1)) + 1
    if ($Index -eq 0) { $start = 0 }
    $end = $Text.IndexOf("`n", $Index); if ($end -lt 0) { $end = $Text.Length }
    $line = $Text.Substring($start, $end - $start).TrimEnd("`r")
    $num = 1
    $p = -1
    while (($p = $Text.IndexOf("`n", $p + 1)) -ge 0 -and $p -lt $start) { $num++ }
    return [pscustomobject]@{ Number = $num; Text = $line.Substring(0, [Math]::Min(400, $line.Length)) }
}

function New-AmonClientFinding {
    # Hallazgo de cliente a partir de coincidencias no basadas en archivo (log / config / perfil).
    param($Set, [string]$ClientId, [string]$Category, [string]$Title, [object[]]$Hits, [string]$Path, $TimestampUtc, [string]$Base, [object[]]$Evidence, [switch]$ExecutionEvidence)
    $client = $Set.ClientIndex[$ClientId]
    $validated = @($Hits | Where-Object { $_.Indicator.Validated })
    $vStrong = @($validated | Where-Object { $_.Indicator.Strength -eq 'strong' }).Count
    $vMedium = @($validated | Where-Object { $_.Indicator.Strength -eq 'medium' }).Count
    $conf = 'Low'
    if ($vStrong -ge 1 -or $vMedium -ge 2) { $conf = 'High' } elseif ($vMedium -ge 1) { $conf = 'Medium' }
    if ($Category -eq 'ClientConfig' -and $conf -eq 'High') { $conf = 'Medium' }
    $status = if ($conf -eq 'Low') { 'INCONCLUSIVE' } else { 'DETECTED' }
    $severity = if ($client.Category -eq 'dual-use' -or $status -ne 'DETECTED') { 'Low' } elseif ($conf -eq 'High') { 'High' } else { 'Medium' }
    $j = $Base
    if (-not $validated.Count) { $j += ' Indicadores sin validar (fuente secundaria o del usuario): requieren comprobación manual.' }
    if ($client.Category -eq 'dual-use') { $j += ' Herramienta de uso dual: muchos servidores la permiten.' }
    New-AmonFinding -Module 'Signatures' -Category $Category -Title $Title -Status $status -Severity $severity -Confidence $conf `
        -Path $Path -TimestampUtc $TimestampUtc -Indicator (@($Hits | ForEach-Object Value) -join ' | ') -IndicatorType (@($Hits | ForEach-Object Type | Select-Object -Unique) -join ',') `
        -Client $client.Name -ClientId $client.Id -Source ('Signatures (' + (@($Hits | ForEach-Object { $_.Indicator.Source } | Select-Object -Unique) -join ' ; ') + ')') `
        -Justification $j -FalsePositives $client.FalsePositives -Evidence $Evidence -Data @{ Execution = [bool]$ExecutionEvidence; Hits = $Hits }
}

function Invoke-AmonLogSignatureCheck {
    param($Context, $Set, $Instance, $Session, $Result)
    $byClient = @{}
    $addHit = {
        param($ind, $location, $line)
        if (-not $byClient.ContainsKey($ind.ClientId)) { $byClient[$ind.ClientId] = [System.Collections.Generic.List[object]]::new() }
        foreach ($h in $byClient[$ind.ClientId]) { if ($h.Indicator.Id -eq $ind.Id) { return } }
        $byClient[$ind.ClientId].Add([pscustomobject]@{ ClientId = $ind.ClientId; Indicator = $ind; Type = $ind.Type; Value = $ind.Value; Location = $location; Line = $line })
    }
    foreach ($key in $Set.ModIds.Keys) {
        $how = $null
        if ($Session.TopLevelIds.Contains($key)) { $how = 'en la lista de mods cargados' }
        elseif ($Session.NestedIds.Contains($key)) { $how = 'como mod anidado cargado' }
        elseif ($Session.ResourceIds.Contains($key)) { $how = 'entre los recursos cargados' }
        if ($how) { foreach ($ind in $Set.ModIds[$key]) { & $addHit $ind "id '$key' $how" $null } }
    }
    if ($Set.Logs.Count) {
        $text = $null
        try { $text = Read-AmonLogText -Path $Session.Path -MaxChars ([long]$Context.Settings.limits.maxLogSizeMB * 1MB) } catch { $Result.Warnings.Add("No se pudo releer $($Session.Path): $($_.Exception.Message)") }
        if ($text) {
            foreach ($li in $Set.Logs) {
                $idx = -1
                if ($li.Regex) { $m = $li.Regex.Match($text); if ($m.Success) { $idx = $m.Index } }
                else { $idx = $text.IndexOf($li.Value, [StringComparison]::Ordinal) }
                if ($idx -ge 0) {
                    $line = Get-AmonLineAt -Text $text -Index $idx
                    & $addHit $li "línea $($line.Number)" $line
                }
            }
        }
    }
    $inWindow = Test-AmonInWindow -Context $Context -Utc $Session.SessionStartUtc
    foreach ($cid in $byClient.Keys) {
        $hits = $byClient[$cid].ToArray()
        $client = $Set.ClientIndex[$cid]
        $ev = @($hits | ForEach-Object {
                $d = if ($_.Line) { "$($Session.FileName) $($_.Location): $($_.Line.Text)" } else { "$($Session.FileName): $($_.Location)" }
                New-AmonEvidence -Source 'Minecraft (log)' -Kind LogLoaded -Path $Session.Path -TimestampUtc $Session.SessionStartUtc -Description $d
            })
        $base = "El log $($Session.FileName) de $($Instance.Name) contiene evidencia de que $($client.Name) se cargó o arrancó (sesión del $(Format-AmonTimestamp $Session.SessionStartUtc))."
        if (-not $inWindow) { $base += ' La sesión queda fuera del periodo analizado.' }
        $Result.Findings.Add((New-AmonClientFinding -Set $Set -ClientId $cid -Category 'ClientLog' -Title "$($client.Name): evidencia en log de Minecraft" -Hits $hits -Path $Session.Path -TimestampUtc $Session.SessionStartUtc -Base $base -Evidence $ev -ExecutionEvidence))
        if ($Session.SessionStartUtc) {
            $Result.Events.Add((New-AmonEvent -TimestampUtc $Session.SessionStartUtc -Type 'Cliente detectado en log' -Kind LogLoaded -Source 'Signatures (log)' -Path $Session.Path -Indicator $client.Name -Confidence $(if (@($hits | Where-Object { $_.Indicator.Validated }).Count) { 'High' } else { 'Low' }) -Description (@($hits | ForEach-Object Value) -join ' | ')))
        }
    }
}

function Resolve-AmonIndicatorPath {
    # Ruta de un indicador config/path: se ignoran segmentos con marcadores <...>.
    param($Indicator, [string]$Base)
    $parts = @($Indicator.Value -split '[\\/]' | Where-Object { $_ })
    $clean = @()
    foreach ($p in $parts) { if ($p -match '[<>]') { break }; $clean += $p }
    if (-not $clean.Count) { return $null }
    return Join-Path $Base ($clean -join '\')
}

function Invoke-AmonConfigSignatureCheck {
    param($Context, $Set, [string]$Base, [string]$RelativeTo, [string]$Label, $Result)
    foreach ($ci in @($Set.Configs | Where-Object RelativeTo -EQ $RelativeTo)) {
        $p = Resolve-AmonIndicatorPath -Indicator $ci -Base $Base
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $facts = Get-AmonFileFacts -Path $p
        $client = $Set.ClientIndex[$ci.ClientId]
        $hit = [pscustomobject]@{ ClientId = $ci.ClientId; Indicator = $ci; Type = $ci.Type; Value = $ci.Value; Location = $p }
        $ev = @(New-AmonEvidence -Source 'Sistema de archivos' -Kind Configuration -Path $p -TimestampUtc $facts.ModifiedUtc -Description ("Creada: {0}; última modificación: {1}" -f (Format-AmonTimestamp $facts.CreatedUtc), (Format-AmonTimestamp $facts.ModifiedUtc)))
        # No llamar a esta variable $base: PowerShell no distingue mayúsculas y pisaría el parámetro $Base.
        $why = "Existe '$($ci.Value)' en $Label. Según $($ci.Source), $($client.Name) crea esa ruta. Prueba uso pasado, no que el cliente siga instalado."
        $Result.Findings.Add((New-AmonClientFinding -Set $Set -ClientId $ci.ClientId -Category 'ClientConfig' -Title "$($client.Name): configuración presente" -Hits @($hit) -Path $p -TimestampUtc $facts.ModifiedUtc -Base $why -Evidence $ev))
        foreach ($t in @(@('Creada', $facts.CreatedUtc), @('Modificada', $facts.ModifiedUtc))) {
            if (Test-AmonInWindow -Context $Context -Utc $t[1]) {
                $Result.Events.Add((New-AmonEvent -TimestampUtc $t[1] -Type "Configuración de cliente $($t[0].ToLowerInvariant())" -Kind Configuration -Source 'Signatures (configuración)' -Path $p -Indicator $client.Name -Confidence Medium))
            }
        }
        $Result.ArtifactsReviewed++
    }
}

#endregion

#region Módulo

function Invoke-AmonSignatureAnalysis {
    <#
    .SYNOPSIS
        Escanea los JAR de las instancias de Minecraft (y rutas de evidencia) con las firmas,
        revisa carpetas de configuración, perfiles de versión y logs.
    .PARAMETER EvidenceOnly
        Solo escanea rutas de evidencia nuevas (segunda pasada tras Prefetch/Recent/UserAssist).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, $Set, [string[]]$ExtraPaths = @(), [switch]$EvidenceOnly)
    if (-not $Set) { $Set = if ($Context.Signatures) { $Context.Signatures } else { Get-AmonSignatureSet } }
    $Context.Signatures = $Set
    foreach ($k in $Set.Keywords) { [void]$Context.Keywords.Add($k) }
    $name = if ($EvidenceOnly) { 'SignaturesEvidence' } else { 'Signatures' }
    $res = New-AmonModuleResult -Module $name -DisplayName $(if ($EvidenceOnly) { 'Signature Scan (evidencias)' } else { 'Cheat Signature Scanner' })
    $res.Data['Clients'] = $Set.Clients.Count
    $res.Data['Indicators'] = $Set.Indicators.Count
    $res.Data['ClientsWithoutSignatures'] = @($Set.Clients | Where-Object { $_.Indicators.Count -eq 0 } | ForEach-Object Name)
    foreach ($e in $Set.Errors) { $res.Warnings.Add("Firmas: $e") }

    $targets = [System.Collections.Generic.List[object]]::new()
    if (-not $EvidenceOnly) {
        foreach ($inst in $Context.Instances) {
            foreach ($m in $inst.Mods) { $targets.Add([pscustomobject]@{ Path = $m.Path; Origin = 'mods'; Instance = $inst.Name }) }
            if ($Context.Settings.scan.scanVersionJarsWhenHashUnverified) {
                foreach ($v in $inst.Versions) { if ($v.JarPath -and $v.HashStatus -ne 'Verified') { $targets.Add([pscustomobject]@{ Path = $v.JarPath; Origin = 'versions'; Instance = $inst.Name }) } }
            }
        }
        $extra = @($ExtraPaths) + @($Context.ExtraScanPaths) + @($Context.Settings.scan.extraScanPaths)
        foreach ($p in $extra) {
            $p = Expand-AmonPath $p
            if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
            if ((Get-Item -LiteralPath $p).PSIsContainer) {
                foreach ($f in (Get-AmonChildItemSafe -Path $p -Include @('*.jar', '*.exe', '*.dll', '*.zip') -Depth 2 -MaxItems ([int]$Context.Settings.limits.maxFilesPerDirectory))) {
                    $targets.Add([pscustomobject]@{ Path = $f.FullName; Origin = 'ruta personalizada'; Instance = $null })
                }
            } else { $targets.Add([pscustomobject]@{ Path = $p; Origin = 'ruta personalizada'; Instance = $null }) }
        }
    }
    foreach ($ev in $Context.EvidencePaths) {
        $ext = [IO.Path]::GetExtension($ev.Path).ToLowerInvariant()
        if ($ext -notin @('.jar', '.exe', '.dll', '.zip')) { continue }
        if (-not (Test-Path -LiteralPath $ev.Path -PathType Leaf)) { continue }
        $targets.Add([pscustomobject]@{ Path = $ev.Path; Origin = "evidencia: $($ev.Source)"; Instance = $null })
    }

    # Un escaneo completo sustituye a los anteriores (también a la pasada de evidencias, que
    # vuelve a cubrir): se empieza de cero para no saltarse archivos de un escaneo interrumpido.
    if (-not $EvidenceOnly) {
        $Context.ScannedPaths.Clear()
        if ($Context.Results.Contains('SignaturesEvidence')) { $Context.Results.Remove('SignaturesEvidence') }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $todo = @($targets | Where-Object { -not $Context.ScannedPaths.Contains($_.Path) -and $seen.Add($_.Path) })
    $n = [Math]::Max(1, $todo.Count); $i = 0
    foreach ($t in $todo) {
        if (Test-AmonCancel -Context $Context) { break }
        $i++
        Update-AmonProgress -Context $Context -Percent (90.0 * ($i - 1) / $n) -Detail ([IO.Path]::GetFileName($t.Path)) -Count $res.ArtifactsReviewed
        $scan = Invoke-AmonFileSignatureScan -Path $t.Path -Set $Set -Context $Context
        # Solo cuenta como escaneado si el escaneo terminó (no por cancelación ni límite de tiempo).
        if (-not $scan.Stats.Truncated -and -not $Context.CancelRequested -and -not $Context.ModuleTimedOut) { [void]$Context.ScannedPaths.Add($t.Path) }
        $res.ArtifactsReviewed++
        foreach ($err in $scan.Stats.Errors) { $res.Warnings.Add("$($t.Path): $err") }
        if ($scan.Stats.Truncated) { $res.Limitations.Add("Escaneo parcial por límites de tamaño o tiempo: $($t.Path)") }
        $resultLabel = 'Sin coincidencias'
        if ($scan.Detections | Where-Object Status -EQ 'DETECTED') { $resultLabel = 'Detección' } elseif ($scan.Detections) { $resultLabel = 'No concluyente' }
        $res.Artifacts.Add([pscustomobject]@{
                Path = $t.Path; FileName = $scan.Name; Origin = $t.Origin; Instance = $t.Instance; Sha256 = $scan.Sha256; Size = $scan.Size
                ModifiedUtc = $scan.ModifiedUtc; Result = $resultLabel; Clients = (@($scan.Detections | ForEach-Object ClientName) -join ', ')
                EntriesScanned = $scan.Stats.EntriesScanned; Error = $scan.Error
            })
        foreach ($d in $scan.Detections) {
            $ev = @($d.Matches | ForEach-Object {
                    New-AmonEvidence -Source 'Signatures' -Kind Signature -Path $t.Path -Description ("{0} '{1}' en {2}. Fuente: {3} ({4}{5})." -f $script:TypeLabel[$_.Type], $_.Value, $_.Location, $_.Indicator.Source, $_.Indicator.Provenance, $(if ($_.Indicator.Validated) { ', validada' } else { ', sin validar' }))
                })
            $first = $d.Matches | Sort-Object { @{ strong = 0; medium = 1; weak = 2 }[$_.Indicator.Strength] } | Select-Object -First 1
            $indicatorText = "$($first.Value) ($($script:TypeLabel[$first.Type]))"
            if ($d.Matches.Count -gt 1) { $indicatorText += " +$($d.Matches.Count - 1)" }
            $res.Findings.Add((New-AmonFinding -Module 'Signatures' -Category 'CheatSignature' -Title $d.ClientName -Status $d.Status -Severity $d.Severity -Confidence $d.Confidence `
                        -Path $t.Path -Sha256 $scan.Sha256 -TimestampUtc $scan.ModifiedUtc -Indicator $indicatorText -IndicatorType $first.Type -Client $d.ClientName -ClientId $d.ClientId `
                        -Source ('Signatures: ' + ($d.Sources -join ' ; ')) -Justification $d.Justification -FalsePositives $d.FalsePositives -Evidence $ev `
                        -Data @{ Origin = $t.Origin; Instance = $t.Instance; CreatedUtc = $scan.CreatedUtc; Groups = $d.Groups; Matches = $d.Matches }))
            # Solo una detección firme guía a los demás módulos: una no concluyente haría que
            # Prefetch, eventos, etc. emitieran hallazgos por simple coincidencia de nombre.
            if ($d.Status -eq 'DETECTED') { Add-AmonIndicator -Context $Context -FileName $scan.Name -Sha256 $scan.Sha256 -Source 'Signatures' }
            if ($scan.ModifiedUtc) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $scan.ModifiedUtc -Type 'Archivo con firma de cliente (última modificación)' -Kind Presence -Source 'Signatures' -Path $t.Path -Sha256 $scan.Sha256 -Indicator $d.ClientName -Confidence $d.Confidence))
            }
        }
        if (-not $scan.Detections -and $scan.Exists) {
            foreach ($c in $Set.Clients) {
                $kw = $c.Keywords | Where-Object { $scan.Name.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
                if ($kw) {
                    $res.Findings.Add((New-AmonFinding -Module 'Signatures' -Category 'KeywordName' -Title "Nombre de archivo relacionado con $($c.Name)" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                                -Path $t.Path -Sha256 $scan.Sha256 -TimestampUtc $scan.ModifiedUtc -Indicator "palabra clave '$kw'" -IndicatorType 'keyword' -Client $c.Name -ClientId $c.Id `
                                -Justification "El nombre contiene '$kw', pero ninguna firma coincide con el contenido. Un nombre de archivo no prueba nada por sí solo." -FalsePositives @('Coincidencia casual de nombre.')))
                    break
                }
            }
        }
    }

    if (-not $EvidenceOnly) {
        Update-AmonProgress -Context $Context -Percent 92 -Detail 'configuraciones y logs' -Count $res.ArtifactsReviewed
        foreach ($inst in $Context.Instances) {
            if (Test-AmonCancel -Context $Context) { break }
            Invoke-AmonConfigSignatureCheck -Context $Context -Set $Set -Base $inst.GameDir -RelativeTo 'gameDir' -Label $inst.Name -Result $res
            foreach ($v in $inst.Versions) {
                foreach ($vi in $Set.VersionIds) {
                    if ($vi.Regex -and $vi.Regex.IsMatch($v.Id)) {
                        $hit = [pscustomobject]@{ ClientId = $vi.ClientId; Indicator = $vi; Type = 'versionId'; Value = $v.Id; Location = $v.JsonPath }
                        $res.Findings.Add((New-AmonClientFinding -Set $Set -ClientId $vi.ClientId -Category 'ClientVersionProfile' -Title "$($vi.ClientName): perfil de versión" -Hits @($hit) -Path $v.JsonPath -TimestampUtc $v.JsonModifiedUtc -Base "El perfil de versión '$($v.Id)' sigue el formato que crea el instalador de $($vi.ClientName) ($($vi.Source))."))
                    }
                }
                $jvmText = @($v.JvmArgs) -join ' '
                foreach ($ja in $Set.JvmArgs) {
                    if ($jvmText.IndexOf($ja.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $hit = [pscustomobject]@{ ClientId = $ja.ClientId; Indicator = $ja; Type = 'jvmArg'; Value = $ja.Value; Location = $v.JsonPath }
                        $res.Findings.Add((New-AmonClientFinding -Set $Set -ClientId $ja.ClientId -Category 'ClientVersionProfile' -Title "$($ja.ClientName): argumento JVM en perfil" -Hits @($hit) -Path $v.JsonPath -TimestampUtc $v.JsonModifiedUtc -Base "El perfil '$($v.Id)' incluye '$($ja.Value)' ($($ja.Source))."))
                    }
                }
            }
            foreach ($s in $inst.Sessions) {
                if (Test-AmonCancel -Context $Context) { break }
                Invoke-AmonLogSignatureCheck -Context $Context -Set $Set -Instance $inst -Session $s -Result $res
                $res.ArtifactsReviewed++
            }
        }
        $userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
        Invoke-AmonConfigSignatureCheck -Context $Context -Set $Set -Base $userHome -RelativeTo 'userHome' -Label 'el perfil del usuario' -Result $res
        $res.Scope.Add("Carpetas mods, versions y configuración de $($Context.Instances.Count) instancia(s); perfil del usuario (solo rutas de firmas).")
        if ($res.Data['ClientsWithoutSignatures'].Count) {
            $res.Limitations.Add('Sin firmas verificables (el escaneo no puede descartarlos): ' + ($res.Data['ClientsWithoutSignatures'] -join ', ') + '.')
        }
        $res.Limitations.Add('Los clientes inyectables o cargados desde memoria pueden no dejar archivos en las carpetas analizadas; el escaneo de memoria está fuera del alcance de esta herramienta.')
    }
    Update-AmonProgress -Context $Context -Percent 100 -Detail 'firmas' -Count $res.ArtifactsReviewed
    return Complete-AmonModuleResult -Result $res
}

#endregion

Export-ModuleMember -Function @(
    'Get-AmonSignatureSet', 'Test-AmonSignatureSet', 'Invoke-AmonFileSignatureScan', 'Get-AmonSignatureDetections',
    'Invoke-AmonSignatureAnalysis', 'Read-AmonLogText', 'Resolve-AmonIndicatorPath'
)
