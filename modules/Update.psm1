#Requires -Version 5.1
<#
    Amon SS - modules/Update.psm1
    Actualizaciones verificadas, siempre a petición explícita del operador (nunca automáticas).

      * Consulta la última release publicada en GitHub (solo lectura de la API pública).
      * Descarga el ZIP de la versión elegida y lo acepta únicamente si su SHA-256 coincide con
        el valor que el operador obtuvo de un canal de confianza (README / anuncio firmado).
      * Extrae la versión verificada en %LOCALAPPDATA%\AmonSS\versions\<versión> sin tocar la
        instalación actual ni ninguna política del sistema.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

function Get-AmonLatestRelease {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers @{ 'User-Agent' = 'Amon-SS'; Accept = 'application/vnd.github+json' } -TimeoutSec 20 -ErrorAction Stop
    [pscustomobject]@{
        Tag = [string]$r.tag_name; Name = [string]$r.name; PublishedUtc = (ConvertTo-AmonUtc $r.published_at); Url = [string]$r.html_url
        Assets = @($r.assets | ForEach-Object { [pscustomobject]@{ Name = [string]$_.name; Url = [string]$_.browser_download_url; Size = [long]$_.size } })
    }
}

function Test-AmonRepositoryName {
    # "propietario/repositorio" de GitHub; se comprueba antes de guardarlo en los ajustes.
    param([AllowEmptyString()][string]$Name)
    return [bool]($Name -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
}

function Compare-AmonVersion {
    # >0 si $A es más reciente que $B; $null si alguna etiqueta no es una versión (p. ej. 'nightly').
    param([string]$A, [string]$B)
    $pa = $null; $pb = $null
    if (-not [version]::TryParse((($A -replace '^v', '') -replace '[^0-9.].*$', ''), [ref]$pa)) { return $null }
    if (-not [version]::TryParse((($B -replace '^v', '') -replace '[^0-9.].*$', ''), [ref]$pb)) { return $null }
    return $pa.CompareTo($pb)
}

function Install-AmonRelease {
    <#
    .SYNOPSIS
        Descarga y verifica una versión publicada. Devuelve la ruta del Start-AmonSS.ps1 verificado.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
        [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Sha256,
        [string]$Destination = (Join-Path (Get-AmonDataDirectory) 'versions')
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $name = "Amon-SS-$Version.zip"
    $url = "https://github.com/$Repository/releases/download/v$Version/$name"
    $target = Join-Path $Destination $Version
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $zip = Join-Path $Destination $name
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.ToUpperInvariant()) {
        Remove-Item -LiteralPath $zip -Force
        throw "SHA-256 no coincide (esperado $Sha256, obtenido $actual): la descarga se rechazó y se eliminó."
    }
    if (Test-Path -LiteralPath $target) { throw "La versión $Version ya existe en $target." }
    Expand-Archive -LiteralPath $zip -DestinationPath $target
    Get-ChildItem -LiteralPath $target -Recurse -File | Unblock-File
    $start = Get-ChildItem -LiteralPath $target -Recurse -Filter 'Start-AmonSS.ps1' | Select-Object -First 1
    if (-not $start) { throw 'El paquete verificado no contiene Start-AmonSS.ps1.' }
    return $start.FullName
}

Export-ModuleMember -Function @('Get-AmonLatestRelease', 'Test-AmonRepositoryName', 'Compare-AmonVersion', 'Install-AmonRelease')
