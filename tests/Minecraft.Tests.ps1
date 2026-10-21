BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Jar, Minecraft

    function New-FabricModJar([string]$Path, [string]$Id, [string]$Version = '1.0.0') {
        New-AmonTestJar -Path $Path -Entries @{ 'fabric.mod.json' = ('{"schemaVersion":1,"id":"' + $Id + '","version":"' + $Version + '"}') } | Out-Null
    }

    $script:FabricLog = @"
[12:00:00] [main/INFO]: Loading Minecraft 1.20.1 with Fabric Loader 0.15.11
[12:00:00] [main/INFO]: Loading 6 mods:
	- fabric-api 0.92.2+1.20.1
	   |-- fabric-api-base 0.4.31+1802ada577
	- fabricloader 0.15.11
	- java 17
	- minecraft 1.20.1
	- moda 1.0.0
	- modc 3.1.0
[12:00:02] [Render thread/INFO]: Setting user: Steve
[12:00:05] [Render thread/INFO]: Backend library: LWJGL version 3.3.1
[12:30:00] [Render thread/INFO]: Stopping!
"@
}

Describe 'Minecraft: análisis de logs' -Tag 'Unit' {
    It 'interpreta la lista de mods de Fabric (formato actual)' {
        $p = New-AmonTestFile -Path (Join-Path $TestDrive 'fabric\latest.log') -Text $script:FabricLog
        $l = Get-AmonMinecraftLogInfo -Path $p
        $l.MinecraftVersion | Should -Be '1.20.1'
        $l.Loader | Should -Be 'Fabric'
        $l.LoaderVersion | Should -Be '0.15.11'
        $l.Username | Should -Be 'Steve'
        ($l.TopLevelMods | ForEach-Object Id) | Should -Contain 'modc'
        ($l.NestedMods | ForEach-Object Id) | Should -Contain 'fabric-api-base'
        ($l.TopLevelMods | ForEach-Object Id) | Should -Not -Contain 'fabric-api-base'
    }

    It 'interpreta el formato antiguo de Fabric' {
        $p = New-AmonTestFile -Path (Join-Path $TestDrive 'old\latest.log') -Text "[10:00:00] [main/INFO]: Loading 3 mods: fabric@0.28.4+1.16, fabricloader@0.11.1, minecraft@1.16.5`n"
        $ids = (Get-AmonMinecraftLogInfo -Path $p).TopLevelMods | ForEach-Object Id
        $ids | Should -Contain 'fabric'
        $ids | Should -Contain 'minecraft'
    }

    It 'interpreta Forge: versión, loader y archivos de mod' {
        $text = @"
[20oct.2026 10:00:00.000] [main/INFO] [cpw.mods.modlauncher.Launcher/MODLAUNCHER]: ModLauncher running: args [--username, Alex, --version, 1.20.1-forge-47.2.0, --gameDir, C:\mc, --fml.forgeVersion, 47.2.0, --fml.mcVersion, 1.20.1, --fml.forgeGroup, net.minecraftforge]
[20oct.2026 10:00:03.000] [main/INFO] [ne.mi.fm.lo.mo.ModFileParser/LOADING]: Found valid mod file jei-1.20.1-forge.jar with {jei} mods - versions {15.2.0}
"@
        $p = New-AmonTestFile -Path (Join-Path $TestDrive 'forge\latest.log') -Text $text
        $l = Get-AmonMinecraftLogInfo -Path $p
        $l.Loader | Should -Be 'Forge'
        $l.LoaderVersion | Should -Be '47.2.0'
        $l.MinecraftVersion | Should -Be '1.20.1'
        $l.JarFiles | Should -Contain 'jei-1.20.1-forge.jar'
        ($l.TopLevelMods | ForEach-Object Id) | Should -Contain 'jei'
    }

    It 'lee logs rotados comprimidos y fecha la sesión por el nombre' {
        $p = Join-Path $TestDrive '2026-10-18-1.log.gz'
        New-AmonTestGzip -Path $p -Text $script:FabricLog
        $l = Get-AmonMinecraftLogInfo -Path $p
        $l.IsCompressed | Should -BeTrue
        $l.Loader | Should -Be 'Fabric'
        $l.SessionStartUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-10-18 12:00'
    }

    It 'un log con fecha imposible en el nombre no rompe el análisis' {
        $p = New-AmonTestFile -Path (Join-Path $TestDrive 'logs\2026-99-99-1.log') -Text "[10:00:00] [main/INFO]: Loading Minecraft 1.21 with Fabric Loader 0.16.0`n"
        $i = Get-AmonMinecraftLogInfo -Path $p
        $i.Loader | Should -Be 'Fabric'
        $i.SessionStartUtc | Should -Not -BeNullOrEmpty
        $i.SessionDateSource | Should -Match 'modificación'
    }

    It 'reconoce Lunar Client y los ids de recursos cargados' {
        $text = @"
[21:24:35] [Render thread/INFO]: [LC] Enabling OpenGL No Error Context
[21:24:40] [Render thread/INFO]: Reloading ResourceManager: lunar, vanilla, sodium, file/MyPack.zip, iris
[21:24:42] [Render thread/INFO]: [LC] Starting Lunar client...
"@
        $p = New-AmonTestFile -Path (Join-Path $TestDrive 'lunar\latest.log') -Text $text
        $l = Get-AmonMinecraftLogInfo -Path $p
        $l.ClientBrand | Should -Be 'Lunar Client'
        $l.ResourceIds | Should -Contain 'sodium'
        $l.ResourceIds | Should -Not -Contain 'file/MyPack.zip'
    }
}

Describe 'Minecraft: descubrimiento de instancias' -Tag 'Unit' {
    It 'encuentra .minecraft, perfiles de Lunar e instancias de Prism' {
        $roam = Join-Path $TestDrive 'disc\Roaming'; $userHome = Join-Path $TestDrive 'disc\Home'
        New-Item -ItemType Directory -Force -Path "$roam\.minecraft\mods", "$roam\.minecraft\logs", "$userHome\.lunarclient\profiles\1.21\mods", "$userHome\.lunarclient\profiles\1.21\logs" | Out-Null
        New-Item -ItemType Directory -Force -Path "$roam\PrismLauncher\instances\Pack\.minecraft\mods" | Out-Null
        New-AmonTestFile -Path "$roam\PrismLauncher\instances\Pack\instance.cfg" -Text "InstanceType=OneSix`nname=Mi Pack`n" | Out-Null
        New-AmonTestFile -Path "$roam\PrismLauncher\instances\Pack\mmc-pack.json" -Text '{"components":[{"uid":"net.minecraft","version":"1.20.4"},{"uid":"net.fabricmc.fabric-loader","version":"0.15.7"}],"formatVersion":1}' | Out-Null
        $ctx = New-AmonTestContext
        $inst = Find-AmonMinecraftInstance -Context $ctx -Roots @{ AppData = $roam; UserProfile = $userHome; LocalAppData = (Join-Path $TestDrive 'disc\Local') } -SkipProcesses
        ($inst | ForEach-Object Launcher) | Should -Contain 'Minecraft Launcher'
        ($inst | ForEach-Object Launcher) | Should -Contain 'Lunar Client'
        $prism = $inst | Where-Object Launcher -EQ 'Prism Launcher'
        $prism.Name | Should -Be 'Mi Pack'
        $prism.Loader | Should -Be 'Fabric'
        $prism.MinecraftVersion | Should -Be '1.20.4'
    }
}

Describe 'Minecraft: mods instalados frente a cargados' -Tag 'Unit' {
    BeforeAll {
        $script:roam = Join-Path $TestDrive 'an\Roaming'; $script:userHome = Join-Path $TestDrive 'an\Home'
        $gd = "$script:roam\.minecraft"
        New-FabricModJar "$gd\mods\moda.jar" 'moda'
        New-FabricModJar "$gd\mods\modb.jar" 'modb'
        New-AmonTestFile -Path "$gd\logs\latest.log" -Text $script:FabricLog | Out-Null
        $script:ctx = New-AmonTestContext
        $script:res = Invoke-AmonMinecraftAnalysis -Context $script:ctx -Roots @{ AppData = $script:roam; UserProfile = $script:userHome; LocalAppData = (Join-Path $TestDrive 'an\Local') } -SkipProcesses
    }

    It 'marca como cargado el mod que aparece en el log' {
        ($script:res.Artifacts | Where-Object FileName -EQ 'moda.jar').Loaded | Should -Be 'Sí'
    }

    It 'distingue un mod instalado sin evidencia de carga' {
        ($script:res.Artifacts | Where-Object FileName -EQ 'modb.jar').Loaded | Should -Be 'No'
    }

    It 'avisa de un mod cargado que ya no está instalado, sin contar los integrados' {
        $f = @($script:res.Findings | Where-Object Category -EQ 'RemovedMod')
        ($f | ForEach-Object Indicator) | Should -Contain 'modc'
        ($f | ForEach-Object Indicator) | Should -Not -Contain 'minecraft'
        ($f | ForEach-Object Indicator) | Should -Not -Contain 'fabric-api'
    }

    It 'registra la instancia en el contexto y genera eventos de timeline' {
        $script:ctx.Instances.Count | Should -BeGreaterThan 0
        @($script:res.Events | Where-Object Kind -EQ 'Execution').Count | Should -BeGreaterThan 0
        $script:res.Status | Should -Be 'Completed'
    }

    It 'incluye el hash SHA-256 y la ruta completa de cada JAR' {
        $a = $script:res.Artifacts | Where-Object FileName -EQ 'moda.jar'
        $a.Sha256 | Should -Match '^[0-9a-f]{64}$'
        $a.Path | Should -Be (Join-Path "$script:roam\.minecraft\mods" 'moda.jar')
    }

    It 'un id de mod con caracteres comodín no rompe el análisis' {
        $roam = Join-Path $TestDrive 'wild\Roaming'; $gd = "$roam\.minecraft"
        New-FabricModJar "$gd\mods\weird.jar" '[x'
        New-Item -ItemType Directory -Force -Path "$gd\config\[x-settings" | Out-Null
        $ctx = New-AmonTestContext
        $r = Invoke-AmonMinecraftAnalysis -Context $ctx -Roots @{ AppData = $roam; UserProfile = (Join-Path $TestDrive 'wild\Home'); LocalAppData = (Join-Path $TestDrive 'wild\Local') } -SkipProcesses
        $r.Status | Should -Be 'Completed'
        ($r.Artifacts | Where-Object FileName -EQ 'weird.jar').ConfigFiles | Should -Contain '[x-settings'
    }
}

Describe 'Minecraft: perfiles de versión' -Tag 'Unit' {
    BeforeAll {
        $vd = Join-Path $TestDrive 'ver\versions'
        New-AmonTestFile -Path "$vd\hacked\hacked.json" -Text '{"id":"hacked","inheritsFrom":"1.20.1","mainClass":"com.evil.Main","arguments":{"jvm":["-javaagent:C:\\x\\agent.jar",{"rules":[],"value":["-Dfoo=bar"]}]}}' | Out-Null
        New-Item -ItemType Directory -Force -Path "$vd\1.20.1", "$vd\1.19.4" | Out-Null
        [IO.File]::WriteAllBytes("$vd\1.20.1\1.20.1.jar", [Text.Encoding]::ASCII.GetBytes('modified'))
        New-AmonTestFile -Path "$vd\1.20.1\1.20.1.json" -Text '{"id":"1.20.1","mainClass":"net.minecraft.client.main.Main","downloads":{"client":{"sha1":"a9993e364706816aba3e25717850c26c9cd0d89d"}}}' | Out-Null
        [IO.File]::WriteAllBytes("$vd\1.19.4\1.19.4.jar", [Text.Encoding]::ASCII.GetBytes('abc'))
        New-AmonTestFile -Path "$vd\1.19.4\1.19.4.json" -Text '{"id":"1.19.4","mainClass":"net.minecraft.client.main.Main","downloads":{"client":{"sha1":"a9993e364706816aba3e25717850c26c9cd0d89d"}}}' | Out-Null
        $script:vers = Get-AmonMinecraftVersions -VersionsDir $vd -Context (New-AmonTestContext)
    }

    It 'señala argumentos -javaagent en el perfil' {
        ($script:vers | Where-Object Id -EQ 'hacked').JavaAgents | Should -Contain '-javaagent:C:\x\agent.jar'
    }

    It 'señala una clase principal no reconocida' {
        ($script:vers | Where-Object Id -EQ 'hacked').MainClassKnown | Should -BeFalse
    }

    It 'detecta un JAR de versión que no coincide con el SHA-1 declarado' {
        ($script:vers | Where-Object Id -EQ '1.20.1').HashStatus | Should -Be 'Mismatch'
    }

    It 'verifica un JAR de versión que coincide con el SHA-1 declarado' {
        ($script:vers | Where-Object Id -EQ '1.19.4').HashStatus | Should -Be 'Verified'
    }
}
