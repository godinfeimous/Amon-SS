BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Core
}

Describe 'Core: hallazgos y eventos' -Tag 'Unit' {
    It 'crea un hallazgo con identificador y estado válido' {
        $f = New-AmonFinding -Module 'Signatures' -Title 'Meteor Client' -Status DETECTED -Confidence High -Path 'C:\x.jar'
        $f.Id | Should -Match '^F-[0-9a-f]{10}$'
        $f.Status | Should -Be 'DETECTED'
        $f.PSObject.TypeNames | Should -Contain 'AmonSS.Finding'
    }

    It 'rechaza estados que no están definidos' {
        { New-AmonFinding -Module 'X' -Title 'Y' -Status 'GUILTY' } | Should -Throw
    }

    It 'las listas de un resultado de módulo se pueden enumerar con @() en Windows PowerShell 5.1' {
        # Regresión: List[T] creada con New-Object queda envuelta en PSObject y @() falla en 5.1.
        $r = New-AmonModuleResult -Module 'X'
        $r.Findings.Add((New-AmonFinding -Module 'X' -Title 'Y'))
        @($r.Findings).Count | Should -Be 1
        @($r.Events).Count | Should -Be 0
        $ctx = New-AmonContext -Days 1 -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'n.json') -Reload)
        @($ctx.EvidencePaths).Count | Should -Be 0
        @($ctx.Keywords).Count | Should -BeGreaterThan 0
    }

    It 'normaliza las fechas de eventos a UTC' {
        $local = [datetime]::SpecifyKind([datetime]'2026-10-19 12:00:00', [DateTimeKind]::Local)
        $e = New-AmonEvent -TimestampUtc $local -Type 'Prueba' -Source 'Test'
        $e.TimestampUtc.Kind | Should -Be ([DateTimeKind]::Utc)
        $e.TimestampUtc | Should -Be $local.ToUniversalTime()
    }
}

Describe 'Core: tiempo' -Tag 'Unit' {
    It 'convierte FILETIME válidos' {
        $d = [datetime]::SpecifyKind([datetime]'2026-10-18 08:30:00', [DateTimeKind]::Utc)
        ConvertFrom-AmonFileTime $d.ToFileTimeUtc() | Should -Be $d
    }

    It 'descarta FILETIME nulos o fuera de rango' {
        ConvertFrom-AmonFileTime 0 | Should -BeNullOrEmpty
        ConvertFrom-AmonFileTime ([datetime]'1801-01-01').ToFileTimeUtc() | Should -BeNullOrEmpty
    }
}

Describe 'Core: archivos' -Tag 'Unit' {
    It 'calcula SHA-256 y SHA-1 conocidos' {
        $p = Join-Path $TestDrive 'abc.txt'
        [IO.File]::WriteAllBytes($p, [Text.Encoding]::ASCII.GetBytes('abc'))
        Get-AmonFileHash -Path $p | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        Get-AmonFileHash -Path $p -Algorithm SHA1 | Should -Be 'a9993e364706816aba3e25717850c26c9cd0d89d'
    }

    It 'lee archivos aunque otro proceso los tenga abiertos para escritura' {
        $p = Join-Path $TestDrive 'locked.bin'
        $fs = [IO.File]::Open($p, 'Create', 'ReadWrite', 'ReadWrite')
        try {
            $fs.Write([byte[]](1, 2, 3), 0, 3); $fs.Flush()
            (Read-AmonFileBytes -Path $p -MaxBytes 10).Length | Should -Be 3
        } finally { $fs.Dispose() }
    }

    It 'no lee más allá del límite indicado' {
        $p = Join-Path $TestDrive 'big.bin'
        [IO.File]::WriteAllBytes($p, (New-Object byte[] 1000))
        (Read-AmonFileBytes -Path $p -MaxBytes 100).Length | Should -Be 100
    }
}

Describe 'Core: privacidad de líneas de comando' -Tag 'Unit' {
    It 'oculta el token de acceso de Minecraft y conserva el resto' {
        $cl = 'javaw.exe -Xmx4G net.minecraft.client.main.Main --username Steve --accessToken eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij --version 1.20.1'
        $r = Protect-AmonCommandLine $cl
        $r | Should -Not -Match 'eyJhbGci'
        $r | Should -Match '--accessToken \[REDACTADO\]'
        $r | Should -Match '--username Steve'
        $r | Should -Match '--version 1\.20\.1'
    }

    It 'oculta propiedades -D con nombres sensibles' {
        Protect-AmonCommandLine 'java -Dproxy.password=hunter2 -jar x.jar' | Should -Not -Match 'hunter2'
    }
}

Describe 'Core: palabras clave e indicadores' -Tag 'Unit' {
    It 'detecta palabras clave sin distinguir mayúsculas' {
        Test-AmonKeywordMatch -Text 'C:\Users\x\AppData\Roaming\.MINECRAFT\mods' -Keywords @('minecraft') | Should -Be 'minecraft'
        Test-AmonKeywordMatch -Text 'C:\Windows\notepad.exe' -Keywords @('minecraft') | Should -BeNullOrEmpty
    }

    It 'el contexto calcula la ventana temporal y registra indicadores' {
        $ctx = New-AmonContext -Days 3 -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'none.json') -Reload)
        ([datetime]::UtcNow - $ctx.SinceUtc).TotalDays | Should -BeGreaterThan 2.99
        Add-AmonIndicator -Context $ctx -FileName 'cheat.jar' -Sha256 'ABC' -Source 'Test'
        $ctx.IndicatorNames.Contains('CHEAT.JAR') | Should -BeTrue
        $ctx.IndicatorHashes.Contains('abc') | Should -BeTrue
        $ctx.Keywords.Contains('cheat.jar') | Should -BeTrue
    }

    It 'solo acepta rutas de unidades locales (nunca recursos de red)' {
        Test-AmonLocalPath -Path "$env:SystemRoot\notepad.exe" | Should -BeTrue
        foreach ($p in '\\servidor\recurso\x.jar', '//servidor/recurso/x.jar', '\\?\UNC\servidor\recurso\x.jar', '\\.\pipe\x', 'mods\x.jar', '', $null) {
            Test-AmonLocalPath -Path $p | Should -BeFalse -Because "'$p' no es una ruta local"
        }
    }

    It 'no registra rutas de evidencia de red' {
        $ctx = New-AmonContext -Days 3 -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'none.json') -Reload)
        Add-AmonEvidencePath -Context $ctx -Path '\\servidor\recurso\agent.jar' -Source 'Test'
        Add-AmonEvidencePath -Context $ctx -Path "$env:SystemRoot\x.jar" -Source 'Test'
        @($ctx.EvidencePaths | ForEach-Object Path) | Should -Be @("$env:SystemRoot\x.jar")
    }

    It 'sin fin explícito, la ventana avanza hasta el inicio de cada módulo' {
        $ctx = New-AmonContext -Days 3 -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'none.json') -Reload)
        $ctx.UntilUtc = [datetime]::UtcNow.AddHours(-1)
        $before = [datetime]::UtcNow
        $null = Invoke-AmonModule -Name 'X' -Context $ctx -ScriptBlock { param($c) Complete-AmonModuleResult -Result (New-AmonModuleResult -Module 'X') }
        $ctx.UntilUtc | Should -BeGreaterOrEqual $before
        Test-AmonInWindow -Context $ctx -Utc ([datetime]::UtcNow.AddMinutes(-1)) | Should -BeTrue
    }

    It 'un fin explícito se respeta' {
        $until = [datetime]::UtcNow.AddDays(-1)
        $ctx = New-AmonContext -Days 3 -UntilUtc $until -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'none.json') -Reload)
        $null = Invoke-AmonModule -Name 'X' -Context $ctx -ScriptBlock { param($c) Complete-AmonModuleResult -Result (New-AmonModuleResult -Module 'X') }
        $ctx.UntilUtc | Should -Be $until.ToUniversalTime()
    }
}

Describe 'Core: ajustes' -Tag 'Unit' {
    It 'combina los ajustes del usuario sobre los predeterminados' {
        $user = Join-Path $TestDrive 'user-settings.json'
        '{ "theme": "MinimalPurple", "limits": { "maxJarSizeMB": 8 } }' | Set-Content -Path $user -Encoding UTF8
        $s = Get-AmonSettings -UserPath $user -Reload
        $s.theme | Should -Be 'MinimalPurple'
        $s.limits.maxJarSizeMB | Should -Be 8
        $s.limits.maxEntrySizeMB | Should -BeGreaterThan 0
    }

    It 'persiste un cambio de ajuste en el archivo del usuario' {
        $user = Join-Path $TestDrive 'persist.json'
        $null = Get-AmonSettings -UserPath $user -Reload
        Set-AmonSetting -Name 'theme' -Value 'ClassicTerminal' -Persist
        (Get-Content $user -Raw | ConvertFrom-Json).theme | Should -Be 'ClassicTerminal'
    }
}

Describe 'Core: ejecución de módulos' -Tag 'Unit' {
    BeforeEach {
        $script:ctx = New-AmonContext -Days 7 -Settings (Get-AmonSettings -UserPath (Join-Path $TestDrive 'none.json') -Reload)
    }

    It 'registra un módulo que falla sin detener el escaneo' {
        $r = Invoke-AmonModule -Name 'Roto' -Context $script:ctx -ScriptBlock { param($c) throw 'fallo simulado' }
        $r.Status | Should -Be 'Failed'
        $r.Errors[0] | Should -Match 'fallo simulado'
        $script:ctx.Results['Roto'] | Should -Not -BeNullOrEmpty
    }

    It 'marca como parcial un módulo que agota su tiempo' {
        $r = Invoke-AmonModule -Name 'Lento' -Context $script:ctx -TimeoutSeconds 1 -ScriptBlock {
            param($c)
            $res = New-AmonModuleResult -Module 'Lento'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-AmonCancel -Context $c) -and $sw.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50 }
            Complete-AmonModuleResult -Result $res
        }
        $r.Status | Should -Be 'Partial'
        ($r.Limitations -join ' ') | Should -Match 'tiempo'
    }

    It 'mide la duración de un módulo correcto' {
        $r = Invoke-AmonModule -Name 'Ok' -Context $script:ctx -ScriptBlock {
            param($c) $res = New-AmonModuleResult -Module 'Ok'; $res.ArtifactsReviewed = 3; Complete-AmonModuleResult -Result $res
        }
        $r.Status | Should -Be 'Completed'
        $r.ArtifactsReviewed | Should -Be 3
        $r.DurationMs | Should -BeGreaterOrEqual 0
    }
}
