BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule USNJournal
    Import-AmonNative

    function New-UsnV2Bytes([uint64]$Frn, [uint64]$Parent, [int64]$Usn, [datetime]$Utc, [int64]$Reason, [string]$Name) {
        $nameBytes = [Text.Encoding]::Unicode.GetBytes($Name)
        $len = 60 + $nameBytes.Length
        $len = ($len + 7) -band (-bnot 7)
        $b = New-Object byte[] $len
        [Array]::Copy([BitConverter]::GetBytes([uint32]$len), 0, $b, 0, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint16]2), 0, $b, 4, 2)
        [Array]::Copy([BitConverter]::GetBytes($Frn), 0, $b, 8, 8)
        [Array]::Copy([BitConverter]::GetBytes($Parent), 0, $b, 16, 8)
        [Array]::Copy([BitConverter]::GetBytes($Usn), 0, $b, 24, 8)
        [Array]::Copy([BitConverter]::GetBytes($Utc.ToUniversalTime().ToFileTimeUtc()), 0, $b, 32, 8)
        [Array]::Copy([BitConverter]::GetBytes([uint32]($Reason -band 0xFFFFFFFFL)), 0, $b, 40, 4)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$nameBytes.Length), 0, $b, 56, 2)
        [Array]::Copy([BitConverter]::GetBytes([uint16]60), 0, $b, 58, 2)
        [Array]::Copy($nameBytes, 0, $b, 60, $nameBytes.Length)
        return , $b
    }

    function New-UsnRecord([uint64]$Frn, [uint64]$Parent, [datetime]$Utc, [int64]$Reason, [string]$Name, [string]$ParentPath) {
        $r = New-Object AmonSS.Native.UsnRecordInfo
        $r.FileReference = $Frn; $r.ParentReference = $Parent; $r.TimestampUtc = $Utc.ToUniversalTime(); $r.Reason = [uint32]($Reason -band 0xFFFFFFFFL); $r.FileName = $Name; $r.ParentPath = $ParentPath; $r.MajorVersion = 2
        return $r
    }
}

Describe 'USN: interpretación de motivos' -Tag 'Unit' {
    It 'clasifica la operación a partir de los flags de motivo' {
        Get-AmonUsnOperation -Reason 0x80000200 | Should -Be 'Eliminación'
        Get-AmonUsnOperation -Reason 0x80002000 | Should -Be 'Renombrado (nombre nuevo)'
        Get-AmonUsnOperation -Reason 0x00001000 | Should -Be 'Renombrado (nombre anterior)'
        Get-AmonUsnOperation -Reason 0x80000102 | Should -Be 'Creación'
        Get-AmonUsnOperation -Reason 0x80000002 | Should -Be 'Modificación de datos'
        Get-AmonUsnOperation -Reason 0x80008000 | Should -Be 'Cambio de atributos o fechas'
    }

    It 'enumera los nombres de los flags' {
        ConvertTo-AmonUsnReasonText -Reason 0x80000200 | Should -Be @('FILE_DELETE', 'CLOSE')
    }
}

Describe 'USN: registros binarios' -Tag 'Unit' {
    It 'interpreta USN_RECORD_V2 consecutivos' {
        $t = [datetime]'2026-10-19T12:00:00Z'
        $a = New-UsnV2Bytes 100 5 1000 $t 0x80000200 'cheat.jar'
        $b = New-UsnV2Bytes 101 5 1080 $t 0x80000100 'notes.txt'
        $buf = New-Object byte[] ($a.Length + $b.Length)
        [Array]::Copy($a, 0, $buf, 0, $a.Length); [Array]::Copy($b, 0, $buf, $a.Length, $b.Length)
        $list = [AmonSS.Native.Usn]::ParseRecords($buf, 0, $buf.Length)
        $list.Count | Should -Be 2
        $list[0].FileName | Should -Be 'cheat.jar'
        $list[0].Reason | Should -Be ([uint32]2147484160)
        $list[0].TimestampUtc | Should -Be $t.ToUniversalTime()
        $list[1].FileReference | Should -Be 101
    }

    It 'recupera el nombre original de un archivo enviado a la papelera' {
        $t = [datetime]'2026-10-19T12:00:00Z'
        $old = New-UsnRecord 7 10 $t 0x00001000 'cheat.jar' $null
        $new = New-UsnRecord 7 20 $t 0x80002000 '$R1A2B3C.jar' $null
        $f = New-Object AmonSS.Native.UsnFilter
        $f.NamePrefixes = [string[]]@('$R')
        $state = New-Object AmonSS.Native.UsnFilterState
        $trunc = $false
        $list = [System.Collections.Generic.List[AmonSS.Native.UsnRecordInfo]]::new()
        $list.Add($old); $list.Add($new)
        $kept = [AmonSS.Native.Usn]::Apply($list, $f, $state)
        ($kept | Where-Object FileName -EQ '$R1A2B3C.jar').PreviousName | Should -Be 'cheat.jar'
    }

    It 'al alcanzar el máximo conserva los registros más recientes' {
        $list = [System.Collections.Generic.List[AmonSS.Native.UsnRecordInfo]]::new()
        1..5 | ForEach-Object { $list.Add((New-UsnRecord $_ 10 ([datetime]'2026-10-19T12:00:00Z').AddMinutes($_) 0x80000200 "f$_.jar" $null)) }
        [AmonSS.Native.Usn]::TrimToNewest($list, 2) | Should -BeTrue
        ($list | ForEach-Object FileName) | Should -Be @('f4.jar', 'f5.jar')
        [AmonSS.Native.Usn]::TrimToNewest($list, 2) | Should -BeFalse
    }

    It 'el filtro no vigila la carpeta Prefetch ni borra-nombres de comprimidos o logs' {
        $f = New-AmonUsnFilter -Context (New-AmonTestContext)
        $pfRef = [AmonSS.Native.Usn]::GetFileReference((Join-Path $env:SystemRoot 'Prefetch'))
        if ($pfRef) { $f.ParentReferences | Should -Not -Contain $pfRef }
        foreach ($e in '.zip', '.rar', '.7z', '.log', '.gz', '.dll') { $f.DeleteOnlyExtensions | Should -Not -Contain $e }
        $f.DeleteOnlyExtensions | Should -Contain '.pf'
    }
}

Describe 'USN: análisis con registros inyectados' -Tag 'Unit' {
    BeforeAll {
        $now = [datetime]::UtcNow
        $scan = New-Object AmonSS.Native.UsnScanResult
        $j = New-Object AmonSS.Native.UsnJournalInfo
        $j.JournalId = [uint64]$now.AddDays(-2).ToFileTimeUtc()
        $scan.Journal = $j
        $scan.TotalRecords = 5000
        $scan.FirstTimestampUtc = $now.AddDays(-2)
        $scan.LastTimestampUtc = $now
        $r1 = New-UsnRecord 7 20 $now.AddHours(-5) 0x80002000 '$R1A2B3C.jar' 'C:\$Recycle.Bin\S-1-5-21-1000'
        $r1.PreviousName = 'cheat.jar'; $r1.PreviousParentPath = 'C:\Users\S\Downloads'
        $scan.Records.Add($r1)
        $scan.Records.Add((New-UsnRecord 8 20 $now.AddHours(-4) 0x80000200 '$I1A2B3C.jar' 'C:\$Recycle.Bin\S-1-5-21-1000'))
        $scan.Records.Add((New-UsnRecord 9 30 $now.AddHours(-3) 0x80000200 'JAVAW.EXE-1234ABCD.pf' 'C:\Windows\Prefetch'))
        $scan.Records.Add((New-UsnRecord 10 40 $now.AddHours(-2) 0x80000200 'latest.log' 'C:\Users\S\AppData\Roaming\.minecraft\logs'))
        $script:ctx = New-AmonTestContext -Days 7
        $script:res = Invoke-AmonUsnAnalysis -Context $script:ctx -ScanResults @{ 'C:' = $scan }
    }

    It 'reconstruye el envío a la papelera con nombre y carpeta originales' {
        $a = $script:res.Data['RecycleActivity'] | Where-Object Operation -EQ 'Enviado a la papelera'
        $a.OriginalName | Should -Be 'cheat.jar'
        $a.OriginalFolder | Should -Be 'C:\Users\S\Downloads'
    }

    It 'registra elementos purgados de la papelera' {
        ($script:res.Data['RecycleActivity'] | Where-Object Operation -EQ 'Purgado de la papelera') | Should -Not -BeNullOrEmpty
    }

    It 'señala la eliminación de Prefetch y de logs como no concluyente, con falsos positivos' {
        $pf = $script:res.Findings | Where-Object Category -EQ 'PrefetchDeleted'
        $pf.Status | Should -Be 'INCONCLUSIVE'
        ($pf.FalsePositives -join ' ') | Should -Match 'Windows'
        ($script:res.Findings | Where-Object Category -EQ 'MinecraftLogDeleted') | Should -Not -BeNullOrEmpty
    }

    It 'indica cuándo el journal no cubre todo el periodo' {
        ($script:res.Limitations -join ' ') | Should -Match 'cubre'
    }

    It 'oculta el nombre original de documentos personales enviados a la papelera' {
        $now = [datetime]::UtcNow
        $scan = New-Object AmonSS.Native.UsnScanResult
        $scan.Journal = New-Object AmonSS.Native.UsnJournalInfo
        $r = New-UsnRecord 70 20 $now.AddHours(-1) 0x80002000 '$RZZZ999.docx' 'C:\$Recycle.Bin\S-1-5-21-1000'
        $r.PreviousName = 'carta-privada.docx'; $r.PreviousParentPath = 'C:\Users\S\Documents'
        $scan.Records.Add($r)
        $res = Invoke-AmonUsnAnalysis -Context (New-AmonTestContext) -ScanResults @{ 'C:' = $scan }
        ($res | ConvertTo-Json -Depth 6) | Should -Not -Match 'carta-privada'
    }

    It 'no expone el nombre de comprimidos personales enviados a la papelera' {
        $scan = New-Object AmonSS.Native.UsnScanResult
        $scan.Journal = New-Object AmonSS.Native.UsnJournalInfo
        $r = New-UsnRecord 71 20 ([datetime]::UtcNow.AddHours(-1)) 0x80002000 '$RYYY888.zip' 'C:\$Recycle.Bin\S-1-5-21-1000'
        $r.PreviousName = 'Tesis_Ana.zip'; $r.PreviousParentPath = 'C:\Users\S\Documents'
        $scan.Records.Add($r)
        $res = Invoke-AmonUsnAnalysis -Context (New-AmonTestContext) -ScanResults @{ 'C:' = $scan }
        ($res | ConvertTo-Json -Depth 6) | Should -Not -Match 'Tesis_Ana'
    }

    It 'un .pf borrado de un programa no relacionado se cuenta sin mostrar su nombre' {
        $now = [datetime]::UtcNow
        $scan = New-Object AmonSS.Native.UsnScanResult
        $scan.Journal = New-Object AmonSS.Native.UsnJournalInfo
        $scan.Records.Add((New-UsnRecord 80 30 $now.AddHours(-3) 0x80000200 'JAVAW.EXE-1234ABCD.pf' 'C:\Windows\Prefetch'))
        $scan.Records.Add((New-UsnRecord 81 30 $now.AddHours(-2) 0x80000200 'TELEGRAM.EXE-AAAA1111.pf' 'C:\Windows\Prefetch'))
        $res = Invoke-AmonUsnAnalysis -Context (New-AmonTestContext) -ScanResults @{ 'C:' = $scan }
        ($res | ConvertTo-Json -Depth 6) | Should -Not -Match 'TELEGRAM'
        $pf = $res.Findings | Where-Object Category -EQ 'PrefetchDeleted'
        $pf.Title | Should -Match '2 archivo'
        $pf.Indicator | Should -Match 'JAVAW\.EXE'
    }

    It 'incluye ruta, operación y fiabilidad de la ruta en cada registro' {
        $rec = $script:res.Artifacts | Where-Object FileName -EQ 'latest.log'
        $rec.Path | Should -Be 'C:\Users\S\AppData\Roaming\.minecraft\logs\latest.log'
        $rec.Operation | Should -Be 'Eliminación'
        $rec.PathReliability | Should -Not -BeNullOrEmpty
    }
}

Describe 'USN: sistema real' -Tag 'Integration' {
    It 'sin privilegios informa de falta de acceso; con privilegios lee el journal' {
        $res = Invoke-AmonUsnAnalysis -Context (New-AmonTestContext -Days 1)
        if (Test-AmonAdmin) { $res.Status | Should -BeIn @('Completed', 'Partial') } else { $res.Status | Should -Be 'NoAccess' }
    }
}
