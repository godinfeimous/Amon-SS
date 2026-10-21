#Requires -Version 5.1
<#
    Amon SS - modules/TempSweep.psm1
    Revisión de %TEMP%:

      * Siempre, y solo por nombre: la DLL nativa de JNativeHook (JNativeHook-<versión>.<arq>.dll),
        que la versión 2.1 extrae en java.io.tmpdir cuando un programa Java instala un gancho
        global de teclado y ratón (lo usan muchos autoclickers en Java). Fuente:
        https://github.com/kwhat/jnativehook (DefaultLibraryLocator, rama 2.1).
      * Con indicadores concretos de otros módulos (nombre de archivo o SHA-256), copias de esos
        archivos. Sin indicadores no se mira nada más (privacidad).
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

function Invoke-AmonTempSweep {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string]$Path = $env:TEMP)
    $res = New-AmonModuleResult -Module 'Temp' -DisplayName 'Temp Indicator Sweep'
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        $res.Warnings.Add('La carpeta temporal no existe o no es accesible.')
        return Complete-AmonModuleResult -Result $res -Status Skipped
    }
    $res.Scope.Add("$Path (DLL de JNativeHook y, si los hay, nombres y hashes de indicadores ya encontrados)")

    # 1. JNativeHook: solo el primer nivel de Temp, donde la 2.1 extrae la DLL.
    try {
        foreach ($f in @(([IO.DirectoryInfo]$Path).GetFiles('JNativeHook*.dll'))) {
            $res.ArtifactsReviewed++
            $res.Artifacts.Add([pscustomobject]@{ Path = $f.FullName; Sha256 = $null; Size = $f.Length; CreatedUtc = $f.CreationTimeUtc; ModifiedUtc = $f.LastWriteTimeUtc; Match = 'JNativeHook (gancho global de teclado y ratón)' })
            $res.Findings.Add((New-AmonFinding -Module 'Temp' -Category 'GlobalInputHook' -Title 'Un programa Java capturó el teclado y el ratón (JNativeHook)' -Status INCONCLUSIVE -Severity Medium -Confidence Medium `
                        -Path $f.FullName -TimestampUtc $f.LastWriteTimeUtc -Indicator $f.Name -IndicatorType 'filename' `
                        -Justification ("JNativeHook extrae esta DLL en Temp cuando un programa Java instala un gancho global de teclado y ratón; creada el {0}, modificada el {1}. Es la librería que usan muchos autoclickers escritos en Java; Minecraft no la usa." -f (Format-AmonTimestamp $f.CreationTimeUtc), (Format-AmonTimestamp $f.LastWriteTimeUtc)) `
                        -FalsePositives @('Programas Java legítimos de atajos de teclado, macros de accesibilidad o grabación.')))
            foreach ($t in @(@('creada', $f.CreationTimeUtc), @('modificada', $f.LastWriteTimeUtc))) {
                if (Test-AmonInWindow -Context $Context -Utc $t[1]) { $res.Events.Add((New-AmonEvent -TimestampUtc $t[1] -Type "DLL de JNativeHook $($t[0])" -Kind Presence -Source 'Temp' -Path $f.FullName -Confidence Medium)) }
            }
        }
    } catch { $res.Warnings.Add("No se pudo listar $Path : $($_.Exception.Message)") }

    # 2. Copias de indicadores concretos.
    if (-not $Context.IndicatorNames.Count -and -not $Context.IndicatorHashes.Count) {
        $res.Limitations.Add('No hay indicadores concretos de otros módulos: en Temp solo se buscó JNativeHook (privacidad).')
        return Complete-AmonModuleResult -Result $res
    }
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
