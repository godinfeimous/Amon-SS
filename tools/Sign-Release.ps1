<#
.SYNOPSIS
    Firma con Authenticode todos los scripts de una copia de release (para entornos AllSigned).
.DESCRIPTION
    Usa un certificado de firma de código de Cert:\CurrentUser\My identificado por su huella.
    Firma .ps1, .psm1 y .psd1 de la carpeta indicada, o un único archivo (Build-Release lo usa
    para firmar Integrity.psd1, que protege los JSON y los .cs, después de generarlo).
    Trabaja sobre la carpeta de staging, nunca sobre el repositorio.
.EXAMPLE
    .\tools\Sign-Release.ps1 -Path .\release\Amon-SS-1.0.0 -Thumbprint 0123ABCD... -TimestampServer http://timestamp.digicert.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Thumbprint,
    [string]$TimestampServer
)
$ErrorActionPreference = 'Stop'
$cert = Get-ChildItem -LiteralPath "Cert:\CurrentUser\My\$Thumbprint" -CodeSigningCert -ErrorAction Stop
$item = Get-Item -LiteralPath $Path -ErrorAction Stop
$files = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $Path -Recurse -File -Include *.ps1, *.psm1, *.psd1) } else { @($item) }
foreach ($f in $files) {
    $params = @{ FilePath = $f.FullName; Certificate = $cert; HashAlgorithm = 'SHA256' }
    if ($TimestampServer) { $params.TimestampServer = $TimestampServer }
    $s = Set-AuthenticodeSignature @params
    if ($s.Status -ne 'Valid') { throw "No se pudo firmar $($f.FullName): $($s.StatusMessage)" }
}
Write-Host "Firmados $($files.Count) scripts con '$($cert.Subject)'."
