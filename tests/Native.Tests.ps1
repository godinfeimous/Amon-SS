BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Core
    Import-AmonNative
    function Get-Bytes([string]$s) { [Text.Encoding]::UTF8.GetBytes($s) }
    function New-Matcher([object[]]$Patterns) {
        $l = [System.Collections.Generic.List[byte[]]]::new()
        foreach ($p in $Patterns) { if ($p -is [string]) { $l.Add((Get-Bytes $p)) } else { $l.Add([byte[]]$p) } }
        New-Object AmonSS.Native.PatternMatcher (, $l.ToArray())
    }
}

Describe 'Native: motor multi-patrón (Aho-Corasick)' -Tag 'Unit' {
    It 'encuentra varios patrones y su primer desplazamiento' {
        $m = New-Matcher @('he', 'she', 'hers')
        $r = $m.ScanBytes((Get-Bytes 'ushers'))
        $r.Patterns | Sort-Object | Should -Be @(0, 1, 2)
        $r.Offsets[[array]::IndexOf($r.Patterns, 1)] | Should -Be 1
    }

    It 'distingue mayúsculas y conserva símbolos y barras invertidas' {
        $m = New-Matcher @('pcwP\tDGFtvjQb')
        $m.ScanBytes((Get-Bytes 'xxpcwP\tDGFtvjQbxx')).Patterns.Count | Should -Be 1
        $m.ScanBytes((Get-Bytes "xxpcwP`tDGFtvjQbxx")).Patterns.Count | Should -Be 0
        $m.ScanBytes((Get-Bytes 'xxPCWP\TDGFTVJQBxx')).Patterns.Count | Should -Be 0
    }

    It 'detecta patrones partidos entre bloques de lectura de un archivo grande' {
        $p = Join-Path $TestDrive 'split.bin'
        $data = New-Object byte[] (200000)
        $needle = Get-Bytes 'i_PlZygNMqUlcpwF'
        # Colocar el patrón cruzando el límite de 65536 bytes.
        [Array]::Copy($needle, 0, $data, 65536 - 5, $needle.Length)
        [IO.File]::WriteAllBytes($p, $data)
        $m = New-Matcher @(, $needle)
        $r = $m.ScanFile($p, 0)
        $r.Patterns.Count | Should -Be 1
        $r.Offsets[0] | Should -Be (65536 - 5)
        $r.BytesScanned | Should -Be 200000
    }

    It 'respeta el límite de bytes y lo indica' {
        $p = Join-Path $TestDrive 'limit.bin'
        $data = New-Object byte[] 5000
        $needle = Get-Bytes 'zprestige'
        [Array]::Copy($needle, 0, $data, 4500, $needle.Length)
        [IO.File]::WriteAllBytes($p, $data)
        $m = New-Matcher @(, $needle)
        $r = $m.ScanFile($p, 1000)
        $r.Patterns.Count | Should -Be 0
        $r.Truncated | Should -BeTrue
    }

    It 'rechaza patrones vacíos' {
        { New-Matcher @(, (New-Object byte[] 0)) } | Should -Throw
    }
}

Describe 'Native: referencia de archivo NTFS' -Tag 'Integration' {
    It 'GetFileReference coincide con el identificador que muestra fsutil' {
        # El filtro de carpetas del USN Journal compara esta referencia con ParentFileReferenceNumber.
        $f = Join-Path $TestDrive 'ref.txt'
        Set-Content -LiteralPath $f -Value 'x'
        $out = (fsutil file queryFileID $f) -join ' '
        $m = [regex]::Match($out, '0x([0-9a-fA-F]{16,32})')
        if (-not $m.Success) { Set-ItResult -Skipped -Because "fsutil no devolvió un identificador: $out"; return }
        $hex = $m.Groups[1].Value; $hex = $hex.Substring([Math]::Max(0, $hex.Length - 16))
        $expected = [Convert]::ToUInt64($hex, 16)
        [AmonSS.Native.Usn]::GetFileReference($f) | Should -Be $expected
        [AmonSS.Native.Usn]::GetFileReference((Split-Path -Parent $f)) | Should -Not -Be 0
    }
}
