# Utilidades compartidas por todas las pruebas Pester de Amon SS.
# Se carga con dot-source desde BeforeAll en cada archivo *.Tests.ps1.

$script:AmonRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Import-AmonTestModule {
    # Importa Core y los módulos pedidos desde modules\, forzando recarga.
    param([Parameter(Mandatory = $true)][string[]]$Name)
    Import-Module (Join-Path $script:AmonRepoRoot 'modules\Core.psm1') -Force -DisableNameChecking -Global
    foreach ($n in $Name) {
        if ($n -eq 'Core') { continue }
        Import-Module (Join-Path $script:AmonRepoRoot "modules\$n.psm1") -Force -DisableNameChecking -Global
    }
}

function Get-AmonTestRoot { $script:AmonRepoRoot }

function ConvertTo-AmonFileTimeBytes {
    # FILETIME little-endian de una fecha UTC (para construir fixtures binarios).
    param([Parameter(Mandatory = $true)][datetime]$Utc)
    [BitConverter]::GetBytes($Utc.ToFileTimeUtc())
}

function Write-AmonBytesAt {
    # Copia $Source dentro de $Target a partir de $Offset.
    param([byte[]]$Target, [int]$Offset, [byte[]]$Source)
    [Array]::Copy($Source, 0, $Target, $Offset, $Source.Length)
}

function New-AmonTestJarBytes {
    # Construye un ZIP/JAR sintético en memoria. Valores string => UTF-8; byte[] => tal cual.
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entries)
    Add-Type -AssemblyName System.IO.Compression
    $ms = New-Object IO.MemoryStream
    $zip = New-Object IO.Compression.ZipArchive($ms, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($name in $Entries.Keys) {
            $e = $zip.CreateEntry($name)
            $s = $e.Open()
            try {
                $val = $Entries[$name]
                $bytes = if ($val -is [byte[]]) { $val } else { [Text.Encoding]::UTF8.GetBytes([string]$val) }
                $s.Write($bytes, 0, $bytes.Length)
            } finally { $s.Dispose() }
        }
    } finally { $zip.Dispose() }
    return , $ms.ToArray()
}

function New-AmonTestJar {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Entries)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, (New-AmonTestJarBytes -Entries $Entries))
    return $Path
}

function New-AmonTestGzip {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $fs = [IO.File]::Create($Path)
    try {
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Compress)
        try { $b = [Text.Encoding]::UTF8.GetBytes($Text); $gz.Write($b, 0, $b.Length) } finally { $gz.Dispose() }
    } finally { $fs.Dispose() }
}

function New-AmonTestFile {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text = '')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
    return $Path
}

function New-AmonTestContext {
    param([int]$Days = 7)
    $s = Get-AmonSettings -UserPath (Join-Path ([IO.Path]::GetTempPath()) 'amon-test-no-user-settings.json') -Reload
    New-AmonContext -Days $Days -Settings $s
}

function Remove-AmonAnsi {
    param([string]$Text)
    [regex]::Replace($Text, "\x1B\[[0-9;?]*[A-Za-z]", '')
}
