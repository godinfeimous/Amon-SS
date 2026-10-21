#Requires -Version 5.1
<#
    Amon SS - modules/Jar.psm1
    Inspección estática de archivos JAR/ZIP: entradas, paquetes Java, metadatos de mods
    (Fabric, Quilt, Forge, NeoForge, mcmod.info, LiteLoader), MANIFEST.MF y JAR anidados.

    Nunca se ejecuta ni se carga código del JAR: solo se leen entradas como datos.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:ZipReady = $false
$script:MetadataNames = @('fabric.mod.json', 'quilt.mod.json', 'meta-inf/mods.toml', 'meta-inf/neoforge.mods.toml', 'mcmod.info', 'litemod.json', 'meta-inf/manifest.mf')

function Initialize-AmonZip {
    if ($script:ZipReady) { return }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Import-AmonNative
    $script:ZipReady = $true
}

function Read-AmonZipEntryBytes {
    param([Parameter(Mandatory = $true)]$Entry, [long]$MaxBytes = 4MB)
    $len = [Math]::Min([long]$Entry.Length, $MaxBytes)
    $buf = New-Object byte[] $len
    $s = $Entry.Open()
    try {
        $read = 0
        while ($read -lt $len) {
            $n = $s.Read($buf, $read, [int]($len - $read))
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $s.Dispose() }
    if ($read -lt $len) { [Array]::Resize([ref]$buf, $read) }
    return , $buf
}

function Read-AmonZipEntryText {
    param([Parameter(Mandatory = $true)]$Entry, [long]$MaxBytes = 1MB)
    $b = Read-AmonZipEntryBytes -Entry $Entry -MaxBytes $MaxBytes
    $text = [Text.Encoding]::UTF8.GetString($b)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    return $text
}

function ConvertFrom-AmonManifest {
    # MANIFEST.MF: "Clave: valor" con líneas de continuación que empiezan por espacio.
    param([AllowEmptyString()][string]$Text)
    $h = @{}
    $lastKey = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.StartsWith(' ') -and $lastKey) { $h[$lastKey] += $line.Substring(1); continue }
        $idx = $line.IndexOf(':')
        if ($idx -gt 0) {
            $lastKey = $line.Substring(0, $idx).Trim()
            $h[$lastKey] = $line.Substring($idx + 1).Trim()
        }
    }
    return $h
}

function ConvertFrom-AmonModsToml {
    # Extrae modId/version/displayName solo de las tablas [[mods]] (no de [[dependencies.*]]).
    param([AllowEmptyString()][string]$Text)
    $ids = [System.Collections.Generic.List[string]]::new()
    $version = $null; $name = $null; $inMods = $false; $neo = $false
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^\[\[\s*mods\s*\]\]') { $inMods = $true; continue }
        if ($line -match '^\[') { $inMods = $false }
        if ($line -match '^modId\s*=\s*"neoforge"') { $neo = $true }
        if (-not $inMods) { continue }
        if ($line -match '^modId\s*=\s*"([^"]+)"') { $ids.Add($Matches[1]) }
        elseif (-not $version -and $line -match '^version\s*=\s*"([^"]+)"') { $version = $Matches[1] }
        elseif (-not $name -and $line -match '^displayName\s*=\s*"([^"]+)"') { $name = $Matches[1] }
    }
    [pscustomobject]@{ ModIds = $ids.ToArray(); Version = $version; DisplayName = $name; DependsOnNeoForge = $neo }
}

function Get-AmonFabricValues {
    # Valores de entrypoints/mixins: pueden ser cadenas u objetos { value | config }.
    param($Node, [string]$Field)
    $out = @()
    foreach ($item in @($Node)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $out += $item }
        elseif ($item.PSObject.Properties[$Field]) { $out += [string]$item.$Field }
    }
    return $out
}

function Get-AmonJarInfoFromArchive {
    param([Parameter(Mandatory = $true)]$Archive, [string]$Path, [int]$MaxEntries = 60000)
    $info = [ordered]@{
        Path = $Path; Name = $(if ($Path) { [IO.Path]::GetFileName($Path) } else { $null })
        IsValidZip = $true; Error = $null; EntryCount = 0; ClassCount = 0; Truncated = $false
        Entries = $null; Packages = @(); Loader = 'Unknown'; ModIds = @(); ModName = $null; ModVersion = $null
        Entrypoints = @(); Mixins = @(); AccessWidener = $null; Manifest = @{}; IsJavaAgent = $false
        MainClass = $null; NestedJars = @(); HasModMetadata = $false
    }
    $byName = @{}
    if (Test-AmonNativeZip) {
        # Ruta rápida en C#: nombres, clases, paquetes, JAR anidados y metadatos en una pasada.
        $sum = [AmonSS.Native.JarNames]::Summarize([AmonSS.Native.ZipContentScanner]::GetEntryNames($Archive), $MaxEntries, [string[]]$script:MetadataNames)
        $info.EntryCount = $sum.EntryCount; $info.ClassCount = $sum.ClassCount; $info.Truncated = $sum.Truncated
        $info.Entries = $sum.Names; $info.NestedJars = $sum.NestedJars; $info.Packages = @($sum.Packages)
        foreach ($k in $sum.Metadata.Keys) { $byName[$k] = $Archive.GetEntry($sum.Metadata[$k]) }
    } else {
        Get-AmonJarNamesSlow -Archive $Archive -Info $info -ByName $byName -MaxEntries $MaxEntries
    }
    Read-AmonJarMetadata -Info $info -ByName $byName
    return [pscustomobject]$info
}

function Get-AmonJarNamesSlow {
    # Respaldo en PowerShell de JarNames.Summarize (mismo resultado, más lento).
    param($Archive, $Info, [hashtable]$ByName, [int]$MaxEntries)
    $info = $Info
    $byName = $ByName
    $names = [System.Collections.Generic.List[string]]::new()
    $pkgCount = @{}
    $nested = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Archive.Entries) {
        $info.EntryCount++
        if ($names.Count -lt $MaxEntries) { $names.Add($e.FullName) } else { $info.Truncated = $true }
        $n = $e.FullName
        if ($n.EndsWith('.class', [StringComparison]::OrdinalIgnoreCase)) {
            $info.ClassCount++
            $slash = $n.LastIndexOf('/')
            if ($slash -gt 0) {
                $parts = $n.Substring(0, $slash).Split('/')
                $depth = [Math]::Min(3, $parts.Count)
                $prefix = (($parts[0..($depth - 1)]) -join '/') + '/'
                if ($pkgCount.ContainsKey($prefix)) { $pkgCount[$prefix]++ } else { $pkgCount[$prefix] = 1 }
                if ($parts.Count -ge 2) {
                    $p2 = $parts[0] + '/' + $parts[1] + '/'
                    if ($p2 -ne $prefix) { if ($pkgCount.ContainsKey($p2)) { $pkgCount[$p2]++ } else { $pkgCount[$p2] = 1 } }
                }
            }
        } elseif ($n.EndsWith('.jar', [StringComparison]::OrdinalIgnoreCase)) {
            $nested.Add($n)
        }
        $lower = $n.ToLowerInvariant()
        if ($script:MetadataNames -contains $lower -and -not $byName.ContainsKey($lower)) { $byName[$lower] = $e }
    }
    $info.Entries = $names.ToArray()
    $info.NestedJars = $nested.ToArray()
    $info.Packages = @($pkgCount.GetEnumerator() | Where-Object { $_.Key -notlike 'META-INF/*' } | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { $_.Key })
}

function Read-AmonMetadataText {
    # Un metadato dañado (p. ej. deflate inválido) se anota y se trata como vacío: no debe
    # impedir leer el resto del JAR ni el escaneo de firmas.
    param($Info, $Entry, [long]$MaxBytes = 1MB)
    try { return Read-AmonZipEntryText -Entry $Entry -MaxBytes $MaxBytes }
    catch {
        $msg = "No se pudo leer $($Entry.FullName): $($_.Exception.Message)"
        $Info.Error = if ($Info.Error) { "$($Info.Error) $msg" } else { $msg }
        return ''
    }
}

function Read-AmonJarMetadata {
    # Interpreta los archivos de metadatos encontrados (fabric/quilt/forge/neoforge/mcmod/manifest).
    param($Info, [hashtable]$ByName)
    $info = $Info
    $byName = $ByName
    $ids = [System.Collections.Generic.List[string]]::new()
    if ($byName['fabric.mod.json']) {
        $info.Loader = 'Fabric'; $info.HasModMetadata = $true
        $txt = Read-AmonMetadataText -Info $info -Entry $byName['fabric.mod.json']
        try {
            $j = $txt | ConvertFrom-Json -ErrorAction Stop
            if ($j.id) { $ids.Add([string]$j.id) }
            $info.ModVersion = [string]$j.version
            $info.ModName = [string]$j.name
            if ($j.entrypoints) {
                foreach ($p in $j.entrypoints.PSObject.Properties) { $info.Entrypoints += Get-AmonFabricValues $p.Value 'value' }
            }
            $info.Mixins = @(Get-AmonFabricValues $j.mixins 'config')
            if ($j.accessWidener) { $info.AccessWidener = [string]$j.accessWidener }
        } catch {
            if ($txt -match '"id"\s*:\s*"([^"]+)"') { $ids.Add($Matches[1]) }
            $info.Error = 'fabric.mod.json no es JSON válido; se extrajo el id por patrón.'
        }
    }
    if ($byName['quilt.mod.json']) {
        $info.Loader = 'Quilt'; $info.HasModMetadata = $true
        $txt = Read-AmonMetadataText -Info $info -Entry $byName['quilt.mod.json']
        try {
            $j = $txt | ConvertFrom-Json -ErrorAction Stop
            if ($j.quilt_loader.id -and -not $ids.Contains([string]$j.quilt_loader.id)) { $ids.Add([string]$j.quilt_loader.id) }
            if (-not $info.ModVersion) { $info.ModVersion = [string]$j.quilt_loader.version }
        } catch { }
    }
    foreach ($tomlName in @('meta-inf/neoforge.mods.toml', 'meta-inf/mods.toml')) {
        if (-not $byName[$tomlName]) { continue }
        $t = ConvertFrom-AmonModsToml (Read-AmonMetadataText -Info $info -Entry $byName[$tomlName])
        if ($info.Loader -eq 'Unknown') {
            $info.Loader = if ($tomlName -eq 'meta-inf/neoforge.mods.toml' -or $t.DependsOnNeoForge) { 'NeoForge' } else { 'Forge' }
        }
        $info.HasModMetadata = $true
        foreach ($id in $t.ModIds) { if (-not $ids.Contains($id)) { $ids.Add($id) } }
        if (-not $info.ModVersion) { $info.ModVersion = $t.Version }
        if (-not $info.ModName) { $info.ModName = $t.DisplayName }
    }
    if ($byName['mcmod.info']) {
        if ($info.Loader -eq 'Unknown') { $info.Loader = 'LegacyForge' }
        $info.HasModMetadata = $true
        $txt = Read-AmonMetadataText -Info $info -Entry $byName['mcmod.info']
        $found = [regex]::Matches($txt, '"modid"\s*:\s*"([^"]+)"')
        foreach ($m in $found) { if (-not $ids.Contains($m.Groups[1].Value)) { $ids.Add($m.Groups[1].Value) } }
        if (-not $info.ModVersion -and $txt -match '"version"\s*:\s*"([^"]+)"') { $info.ModVersion = $Matches[1] }
        if (-not $info.ModName -and $txt -match '"name"\s*:\s*"([^"]+)"') { $info.ModName = $Matches[1] }
    }
    if ($byName['litemod.json']) {
        if ($info.Loader -eq 'Unknown') { $info.Loader = 'LiteLoader' }
        $info.HasModMetadata = $true
        $txt = Read-AmonMetadataText -Info $info -Entry $byName['litemod.json']
        if ($txt -match '"name"\s*:\s*"([^"]+)"') { if (-not $ids.Contains($Matches[1])) { $ids.Add($Matches[1]) } }
    }
    if ($byName['meta-inf/manifest.mf']) {
        $mf = ConvertFrom-AmonManifest (Read-AmonMetadataText -Info $info -Entry $byName['meta-inf/manifest.mf'] -MaxBytes 256KB)
        $info.Manifest = $mf
        $info.IsJavaAgent = [bool]($mf['Premain-Class'] -or $mf['Agent-Class'] -or $mf['Launcher-Agent-Class'])
        $info.MainClass = $mf['Main-Class']
        if ($info.Loader -eq 'Unknown' -and $info.MainClass) { $info.Loader = 'Standalone' }
    }
    $info.ModIds = $ids.ToArray()
}

function Get-AmonJarInfo {
    <#
    .SYNOPSIS
        Lee la estructura y los metadatos de un JAR sin ejecutarlo.
    .PARAMETER Stream
        Alternativa a -Path para JAR anidados ya extraídos a memoria.
    #>
    [CmdletBinding()]
    param([string]$Path, [IO.Stream]$Stream, [string]$Name, [int]$MaxEntries = 60000)
    Initialize-AmonZip
    $ownStream = $false
    try {
        if (-not $Stream) { $Stream = Open-AmonReadStream -Path $Path; $ownStream = $true }
        $zip = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            $label = if ($Path) { $Path } else { $Name }
            return Get-AmonJarInfoFromArchive -Archive $zip -Path $label -MaxEntries $MaxEntries
        } finally { $zip.Dispose() }
    } catch {
        return [pscustomobject]@{
            Path = $(if ($Path) { $Path } else { $Name }); Name = $(if ($Path) { [IO.Path]::GetFileName($Path) } else { $Name })
            IsValidZip = $false; Error = $_.Exception.Message; EntryCount = 0; ClassCount = 0; Truncated = $false
            Entries = @(); Packages = @(); Loader = 'Unknown'; ModIds = @(); ModName = $null; ModVersion = $null
            Entrypoints = @(); Mixins = @(); AccessWidener = $null; Manifest = @{}; IsJavaAgent = $false
            MainClass = $null; NestedJars = @(); HasModMetadata = $false
        }
    } finally {
        if ($ownStream -and $Stream) { $Stream.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Initialize-AmonZip', 'Read-AmonZipEntryBytes', 'Read-AmonZipEntryText', 'ConvertFrom-AmonManifest',
    'ConvertFrom-AmonModsToml', 'Get-AmonJarInfo', 'Get-AmonJarInfoFromArchive'
)
