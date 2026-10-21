BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Processes
}

Describe 'Procesos: línea de comandos de Java' -Tag 'Unit' {
    BeforeAll {
        $script:cl = '"C:\Program Files\Java\jdk-21\bin\javaw.exe" -Xmx4G -javaagent:"C:\Users\Steve\Downloads\agent.jar"=opt -Dfabric.addMods=C:\x\extra.jar -cp "C:\Users\Steve\AppData\Roaming\.minecraft\libraries\a.jar;C:\Users\Steve\Desktop\hack.jar;C:\Users\Steve\AppData\Roaming\.minecraft\versions\1.20.1\1.20.1.jar" net.fabricmc.loader.impl.launch.knot.KnotClient --username Steve --version fabric-loader-0.15.11-1.20.1 --gameDir "C:\Games\MC Pack" --accessToken eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl'
        $script:j = ConvertFrom-AmonJavaCommandLine -CommandLine $script:cl
    }

    It 'extrae la clase principal, versión y directorio de juego con espacios' {
        $script:j.MainClass | Should -Be 'net.fabricmc.loader.impl.launch.knot.KnotClient'
        $script:j.Version | Should -Be 'fabric-loader-0.15.11-1.20.1'
        $script:j.GameDir | Should -Be 'C:\Games\MC Pack'
        $script:j.Username | Should -Be 'Steve'
    }

    It 'detecta agentes Java y mods añadidos por propiedad' {
        $script:j.JavaAgents | Should -Contain 'C:\Users\Steve\Downloads\agent.jar'
        $script:j.AddedMods | Should -Contain 'C:\x\extra.jar'
    }

    It 'separa JAR del classpath que no son librerías ni versiones' {
        $script:j.NonLibraryClassPath | Should -Be @('C:\Users\Steve\Desktop\hack.jar')
    }

    It 'oculta el token de sesión en la línea mostrada' {
        $script:j.SafeCommandLine | Should -Not -Match 'eyJhbGci'
    }

    It 'reconoce java -jar' {
        (ConvertFrom-AmonJavaCommandLine -CommandLine 'java.exe -jar "C:\Users\S\Downloads\client.jar"').Jar | Should -Be 'C:\Users\S\Downloads\client.jar'
    }
}

Describe 'Procesos: módulos cargados' -Tag 'Unit' {
    It 'no marca librerías nativas conocidas de Minecraft' {
        Test-AmonModuleSuspicious -Path 'C:\Users\S\AppData\Local\Temp\lwjglS\3.3.1\lwjgl_opengl.dll' -Signed $false | Should -BeFalse
    }
    It 'no marca DLL del sistema' {
        Test-AmonModuleSuspicious -Path 'C:\Windows\System32\kernel32.dll' -Signed $false | Should -BeFalse
    }
    It 'no marca superposiciones conocidas (OBS, Steam, Discord)' {
        Test-AmonModuleSuspicious -Path 'C:\Program Files\obs-studio\data\obs-plugins\win-capture\graphics-hook64.dll' -Signed $false | Should -BeFalse
    }
    It 'no marca las nativas de Simple Voice Chat ni las de Lunar' {
        Test-AmonModuleSuspicious -Path 'C:\Users\S\AppData\Local\Temp\libopus4j-9783d0e0\libopus4j.dll' -Signed $false | Should -BeFalse
        Test-AmonModuleSuspicious -Path 'C:\Users\S\.lunarclient\offline\multiver\natives\webp-imageio64.dll' -Signed $false | Should -BeFalse
    }
    It 'marca una DLL sin firma cargada desde Descargas' {
        Test-AmonModuleSuspicious -Path 'C:\Users\S\Downloads\loader\inject.dll' -Signed $false | Should -BeTrue
    }
    It 'no marca una DLL firmada aunque esté en una carpeta de usuario' {
        Test-AmonModuleSuspicious -Path 'C:\Users\S\Downloads\x\signed.dll' -Signed $true | Should -BeFalse
    }
}

Describe 'Procesos: argumentos JVM de clientes' -Tag 'Unit' {
    It 'un argumento JVM sin validar queda como no concluyente; uno validado, como detectado' {
        Import-AmonTestModule Jar, Signatures, Processes
        $dir = Join-Path $TestDrive 'sigs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item (Join-Path (Get-AmonTestRoot) 'signatures\rusherhack.json') $dir
        '{ "schemaVersion": 1, "id": "testclient", "name": "Test Client", "category": "cheat-client", "indicators": [ { "id": "tc.jvm", "type": "jvmArg", "value": "-Dtestclient.inject=true", "strength": "medium", "provenance": "user-provided", "validated": false, "source": "prueba" } ] }' |
            Set-Content -LiteralPath (Join-Path $dir 'testclient.json') -Encoding UTF8
        $ctx = New-AmonTestContext
        $ctx.Signatures = Get-AmonSignatureSet -Path $dir
        $snap = @([pscustomobject]@{ ProcessId = 999999; ParentProcessId = 0; Name = 'javaw.exe'; ExecutablePath = 'C:\Java\bin\javaw.exe'; CommandLine = 'javaw.exe -Dtestclient.inject=true -Drusherhack.enablePlugins=true -cp x.jar net.minecraft.client.main.Main'; CreationUtc = [datetime]::UtcNow })
        $r = Invoke-AmonProcessAnalysis -Context $ctx -Snapshot $snap
        ($r.Findings | Where-Object ClientId -EQ 'testclient').Status | Should -Be 'INCONCLUSIVE'
        ($r.Findings | Where-Object ClientId -EQ 'rusherhack').Status | Should -Be 'DETECTED'
    }
}

Describe 'Procesos: sistema real' -Tag 'Integration' {
    It 'inspecciona los procesos sin modificarlos' {
        $res = Invoke-AmonProcessAnalysis -Context (New-AmonTestContext)
        $res.Status | Should -BeIn @('Completed', 'Partial')
        $res.ArtifactsReviewed | Should -BeGreaterThan 0
    }
}
