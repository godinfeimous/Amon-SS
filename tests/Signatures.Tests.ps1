BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Jar, Minecraft, Signatures
    $script:Set = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')
    $script:Class = [byte[]](0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52)
    function Find-Ind([string]$ClientId, [string]$Value) {
        $script:Set.Indicators | Where-Object { $_.ClientId -eq $ClientId -and $_.Value -ceq $Value }
    }
}

Describe 'Firmas: definiciones' -Tag 'Unit' {
    It 'todas las definiciones son válidas según el esquema' {
        $errors = Test-AmonSignatureSet -Set $script:Set
        $errors | Should -BeNullOrEmpty
    }

    It 'el software de macros instalado solo se informa (INFO), no cuenta como indicio' {
        $dir = Join-Path $TestDrive 'sig-macro'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{ "schemaVersion": 1, "id": "macro-x", "name": "Macro X", "category": "macro", "indicators": [ { "id": "mx.cfg", "type": "config", "value": "MacroX/macros", "relativeTo": "userHome", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://example.org/macrox" } ] }' |
            Set-Content -LiteralPath (Join-Path $dir 'macro-x.json') -Encoding UTF8
        $set = Get-AmonSignatureSet -Path $dir
        $home2 = Join-Path $TestDrive 'home-macro'
        New-Item -ItemType Directory -Path (Join-Path $home2 'MacroX\macros') -Force | Out-Null
        $res = New-AmonModuleResult -Module 'Signatures'
        Invoke-AmonConfigSignatureCheck -Context (New-AmonTestContext) -Set $set -Base $home2 -RelativeTo 'userHome' -Label 'perfil' -Result $res
        ($res.Findings | Where-Object ClientId -EQ 'macro-x').Status | Should -Be 'INFO'
    }

    It 'indexa los nombres de archivo de herramientas (tipo filename) sin distinguir mayúsculas' {
        $dir = Join-Path $TestDrive 'sig-filename'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{ "schemaVersion": 1, "id": "clicker-x", "name": "Clicker X", "category": "autoclicker", "indicators": [ { "id": "cx.exe", "type": "filename", "value": "ClickerX.exe", "strength": "medium", "provenance": "secondary", "validated": false, "source": "https://example.org/clickerx" } ] }' |
            Set-Content -LiteralPath (Join-Path $dir 'clicker-x.json') -Encoding UTF8
        $set = Get-AmonSignatureSet -Path $dir
        (Test-AmonSignatureSet -Set $set) | Should -BeNullOrEmpty
        $set.FileNames['clickerx.exe'][0].ClientName | Should -Be 'Clicker X'
    }

    It 'el validador detecta campos obligatorios ausentes aunque tengan valor por defecto' {
        $dir = Join-Path $TestDrive 'sig-missing'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '{ "schemaVersion": 1, "id": "sin-campos", "name": "Sin campos", "indicators": [ { "id": "x.1", "type": "package", "value": "x/y/", "provenance": "secondary", "validated": false, "source": "prueba" } ] }' |
            Set-Content -LiteralPath (Join-Path $dir 'sin-campos.json') -Encoding UTF8
        $errors = Test-AmonSignatureSet -Set (Get-AmonSignatureSet -Path $dir)
        ($errors -join ' ') | Should -Match "falta 'category'"
        ($errors -join ' ') | Should -Match "falta 'strength'"
    }

    It 'cada cliente tiene un id único y cada indicador una fuente' {
        $ids = $script:Set.Clients | ForEach-Object Id
        ($ids | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        ($script:Set.Indicators | Where-Object { -not $_.Source }) | Should -BeNullOrEmpty
    }

    It 'incluye los clientes pedidos como definiciones independientes' {
        foreach ($id in 'doomsday', 'meteor-client', 'nova-client', 'prestige', 'liquidbounce', 'wurst', 'aristois', 'impact', 'inertia', 'rusherhack', 'future', 'vape', 'raven') {
            ($script:Set.Clients | Where-Object Id -EQ $id) | Should -Not -BeNullOrEmpty -Because "falta la definición de $id"
        }
    }

    It 'conserva exactamente las cadenas de Doomsday con barras invertidas y símbolos' {
        foreach ($v in @('i_PlZygNMqUlcpwF', 'LNYlpCwym]p_m', 'NHTA1%n;R', 'Z;\<Rr', 'lTUPDuXI\JqjweAgtpN', 'pcwP\tDGFtvjQb', ";E#/hOgBaF.1d&l5['A", '|2||4|', '(YPg@BAJK,X', ']Cu2TF,', '?WHt4Y', 'F:tKChIta81qvEbZO', 'InJEkojpHG')) {
            Find-Ind 'doomsday' $v | Should -Not -BeNullOrEmpty -Because "la cadena '$v' debe existir tal cual"
        }
        @($script:Set.Indicators | Where-Object { $_.ClientId -eq 'doomsday' -and $_.Type -eq 'string' -and $_.Provenance -eq 'user-provided' }).Count | Should -Be 26
    }

    It 'conserva las cadenas de Nova y Prestige' {
        foreach ($v in @('U2VsZiBEZXN0cnVjdA==', 'aHR0cDovL2FwaS5ub3ZhY2xpZW50LmxvbC93ZWJob29rLnR4dA==', 'Tm9CcmVha0RlbGF5', 'UJHfsGGjbPfVZ', 'U2VsZiBEZXN0cnVjdA')) { Find-Ind 'nova-client' $v | Should -Not -BeNullOrEmpty }
        foreach ($v in @('dev/zprestige/prestige/api/mixin/MixinLightmapTextureManager.classPK', '8}u6tWfJy\', 'zprestige')) { Find-Ind 'prestige' $v | Should -Not -BeNullOrEmpty }
    }

    It 'marca como no validadas las cadenas aportadas por el usuario' {
        ($script:Set.Indicators | Where-Object { $_.Provenance -eq 'user-provided' -and $_.Validated }) | Should -BeNullOrEmpty
    }

    It 'los indicadores de clientes cerrados citan una fuente pública y no se validan sin fuente primaria' {
        foreach ($id in 'vape', 'raven', 'inertia', 'sigma', 'rise', 'novoline') {
            $inds = @($script:Set.Indicators | Where-Object ClientId -EQ $id)
            $inds.Count | Should -BeGreaterThan 0 -Because "$id tiene indicadores con fuente desde la investigación del 2026-10-21"
            foreach ($i in $inds) {
                $i.Source | Should -Match '^https?://' -Because "$($i.Id) debe citar su fuente"
                if ($i.Validated) { $i.Provenance | Should -Be 'primary-source' -Because "$($i.Id) solo puede estar validado con fuente primaria" }
            }
        }
    }
}

Describe 'Firmas: escaneo de JAR' -Tag 'Unit' {
    It 'identifica Meteor por paquete, modid y mixins con confianza alta' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\meteor-client-0.5.8.jar') -Entries ([ordered]@{
                'fabric.mod.json'                                           = '{"schemaVersion":1,"id":"meteor-client","version":"0.5.8","entrypoints":{"client":["meteordevelopment.meteorclient.MeteorClient"]}}'
                'meteor-client.mixins.json'                                 = '{}'
                'meteordevelopment/meteorclient/MeteorClient.class'         = $script:Class
            })
        $r = Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)
        $d = $r.Detections | Where-Object ClientId -EQ 'meteor-client'
        $d | Should -Not -BeNullOrEmpty
        $d.Confidence | Should -Be 'High'
        $d.Status | Should -Be 'DETECTED'
        ($d.Matches | ForEach-Object Type) | Should -Contain 'package'
        ($d.Matches | ForEach-Object Type) | Should -Contain 'modid'
        $r.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'encuentra cadenas dentro de clases comprimidas (no visibles en bruto)' {
        $content = [Text.Encoding]::ASCII.GetBytes(('x' * 500) + 'i_PlZygNMqUlcpwF' + ('y' * 500) + 'LNYlpCwym]p_m' + ('z' * 500))
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\random-name.jar') -Entries @{ 'a/b/C.class' = $content }
        [IO.File]::ReadAllBytes($p) | Out-Null
        $r = Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)
        $d = $r.Detections | Where-Object ClientId -EQ 'doomsday'
        $d | Should -Not -BeNullOrEmpty
        ($d.Matches | ForEach-Object Value) | Should -Contain 'i_PlZygNMqUlcpwF'
    }

    It 'limita a confianza media las detecciones basadas solo en firmas no validadas' {
        $txt = 'i_PlZygNMqUlcpwF LNYlpCwym]p_m RhKPfWtHijBnv lTUPDuXI\JqjweAgtpN pcwP\tDGFtvjQb yTvPOTqFL_BcErx'
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\many.jar') -Entries @{ 'x/Y.class' = [Text.Encoding]::ASCII.GetBytes($txt) }
        $d = (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Where-Object ClientId -EQ 'doomsday'
        $d.Confidence | Should -Be 'Medium'
        $d.Justification | Should -Match 'validaci'
    }

    It 'los JAR anidados respetan el límite total descomprimido' {
        $inner = New-AmonTestJarBytes -Entries @{ 'x.bin' = [byte[]]::new(256KB) }
        $entries = [ordered]@{}
        for ($k = 1; $k -le 20; $k++) { $entries["META-INF/jars/n$k.jar"] = $inner }
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\bomb.jar') -Entries $entries
        $ctx = New-AmonTestContext
        $ctx.Settings.limits.maxDecompressedPerJarMB = 1
        $r = Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context $ctx
        $r.Stats.Truncated | Should -BeTrue
        $r.Stats.NestedScanned | Should -BeLessThan 20
    }

    It 'identifica Raven bS (firmas nuevas de fuente primaria) aunque se haga pasar por KeystrokesMod' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\keystrokes-1.8.9.jar') -Entries ([ordered]@{
                'mcmod.info'                                = '[{"modid":"keystrokes","name":"KeystrokesMod","version":"2.2"}]'
                'mixins.raven.json'                         = '{}'
                'keystrokesmod/module/impl/combat/Reach.class' = $script:Class
            })
        $d = (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Where-Object ClientId -EQ 'raven'
        $d.Status | Should -Be 'DETECTED'
        $d.Confidence | Should -Be 'High'
    }

    It 'un KeystrokesMod legítimo (mismo modid) no se confunde con Raven' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\keystrokes-legit.jar') -Entries ([ordered]@{
                'mcmod.info'                         = '[{"modid":"keystrokes","name":"KeystrokesMod","version":"3.0"}]'
                'me/legit/keystrokes/KeystrokesMod.class' = $script:Class
            })
        @((Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections).Count | Should -Be 0
    }

    It 'una sola cadena corta no validada queda como no concluyente' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\one.jar') -Entries @{ 'x/Y.class' = [Text.Encoding]::ASCII.GetBytes('....Kptie....') }
        $d = (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Where-Object ClientId -EQ 'doomsday'
        $d.Status | Should -Be 'INCONCLUSIVE'
        $d.Confidence | Should -Be 'Low'
    }

    It 'no cuenta dos veces una cadena contenida en otra coincidente' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\nova.jar') -Entries @{ 'n/V.class' = [Text.Encoding]::ASCII.GetBytes('U2VsZiBEZXN0cnVjdA==') }
        $d = (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Where-Object ClientId -EQ 'nova-client'
        @($d.Matches).Count | Should -Be 1
    }

    It 'revisa los JAR anidados' {
        $inner = New-AmonTestJarBytes -Entries @{ 'net/wurstclient/WurstClient.class' = $script:Class; 'fabric.mod.json' = '{"id":"wurst"}' }
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\innocent.jar') -Entries @{ 'fabric.mod.json' = '{"id":"innocent"}'; 'META-INF/jars/lib.jar' = $inner }
        $d = (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Where-Object ClientId -EQ 'wurst'
        $d | Should -Not -BeNullOrEmpty
        ($d.Matches | ForEach-Object Location) -join ' ' | Should -Match 'lib\.jar'
    }

    It 'no detecta nada en un mod legítimo' {
        $p = New-AmonTestJar -Path (Join-Path $TestDrive 'mods\sodium.jar') -Entries @{ 'fabric.mod.json' = '{"id":"sodium","version":"0.5.8"}'; 'net/caffeinemc/mods/sodium/Sodium.class' = $script:Class }
        (Invoke-AmonFileSignatureScan -Path $p -Set $script:Set -Context (New-AmonTestContext)).Detections | Should -BeNullOrEmpty
    }
}

Describe 'Firmas: módulo completo sobre una instancia' -Tag 'Unit' {
    BeforeAll {
        $roam = Join-Path $TestDrive 'sig\Roaming'
        $gd = "$roam\.minecraft"
        New-AmonTestJar -Path "$gd\mods\wurst.jar" -Entries @{ 'fabric.mod.json' = '{"id":"wurst","version":"7.56"}'; 'net/wurstclient/WurstClient.class' = $script:Class } | Out-Null
        New-AmonTestJar -Path "$gd\mods\libutil.jar" -Entries @{ 'x/Y.class' = [Text.Encoding]::ASCII.GetBytes('....Kptie....') } | Out-Null
        New-Item -ItemType Directory -Force -Path "$gd\meteor-client", "$gd\wurst", "$gd\logs" | Out-Null
        New-AmonTestFile -Path "$gd\logs\latest.log" -Text "[10:00:00] [main/INFO]: Loading Minecraft 1.21 with Fabric Loader 0.16.0`n[10:00:01] [main/INFO]: Loading 2 mods:`n`t- wurst 7.56`n`t- minecraft 1.21`n[10:00:05] [Render thread/INFO]: [STDOUT]: Starting Wurst Client...`n" | Out-Null
        $script:ctx = New-AmonTestContext
        Invoke-AmonMinecraftAnalysis -Context $script:ctx -Roots @{ AppData = $roam; UserProfile = (Join-Path $TestDrive 'sig\Home'); LocalAppData = (Join-Path $TestDrive 'sig\Local') } -SkipProcesses | Out-Null
        $script:res = Invoke-AmonSignatureAnalysis -Context $script:ctx -Set $script:Set
    }

    It 'detecta el JAR del cliente con ruta, hash y fuente de la firma' {
        $f = $script:res.Findings | Where-Object { $_.ClientId -eq 'wurst' -and $_.Category -eq 'CheatSignature' }
        $f | Should -Not -BeNullOrEmpty
        $f.Path | Should -Match 'wurst\.jar$'
        $f.Sha256 | Should -Match '^[0-9a-f]{64}$'
        ($f.Evidence | ForEach-Object Description) -join ' ' | Should -Match 'github'
    }

    It 'aporta evidencia de ejecución desde el log (mod cargado y mensaje de arranque)' {
        $f = @($script:res.Findings | Where-Object { $_.ClientId -eq 'wurst' -and $_.Category -eq 'ClientLog' })
        $f.Count | Should -BeGreaterThan 0
        ($f | ForEach-Object Indicator) -join ' ' | Should -Match 'Starting Wurst Client'
    }

    It 'detecta la carpeta de configuración de otro cliente' {
        $f = $script:res.Findings | Where-Object { $_.ClientId -eq 'meteor-client' -and $_.Category -eq 'ClientConfig' }
        $f | Should -Not -BeNullOrEmpty
        $f.Path | Should -Match 'meteor-client$'
    }

    It 'detecta todas las carpetas de configuración presentes, no solo la primera' {
        # Regresión: una variable que pisaba el parámetro $Base desviaba las comprobaciones siguientes.
        $ids = @($script:res.Findings | Where-Object Category -EQ 'ClientConfig' | ForEach-Object ClientId)
        $ids | Should -Contain 'meteor-client'
        $ids | Should -Contain 'wurst'
    }

    It 'registra los indicadores concretos en el contexto para los módulos siguientes' {
        $script:ctx.IndicatorNames.Contains('wurst.jar') | Should -BeTrue
    }

    It 'escanea las rutas adicionales autorizadas en la sesión, aunque tengan comillas tipográficas' {
        $dir = Join-Path $TestDrive "Mike$([char]0x2019)s mods"
        New-AmonTestJar -Path (Join-Path $dir 'extra.jar') -Entries @{ 'fabric.mod.json' = '{"id":"wurst","version":"7.56"}'; 'net/wurstclient/WurstClient.class' = $script:Class } | Out-Null
        $ctx = New-AmonTestContext
        $ctx.ExtraScanPaths.Add($dir)
        $r = Invoke-AmonSignatureAnalysis -Context $ctx -Set $script:Set
        ($r.Findings | Where-Object { $_.Category -eq 'CheatSignature' -and $_.Path -like '*extra.jar' }) | Should -Not -BeNullOrEmpty
    }

    It 'una detección no concluyente no se registra como indicador' {
        ($script:res.Findings | Where-Object { $_.Path -match 'libutil\.jar$' }).Status | Should -Be 'INCONCLUSIVE'
        $script:ctx.IndicatorNames.Contains('libutil.jar') | Should -BeFalse
    }

    It 'repetir los análisis vuelve a escanear los JAR y no duplica instancias' {
        $n = $script:ctx.Instances.Count
        $roam = Join-Path $TestDrive 'sig\Roaming'
        Invoke-AmonMinecraftAnalysis -Context $script:ctx -Roots @{ AppData = $roam; UserProfile = (Join-Path $TestDrive 'sig\Home'); LocalAppData = (Join-Path $TestDrive 'sig\Local') } -SkipProcesses | Out-Null
        $script:ctx.Instances.Count | Should -Be $n
        $again = Invoke-AmonSignatureAnalysis -Context $script:ctx -Set $script:Set
        ($again.Findings | Where-Object { $_.ClientId -eq 'wurst' -and $_.Category -eq 'CheatSignature' }) | Should -Not -BeNullOrEmpty
        @($again.Findings | Where-Object { $_.ClientId -eq 'meteor-client' -and $_.Category -eq 'ClientConfig' }).Count | Should -Be 1
    }
}
