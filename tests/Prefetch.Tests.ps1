BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    . (Join-Path $PSScriptRoot 'Helpers\PrefetchFixture.ps1')
    Import-AmonTestModule Prefetch
    $script:Runs = @([datetime]'2026-10-19T20:15:00Z', [datetime]'2026-10-18T10:00:00Z', [datetime]'2026-10-15T08:30:00Z')
    $script:Files = @(
        '\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\PROGRAM FILES\JAVA\JDK-21\BIN\JAVAW.EXE',
        '\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\USERS\STEVE\DOWNLOADS\INJECTOR.JAR',
        '\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\USERS\STEVE\APPDATA\ROAMING\.MINECRAFT\LIBRARIES\ORG\LWJGL\LWJGL.JAR'
    )
}

Describe 'Prefetch: parser SCCA' -Tag 'Unit' {
    It 'lee nombre, contador, últimas ejecuciones, archivos y volumen (v30, variante 1)' {
        $b = New-AmonTestPrefetchBytes -LastRuns $script:Runs -FileNames $script:Files -RunCount 7 -Directories @('\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\USERS')
        $pf = ConvertFrom-AmonPrefetchBytes -Bytes $b -FileName 'JAVAW.EXE-DEADBEEF.pf'
        $pf.Version | Should -Be 30
        $pf.ExecutableName | Should -Be 'JAVAW.EXE'
        $pf.RunCount | Should -Be 7
        $pf.LastRunTimes.Count | Should -Be 3
        $pf.LastRunTimes[0] | Should -Be ([datetime]'2026-10-19T20:15:00Z').ToUniversalTime()
        $pf.FileNames | Should -Contain $script:Files[1]
        $pf.Volumes[0].Serial | Should -Be '1234ABCD'
        $pf.Volumes[0].Directories | Should -Contain '\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\USERS'
    }

    It 'lee el contador de ejecuciones en la variante 2 de v30' {
        $b = New-AmonTestPrefetchBytes -Variant 2 -RunCount 42 -LastRuns $script:Runs -FileNames $script:Files
        (ConvertFrom-AmonPrefetchBytes -Bytes $b).RunCount | Should -Be 42
    }

    It 'descomprime Prefetch MAM (XPRESS Huffman) de Windows 10/11' {
        $b = New-AmonTestPrefetchBytes -LastRuns $script:Runs -FileNames $script:Files -RunCount 3
        $mam = ConvertTo-AmonTestMam -Bytes $b
        [Text.Encoding]::ASCII.GetString($mam, 0, 3) | Should -Be 'MAM'
        $p = Join-Path $TestDrive 'JAVAW.EXE-DEADBEEF.pf'
        [IO.File]::WriteAllBytes($p, $mam)
        $pf = Read-AmonPrefetchFile -Path $p
        $pf.Compressed | Should -BeTrue
        $pf.RunCount | Should -Be 3
        $pf.FileNames | Should -Contain $script:Files[1]
    }

    It 'rechaza datos que no son Prefetch' {
        { ConvertFrom-AmonPrefetchBytes -Bytes ([byte[]](1..200 | ForEach-Object { [byte]$_ })) } | Should -Throw
    }

    It 'traduce rutas \VOLUME{...} a letras de unidad' {
        $map = @{ '1234ABCD' = 'C:' }
        Convert-AmonPrefetchPath -Path $script:Files[1] -VolumeMap $map | Should -Be 'C:\USERS\STEVE\DOWNLOADS\INJECTOR.JAR'
        Convert-AmonPrefetchPath -Path '\DEVICE\HARDDISKVOLUME3\X\Y.EXE' -VolumeMap @{ '\DEVICE\HARDDISKVOLUME3' = 'D:' } | Should -Be 'D:\X\Y.EXE'
    }
}

Describe 'Prefetch: módulo sobre una carpeta sintética' -Tag 'Unit' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'Prefetch'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $recent = [datetime]::UtcNow.AddHours(-3)
        [IO.File]::WriteAllBytes((Join-Path $dir 'JAVAW.EXE-DEADBEEF.pf'), (ConvertTo-AmonTestMam -Bytes (New-AmonTestPrefetchBytes -LastRuns @($recent) -FileNames $script:Files -RunCount 2)))
        [IO.File]::WriteAllBytes((Join-Path $dir 'NOTEPAD.EXE-11111111.pf'), (New-AmonTestPrefetchBytes -ExeName 'NOTEPAD.EXE' -LastRuns @($recent) -FileNames @('\VOLUME{01d2f1e8a3b4c5d6-1234abcd}\WINDOWS\SYSTEM32\NOTEPAD.EXE')))
        $script:ctx = New-AmonTestContext
        $script:res = Invoke-AmonPrefetchAnalysis -Context $script:ctx -Path $dir -VolumeMap @{ '1234ABCD' = 'C:' }
    }

    It 'muestra Java y omite programas no relacionados' {
        ($script:res.Artifacts | ForEach-Object ExecutableName) | Should -Contain 'JAVAW.EXE'
        ($script:res.Artifacts | ForEach-Object ExecutableName) | Should -Not -Contain 'NOTEPAD.EXE'
        $script:res.ArtifactsReviewed | Should -Be 2
    }

    It 'lista los JAR ejecutados por Java fuera de las librerías' {
        $a = $script:res.Artifacts | Where-Object ExecutableName -EQ 'JAVAW.EXE'
        $a.ReferencedJars | Should -Contain 'C:\USERS\STEVE\DOWNLOADS\INJECTOR.JAR'
        $a.ReferencedJars | Should -Not -Contain 'C:\USERS\STEVE\APPDATA\ROAMING\.MINECRAFT\LIBRARIES\ORG\LWJGL\LWJGL.JAR'
    }

    It 'registra ejecuciones en la timeline y rutas de evidencia' {
        @($script:res.Events | Where-Object Kind -EQ 'Execution').Count | Should -BeGreaterThan 0
        ($script:ctx.EvidencePaths | ForEach-Object Path) | Should -Contain 'C:\USERS\STEVE\DOWNLOADS\INJECTOR.JAR'
    }
}

Describe 'Prefetch: sistema real' -Tag 'Admin' {
    It 'interpreta los Prefetch reales de este equipo en un tiempo acotado' {
        # A través de Invoke-AmonModule: si algo se alarga, el módulo se corta y queda Partial.
        $ctx = New-AmonTestContext
        $res = Invoke-AmonModule -Name 'Prefetch' -Context $ctx -TimeoutSeconds 120 -ScriptBlock { param($c) Invoke-AmonPrefetchAnalysis -Context $c }
        Write-Host ("      Prefetch real: {0} archivos, {1} relevantes, {2:n1} s, estado {3}" -f $res.ArtifactsReviewed, $res.Artifacts.Count, ($res.DurationMs / 1000), $res.Status)
        foreach ($w in $res.Warnings) { Write-Host "      Aviso: $w" }
        $res.Status | Should -BeIn @('Completed', 'Partial')
        $res.ArtifactsReviewed | Should -BeGreaterThan 0
        @($res.Warnings | Where-Object { $_ -match 'no se pudieron interpretar' }).Count | Should -Be 0 -Because 'todos los .pf reales deben interpretarse'
    }
}
