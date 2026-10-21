<#
.SYNOPSIS
    Construye el paquete de release verificable de Amon SS.
.DESCRIPTION
    1. Comprueba UTF-8 con BOM y la validez de las firmas JSON.
    2. Ejecuta las pruebas Pester (salvo -SkipTests).
    3. Copia los archivos distribuibles a release\Amon-SS-<versión>\ y marca Core.psm1 como
       release (exige Integrity.psd1 al arrancar).
    4. Firma los scripts con Authenticode si se indica -SignThumbprint.
    5. Genera Integrity.psd1 (SHA-256 de cada archivo, ya firmados) y lo firma también.
    6. Crea Amon-SS-<versión>.zip (rutas con '/'), SHA256SUMS.txt, INSTALL-CMD.txt y RELEASE-NOTES.md.
.EXAMPLE
    .\tools\Build-Release.ps1 -Owner miusuario
.EXAMPLE
    .\tools\Build-Release.ps1 -Owner miusuario -SignThumbprint 0123ABCD... -TimestampServer http://timestamp.digicert.com
#>
[CmdletBinding()]
param(
    [string]$Owner = 'OWNER',
    [string]$Repository = 'Amon-SS',
    [string]$OutputDirectory,
    [switch]$SkipTests,
    [string]$SignThumbprint,
    [string]$TimestampServer
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'release' }
$core = Get-Content -LiteralPath (Join-Path $root 'modules\Core.psm1') -Raw -Encoding UTF8
$version = [regex]::Match($core, '\$script:AmonVersion = ''([^'']+)''').Groups[1].Value
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "No se pudo leer la versión desde modules\Core.psm1 (obtenido: '$version')." }
Write-Host "Amon SS $version -> $OutputDirectory"

& (Join-Path $root 'tools\Repair-Encoding.ps1') -Check
if ($LASTEXITCODE) { throw 'Hay scripts sin UTF-8 con BOM. Ejecuta tools\Repair-Encoding.ps1.' }

Import-Module (Join-Path $root 'modules\Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\Jar.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'modules\Signatures.psm1') -Force -DisableNameChecking
$sigErrors = @(Test-AmonSignatureSet -Set (Get-AmonSignatureSet -Path (Join-Path $root 'signatures')))
if ($sigErrors.Count) { $sigErrors | ForEach-Object { Write-Host "  $_" }; throw 'Las definiciones de firmas no son válidas.' }

if (-not $SkipTests) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Invoke-AmonTests.ps1')
    if ($LASTEXITCODE) { throw 'Las pruebas fallaron: no se genera la release.' }
}

$name = "Amon-SS-$version"
$stage = Join-Path $OutputDirectory $name
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($item in 'Start-AmonSS.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'SECURITY.md', 'config', 'modules', 'signatures', 'docs') {
    $src = Join-Path $root $item
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $stage -Recurse -Force }
}

# Marca de release: el Core del paquete exige Integrity.psd1 y se niega a arrancar sin él.
$stageCore = Join-Path $stage 'modules\Core.psm1'
$coreText = [IO.File]::ReadAllText($stageCore, [Text.Encoding]::UTF8)
if ($coreText.IndexOf('$script:AmonReleaseBuild = $false') -lt 0) { throw 'No se encontró la marca $script:AmonReleaseBuild en Core.psm1.' }
[IO.File]::WriteAllText($stageCore, $coreText.Replace('$script:AmonReleaseBuild = $false', '$script:AmonReleaseBuild = $true'), (New-Object System.Text.UTF8Encoding($true)))

# Primero se firman los scripts y después se calcula el manifiesto: así fija los bytes finales.
$signer = Join-Path $root 'tools\Sign-Release.ps1'
if ($SignThumbprint) { & $signer -Path $stage -Thumbprint $SignThumbprint -TimestampServer $TimestampServer }
$integrity = New-AmonIntegrityManifest -Root $stage
if ($SignThumbprint) { & $signer -Path $integrity -Thumbprint $SignThumbprint -TimestampServer $TimestampServer }

# ZIP con separadores '/' (ZipFile.CreateFromDirectory de .NET Framework usa '\').
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $OutputDirectory "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
try {
    $archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName)) {
            $entryName = $f.FullName.Substring($stage.TrimEnd('\').Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $archive.Dispose() }
} finally { $fs.Dispose() }
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), ("{0}  {1}.zip`n" -f $hash.ToLowerInvariant(), $name), $utf8)
$template = Get-Content -LiteralPath (Join-Path $root 'install\one-liner.template.txt') -Raw -Encoding UTF8
$cmd = $template.Trim().Replace('{{VERSION}}', $version).Replace('{{HASH}}', $hash).Replace('{{OWNER}}', $Owner).Replace('{{REPOSITORY}}', $Repository)
if ($cmd.Length -gt 8000) { throw 'El comando de instalación supera el límite de CMD.' }
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'INSTALL-CMD.txt'), $cmd + "`r`n", $utf8)

$changelog = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Raw -Encoding UTF8
$section = [regex]::Match($changelog, "(?s)## \[$([regex]::Escape($version))\].*?(?=\r?\n## \[|\z)").Value
$notes = @(
    "# Amon SS $version",
    '',
    '## Verificación',
    '',
    "SHA-256 de ``$name.zip``:",
    '',
    '```',
    $hash,
    '```',
    '',
    '## Instalación desde CMD (versión fijada y verificada)',
    '',
    '```bat',
    $cmd,
    '```',
    '',
    $section
) -join "`n"
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'RELEASE-NOTES.md'), $notes, $utf8)

Write-Host ''
Write-Host "Paquete : $zip"
Write-Host "SHA-256 : $hash"
Write-Host "Comando : $(Join-Path $OutputDirectory 'INSTALL-CMD.txt')"
if ($Owner -eq 'OWNER') { Write-Warning 'Usa -Owner <tu usuario de GitHub> para que el comando apunte al repositorio real.' }
