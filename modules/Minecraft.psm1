#Requires -Version 5.1
<#
    Amon SS - modules/Minecraft.psm1
    Motor de análisis de Minecraft Java Edition.

      * Descubre instancias: .minecraft (Minecraft Launcher, TLauncher, Badlion), perfiles con
        gameDir propio, Lunar Client, Feather, Prism/PolyMC, CurseForge, Modrinth App,
        GDLauncher, rutas extra configuradas y --gameDir de procesos Java en ejecución.
        MultiMC es portable (sin ubicación fija): se detecta si está en ejecución o si se
        añade su carpeta en extraInstancePaths.
      * Interpreta logs (latest.log y rotados .log.gz): versión, loader, usuario, mods
        cargados, JAR mencionados y marca del cliente.
      * Diferencia mods INSTALADOS (JAR en la carpeta mods) de mods CARGADOS (evidencia en log).
      * Verifica perfiles de versión: clase principal, argumentos -javaagent y SHA-1 del JAR
        frente al hash que declara el propio JSON de Mojang.

    No se leen archivos de cuentas (launcher_accounts*.json, *.bin de credenciales) y no se
    ejecuta ningún JAR.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Jar.psm1') -DisableNameChecking

# Clases principales de perfiles de versión conocidas (vanilla y loaders documentados).
$script:KnownMainClasses = @(
    'net.minecraft.client.main.Main',
    'net.minecraft.client.Minecraft',
    'net.fabricmc.loader.impl.launch.knot.KnotClient',
    'net.fabricmc.loader.launch.knot.KnotClient',
    'org.quiltmc.loader.impl.launch.knot.KnotClient',
    'cpw.mods.bootstraplauncher.BootstrapLauncher',
    'cpw.mods.modlauncher.Launcher',
    'net.minecraft.launchwrapper.Launch',
    'net.minecraftforge.bootstrap.ForgeBootstrap',
    'net.neoforged.fml.startup.Client'
)

# Ids de plataforma que no cuentan como "mod eliminado" aunque no haya JAR propio.
$script:PlatformModIds = @(
    'minecraft', 'java', 'fabricloader', 'fabric-loader', 'quilt_loader', 'quilt_base', 'forge', 'neoforge',
    'fml', 'mcp', 'javafml', 'lowcodefml', 'mixinextras', 'fabric', 'fabric-api', 'quilted_fabric_api', 'qsl'
)

$script:Rx = @{
    Time        = [regex]::new('^\[[^\]]*?(\d{2}):(\d{2}):(\d{2})', 'Compiled')
    FabricHead  = [regex]::new('Loading Minecraft (\S+) with (Fabric|Quilt) Loader (\S+)', 'Compiled')
    ModsHeader  = [regex]::new('Loading \d+ mods:\s*$', 'Compiled')
    ModsOld     = [regex]::new('Loading \d+ mods: (.+)$', 'Compiled')
    TopMod      = [regex]::new('^\s*-\s+(\S+)\s+(\S+)', 'Compiled')
    NestedMod   = [regex]::new('^\s*(?:\|\s+)*[|\\]--\s+(\S+)\s+(\S+)', 'Compiled')
    QuiltRow    = [regex]::new('^\|\s*\d+\s*\|', 'Compiled')
    ForgeVer    = [regex]::new('--fml\.forgeVersion, ([^,\]\s]+)', 'Compiled')
    NeoVer      = [regex]::new('--fml\.neoForgeVersion, ([^,\]\s]+)', 'Compiled')
    FmlMc       = [regex]::new('--fml\.mcVersion, ([^,\]\s]+)', 'Compiled')
    ModLoading  = [regex]::new('(NeoForge|Forge) mod loading, version (\S+), for MC (\S+)', 'Compiled')
    LegacyFml   = [regex]::new('Forge Mod Loader version (\S+) for Minecraft (\S+)', 'Compiled')
    ForgeFile   = [regex]::new('Found valid mod file (\S+\.jar) with \{([^}]*)\} mods', 'Compiled')
    User        = [regex]::new('Setting user: (\S+)', 'Compiled')
    Resources   = [regex]::new('Reloading ResourceManager: (.+)$', 'Compiled')
    AddedByMods = [regex]::new('added by mods \[([^\]]+)\]', 'Compiled')
    JarToken    = [regex]::new('([^\s\\/\[\]\("''<>|:*?,{}]+\.jar)\b', 'Compiled, IgnoreCase')
    LogDate     = [regex]::new('^(\d{4})-(\d{2})-(\d{2})-\d+\.log', 'Compiled')
    GameDirArg  = [regex]::new('--gameDir\s+(?:"([^"]+)"|(\S+))', 'Compiled, IgnoreCase')
    VersionArg  = [regex]::new('--version\s+(?:"([^"]+)"|(\S+))', 'Compiled, IgnoreCase')
}

#region Descubrimiento de instancias

function Get-AmonRootPaths {
    param([hashtable]$Roots)
    $r = @{ AppData = $env:APPDATA; UserProfile = $env:USERPROFILE; LocalAppData = $env:LOCALAPPDATA }
    if ($Roots) { foreach ($k in @($Roots.Keys)) { $r[$k] = $Roots[$k] } }
    return $r
}

function New-AmonInstance {
    param(
        [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Launcher,
        [Parameter(Mandatory = $true)][string]$GameDir, [string]$Source,
        [string[]]$LogDirs, [string[]]$ModsDirs, [string]$Loader, [string]$LoaderVersion, [string]$MinecraftVersion
    )
    if (-not $LogDirs) { $LogDirs = @(Join-Path $GameDir 'logs') }
    if (-not $ModsDirs) { $ModsDirs = @(Join-Path $GameDir 'mods') }
    $versions = Join-Path $GameDir 'versions'
    $config = Join-Path $GameDir 'config'
    [pscustomobject]@{
        PSTypeName       = 'AmonSS.MinecraftInstance'
        Name             = $Name
        Launcher         = $Launcher
        GameDir          = $GameDir
        Source           = $Source
        LogDirs          = @($LogDirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        ModsDirs         = @($ModsDirs | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
        VersionsDir      = $(if (Test-Path -LiteralPath $versions) { $versions } else { $null })
        ConfigDir        = $(if (Test-Path -LiteralPath $config) { $config } else { $null })
        Loader           = $Loader
        LoaderVersion    = $LoaderVersion
        MinecraftVersion = $MinecraftVersion
        Mods             = [System.Collections.Generic.List[object]]::new()
        Sessions         = [System.Collections.Generic.List[object]]::new()
        Versions         = [System.Collections.Generic.List[object]]::new()
        NonStandardDirs  = @()
    }
}

function Get-AmonMmcPackInfo {
    # mmc-pack.json de Prism/PolyMC/MultiMC: componentes con uid y versión.
    param([string]$Path)
    $r = @{ Loader = $null; LoaderVersion = $null; MinecraftVersion = $null }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($c in @($j.components)) {
            switch ([string]$c.uid) {
                'net.minecraft' { $r.MinecraftVersion = [string]$c.version }
                'net.fabricmc.fabric-loader' { $r.Loader = 'Fabric'; $r.LoaderVersion = [string]$c.version }
                'org.quiltmc.quilt-loader' { $r.Loader = 'Quilt'; $r.LoaderVersion = [string]$c.version }
                'net.minecraftforge' { $r.Loader = 'Forge'; $r.LoaderVersion = [string]$c.version }
                'net.neoforged' { $r.Loader = 'NeoForge'; $r.LoaderVersion = [string]$c.version }
                'com.mumfrey.liteloader' { if (-not $r.Loader) { $r.Loader = 'LiteLoader'; $r.LoaderVersion = [string]$c.version } }
            }
        }
    } catch { }
    return $r
}

function Get-AmonInstanceCfgName {
    param([string]$Path)
    try {
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 200)) {
            if ($line -match '^name=(.+)$') { return $Matches[1].Trim() }
        }
    } catch { }
    return $null
}

function Get-AmonCurseForgeInfo {
    param([string]$Path)
    $r = @{ Loader = $null; LoaderVersion = $null; MinecraftVersion = $null; Name = $null }
    try {
        $j = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $r.Name = [string]$j.name
        $r.MinecraftVersion = [string]$j.gameVersion
        $bl = [string]$j.baseModLoader.name
        if ($bl -match '^(forge|neoforge|fabric|quilt)-(.+)$') {
            $r.Loader = @{ forge = 'Forge'; neoforge = 'NeoForge'; fabric = 'Fabric'; quilt = 'Quilt' }[$Matches[1]]
            $r.LoaderVersion = $Matches[2]
        }
    } catch { }
    return $r
}

function Get-AmonJavaProcessGameDirs {
    # --gameDir de los procesos Java vivos (lectura de CIM, sin tocar los procesos).
    $out = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='java.exe' OR Name='javaw.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            $cl = [string]$p.CommandLine
            $m = $script:Rx.GameDirArg.Match($cl)
            if ($m.Success) {
                $gd = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                $v = $script:Rx.VersionArg.Match($cl)
                $out += [pscustomobject]@{ GameDir = $gd; ProcessId = $p.ProcessId; Version = $(if ($v.Success) { if ($v.Groups[1].Success) { $v.Groups[1].Value } else { $v.Groups[2].Value } } else { $null }) }
            }
        }
    } catch { }
    return $out
}

function Find-AmonMinecraftInstance {
    <#
    .SYNOPSIS
        Localiza instancias de Minecraft Java en las rutas conocidas de launchers.
    .PARAMETER Roots
        Permite sustituir APPDATA/USERPROFILE/LOCALAPPDATA (pruebas o análisis de otra raíz).
    #>
    [CmdletBinding()]
    param($Context, [hashtable]$Roots, [string[]]$ExtraPaths = @(), [switch]$SkipProcesses)
    $r = Get-AmonRootPaths $Roots
    $list = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($inst)
        if (-not $inst) { return }
        if ($seen.Add($inst.GameDir.TrimEnd('\'))) { $list.Add($inst) }
    }

    # 1. .minecraft (Minecraft Launcher / TLauncher / Badlion comparten esta carpeta)
    $mc = Join-Path $r.AppData '.minecraft'
    if (Test-Path -LiteralPath $mc) {
        $launcher = 'Minecraft Launcher'
        if (Test-Path -LiteralPath (Join-Path $mc 'TlauncherProfiles.json')) { $launcher = 'TLauncher' }
        $logDirs = @(Join-Path $mc 'logs')
        $bl = Join-Path $mc 'logs\blclient\minecraft'
        if (Test-Path -LiteralPath $bl) { $logDirs += $bl; $launcher += ' / Badlion Client' }
        & $add (New-AmonInstance -Name '.minecraft' -Launcher $launcher -GameDir $mc -Source 'Ruta predeterminada' -LogDirs $logDirs)
        $lp = Join-Path $mc 'launcher_profiles.json'
        if (Test-Path -LiteralPath $lp) {
            try {
                $j = Get-Content -LiteralPath $lp -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $j.profiles.PSObject.Properties) {
                    $gd = [string]$p.Value.gameDir
                    if ($gd -and (Test-AmonLocalPath -Path $gd) -and (Test-Path -LiteralPath $gd)) {
                        $pname = if ($p.Value.name) { [string]$p.Value.name } else { $p.Name }
                        & $add (New-AmonInstance -Name "Perfil: $pname" -Launcher 'Minecraft Launcher' -GameDir $gd -Source 'launcher_profiles.json')
                    }
                }
            } catch { }
        }
    }

    # 2. Lunar Client: cada perfil es un directorio de juego propio
    $lunar = Join-Path $r.UserProfile '.lunarclient'
    if (Test-Path -LiteralPath $lunar) {
        foreach ($pd in @(Get-ChildItem -LiteralPath (Join-Path $lunar 'profiles') -Directory -ErrorAction SilentlyContinue)) {
            if ((Test-Path -LiteralPath (Join-Path $pd.FullName 'mods')) -or (Test-Path -LiteralPath (Join-Path $pd.FullName 'logs'))) {
                & $add (New-AmonInstance -Name "Lunar: $($pd.Name)" -Launcher 'Lunar Client' -GameDir $pd.FullName -Source '.lunarclient\profiles')
            }
        }
    }

    # 3. Feather Client: estructura no documentada; se buscan carpetas mods/user-mods y logs
    $feather = Join-Path $r.AppData '.feather'
    if (Test-Path -LiteralPath $feather) {
        $dirs = Get-AmonChildItemSafe -Path $feather -Include @('mods', 'user-mods', 'logs') -Depth 3 -Directories -MaxItems 50
        $mods = @($dirs | Where-Object { $_.Name -ne 'logs' } | ForEach-Object FullName)
        $logs = @($dirs | Where-Object { $_.Name -eq 'logs' } | ForEach-Object FullName)
        & $add (New-AmonInstance -Name 'Feather' -Launcher 'Feather Client' -GameDir $feather -Source '.feather' -ModsDirs $mods -LogDirs $logs)
    }

    # 4. Prism / PolyMC / MultiMC (formato de instancia común)
    $mmcRoots = @(
        @('Prism Launcher', (Join-Path $r.AppData 'PrismLauncher\instances')),
        @('PolyMC', (Join-Path $r.AppData 'PolyMC\instances'))
    )
    foreach ($pair in $mmcRoots) {
        foreach ($id in @(Get-ChildItem -LiteralPath $pair[1] -Directory -ErrorAction SilentlyContinue)) {
            $gd = $null
            foreach ($sub in '.minecraft', 'minecraft') { $c = Join-Path $id.FullName $sub; if (Test-Path -LiteralPath $c) { $gd = $c; break } }
            if (-not $gd) { continue }
            $name = Get-AmonInstanceCfgName (Join-Path $id.FullName 'instance.cfg'); if (-not $name) { $name = $id.Name }
            $pack = Get-AmonMmcPackInfo (Join-Path $id.FullName 'mmc-pack.json')
            & $add (New-AmonInstance -Name $name -Launcher $pair[0] -GameDir $gd -Source $pair[1] -Loader $pack.Loader -LoaderVersion $pack.LoaderVersion -MinecraftVersion $pack.MinecraftVersion)
        }
    }

    # 5. CurseForge
    foreach ($id in @(Get-ChildItem -LiteralPath (Join-Path $r.UserProfile 'curseforge\minecraft\Instances') -Directory -ErrorAction SilentlyContinue)) {
        $cf = Get-AmonCurseForgeInfo (Join-Path $id.FullName 'minecraftinstance.json')
        $name = if ($cf.Name) { $cf.Name } else { $id.Name }
        & $add (New-AmonInstance -Name $name -Launcher 'CurseForge' -GameDir $id.FullName -Source 'curseforge\minecraft\Instances' -Loader $cf.Loader -LoaderVersion $cf.LoaderVersion -MinecraftVersion $cf.MinecraftVersion)
    }

    # 6. Modrinth App y 7. GDLauncher
    $simpleRoots = @(
        @('Modrinth App', (Join-Path $r.AppData 'ModrinthApp\profiles'), $null),
        @('Modrinth App', (Join-Path $r.AppData 'com.modrinth.theseus\profiles'), $null),
        @('GDLauncher', (Join-Path $r.AppData 'gdlauncher_next\instances'), $null),
        @('GDLauncher', (Join-Path $r.AppData 'gdlauncher_carbon\data\instances'), 'instance')
    )
    foreach ($s in $simpleRoots) {
        foreach ($id in @(Get-ChildItem -LiteralPath $s[1] -Directory -ErrorAction SilentlyContinue)) {
            $gd = if ($s[2]) { Join-Path $id.FullName $s[2] } else { $id.FullName }
            if (Test-Path -LiteralPath $gd) { & $add (New-AmonInstance -Name $id.Name -Launcher $s[0] -GameDir $gd -Source $s[1]) }
        }
    }

    # 8. Rutas configuradas por el operador
    $extra = @($ExtraPaths)
    if ($Context -and $Context.Settings.minecraft.extraInstancePaths) { $extra += @($Context.Settings.minecraft.extraInstancePaths) }
    foreach ($p in $extra) {
        $p = Expand-AmonPath $p
        if ($p -and (Test-Path -LiteralPath $p)) { & $add (New-AmonInstance -Name (Split-Path -Leaf $p) -Launcher 'Ruta configurada' -GameDir $p -Source 'settings.json') }
    }

    # 9. Procesos Java en ejecución (--gameDir)
    if (-not $SkipProcesses) {
        foreach ($g in (Get-AmonJavaProcessGameDirs)) {
            if ($g.GameDir -and (Test-AmonLocalPath -Path $g.GameDir) -and (Test-Path -LiteralPath $g.GameDir)) {
                & $add (New-AmonInstance -Name (Split-Path -Leaf $g.GameDir) -Launcher 'Proceso Java en ejecución' -GameDir $g.GameDir -Source "PID $($g.ProcessId)" -MinecraftVersion $g.Version)
            }
        }
    }
    return $list.ToArray()
}

#endregion

#region Logs

# La coma unaria evita que PowerShell desenrolle el conjunto vacío a $null al devolverlo.
function New-AmonCaseSet { return , ([System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)) }

function Get-AmonMinecraftLogInfo {
    <#
    .SYNOPSIS
        Interpreta un log de Minecraft (texto o .gz) en una sola pasada.
    .PARAMETER Patterns
        Expresiones regulares adicionales; las líneas que coinciden se guardan en NotableLines.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [long]$MaxBytes = 64MB, [regex[]]$Patterns = @())
    $fi = Get-Item -LiteralPath $Path -Force
    $isGz = $fi.Name.EndsWith('.gz', [StringComparison]::OrdinalIgnoreCase)
    $info = [ordered]@{
        PSTypeName = 'AmonSS.MinecraftLog'
        Path = $fi.FullName; FileName = $fi.Name; IsCompressed = $isGz; Length = $fi.Length
        FileCreatedUtc = $fi.CreationTimeUtc; FileModifiedUtc = $fi.LastWriteTimeUtc
        SessionStartUtc = $null; SessionEndUtc = $null; SessionDateSource = $null
        MinecraftVersion = $null; Loader = $null; LoaderVersion = $null; Username = $null; ClientBrand = $null
        TopLevelMods = [System.Collections.Generic.List[object]]::new()
        NestedMods = [System.Collections.Generic.List[object]]::new()
        ForgeModFiles = [System.Collections.Generic.List[string]]::new()
        TopLevelIds = (New-AmonCaseSet); NestedIds = (New-AmonCaseSet); ResourceIds = (New-AmonCaseSet); JarFiles = (New-AmonCaseSet)
        NotableLines = [System.Collections.Generic.List[object]]::new()
        LineCount = 0; Truncated = $false; Error = $null
    }
    $addTop = {
        param($id, $ver)
        if ($id -and $info.TopLevelIds.Add($id)) { $info.TopLevelMods.Add([pscustomobject]@{ Id = $id; Version = $ver }) }
    }
    $firstTime = $null; $lastTimeLine = $null; $inList = $false; $bytes = 0
    $fs = $null; $gz = $null; $reader = $null
    try {
        $fs = Open-AmonReadStream -Path $fi.FullName
        $stream = $fs
        if ($isGz) { $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress); $stream = $gz }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $reader.ReadLine())) {
            $info.LineCount++
            $bytes += $line.Length + 1
            if ($bytes -gt $MaxBytes) { $info.Truncated = $true; break }
            if ($line.Length -gt 0 -and $line[0] -eq '[') {
                $lastTimeLine = $line
                if (-not $firstTime) { $m = $script:Rx.Time.Match($line); if ($m.Success) { $firstTime = New-TimeSpan -Hours $m.Groups[1].Value -Minutes $m.Groups[2].Value -Seconds $m.Groups[3].Value } }
            }
            if ($inList) {
                $m = $script:Rx.TopMod.Match($line)
                if ($m.Success) { & $addTop $m.Groups[1].Value $m.Groups[2].Value; continue }
                $m = $script:Rx.NestedMod.Match($line)
                if ($m.Success) {
                    if ($info.NestedIds.Add($m.Groups[1].Value)) { $info.NestedMods.Add([pscustomobject]@{ Id = $m.Groups[1].Value; Version = $m.Groups[2].Value }) }
                    continue
                }
                if ($script:Rx.QuiltRow.IsMatch($line) -or $line.StartsWith('|')) { } else { $inList = $false }
            }
            if ($line.StartsWith('|') -and $script:Rx.QuiltRow.IsMatch($line)) {
                $cols = $line.Split('|')
                if ($cols.Count -ge 5) { & $addTop $cols[3].Trim() $cols[4].Trim() }
                if ($cols.Count -ge 8) { foreach ($f in ($cols[7] -split ',')) { $n = [IO.Path]::GetFileName($f.Trim()); if ($n -like '*.jar') { [void]$info.JarFiles.Add($n) } } }
                continue
            }
            if ($line.Contains('Loading')) {
                $m = $script:Rx.FabricHead.Match($line)
                if ($m.Success) { $info.MinecraftVersion = $m.Groups[1].Value; $info.Loader = $m.Groups[2].Value; $info.LoaderVersion = $m.Groups[3].Value }
                if ($script:Rx.ModsHeader.IsMatch($line)) { $inList = $true }
                else {
                    $m = $script:Rx.ModsOld.Match($line)
                    if ($m.Success) {
                        foreach ($tok in ($m.Groups[1].Value -split ',\s*')) {
                            $kv = $tok.Split('@'); & $addTop $kv[0].Trim() $(if ($kv.Count -gt 1) { $kv[1].Trim() } else { $null })
                        }
                    }
                }
            }
            if ($line.Contains('--fml.')) {
                $m = $script:Rx.NeoVer.Match($line); if ($m.Success) { $info.Loader = 'NeoForge'; $info.LoaderVersion = $m.Groups[1].Value }
                $m = $script:Rx.ForgeVer.Match($line); if ($m.Success -and $info.Loader -ne 'NeoForge') { $info.Loader = 'Forge'; $info.LoaderVersion = $m.Groups[1].Value }
                $m = $script:Rx.FmlMc.Match($line); if ($m.Success) { $info.MinecraftVersion = $m.Groups[1].Value }
            }
            if ($line.Contains('mod loading, version')) {
                $m = $script:Rx.ModLoading.Match($line)
                if ($m.Success) { $info.Loader = $m.Groups[1].Value; $info.LoaderVersion = $m.Groups[2].Value; $info.MinecraftVersion = $m.Groups[3].Value }
            }
            if ($line.Contains('Forge Mod Loader version')) {
                $m = $script:Rx.LegacyFml.Match($line)
                if ($m.Success) { $info.Loader = 'LegacyForge'; $info.LoaderVersion = $m.Groups[1].Value; $info.MinecraftVersion = $m.Groups[2].Value }
            }
            if ($line.Contains('Found valid mod file')) {
                $m = $script:Rx.ForgeFile.Match($line)
                if ($m.Success) {
                    $jar = [IO.Path]::GetFileName($m.Groups[1].Value)
                    [void]$info.JarFiles.Add($jar); $info.ForgeModFiles.Add($jar)
                    foreach ($id in ($m.Groups[2].Value -split ',')) { & $addTop $id.Trim() $null }
                }
            }
            if (-not $info.Username -and $line.Contains('Setting user:')) { $m = $script:Rx.User.Match($line); if ($m.Success) { $info.Username = $m.Groups[1].Value } }
            if (-not $info.Loader -and $line.Contains('[OptiFine]')) { $info.Loader = 'OptiFine' }
            if (-not $info.ClientBrand) {
                if ($line.Contains('[LC]') -or $line.Contains('[LC Ichor]') -or $line.Contains('LUNARCLIENT_STATUS')) { $info.ClientBrand = 'Lunar Client' }
                elseif ($line.Contains('Badlion')) { $info.ClientBrand = 'Badlion Client' }
                elseif ($line -match '(?i)\bfeather\s*client\b') { $info.ClientBrand = 'Feather Client' }
            }
            if ($line.Contains('Reloading ResourceManager:')) {
                $m = $script:Rx.Resources.Match($line)
                if ($m.Success) { foreach ($t in ($m.Groups[1].Value -split ',\s*')) { $t = $t.Trim(); if ($t -match '^[a-z0-9_\-\.]+$') { [void]$info.ResourceIds.Add($t) } } }
            }
            if ($line.Contains('added by mods [')) {
                foreach ($m in $script:Rx.AddedByMods.Matches($line)) { foreach ($t in ($m.Groups[1].Value -split ',\s*')) { [void]$info.ResourceIds.Add($t.Trim()) } }
            }
            if ($line.IndexOf('.jar', [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $info.JarFiles.Count -lt 5000) {
                foreach ($m in $script:Rx.JarToken.Matches($line)) { [void]$info.JarFiles.Add($m.Groups[1].Value) }
            }
            foreach ($rx in $Patterns) {
                if ($rx.IsMatch($line)) {
                    if ($info.NotableLines.Count -lt 500) { $info.NotableLines.Add([pscustomobject]@{ LineNumber = $info.LineCount; Pattern = $rx.ToString(); Text = $line.Substring(0, [Math]::Min(400, $line.Length)) }) }
                }
            }
        }
    } catch {
        $info.Error = $_.Exception.Message
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($gz) { $gz.Dispose() }
        if ($fs) { $fs.Dispose() }
    }

    # Lunar y vanilla no imprimen la versión: se deduce del JAR del juego citado en trazas
    # (p. ej. "~[1.21.11.jar:?]"). Se marca la fuente para no confundirla con un dato explícito.
    if (-not $info.MinecraftVersion) {
        foreach ($j in $info.JarFiles) {
            if ($j -match '^((?:1\.\d+(?:\.\d+)?)|(?:\d{2}\.\d+(?:\.\d+)?))\.jar$') { $info.MinecraftVersion = $Matches[1] + ' (deducida del JAR del juego)'; break }
        }
    }

    # Fechado de la sesión: la hora sale del log; la fecha, del nombre o de la modificación.
    $lastTime = $null
    if ($lastTimeLine) { $m = $script:Rx.Time.Match($lastTimeLine); if ($m.Success) { $lastTime = New-TimeSpan -Hours $m.Groups[1].Value -Minutes $m.Groups[2].Value -Seconds $m.Groups[3].Value } }
    $dm = $script:Rx.LogDate.Match($fi.Name)
    # Un nombre con fecha imposible (2026-99-99-1.log) no es fiable: se usa la modificación.
    $date = $null
    if ($dm.Success) {
        $y = [int]$dm.Groups[1].Value; $mo = [int]$dm.Groups[2].Value; $dd = [int]$dm.Groups[3].Value
        if ($y -ge 2009 -and $mo -ge 1 -and $mo -le 12 -and $dd -ge 1 -and $dd -le [DateTime]::DaysInMonth($y, $mo)) {
            $date = New-Object DateTime $y, $mo, $dd, 0, 0, 0, ([DateTimeKind]::Local)
        }
    }
    if ($date -and $firstTime) {
        $info.SessionStartUtc = $date.Add($firstTime).ToUniversalTime()
        if ($lastTime) {
            $end = $date.Add($lastTime); if ($lastTime -lt $firstTime) { $end = $end.AddDays(1) }
            $info.SessionEndUtc = $end.ToUniversalTime()
        }
        $info.SessionDateSource = 'Fecha del nombre del archivo + hora registrada en el log'
    } elseif ($firstTime) {
        $mod = $fi.LastWriteTime
        $start = $mod.Date.Add($firstTime)
        if ($lastTime -and $lastTime -lt $firstTime) { $start = $start.AddDays(-1) }
        if ($start -gt $mod) { $start = $start.AddDays(-1) }
        $info.SessionStartUtc = [datetime]::SpecifyKind($start, [DateTimeKind]::Local).ToUniversalTime()
        $info.SessionEndUtc = $fi.LastWriteTimeUtc
        $info.SessionDateSource = 'Fecha de modificación del archivo + hora registrada en el log'
    } else {
        $info.SessionStartUtc = $fi.CreationTimeUtc
        $info.SessionEndUtc = $fi.LastWriteTimeUtc
        $info.SessionDateSource = 'Fechas del sistema de archivos (el log no contiene horas)'
    }
    return [pscustomobject]$info
}

function Get-AmonInstanceLogFiles {
    # latest.log (siempre) + logs rotados modificados dentro de la ventana.
    param([Parameter(Mandatory = $true)]$Instance, [Parameter(Mandatory = $true)]$Context)
    $max = [int]$Context.Settings.limits.maxLogFiles; if ($max -le 0) { $max = 60 }
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $Instance.LogDirs) {
        try {
            foreach ($f in ([IO.DirectoryInfo]$d).GetFiles()) {
                $isLatest = $f.Name -ieq 'latest.log'
                $isRot = $f.Name -match '^\d{4}-\d{2}-\d{2}-\d+\.log(\.gz)?$'
                if ($isLatest -or ($isRot -and $f.LastWriteTimeUtc -ge $Context.SinceUtc)) { $files.Add($f) }
            }
        } catch { }
    }
    return @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $max)
}

#endregion

#region Mods y versiones

function Get-AmonInstanceMods {
    param([Parameter(Mandatory = $true)]$Instance, [Parameter(Mandatory = $true)]$Context)
    $limits = $Context.Settings.limits
    $maxJar = [long]$limits.maxJarSizeMB * 1MB
    $mods = [System.Collections.Generic.List[object]]::new()
    $configNames = @()
    if ($Instance.ConfigDir) { try { $configNames = @(([IO.DirectoryInfo]$Instance.ConfigDir).GetFileSystemInfos() | ForEach-Object Name) } catch { } }
    foreach ($md in $Instance.ModsDirs) {
        $files = Get-AmonChildItemSafe -Path $md -Include @('*.jar', '*.disabled', '*.litemod') -Depth 1 -MaxItems ([int]$limits.maxFilesPerDirectory)
        foreach ($f in $files) {
            if (Test-AmonCancel -Context $Context) { break }
            $disabled = $f.Name.EndsWith('.disabled', [StringComparison]::OrdinalIgnoreCase)
            $tooBig = $f.Length -gt $maxJar
            $sha = if ($tooBig) { $null } else { Get-AmonFileHash -Path $f.FullName -Context $Context }
            $ji = if ($tooBig) { $null } else { Get-AmonJarInfo -Path $f.FullName -MaxEntries ([int]$limits.maxEntriesPerJar) }
            $ids = if ($ji) { @($ji.ModIds) } else { @() }
            $cfg = @()
            # El id viene del JAR (no confiable): comparación literal, nunca como patrón.
            foreach ($id in $ids) { if ($id) { $cfg += @($configNames | Where-Object { $_.StartsWith($id, [StringComparison]::OrdinalIgnoreCase) }) } }
            $mods.Add([pscustomobject]@{
                    PSTypeName     = 'AmonSS.MinecraftMod'
                    Instance       = $Instance.Name
                    Launcher       = $Instance.Launcher
                    FileName       = $f.Name
                    Path           = $f.FullName
                    Length         = $f.Length
                    Sha256         = $sha
                    CreatedUtc     = $f.CreationTimeUtc
                    ModifiedUtc    = $f.LastWriteTimeUtc
                    Disabled       = $disabled
                    TooLarge       = $tooBig
                    Loader         = $(if ($ji) { $ji.Loader } else { 'Unknown' })
                    ModIds         = $ids
                    ModId          = ($ids -join ', ')
                    ModName        = $(if ($ji) { $ji.ModName } else { $null })
                    Version        = $(if ($ji) { $ji.ModVersion } else { $null })
                    IsJavaAgent    = $(if ($ji) { $ji.IsJavaAgent } else { $false })
                    HasModMetadata = $(if ($ji) { $ji.HasModMetadata } else { $false })
                    IsValidZip     = $(if ($ji) { $ji.IsValidZip } else { $null })
                    JarInfo        = $ji
                    ConfigFiles    = @($cfg | Select-Object -Unique)
                    Loaded         = 'Sin logs'
                    LoadEvidence   = [System.Collections.Generic.List[string]]::new()
                    LastLoadedUtc  = $null
                })
        }
    }
    return $mods.ToArray()
}

function Set-AmonModLoadState {
    # Cruza mods instalados con las sesiones de log: lista de mods, JAR citados o recursos.
    param([object[]]$Mods, [object[]]$Sessions)
    foreach ($mod in $Mods) {
        if (-not $Sessions -or $Sessions.Count -eq 0) { $mod.Loaded = 'Sin logs'; continue }
        $nameKey = $mod.FileName -replace '\.disabled$', ''
        $found = $false
        foreach ($s in $Sessions) {
            $how = $null
            foreach ($id in $mod.ModIds) {
                if ($s.TopLevelIds.Contains($id) -or $s.NestedIds.Contains($id)) { $how = "lista de mods ($id)"; break }
            }
            if (-not $how -and $s.JarFiles.Contains($nameKey)) { $how = 'JAR citado en el log' }
            if (-not $how) { foreach ($id in $mod.ModIds) { if ($s.ResourceIds.Contains($id)) { $how = "recursos del mod ($id)"; break } } }
            if ($how) {
                $found = $true
                $when = if ($s.SessionStartUtc) { Format-AmonTimestamp $s.SessionStartUtc } else { '' }
                $mod.LoadEvidence.Add("$($s.FileName) $when - $how")
                if (-not $mod.LastLoadedUtc -or ($s.SessionStartUtc -and $s.SessionStartUtc -gt $mod.LastLoadedUtc)) { $mod.LastLoadedUtc = $s.SessionStartUtc }
            }
        }
        $mod.Loaded = if ($found) { 'Sí' } else { 'No' }
    }
}

function Get-AmonJsonArgStrings {
    # Aplana arguments.jvm: cadenas u objetos { rules, value (cadena o lista) }.
    param($Node)
    $out = @()
    foreach ($item in @($Node)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $out += $item }
        elseif ($item.PSObject.Properties['value']) { foreach ($v in @($item.value)) { $out += [string]$v } }
    }
    return $out
}

function Get-AmonMinecraftVersions {
    <#
    .SYNOPSIS
        Analiza versions\<id>\<id>.json: clase principal, loader, -javaagent y SHA-1 del JAR.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'Mojang declara el SHA-1 del cliente en el JSON de versión; se compara con ese valor, no se usa para seguridad.')]
    param([Parameter(Mandatory = $true)][string]$VersionsDir, $Context, [string]$InstanceName)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in @(Get-ChildItem -LiteralPath $VersionsDir -Directory -ErrorAction SilentlyContinue)) {
        $jsonPath = Join-Path $dir.FullName "$($dir.Name).json"
        if (-not (Test-Path -LiteralPath $jsonPath)) {
            $alt = Get-ChildItem -LiteralPath $dir.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $alt) { continue }
            $jsonPath = $alt.FullName
        }
        $j = $null; $err = $null
        try { $j = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { $err = $_.Exception.Message }
        $id = if ($j -and $j.id) { [string]$j.id } else { $dir.Name }
        $mainClass = if ($j) { [string]$j.mainClass } else { $null }
        $jvm = @()
        if ($j -and $j.arguments -and $j.arguments.jvm) { $jvm = Get-AmonJsonArgStrings $j.arguments.jvm }
        $agents = @($jvm | Where-Object { $_ -match '^-javaagent:' })
        $libs = @(); if ($j -and $j.libraries) { $libs = @($j.libraries | ForEach-Object { [string]$_.name }) }
        $loader = 'Vanilla'
        $libText = $libs -join ' '
        if ($libText -match 'net\.fabricmc:fabric-loader' -or $mainClass -like 'net.fabricmc.*') { $loader = 'Fabric' }
        elseif ($libText -match 'org\.quiltmc:quilt-loader' -or $mainClass -like 'org.quiltmc.*') { $loader = 'Quilt' }
        elseif ($libText -match 'net\.neoforged') { $loader = 'NeoForge' }
        elseif ($libText -match 'net\.minecraftforge') { $loader = 'Forge' }
        elseif ($libText -match '(?i)optifine') { $loader = 'OptiFine' }
        elseif ($mainClass -eq 'net.minecraft.launchwrapper.Launch') { $loader = 'LaunchWrapper' }
        elseif ($j -and $j.inheritsFrom) { $loader = 'Desconocido (hereda de ' + $j.inheritsFrom + ')' }
        $jar = Join-Path $dir.FullName "$id.jar"
        if (-not (Test-Path -LiteralPath $jar)) { $jar = Join-Path $dir.FullName "$($dir.Name).jar" }
        $jarExists = Test-Path -LiteralPath $jar
        $declared = $null
        if ($j -and $j.downloads -and $j.downloads.client) { $declared = [string]$j.downloads.client.sha1 }
        $actual = $null; $status = 'NoJar'
        if ($jarExists) {
            if ($declared) {
                $actual = Get-AmonFileHash -Path $jar -Algorithm SHA1 -Context $Context
                $status = if ($actual -and $actual -ieq $declared) { 'Verified' } elseif ($actual) { 'Mismatch' } else { 'Unreadable' }
            } else { $status = 'NotDeclared' }
        }
        $out.Add([pscustomobject]@{
                PSTypeName      = 'AmonSS.MinecraftVersion'
                Instance        = $InstanceName
                Id              = $id
                JsonPath        = $jsonPath
                JarPath         = $(if ($jarExists) { $jar } else { $null })
                InheritsFrom    = $(if ($j) { [string]$j.inheritsFrom } else { $null })
                Type            = $(if ($j) { [string]$j.type } else { $null })
                MainClass       = $mainClass
                MainClassKnown  = [bool]($mainClass -and ($script:KnownMainClasses -contains $mainClass))
                Loader          = $loader
                JavaAgents      = $agents
                JvmArgs         = $jvm
                LibraryCount    = $libs.Count
                DeclaredSha1    = $declared
                ActualSha1      = $actual
                HashStatus      = $status
                JsonModifiedUtc = (Get-Item -LiteralPath $jsonPath -Force).LastWriteTimeUtc
                JarModifiedUtc  = $(if ($jarExists) { (Get-Item -LiteralPath $jar -Force).LastWriteTimeUtc } else { $null })
                ParseError      = $err
            })
    }
    return $out.ToArray()
}

#endregion

#region Módulo

function Invoke-AmonMinecraftAnalysis {
    <#
    .SYNOPSIS
        Ejecuta el análisis de Minecraft y devuelve un AmonSS.ModuleResult.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [hashtable]$Roots, [switch]$SkipProcesses)
    $res = New-AmonModuleResult -Module 'Minecraft' -DisplayName 'Minecraft Analysis'
    # Repetir el análisis sustituye las instancias anteriores en lugar de acumularlas.
    $Context.Instances.Clear()
    $instances = @(Find-AmonMinecraftInstance -Context $Context -Roots $Roots -SkipProcesses:$SkipProcesses)
    $res.Data['Instances'] = [System.Collections.Generic.List[object]]::new()
    $res.Data['Versions'] = [System.Collections.Generic.List[object]]::new()
    $res.Data['Sessions'] = [System.Collections.Generic.List[object]]::new()
    if (-not $instances.Count) {
        $res.Warnings.Add('No se encontraron instancias de Minecraft Java en las rutas conocidas. Si el jugador usa un launcher portable, añade la ruta en Settings (extraInstancePaths).')
        return Complete-AmonModuleResult -Result $res
    }
    $standard = @($Context.Settings.minecraft.standardGameDirectories)
    $maxLog = [long]$Context.Settings.limits.maxLogSizeMB * 1MB
    $n = $instances.Count; $i = 0
    foreach ($inst in $instances) {
        if (Test-AmonCancel -Context $Context) { break }
        $i++
        Update-AmonProgress -Context $Context -Percent (100.0 * ($i - 1) / $n) -Detail $inst.Name -Count $res.ArtifactsReviewed
        $res.Scope.Add($inst.GameDir)

        foreach ($lf in (Get-AmonInstanceLogFiles -Instance $inst -Context $Context)) {
            if (Test-AmonCancel -Context $Context) { break }
            # Un log que no se puede interpretar se anota y no detiene el resto de la instancia.
            try { $log = Get-AmonMinecraftLogInfo -Path $lf.FullName -MaxBytes $maxLog }
            catch { $res.Warnings.Add("No se pudo interpretar $($lf.FullName): $($_.Exception.Message)"); continue }
            $inst.Sessions.Add($log)
            $res.ArtifactsReviewed++
            if ($log.Error) { $res.Warnings.Add("No se pudo leer por completo $($log.Path): $($log.Error)") }
            if ($log.Truncated) { $res.Limitations.Add("Log truncado por tamaño: $($log.Path)") }
        }
        $sessions = @($inst.Sessions | Sort-Object { $_.SessionStartUtc } -Descending)
        $latest = $sessions | Where-Object { $_.Loader -or $_.MinecraftVersion } | Select-Object -First 1
        if ($latest) {
            if (-not $inst.Loader -and $latest.Loader) { $inst.Loader = $latest.Loader; $inst.LoaderVersion = $latest.LoaderVersion }
            if (-not $inst.MinecraftVersion -and $latest.MinecraftVersion) { $inst.MinecraftVersion = $latest.MinecraftVersion }
        }

        $mods = @(Get-AmonInstanceMods -Instance $inst -Context $Context)
        $res.ArtifactsReviewed += $mods.Count
        Set-AmonModLoadState -Mods $mods -Sessions $sessions
        foreach ($m in $mods) { $inst.Mods.Add($m) }
        if (-not $inst.Loader) {
            $guess = $mods | Where-Object { $_.Loader -notin @('Unknown', 'Standalone') } | Group-Object Loader | Sort-Object Count -Descending | Select-Object -First 1
            if ($guess) { $inst.Loader = "$($guess.Name) (según metadatos de los mods)" }
        }

        if ($inst.VersionsDir) {
            foreach ($v in (Get-AmonMinecraftVersions -VersionsDir $inst.VersionsDir -Context $Context -InstanceName $inst.Name)) {
                $inst.Versions.Add($v); $res.Data['Versions'].Add($v); $res.ArtifactsReviewed++
            }
        }
        try {
            $inst.NonStandardDirs = @(([IO.DirectoryInfo]$inst.GameDir).GetDirectories() | Where-Object { $standard -notcontains $_.Name -and -not $_.Name.StartsWith('.') } | ForEach-Object Name)
        } catch { }

        # Artefactos (tabla de mods)
        foreach ($m in $mods) {
            $res.Artifacts.Add([pscustomobject]@{
                    Instance = $m.Instance; Launcher = $m.Launcher; FileName = $m.FileName; ModId = $m.ModId; Version = $m.Version
                    Loader = $m.Loader; Loaded = $(if ($m.Disabled -and $m.Loaded -eq 'No') { 'No (desactivado)' } else { $m.Loaded }); LastLoadedUtc = $m.LastLoadedUtc
                    CreatedUtc = $m.CreatedUtc; ModifiedUtc = $m.ModifiedUtc; Sha256 = $m.Sha256; Path = $m.Path
                    Disabled = $m.Disabled; IsJavaAgent = $m.IsJavaAgent; HasModMetadata = $m.HasModMetadata
                    LoadEvidence = @($m.LoadEvidence); ConfigFiles = $m.ConfigFiles
                })
            if (Test-AmonInWindow -Context $Context -Utc $m.CreatedUtc) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $m.CreatedUtc -Type 'JAR de mod creado o copiado' -Kind Creation -Source 'Minecraft (sistema de archivos)' -Path $m.Path -Sha256 $m.Sha256 -Confidence Medium -Description "Fecha de creación NTFS del archivo en $($m.Instance)."))
            }
            if ((Test-AmonInWindow -Context $Context -Utc $m.ModifiedUtc) -and [Math]::Abs(($m.ModifiedUtc - $m.CreatedUtc).TotalSeconds) -gt 2) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $m.ModifiedUtc -Type 'JAR de mod modificado' -Kind Modification -Source 'Minecraft (sistema de archivos)' -Path $m.Path -Sha256 $m.Sha256 -Confidence Medium -Description 'Fecha de última modificación NTFS.'))
            }
            if ($m.IsJavaAgent) {
                $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'JavaAgentJar' -Title 'JAR con atributos de javaagent en la carpeta de mods' -Status INCONCLUSIVE -Severity Low -Confidence Low `
                            -Path $m.Path -Sha256 $m.Sha256 -TimestampUtc $m.ModifiedUtc -Indicator ('Premain/Agent-Class: ' + (@($m.JarInfo.Manifest['Premain-Class'], $m.JarInfo.Manifest['Agent-Class']) -join ' ').Trim()) -IndicatorType 'manifest' `
                            -Justification 'Un mod normal no necesita declararse como agente Java; los clientes inyectados por -javaagent sí. Requiere revisar si el JAR es una librería legítima.' `
                            -FalsePositives @('Algunas librerías de perfilado o compatibilidad incluyen Premain-Class aunque no se usen como agente.')))
            }
            if ($m.IsValidZip -eq $false) {
                $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'InvalidJar' -Title 'Archivo .jar que no es un ZIP válido' -Status INCONCLUSIVE -Severity Low -Confidence Low -Path $m.Path -Sha256 $m.Sha256 `
                            -Justification 'El archivo tiene extensión de mod pero no es un JAR legible: puede estar dañado, cifrado o ser otro tipo de archivo renombrado.' -FalsePositives @('Descarga incompleta o archivo corrupto.')))
            }
        }

        # Mods cargados en sesiones de la ventana que ya no están instalados
        $installedIds = New-AmonCaseSet; $installedJars = New-AmonCaseSet
        foreach ($m in $mods) { foreach ($id in $m.ModIds) { [void]$installedIds.Add($id) }; [void]$installedJars.Add(($m.FileName -replace '\.disabled$', '')) }
        $removed = @{}
        foreach ($s in $sessions) {
            $inWin = (Test-AmonInWindow -Context $Context -Utc $s.SessionStartUtc) -or (Test-AmonInWindow -Context $Context -Utc $s.FileModifiedUtc)
            if (-not $inWin) { continue }
            foreach ($tm in $s.TopLevelMods) {
                if ($script:PlatformModIds -contains $tm.Id -or $installedIds.Contains($tm.Id)) { continue }
                if (-not $removed.ContainsKey($tm.Id)) { $removed[$tm.Id] = [System.Collections.Generic.List[object]]::new() }
                $removed[$tm.Id].Add(@($s, $tm.Version))
            }
            foreach ($jar in $s.ForgeModFiles) {
                if ($installedJars.Contains($jar)) { continue }
                $key = "jar:$jar"
                if (-not $removed.ContainsKey($key)) { $removed[$key] = [System.Collections.Generic.List[object]]::new() }
                $removed[$key].Add(@($s, $null))
            }
        }
        foreach ($k in $removed.Keys) {
            $occ = $removed[$k]
            $first = $occ[0][0]
            $ev = @($occ | ForEach-Object { New-AmonEvidence -Source 'Minecraft (log)' -Kind LogLoaded -Path $_[0].Path -TimestampUtc $_[0].SessionStartUtc -Description ("{0}: cargado{1} en la sesión del {2}" -f $_[0].FileName, $(if ($_[1]) { " v$($_[1])" } else { '' }), (Format-AmonTimestamp $_[0].SessionStartUtc)) })
            $label = $k -replace '^jar:', ''
            $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'RemovedMod' -Title "Mod cargado que ya no está instalado: $label" -Status DETECTED -Severity Low -Confidence Medium `
                        -Path $first.Path -TimestampUtc $first.SessionStartUtc -Indicator $label -IndicatorType $(if ($k -like 'jar:*') { 'jar' } else { 'modid' }) -Evidence $ev `
                        -Justification ("Los logs de $($inst.Name) muestran que '$label' se cargó dentro del periodo analizado, pero ningún JAR instalado en la carpeta mods declara ese id o nombre.") `
                        -FalsePositives @('El mod pudo actualizarse con otro id, moverse a otra instancia o desinstalarse legítimamente.')))
        }

        # Perfiles de versión
        foreach ($v in $inst.Versions) {
            foreach ($a in $v.JavaAgents) {
                $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'VersionJavaAgent' -Title "Argumento -javaagent en el perfil de versión '$($v.Id)'" -Status INCONCLUSIVE -Severity Medium -Confidence Medium `
                            -Path $v.JsonPath -TimestampUtc $v.JsonModifiedUtc -Indicator $a -IndicatorType 'javaagent' `
                            -Justification 'El perfil de versión inyecta un agente Java al arrancar el juego. Es el mecanismo que usan varios clientes inyectados; hay que identificar el JAR del agente.' `
                            -FalsePositives @('Herramientas de perfilado o depuración configuradas a propósito.')))
                $agentPath = ($a -replace '^-javaagent:', '') -replace '=.*$', ''
                if ($agentPath) { Add-AmonEvidencePath -Context $Context -Path $agentPath -Source 'Minecraft (perfil de versión)' -Reason '-javaagent' }
            }
            if ($v.MainClass -and -not $v.MainClassKnown) {
                $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'VersionMainClass' -Title "Clase principal no reconocida en '$($v.Id)'" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                            -Path $v.JsonPath -TimestampUtc $v.JsonModifiedUtc -Indicator $v.MainClass -IndicatorType 'mainClass' `
                            -Justification 'La clase principal no es la de vanilla ni la de un loader documentado (Fabric, Quilt, Forge, NeoForge, LaunchWrapper). Puede ser un launcher o cliente propio.' `
                            -FalsePositives @('Launchers y clientes legítimos con arranque propio (LabyMod, Lunar, Badlion, OptiFine antiguos).')))
            }
            if ($v.HashStatus -eq 'Mismatch') {
                $res.Findings.Add((New-AmonFinding -Module 'Minecraft' -Category 'VersionJarModified' -Title "JAR de versión '$($v.Id)' distinto al declarado por Mojang" -Status DETECTED -Severity Medium -Confidence Medium `
                            -Path $v.JarPath -TimestampUtc $v.JarModifiedUtc -Indicator "SHA-1 declarado $($v.DeclaredSha1) / real $($v.ActualSha1)" -IndicatorType 'sha1' `
                            -Justification 'El JSON de la versión declara el SHA-1 oficial del cliente y el JAR presente no coincide: el cliente vanilla fue modificado o sustituido.' `
                            -FalsePositives @('Instaladores antiguos que parchean el JAR (p. ej. OptiFine pre-1.14 en el mismo id) o un JSON editado a mano.')))
                Add-AmonEvidencePath -Context $Context -Path $v.JarPath -Source 'Minecraft (versión)' -Reason 'JAR de versión modificado'
            }
            if (Test-AmonInWindow -Context $Context -Utc $v.JsonModifiedUtc) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $v.JsonModifiedUtc -Type 'Perfil de versión modificado' -Kind Modification -Source 'Minecraft (versions)' -Path $v.JsonPath -Confidence Medium))
            }
        }

        # Sesiones -> eventos
        foreach ($s in $sessions) {
            $res.Data['Sessions'].Add([pscustomobject]@{
                    Instance = $inst.Name; Path = $s.Path; FileName = $s.FileName; StartUtc = $s.SessionStartUtc; EndUtc = $s.SessionEndUtc
                    MinecraftVersion = $s.MinecraftVersion; Loader = $s.Loader; LoaderVersion = $s.LoaderVersion; Username = $s.Username
                    ClientBrand = $s.ClientBrand; ModCount = $s.TopLevelMods.Count; DateSource = $s.SessionDateSource
                })
            if ($s.SessionStartUtc -and (Test-AmonInWindow -Context $Context -Utc $s.SessionStartUtc)) {
                $desc = 'Sesión registrada en el log'
                if ($s.Loader) { $desc += "; loader $($s.Loader) $($s.LoaderVersion)" }
                if ($s.MinecraftVersion) { $desc += "; Minecraft $($s.MinecraftVersion)" }
                if ($s.TopLevelMods.Count) { $desc += "; $($s.TopLevelMods.Count) mods en la lista" }
                if ($s.ClientBrand) { $desc += "; $($s.ClientBrand)" }
                $res.Events.Add((New-AmonEvent -TimestampUtc $s.SessionStartUtc -Type 'Sesión de Minecraft' -Kind Execution -Source 'Minecraft (log)' -Path $s.Path -Confidence Medium -Description $desc))
            }
        }

        $res.Data['Instances'].Add([pscustomobject]@{
                Name = $inst.Name; Launcher = $inst.Launcher; GameDir = $inst.GameDir; Loader = $inst.Loader; LoaderVersion = $inst.LoaderVersion
                MinecraftVersion = $inst.MinecraftVersion; Mods = $mods.Count; LoadedMods = @($mods | Where-Object Loaded -EQ 'Sí').Count
                Logs = $inst.Sessions.Count; Versions = $inst.Versions.Count; NonStandardDirs = $inst.NonStandardDirs; Source = $inst.Source
            })
        $Context.Instances.Add($inst)
    }
    Update-AmonProgress -Context $Context -Percent 100 -Detail 'Minecraft' -Count $res.ArtifactsReviewed
    if (@($instances | Where-Object Launcher -EQ 'Lunar Client').Count) {
        $res.Limitations.Add('Lunar Client no imprime la lista estándar de mods de Fabric: la evidencia de carga se basa en JAR citados y recursos del log, y puede ser incompleta.')
    }
    return Complete-AmonModuleResult -Result $res
}

#endregion

Export-ModuleMember -Function @(
    'Find-AmonMinecraftInstance', 'Get-AmonMinecraftLogInfo', 'Get-AmonInstanceLogFiles', 'Get-AmonInstanceMods',
    'Set-AmonModLoadState', 'Get-AmonMinecraftVersions', 'Get-AmonJavaProcessGameDirs', 'Invoke-AmonMinecraftAnalysis',
    'Get-AmonMmcPackInfo'
)
