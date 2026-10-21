<#
.SYNOPSIS
    Ejecuta la batería de pruebas Pester de Amon SS.
.DESCRIPTION
    Por defecto ejecuta solo las pruebas 'Unit' (fixtures sintéticos, no tocan el sistema).
    -Integration añade pruebas de solo lectura contra el Windows real (papelera propia,
    Recent, UserAssist, procesos). -Admin añade las que necesitan elevación (Prefetch real,
    USN Journal, registro de Seguridad).
.EXAMPLE
    powershell -NoProfile -File tests\Invoke-AmonTests.ps1
.EXAMPLE
    powershell -NoProfile -File tests\Invoke-AmonTests.ps1 -Integration -OutputXml results.xml
#>
[CmdletBinding()]
param(
    [switch]$Integration,
    [switch]$Admin,
    [string]$OutputXml,
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' -and $_.Version -lt [version]'6.0.0' } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    throw 'Se necesita Pester 5.x: Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -SkipPublisherCheck'
}
Import-Module $pester.Path -Force

$tags = @('Unit')
if ($Integration) { $tags += 'Integration' }
if ($Admin) { $tags += 'Admin' }

$config = New-PesterConfiguration
$config.Run.Path = if ($Path) { $Path } else { $PSScriptRoot }
$config.Run.Exit = $false
$config.Run.PassThru = $true
$config.Filter.Tag = $tags
$config.Output.Verbosity = 'Detailed'
if ($OutputXml) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = $OutputXml
}

Write-Host ("Pester {0} | PowerShell {1} ({2}) | etiquetas: {3}" -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, ($tags -join ', '))
$result = Invoke-Pester -Configuration $config
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
