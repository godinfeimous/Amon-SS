BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Recent, UserAssist, Events, Jar, Signatures

    function New-LnkBytes([string]$Target, [datetime]$TargetWrite, [uint32]$Size = 1234, [string]$Arguments) {
        # ShellLinkHeader + LinkInfo (VolumeID + LocalBasePath ANSI) [+ argumentos Unicode]
        $flags = 0x2 -bor 0x80
        if ($Arguments) { $flags = $flags -bor 0x20 }
        $base = [Text.Encoding]::ASCII.GetBytes($Target + [char]0)
        $volLabel = [Text.Encoding]::ASCII.GetBytes('DATA' + [char]0)
        $volId = New-Object byte[] (16 + $volLabel.Length)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$volId.Length), 0, $volId, 0, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]3), 0, $volId, 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]0xABCD1234L), 0, $volId, 8, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]16), 0, $volId, 12, 4)
        [Array]::Copy($volLabel, 0, $volId, 16, $volLabel.Length)
        $liHeader = 28
        $suffix = [byte[]]@(0)
        $liSize = $liHeader + $volId.Length + $base.Length + $suffix.Length
        $li = New-Object byte[] $liSize
        [Array]::Copy([BitConverter]::GetBytes([uint32]$liSize), 0, $li, 0, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$liHeader), 0, $li, 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]1), 0, $li, 8, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$liHeader), 0, $li, 12, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]($liHeader + $volId.Length)), 0, $li, 16, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]($liHeader + $volId.Length + $base.Length)), 0, $li, 24, 4)
        [Array]::Copy($volId, 0, $li, $liHeader, $volId.Length)
        [Array]::Copy($base, 0, $li, $liHeader + $volId.Length, $base.Length)
        $hdr = New-Object byte[] 76
        [Array]::Copy([BitConverter]::GetBytes([uint32]0x4C), 0, $hdr, 0, 4)
        [Array]::Copy(([guid]'00021401-0000-0000-C000-000000000046').ToByteArray(), 0, $hdr, 4, 16)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$flags), 0, $hdr, 20, 4)
        [Array]::Copy([BitConverter]::GetBytes($TargetWrite.ToUniversalTime().ToFileTimeUtc()), 0, $hdr, 44, 8)
        [Array]::Copy([BitConverter]::GetBytes($Size), 0, $hdr, 52, 4)
        $parts = @($hdr, $li)
        if ($Arguments) {
            $a = [Text.Encoding]::Unicode.GetBytes($Arguments)
            $parts += , ([BitConverter]::GetBytes([uint16]$Arguments.Length))
            $parts += , $a
        }
        $total = ($parts | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
        $out = New-Object byte[] $total; $pos = 0
        foreach ($p in $parts) { [Array]::Copy($p, 0, $out, $pos, $p.Length); $pos += $p.Length }
        return , $out
    }

    function New-UserAssistData([int]$RunCount, [int]$Focus, [int]$FocusMs, [datetime]$LastRun) {
        $b = New-Object byte[] 72
        [Array]::Copy([BitConverter]::GetBytes([uint32]$RunCount), 0, $b, 4, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$Focus), 0, $b, 8, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint32]$FocusMs), 0, $b, 12, 4)
        [Array]::Copy([BitConverter]::GetBytes($LastRun.ToUniversalTime().ToFileTimeUtc()), 0, $b, 60, 8)
        return , $b
    }
}

Describe 'Recent: archivos LNK' -Tag 'Unit' {
    It 'extrae ruta de destino, fechas, tamaño y serie del volumen' {
        $w = [datetime]'2026-10-18T09:00:00Z'
        $l = ConvertFrom-AmonLnkBytes -Bytes (New-LnkBytes 'C:\Users\S\Downloads\client.jar' $w 4096 '-nogui')
        $l.TargetPath | Should -Be 'C:\Users\S\Downloads\client.jar'
        $l.TargetModifiedUtc | Should -Be $w.ToUniversalTime()
        $l.TargetSize | Should -Be 4096
        $l.DriveSerial | Should -Be 'ABCD1234'
        $l.Arguments | Should -Be '-nogui'
    }

    It 'rechaza datos que no son LNK' {
        { ConvertFrom-AmonLnkBytes -Bytes (New-Object byte[] 100) } | Should -Throw
    }

    It 'muestra solo accesos relevantes y cuenta el resto' {
        $dir = Join-Path $TestDrive 'Recent'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'client.jar.lnk'), (New-LnkBytes 'C:\Users\S\Downloads\client.jar' ([datetime]::UtcNow)))
        [IO.File]::WriteAllBytes((Join-Path $dir 'carta.docx.lnk'), (New-LnkBytes 'C:\Users\S\Documents\carta.docx' ([datetime]::UtcNow)))
        $ctx = New-AmonTestContext
        $res = Invoke-AmonRecentAnalysis -Context $ctx -Path $dir
        ($res.Artifacts | ForEach-Object TargetPath) | Should -Contain 'C:\Users\S\Downloads\client.jar'
        ($res.Artifacts | ForEach-Object TargetPath) | Should -Not -Contain 'C:\Users\S\Documents\carta.docx'
        $res.Data['UnrelatedCount'] | Should -Be 1
        @($res.Events).Count | Should -BeGreaterThan 0
    }
}

Describe 'UserAssist' -Tag 'Unit' {
    It 'decodifica ROT13 solo en letras' {
        ConvertFrom-AmonRot13 '{1NP14R77-02R7-4R5Q-O744-2RO1NR5198O7}\abgrcnq.rkr' | Should -Be '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\notepad.exe'
    }

    It 'interpreta la estructura de 72 bytes (contador, foco y última ejecución)' {
        $t = [datetime]'2026-10-19T21:30:00Z'
        $d = ConvertFrom-AmonUserAssistData -Bytes (New-UserAssistData 12 5 65000 $t)
        $d.RunCount | Should -Be 12
        $d.FocusCount | Should -Be 5
        $d.FocusSeconds | Should -Be 65
        $d.LastRunUtc | Should -Be $t.ToUniversalTime()
    }

    It 'resuelve carpetas conocidas por GUID' {
        Resolve-AmonKnownFolderPath '{374DE290-123F-4565-9164-39C4925E467B}\x.jar' | Should -Be (Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'x.jar')
    }

    It 'filtra por relevancia y genera eventos de ejecución' {
        $t = [datetime]::UtcNow.AddHours(-2)
        $raw = @(
            [pscustomobject]@{ Category = 'Ejecutables'; Name = 'C:\Program Files\Java\jdk-21\bin\javaw.exe'; Data = (New-UserAssistData 3 1 1000 $t) },
            [pscustomobject]@{ Category = 'Ejecutables'; Name = 'C:\Program Files\Office\winword.exe'; Data = (New-UserAssistData 9 9 9000 $t) }
        )
        $res = Invoke-AmonUserAssistAnalysis -Context (New-AmonTestContext) -RawEntries $raw
        ($res.Artifacts | ForEach-Object Name) | Should -Contain 'C:\Program Files\Java\jdk-21\bin\javaw.exe'
        ($res.Artifacts | ForEach-Object Name) | Should -Not -Contain 'C:\Program Files\Office\winword.exe'
        @($res.Events | Where-Object Kind -EQ 'Execution').Count | Should -Be 1
    }
}

Describe 'Eventos de Windows' -Tag 'Unit' {
    It 'extrae el ejecutable de un valor de inicio automático' {
        Get-AmonRunValueExecutable '"C:\Program Files\App\app.exe" --min' | Should -Be 'C:\Program Files\App\app.exe'
        Get-AmonRunValueExecutable 'C:\Tools\tool.exe /silent' | Should -Be 'C:\Tools\tool.exe'
    }

    It 'distingue la limpieza del registro de Seguridad (1102) de la papelera' {
        $now = [datetime]::UtcNow
        $inj = @{
            SecurityAccessible = $true; SecurityOldestUtc = $now.AddDays(-1)
            Audit = [pscustomobject]@{ Enabled = $true; Source = 'prueba'; CommandLineIncluded = $false }
            Security4688 = @([pscustomobject]@{ TimeCreated = $now.AddHours(-3); NewProcessName = 'C:\Program Files\Java\bin\javaw.exe'; CommandLine = ''; ParentProcessName = 'C:\Windows\explorer.exe'; SubjectUserName = 'S' })
            Security1102 = @([pscustomobject]@{ TimeCreated = $now.AddHours(-1); SubjectUserName = 'S' })
            System104 = @([pscustomobject]@{ TimeCreated = $now.AddHours(-1); Channel = 'Application'; SubjectUserName = 'S' })
            Defender = @(); RunEntries = @()
        }
        $res = Invoke-AmonEventAnalysis -Context (New-AmonTestContext) -Injected $inj
        $f = $res.Findings | Where-Object Category -EQ 'SecurityLogCleared'
        $f.Status | Should -Be 'DETECTED'
        $f.Justification | Should -Match 'papelera'
        ($res.Findings | Where-Object Category -EQ 'EventLogCleared') | Should -Not -BeNullOrEmpty
        @($res.Artifacts | Where-Object EventId -EQ 4688).Count | Should -Be 1
    }

    It 'indica cuando la auditoría de creación de procesos no está activa' {
        $inj = @{ SecurityAccessible = $true; SecurityOldestUtc = [datetime]::UtcNow.AddDays(-30); Audit = [pscustomobject]@{ Enabled = $false; Source = 'prueba'; CommandLineIncluded = $false }; Security4688 = @(); Security1102 = @(); System104 = @(); Defender = @(); RunEntries = @() }
        $res = Invoke-AmonEventAnalysis -Context (New-AmonTestContext) -Injected $inj
        ($res.Limitations -join ' ') | Should -Match '4688'
    }

    It 'marca entradas de inicio automático relacionadas' {
        $inj = @{ SecurityAccessible = $false; SecurityOldestUtc = $null; Audit = [pscustomobject]@{ Enabled = $null; Source = 'sin acceso'; CommandLineIncluded = $null }; Security4688 = @(); Security1102 = @(); System104 = @(); Defender = @()
            RunEntries = @([pscustomobject]@{ Hive = 'HKCU'; Key = 'Run'; Name = 'Updater'; Value = 'C:\Users\S\AppData\Local\Temp\vape-loader.exe' }, [pscustomobject]@{ Hive = 'HKCU'; Key = 'Run'; Name = 'OneDrive'; Value = 'C:\Program Files\OneDrive\OneDrive.exe /background' }) }
        $ctx = New-AmonTestContext
        $ctx.Signatures = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')
        $res = Invoke-AmonEventAnalysis -Context $ctx -Injected $inj
        ($res.Findings | Where-Object Category -EQ 'AutorunRelated').Path | Should -Be 'C:\Users\S\AppData\Local\Temp\vape-loader.exe'
        $res.Status | Should -Be 'Partial'
    }

    It 'señala drivers instalados desde carpetas de usuario, USN borrado, exclusiones de Defender y caídas de Java por DLL ajenas' {
        $now = [datetime]::UtcNow
        $inj = @{ SecurityAccessible = $false; SecurityOldestUtc = $null; Audit = [pscustomobject]@{ Enabled = $null; Source = 'sin acceso'; CommandLineIncluded = $null }
            Security4688 = @(); Security1102 = @(); System104 = @(); Defender = @(); RunEntries = @()
            System7045 = @(
                [pscustomobject]@{ TimeCreated = $now.AddHours(-2); ServiceName = 'kdrv'; ImagePath = 'C:\Users\S\AppData\Local\Temp\kdrv.sys'; ServiceType = 'kernel mode driver'; StartType = 'demand start' },
                [pscustomobject]@{ TimeCreated = $now.AddHours(-2); ServiceName = 'Audio'; ImagePath = 'C:\Windows\System32\drivers\audio.sys'; ServiceType = 'kernel mode driver'; StartType = 'auto start' })
            Ntfs501 = @(
                [pscustomobject]@{ TimeCreated = $now.AddHours(-1); ProcessName = 'fsutil.exe'; VolumeName = 'C:'; JournalId = '0x1' },
                [pscustomobject]@{ TimeCreated = $now.AddHours(-1); ProcessName = 'SearchIndexer.'; VolumeName = 'C:'; JournalId = '0x1' })
            DefenderConfig = @(
                [pscustomobject]@{ TimeCreated = $now.AddHours(-4); EventId = 5007; NewValue = 'HKLM\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths\C:\Users\S\Downloads = 0x0'; OldValue = '' },
                [pscustomobject]@{ TimeCreated = $now.AddHours(-4); EventId = 5007; NewValue = 'HKLM\SOFTWARE\Microsoft\Windows Defender\Features\Controls\203 = 0x1'; OldValue = '' },
                [pscustomobject]@{ TimeCreated = $now.AddHours(-4); EventId = 5001; NewValue = $null; OldValue = $null })
            AppCrash = @(
                [pscustomobject]@{ TimeCreated = $now.AddHours(-5); AppName = 'javaw.exe'; AppPath = 'C:\Java\bin\javaw.exe'; ModuleName = 'x.dll'; ModulePath = 'C:\Users\S\AppData\Local\Temp\x.dll'; ExceptionCode = 'c0000005' },
                [pscustomobject]@{ TimeCreated = $now.AddHours(-5); AppName = 'javaw.exe'; AppPath = 'C:\Java\bin\javaw.exe'; ModuleName = 'jvm.dll'; ModulePath = 'C:\Java\bin\server\jvm.dll'; ExceptionCode = 'c0000005' })
        }
        $res = Invoke-AmonEventAnalysis -Context (New-AmonTestContext) -Injected $inj
        ($res.Findings | Where-Object Category -EQ 'DriverInstalled').Path | Should -Be 'C:\Users\S\AppData\Local\Temp\kdrv.sys'
        $usn = @($res.Findings | Where-Object Category -EQ 'UsnJournalDeleted')
        $usn.Count | Should -Be 1
        $usn[0].Status | Should -Be 'DETECTED'
        ($res.Findings | Where-Object Category -EQ 'DefenderExclusion').Indicator | Should -Match 'Downloads'
        ($res.Findings | Where-Object Category -EQ 'DefenderDisabled') | Should -Not -BeNullOrEmpty
        @($res.Findings | Where-Object Category -EQ 'JavaCrashForeignModule').Count | Should -Be 1
    }

    It 'un launcher legítimo en el inicio automático se lista pero no genera hallazgo' {
        $inj = @{ SecurityAccessible = $false; SecurityOldestUtc = $null; Audit = [pscustomobject]@{ Enabled = $null; Source = 'sin acceso'; CommandLineIncluded = $null }; Security4688 = @(); Security1102 = @(); System104 = @(); Defender = @()
            RunEntries = @([pscustomobject]@{ Hive = 'HKCU'; Key = 'Run'; Name = 'Lunar Client'; Value = '"C:\Users\S\AppData\Local\Programs\lunarclient\Lunar Client.exe" --hidden' }) }
        $ctx = New-AmonTestContext
        $ctx.Signatures = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')
        $res = Invoke-AmonEventAnalysis -Context $ctx -Injected $inj
        @($res.Findings | Where-Object Category -EQ 'AutorunRelated').Count | Should -Be 0
        ($res.Artifacts | Where-Object EventId -EQ 'Run').Relevance | Should -Match 'relacionado'
    }
}

Describe 'Artefactos de Windows: sistema real' -Tag 'Integration' {
    It 'Recent, UserAssist y eventos se leen sin errores' {
        $ctx = New-AmonTestContext
        (Invoke-AmonRecentAnalysis -Context $ctx).Status | Should -BeIn @('Completed', 'Partial')
        (Invoke-AmonUserAssistAnalysis -Context $ctx).Status | Should -BeIn @('Completed', 'Partial')
        (Invoke-AmonEventAnalysis -Context $ctx).Status | Should -BeIn @('Completed', 'Partial')
    }
}
