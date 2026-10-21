BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule ExecutionArtifacts, Tamper

    function New-ShimEntryBytes([string]$Path, [datetime]$ModifiedUtc, [byte[]]$Data = [byte[]](1, 2, 3, 4)) {
        # Entrada de Windows 10/11: '10ts', 4 bytes, tamaño, longitud de ruta, ruta UTF-16, FILETIME, datos.
        $p = [Text.Encoding]::Unicode.GetBytes($Path)
        $ms = New-Object IO.MemoryStream
        $w = New-Object IO.BinaryWriter($ms)
        $w.Write([Text.Encoding]::ASCII.GetBytes('10ts')); $w.Write([uint32]0x12345678)
        $w.Write([uint32](2 + $p.Length + 8 + 4 + $Data.Length)); $w.Write([uint16]$p.Length); $w.Write($p)
        $w.Write([int64]$ModifiedUtc.ToFileTimeUtc()); $w.Write([uint32]$Data.Length); $w.Write($Data)
        $w.Flush(); return , $ms.ToArray()
    }
    function New-ShimCacheBytes([object[]]$Entries) {
        $ms = New-Object IO.MemoryStream
        $hdr = New-Object byte[] 0x34; [Array]::Copy([BitConverter]::GetBytes([uint32]0x34), $hdr, 4)
        $ms.Write($hdr, 0, $hdr.Length)
        foreach ($e in $Entries) { $ms.Write($e, 0, $e.Length) }
        return , $ms.ToArray()
    }
    function New-BamValue([datetime]$Utc) {
        $b = New-Object byte[] 24; [Array]::Copy([BitConverter]::GetBytes($Utc.ToFileTimeUtc()), $b, 8); return , $b
    }
}

Describe 'ShimCache (AppCompatCache)' -Tag 'Unit' {
    It 'interpreta las entradas de Windows 10/11 en orden y omite las apps empaquetadas' {
        $t = ([datetime]'2026-10-18T10:00:00Z').ToUniversalTime()
        $raw = New-ShimCacheBytes @(
            (New-ShimEntryBytes 'C:\Users\S\Downloads\loader.exe' $t),
            (New-ShimEntryBytes "00000009`t0001001831c50000`tMicrosoft.WindowsTerminal`t" ([datetime]'1601-01-01Z')),
            (New-ShimEntryBytes 'C:\Program Files\App\app.exe' $t.AddDays(-1)))
        $e = @(ConvertFrom-AmonShimCache -Bytes $raw)
        $e.Count | Should -Be 2
        $e[0].Path | Should -Be 'C:\Users\S\Downloads\loader.exe'
        $e[0].Position | Should -Be 0
        $e[0].ModifiedUtc | Should -Be $t
        $e[1].Position | Should -Be 2
    }

    It 'no confunde software legítimo con nombres de clientes (regresión: SteelSeries GameSense)' {
        Import-AmonTestModule Jar, Signatures, ExecutionArtifacts
        $ctx = New-AmonTestContext
        $ctx.Signatures = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')
        foreach ($k in $ctx.Signatures.Keywords) { [void]$ctx.Keywords.Add($k) }
        $raw = New-ShimCacheBytes @(
            (New-ShimEntryBytes 'C:\Program Files\SteelSeries\GG\cvgamesense\SteelSeriesCVGameSense.exe' ([datetime]::UtcNow.AddDays(-1))),
            (New-ShimEntryBytes 'C:\Program Files\Tenacity\tenacity.exe' ([datetime]::UtcNow.AddDays(-1))))
        @((Invoke-AmonShimCacheAnalysis -Context $ctx -RawBytes $raw).Findings).Count | Should -Be 0
    }

    It 'rechaza datos que no son ShimCache de Windows 10/11' {
        { ConvertFrom-AmonShimCache -Bytes ([byte[]](1..80)) } | Should -Throw
    }

    It 'señala un ejecutable que coincide con un indicador y solo cuenta el resto' {
        $raw = New-ShimCacheBytes @(
            (New-ShimEntryBytes 'C:\Users\S\Downloads\vape-loader.exe' ([datetime]::UtcNow.AddDays(-2))),
            (New-ShimEntryBytes 'C:\Users\S\Documents\fotos-viaje.exe' ([datetime]::UtcNow.AddDays(-2))))
        $ctx = New-AmonTestContext
        [void]$ctx.IndicatorNames.Add('vape-loader.exe')
        $r = Invoke-AmonShimCacheAnalysis -Context $ctx -RawBytes $raw
        # En Windows 10/11 ShimCache prueba que el sistema vio el archivo, no que se ejecutara.
        $f = $r.Findings | Where-Object Category -EQ 'ShimCacheEntry'
        $f.Path | Should -Be 'C:\Users\S\Downloads\vape-loader.exe'
        $f.Justification | Should -Match 'no prueba'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match 'fotos-viaje'
        $r.Data['UnrelatedCount'] | Should -Be 1
    }
}

Describe 'BAM (Background Activity Moderator)' -Tag 'Unit' {
    BeforeAll {
        $script:now = [datetime]::UtcNow
        $script:raw = @(
            [pscustomobject]@{ Sid = 'S-1-5-21-1'; Name = '\Device\HarddiskVolume3\Users\S\Downloads\clicker.exe'; Data = (New-BamValue $script:now.AddHours(-2)) },
            [pscustomobject]@{ Sid = 'S-1-5-21-1'; Name = '\Device\HarddiskVolume3\Windows\System32\notepad.exe'; Data = (New-BamValue $script:now.AddHours(-1)) },
            [pscustomobject]@{ Sid = 'S-1-5-21-1'; Name = '\Device\HarddiskVolume3\Users\S\Desktop\viejo.exe'; Data = (New-BamValue $script:now.AddDays(-40)) },
            [pscustomobject]@{ Sid = 'S-1-5-21-1'; Name = 'Version'; Data = [byte[]](1, 0, 0, 0) },
            [pscustomobject]@{ Sid = 'S-1-5-21-1'; Name = 'Microsoft.WindowsTerminal_8wekyb3d8bbwe'; Data = (New-BamValue $script:now.AddHours(-3)) }
        )
        $script:ctx = New-AmonTestContext
        [void]$script:ctx.IndicatorNames.Add('clicker.exe')
        $script:res = Invoke-AmonBamAnalysis -Context $script:ctx -RawEntries $script:raw -VolumeMap @{ '\DEVICE\HARDDISKVOLUME3' = 'C:' }
    }

    It 'traduce la ruta del dispositivo y la última ejecución' {
        $a = $script:res.Artifacts | Where-Object Path -EQ 'C:\Users\S\Downloads\clicker.exe'
        $a | Should -Not -BeNullOrEmpty
        ([datetime]$a.LastRunUtc - $script:now.AddHours(-2)).TotalSeconds | Should -BeLessThan 1
    }

    It 'señala la ejecución de un archivo indicado como evidencia de ejecución' {
        $f = $script:res.Findings | Where-Object Category -EQ 'ExecutionEvidence'
        $f.Status | Should -Be 'DETECTED'
        @($script:res.Events | Where-Object Kind -EQ 'Execution').Count | Should -BeGreaterThan 0
    }

    It 'no muestra programas del sistema ni ejecuciones fuera del periodo' {
        ($script:res | ConvertTo-Json -Depth 6) | Should -Not -Match 'notepad|viejo\.exe'
    }
}

Describe 'BAM: sistema real' -Tag 'Integration' {
    It 'sin administrador informa de que no hay acceso; con administrador lee las entradas' {
        $ctx = New-AmonTestContext
        $r = Invoke-AmonBamAnalysis -Context $ctx
        if (Test-AmonAdmin) { $r.Status | Should -Be 'Completed' } else { $r.Status | Should -Be 'NoAccess' }
    }
}

Describe 'PCA de Windows 11 y MUICache' -Tag 'Unit' {
    BeforeAll {
        $now = [datetime]::UtcNow
        $fmt = { param($d) $d.ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture) }
        $script:pcaRaw = @{
            Launch = @(
                "C:\Users\S\Downloads\autoclicker-pro.exe|$(& $fmt $now.AddHours(-3))",
                "C:\Users\S\Downloads\borrado.exe|$(& $fmt $now.AddHours(-2))",
                "C:\Program Files\Notepad++\notepad++.exe|$(& $fmt $now.AddHours(-1))",
                'C:\Users\S\Desktop\Ca'
            )
            General = @("$(& $fmt $now.AddHours(-3))|2|%USERPROFILE%\downloads\autoclicker-pro.exe|||||Abnormal process exit with code 0x1")
            Store = @('C:\Users\S\Desktop\mi-tarea.exe', 'C:\Users\S\Tools\autoclicker-pro.exe')
            MuiCache = @('C:\Users\S\Documents\juego-privado.exe')
        }
        $script:pctx = New-AmonTestContext
        [void]$script:pctx.IndicatorNames.Add('autoclicker-pro.exe')
        $script:pres = Invoke-AmonPcaAnalysis -Context $script:pctx -Raw $script:pcaRaw
    }

    It 'lee la última ejecución en UTC de PcaAppLaunchDic y señala un indicador' {
        $f = @($script:pres.Findings | Where-Object { $_.Category -eq 'ExecutionEvidence' -and $_.Path -eq 'C:\Users\S\Downloads\autoclicker-pro.exe' })
        $f.Count | Should -Be 1
        $f[0].Status | Should -Be 'DETECTED'
        @($script:pres.Events | Where-Object { $_.Kind -eq 'Execution' -and $_.Path -match 'autoclicker' }).Count | Should -BeGreaterThan 0
    }

    It 'deja para revisar un ejecutable reciente de una carpeta de usuario que ya no existe' {
        ($script:pres.Findings | Where-Object { $_.Category -eq 'RecentUnsignedExecutable' }).Path | Should -Be 'C:\Users\S\Downloads\borrado.exe'
        ($script:pres.Findings | Where-Object { $_.Category -eq 'RecentUnsignedExecutable' }).Status | Should -Be 'INFO'
    }

    It 'usa Store y MUICache solo para ejecutables relacionados (privacidad)' {
        ($script:pres.Findings | Where-Object { $_.Path -eq 'C:\Users\S\Tools\autoclicker-pro.exe' }) | Should -Not -BeNullOrEmpty
        ($script:pres | ConvertTo-Json -Depth 6) | Should -Not -Match 'mi-tarea|juego-privado|notepad'
    }

    It 'avisa de un registro de lanzamientos truncado' {
        ($script:pres.Limitations -join ' ') | Should -Match 'truncad'
    }

    It 'usa las trazas PcaClient del Explorador: indicadores y ejecutables borrados de Descargas' {
        $ctx = New-AmonTestContext
        [void]$ctx.IndicatorNames.Add('inject0r.exe')
        $r = Invoke-AmonPcaAnalysis -Context $ctx -Raw @{ ExplorerTraces = @('C:\Users\S\Desktop\inject0r.exe', 'C:\Users\S\Downloads\ya-borrado.exe', 'C:\Windows\System32\notepad.exe') }
        ($r.Findings | Where-Object Category -EQ 'ExecutionEvidence').Path | Should -Be 'C:\Users\S\Desktop\inject0r.exe'
        ($r.Findings | Where-Object Category -EQ 'RecentUnsignedExecutable').Justification | Should -Match 'sin hora'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match 'notepad'
    }
}

Describe 'Evasión: servicios y hora del sistema' -Tag 'Unit' {
    BeforeAll {
        $script:boot = [datetime]::UtcNow.AddHours(-6)
        $svc = @(
            [pscustomobject]@{ Name = 'SysMain'; DisplayName = 'SysMain'; State = 'Stopped'; StartMode = 'Disabled'; ProcessStartUtc = $null; SharedProcess = $false },
            [pscustomobject]@{ Name = 'DPS'; DisplayName = 'Servicio de directivas de diagnóstico'; State = 'Running'; StartMode = 'Auto'; ProcessStartUtc = [datetime]::UtcNow.AddMinutes(-20); SharedProcess = $false },
            [pscustomobject]@{ Name = 'PcaSvc'; DisplayName = 'PCA'; State = 'Running'; StartMode = 'Auto'; ProcessStartUtc = $script:boot.AddMinutes(1); SharedProcess = $false },
            [pscustomobject]@{ Name = 'EventLog'; DisplayName = 'Registro de eventos'; State = 'Running'; StartMode = 'Auto'; ProcessStartUtc = $script:boot.AddSeconds(20); SharedProcess = $false }
        )
        $times = @(
            [pscustomobject]@{ TimestampUtc = [datetime]::UtcNow.AddHours(-1); NewTimeUtc = [datetime]::UtcNow.AddHours(-3); OldTimeUtc = [datetime]::UtcNow.AddHours(-1); DeltaMs = -7200000; Process = 'C:\Users\S\Downloads\timechanger.exe' },
            [pscustomobject]@{ TimestampUtc = [datetime]::UtcNow.AddHours(-2); NewTimeUtc = [datetime]::UtcNow.AddHours(-2); OldTimeUtc = [datetime]::UtcNow.AddHours(-2); DeltaMs = -314; Process = 'C:\Windows\System32\svchost.exe' }
        )
        $changes = @([pscustomobject]@{ TimestampUtc = [datetime]::UtcNow.AddHours(-4); Service = 'SysMain'; OldStart = 'inicio automático'; NewStart = 'deshabilitado' })
        $script:ctx = New-AmonTestContext
        $script:res = Invoke-AmonTamperAnalysis -Context $script:ctx -Services $svc -BootUtc $script:boot -TimeChanges $times -StartTypeChanges $changes -Crashes @()
    }

    It 'un servicio forense desactivado queda como no concluyente (lo hacen muchos tweaks)' {
        $f = $script:res.Findings | Where-Object { $_.Category -eq 'ServiceDisabled' -and $_.Indicator -match 'SysMain' }
        $f.Status | Should -Be 'INCONCLUSIVE'
        ($f.FalsePositives -join ' ') | Should -Match 'optimiza'
    }

    It 'detecta un servicio reiniciado mucho después del arranque' {
        ($script:res.Findings | Where-Object { $_.Category -eq 'ServiceRestarted' }).Indicator | Should -Match 'DPS'
        ($script:res.Findings | Where-Object { $_.Category -eq 'ServiceRestarted' -and $_.Indicator -match 'PcaSvc|EventLog' }) | Should -BeNullOrEmpty
    }

    It 'registra el cambio del tipo de inicio de un servicio forense' {
        ($script:res.Findings | Where-Object Category -EQ 'ServiceStartTypeChanged').Status | Should -Be 'DETECTED'
    }

    It 'señala un cambio grande de hora con el programa que lo hizo y omite los ajustes de sincronización' {
        $f = @($script:res.Findings | Where-Object Category -EQ 'SystemTimeChanged')
        $f.Count | Should -Be 1
        $f[0].Path | Should -Be 'C:\Users\S\Downloads\timechanger.exe'
        $f[0].Status | Should -Be 'DETECTED'
    }
}
