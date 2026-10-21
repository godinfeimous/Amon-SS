# Generador de archivos Prefetch sintéticos (formato SCCA v30) y compresor MAM para pruebas.
# Estructura según la documentación pública del formato (libscca, "Windows Prefetch File format").

function New-AmonTestPrefetchBytes {
    param(
        [string]$ExeName = 'JAVAW.EXE',
        [int]$Version = 30,
        [ValidateSet(1, 2)][int]$Variant = 1,
        [int]$RunCount = 5,
        [datetime[]]$LastRuns = @(),
        [string[]]$FileNames = @(),
        [string]$DevicePath = '\VOLUME{01d2f1e8a3b4c5d6-1234abcd}',
        [uint32]$Serial = 0x1234ABCD,
        [string[]]$Directories = @()
    )
    $metricsOffset = if ($Variant -eq 1) { 0x130 } else { 0x128 }
    $buf = New-Object byte[] 65536
    # Los literales hex >= 0x80000000 son Int32 negativos en PowerShell: se enmascaran a 32 bits.
    $w32 = { param($off, $val) [Array]::Copy([BitConverter]::GetBytes([uint32]([int64]$val -band 0xFFFFFFFFL)), 0, $buf, $off, 4) }
    $w64 = { param($off, $val) [Array]::Copy([BitConverter]::GetBytes([int64]$val), 0, $buf, $off, 8) }
    $wstr = { param($off, $s) $b = [Text.Encoding]::Unicode.GetBytes($s); [Array]::Copy($b, 0, $buf, $off, $b.Length); $b.Length }

    & $w32 0 $Version
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('SCCA'), 0, $buf, 4, 4)
    [void](& $wstr 16 $ExeName)
    & $w32 76 0xDEADBEEF

    # Cadenas de nombres de archivo
    $fnOffset = $metricsOffset
    $pos = $fnOffset
    foreach ($f in $FileNames) { $pos += & $wstr $pos $f; $pos += 2 }
    $fnSize = $pos - $fnOffset
    $pos = ($pos + 7) -band (-bnot 7)

    # Información de volumen (una entrada de 96 bytes) + ruta de dispositivo + directorios
    $volOffset = $pos
    $entry = 96
    $devRel = $entry
    $devBytes = [Text.Encoding]::Unicode.GetBytes($DevicePath)
    [Array]::Copy($devBytes, 0, $buf, $volOffset + $devRel, $devBytes.Length)
    $dirRel = $devRel + $devBytes.Length + 2
    $p = $volOffset + $dirRel
    foreach ($d in $Directories) {
        [Array]::Copy([BitConverter]::GetBytes([uint16]$d.Length), 0, $buf, $p, 2)
        $p += 2
        $p += & $wstr $p $d
        $p += 2
    }
    $volSize = $p - $volOffset
    & $w32 ($volOffset + 0) $devRel
    & $w32 ($volOffset + 4) $DevicePath.Length
    & $w64 ($volOffset + 8) ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime().ToFileTimeUtc()
    & $w32 ($volOffset + 16) $Serial
    & $w32 ($volOffset + 28) $dirRel
    & $w32 ($volOffset + 32) $Directories.Count

    $fi = 84
    & $w32 ($fi + 0) $metricsOffset
    & $w32 ($fi + 4) 0
    & $w32 ($fi + 8) $metricsOffset
    & $w32 ($fi + 12) 0
    & $w32 ($fi + 16) $fnOffset
    & $w32 ($fi + 20) $fnSize
    & $w32 ($fi + 24) $volOffset
    & $w32 ($fi + 28) 1
    & $w32 ($fi + 32) $volSize
    for ($i = 0; $i -lt [Math]::Min(8, $LastRuns.Count); $i++) { & $w64 ($fi + 44 + $i * 8) $LastRuns[$i].ToUniversalTime().ToFileTimeUtc() }
    $runOffset = if ($Variant -eq 1) { $fi + 124 } else { $fi + 116 }
    & $w32 $runOffset $RunCount

    $total = $p
    & $w32 12 $total
    $out = New-Object byte[] $total
    [Array]::Copy($buf, $out, $total)
    return , $out
}

function ConvertTo-AmonTestMam {
    # Comprime con RtlCompressBuffer (XPRESS Huffman) y añade la cabecera MAM\x04 + tamaño.
    param([byte[]]$Bytes)
    if (-not ('AmonTest.Mam' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AmonTest {
    public static class Mam {
        [DllImport("ntdll.dll")] static extern uint RtlGetCompressionWorkSpaceSize(ushort f, out uint ws, out uint frag);
        [DllImport("ntdll.dll")] static extern uint RtlCompressBuffer(ushort f, byte[] src, int srcLen, byte[] dst, int dstLen, int chunk, out int final, byte[] ws);
        public static byte[] Compress(byte[] data) {
            uint ws, frag;
            RtlGetCompressionWorkSpaceSize(4, out ws, out frag);
            byte[] work = new byte[ws];
            byte[] dst = new byte[data.Length + 4096];
            int final;
            uint st = RtlCompressBuffer(4, data, data.Length, dst, dst.Length, 4096, out final, work);
            if (st != 0) throw new Exception("RtlCompressBuffer 0x" + st.ToString("X8"));
            byte[] outBuf = new byte[8 + final];
            outBuf[0] = 0x4D; outBuf[1] = 0x41; outBuf[2] = 0x4D; outBuf[3] = 0x04;
            Buffer.BlockCopy(BitConverter.GetBytes(data.Length), 0, outBuf, 4, 4);
            Buffer.BlockCopy(dst, 0, outBuf, 8, final);
            return outBuf;
        }
    }
}
'@
    }
    return , [AmonTest.Mam]::Compress($Bytes)
}
