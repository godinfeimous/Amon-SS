#Requires -Version 5.1
<#
    Amon SS - modules/TempSweep.psm1
    Revisión de %TEMP% SOLO cuando otro módulo ya encontró un indicador concreto (nombre de
    archivo o SHA-256). Sin indicadores no se toca la carpeta (privacidad).
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

function Invoke-AmonTempSweep {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string]$Path = $env:TEMP)
    $res = New-AmonModuleResult -Module 'Temp' -DisplayName 'Temp Indicator Sweep'
    if (-not $Context.IndicatorNames.Count -and -not $Context.IndicatorHashes.Count) {
        $res.Limitations.Add('No hay indicadores concretos de otros módulos: la carpeta Temp no se revisa (privacidad).')
        return Complete-AmonModuleResult -Result $res -Status Skipped
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $res.Warnings.Add('La carpeta temporal no existe o no es accesible.')
        return Complete-AmonModuleResult -Result $res -Status Skipped
    }
    $res.Scope.Add("$Path (profundidad 3; solo nombres y hashes de indicadores ya encontrados)")
    $max = [int]$Context.Settings.limits.maxTempFiles; if ($max -le 0) { $max = 4000 }
    $files = Get-AmonChildItemSafe -Path $Path -Include @('*.jar', '*.exe', '*.dll', '*.zip') -Depth 3 -MaxItems $max
    if ($files.Count -ge $max) { $res.Limitations.Add("Se revisaron solo los primeros $max archivos de Temp.") }
    $maxHash = [long]$Context.Settings.limits.maxExecutableScanMB * 1MB
    foreach ($f in $files) {
        if (Test-AmonCancel -Context $Context) { break }
        $res.ArtifactsReviewed++
        $byName = $Context.IndicatorNames.Contains($f.Name)
        $sha = $null; $byHash = $false
        if ($Context.IndicatorHashes.Count -and $f.Length -le $maxHash) {
            $sha = Get-AmonFileHash -Path $f.FullName -Context $Context
            $byHash = [bool]($sha -and $Context.IndicatorHashes.Contains($sha))
        }
        if (-not ($byName -or $byHash)) { continue }
        $how = if ($byHash) { 'mismo SHA-256 que un archivo señalado' } else { 'mismo nombre que un archivo señalado' }
        $res.Artifacts.Add([pscustomobject]@{ Path = $f.FullName; Sha256 = $sha; Size = $f.Length; CreatedUtc = $f.CreationTimeUtc; ModifiedUtc = $f.LastWriteTimeUtc; Match = $how })
        $res.Findings.Add((New-AmonFinding -Module 'Temp' -Category 'TempIndicator' -Title "Archivo relacionado en Temp: $($f.Name)" -Status $(if ($byHash) { 'DETECTED' } else { 'INCONCLUSIVE' }) `
                    -Severity $(if ($byHash) { 'Medium' } else { 'Low' }) -Confidence $(if ($byHash) { 'High' } else { 'Low' }) -Path $f.FullName -Sha256 $sha -TimestampUtc $f.CreationTimeUtc `
                    -Indicator $f.Name -IndicatorType $(if ($byHash) { 'sha256' } else { 'filename' }) `
                    -Justification "En la carpeta temporal hay un archivo con el $how. Las copias en Temp suelen proceder de descargas o de extracciones de instaladores." `
                    -FalsePositives @('Coincidencia de nombre con un archivo distinto (sin coincidencia de hash).')))
        foreach ($t in @(@('creado', $f.CreationTimeUtc), @('modificado', $f.LastWriteTimeUtc))) {
            if (Test-AmonInWindow -Context $Context -Utc $t[1]) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $t[1] -Type "Archivo relacionado en Temp ($($t[0]))" -Kind Presence -Source 'Temp' -Path $f.FullName -Sha256 $sha -Confidence $(if ($byHash) { 'High' } else { 'Low' })))
            }
        }
        if (-not $byHash) { Add-AmonEvidencePath -Context $Context -Path $f.FullName -Source 'Temp' -Reason 'nombre de un indicador' }
    }
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('Invoke-AmonTempSweep')
