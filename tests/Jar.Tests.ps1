BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Jar
    $script:ClassBytes = [byte[]](0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52)
}

Describe 'Jar: metadatos de mods' -Tag 'Unit' {
    It 'reconoce un mod de Fabric con id, versión, entrypoints y mixins' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'fabric.jar') -Entries ([ordered]@{
                'fabric.mod.json'                = '{"schemaVersion":1,"id":"examplemod","version":"1.2.3","name":"Example Mod","entrypoints":{"main":["com.example.ExampleMod"],"client":[{"adapter":"kotlin","value":"com.example.Client"}]},"mixins":["examplemod.mixins.json",{"config":"examplemod.client.mixins.json","environment":"client"}]}'
                'com/example/ExampleMod.class'   = $script:ClassBytes
                'com/example/mixin/AMixin.class' = $script:ClassBytes
            })
        $i = Get-AmonJarInfo -Path $p
        $i.IsValidZip | Should -BeTrue
        $i.Loader | Should -Be 'Fabric'
        $i.ModIds | Should -Contain 'examplemod'
        $i.ModVersion | Should -Be '1.2.3'
        $i.Entrypoints | Should -Contain 'com.example.ExampleMod'
        $i.Entrypoints | Should -Contain 'com.example.Client'
        $i.Mixins | Should -Contain 'examplemod.client.mixins.json'
        $i.Packages | Should -Contain 'com/example/'
        $i.ClassCount | Should -Be 2
    }

    It 'en mods.toml de Forge ignora los modId de las dependencias' {
        $toml = @"
modLoader="javafml"
loaderVersion="[47,)"
[[mods]]
modId="forgemod"
version="2.0.0"
displayName="Forge Mod"
[[dependencies.forgemod]]
    modId="forge"
    mandatory=true
[[dependencies.forgemod]]
    modId="minecraft"
"@
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'forge.jar') -Entries @{ 'META-INF/mods.toml' = $toml }
        $i = Get-AmonJarInfo -Path $p
        $i.Loader | Should -Be 'Forge'
        $i.ModIds | Should -Be @('forgemod')
        $i.ModVersion | Should -Be '2.0.0'
    }

    It 'reconoce NeoForge por neoforge.mods.toml' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'neo.jar') -Entries @{ 'META-INF/neoforge.mods.toml' = "[[mods]]`nmodId=`"neomod`"`nversion=`"1.0`"" }
        (Get-AmonJarInfo -Path $p).Loader | Should -Be 'NeoForge'
    }

    It 'reconoce mods antiguos con mcmod.info' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'legacy.jar') -Entries @{ 'mcmod.info' = '[{"modid":"oldmod","name":"Old","version":"1.0"}]' }
        $i = Get-AmonJarInfo -Path $p
        $i.Loader | Should -Be 'LegacyForge'
        $i.ModIds | Should -Contain 'oldmod'
    }

    It 'detecta un javaagent por Premain-Class en el MANIFEST' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'agent.jar') -Entries @{ 'META-INF/MANIFEST.MF' = "Manifest-Version: 1.0`r`nPremain-Class: com.example.Agent`r`nCan-Retransform-Classes: true`r`n" }
        $i = Get-AmonJarInfo -Path $p
        $i.IsJavaAgent | Should -BeTrue
        $i.Manifest['Premain-Class'] | Should -Be 'com.example.Agent'
        $i.HasModMetadata | Should -BeFalse
    }

    It 'lista los JAR anidados (Jar-in-Jar)' {
        $inner = New-AmonTestJarBytes -Entries @{ 'fabric.mod.json' = '{"id":"inner"}' }
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'outer.jar') -Entries @{ 'fabric.mod.json' = '{"id":"outer"}'; 'META-INF/jars/inner-1.0.jar' = $inner }
        (Get-AmonJarInfo -Path $p).NestedJars | Should -Contain 'META-INF/jars/inner-1.0.jar'
    }

    It 'un metadato con deflate dañado no impide leer el resto del JAR' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'decoy.jar') -Entries ([ordered]@{
                'META-INF/mods.toml' = ('modLoader="javafml"' + "`n" + ('# relleno ' * 200))
                'fabric.mod.json'    = '{"id":"realmod","version":"1.0"}'
            })
        # Se sustituye el primer byte del flujo deflate de mods.toml por un bloque de tipo reservado.
        $b = [IO.File]::ReadAllBytes($p)
        $name = [Text.Encoding]::ASCII.GetBytes('META-INF/mods.toml')
        for ($o = 0; $o -lt $b.Length - 30; $o++) {
            if ($b[$o] -eq 0x50 -and $b[$o + 1] -eq 0x4B -and $b[$o + 2] -eq 3 -and $b[$o + 3] -eq 4 -and [BitConverter]::ToUInt16($b, $o + 26) -eq $name.Length) {
                if ([Text.Encoding]::ASCII.GetString($b, $o + 30, $name.Length) -eq 'META-INF/mods.toml') {
                    $b[$o + 30 + $name.Length + [BitConverter]::ToUInt16($b, $o + 28)] = 0xFF; break
                }
            }
        }
        [IO.File]::WriteAllBytes($p, $b)
        $i = Get-AmonJarInfo -Path $p
        $i.IsValidZip | Should -BeTrue
        $i.ModIds | Should -Contain 'realmod'
        $i.Error | Should -Match 'mods\.toml'
    }

    It 'no falla con archivos que no son ZIP' {
        $p = Join-Path $TestDrive 'broken.jar'
        [IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3, 4, 5))
        $i = Get-AmonJarInfo -Path $p
        $i.IsValidZip | Should -BeFalse
        $i.Error | Should -Not -BeNullOrEmpty
    }
}
