#Requires -Version 5.1
<#
    Amon SS - modules/RecycleBin.psm1
    Análisis forense de la papelera del usuario actual: C:\$Recycle.Bin\<SID> en cada unidad fija.

      * $I (metadatos): versión 1 (Vista/7/8, 544 bytes) y versión 2 (Windows 10/11): tamaño
        original, fecha de eliminación y ruta original.
      * $R (contenido): presencia, tipo (archivo/carpeta) y tamaño real.
      * RECYCLE BIN ACTIVITY: eliminaciones registradas en el periodo, inconsistencias de
        metadatos, contenido ausente y modificaciones del contenedor. La correlación con el
        USN Journal la hace el motor de correlación.

    Reglas: no se restaura, mueve ni borra nada. Los elementos sin relación con la revisión
    solo se cuentan por extensión (privacidad). Nunca se afirma intención: los artefactos solo
    permiten describir qué cambió y cuándo.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:ScanExtensions = @('.jar', '.exe', '.dll', '.zip')

function ConvertFrom-AmonRecycleInfoBytes {
    <#
    .SYNOPSIS
        Interpreta un archivo $I de la papelera.
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -lt 24) { throw 'Archivo $I demasiado pequeño.' }
    $version = [BitConverter]::ToInt64($Bytes, 0)
    $size = [BitConverter]::ToInt64($Bytes, 8)
    $deleted = ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 16))
    switch ($version) {
        1 {
            $len = [Math]::Min(520, $Bytes.Length - 24)
            if ($len -le 0) { throw 'Archivo $I v1 truncado.' }
            $path = [Text.Encoding]::Unicode.GetString($Bytes, 24, $len - ($len % 2))
        }
        2 {
            if ($Bytes.Length -lt 28) { throw 'Archivo $I v2 truncado.' }
            $chars = [BitConverter]::ToInt32($Bytes, 24)
            if ($chars -le 0 -or (28 + $chars * 2) -gt $Bytes.Length) { throw 'Longitud de ruta inválida en $I v2.' }
            $path = [Text.Encoding]::Unicode.GetString($Bytes, 28, $chars * 2)
        }
        default { throw "Versión de `$I desconocida: $version" }
    }
    $nul = $path.IndexOf([char]0); if ($nul -ge 0) { $path = $path.Substring(0, $nul) }
    [pscustomobject]@{ Version = [int]$version; DeclaredSize = $size; DeletedUtc = $deleted; OriginalPath = $path }
}

function Get-AmonRecycleBinFolders {
    # Carpetas $Recycle.Bin\<SID> del usuario actual en las unidades fijas.
    param([string]$Sid = (Get-AmonCurrentUserSid))
    if (-not $Sid) { return @() }
    $out = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne [IO.DriveType]::Fixed -or -not $d.IsReady) { continue }
            $p = Join-Path $d.RootDirectory.FullName ('$Recycle.Bin\' + $Sid)
            if ([IO.Directory]::Exists($p)) { $out += $p }
        } catch { }
    }
    return $out
}

function Get-AmonDirectorySize {
    # Tamaño acotado de una carpeta $R (sin seguir puntos de reanálisis).
    param([string]$Path, [int]$MaxFiles = 5000)
    $files = Get-AmonChildItemSafe -Path $Path -Depth 32 -MaxItems ($MaxFiles + 1)
    $sum = 0L; foreach ($f in $files) { $sum += $f.Length }
    [pscustomobject]@{ Size = $sum; Complete = ($files.Count -le $MaxFiles) }
}

function New-AmonRecycleActivity {
    param([string]$Category, $TimestampUtc, [string]$Path, [string]$Description, [string]$Confidence = 'Medium')
    [pscustomobject]@{ Category = $Category; TimestampUtc = (ConvertTo-AmonUtc $TimestampUtc); Path = $Path; Description = $Description; Confidence = $Confidence; Source = 'RecycleBin' }
}

function Invoke-AmonRecycleBinAnalysis {
    <#
    .SYNOPSIS
        Analiza la papelera del usuario actual y devuelve un AmonSS.ModuleResult.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string[]]$Folders)
    $res = New-AmonModuleResult -Module 'RecycleBin' -DisplayName 'Recycle Bin Forensics'
    $activity = [System.Collections.Generic.List[object]]::new()
    $res.Data['Activity'] = $activity
    if (-not $Folders) { $Folders = @(Get-AmonRecycleBinFolders) }
    $res.Data['Folders'] = $Folders
    if (-not $Folders.Count) {
        $activity.Add((New-AmonRecycleActivity -Category 'Evidencia insuficiente' -Description 'No existe carpeta de papelera para el usuario actual en las unidades fijas.' -Confidence Low))
        $res.Limitations.Add('Sin carpeta de papelera: no hay datos que analizar.')
        return Complete-AmonModuleResult -Result $res
    }
    $interesting = @($Context.Settings.interestingExtensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $keywords = @($Context.Keywords)
    $indicators = @($Context.IndicatorNames)
    $instanceDirs = @($Context.Instances | ForEach-Object { $_.GameDir })
    $showAll = [bool]$Context.Settings.privacy.showUnrelatedRecycleEntries
    $unrelated = 0; $byExt = @{}
    $now = [datetime]::UtcNow

    foreach ($folder in $Folders) {
        if (Test-AmonCancel -Context $Context) { break }
        $res.Scope.Add($folder)
        try { $items = @(([IO.DirectoryInfo]$folder).GetFileSystemInfos()) }
        catch {
            $res.Warnings.Add("No se pudo leer $folder : $($_.Exception.Message)")
            $activity.Add((New-AmonRecycleActivity -Category 'Evidencia insuficiente' -Path $folder -Description 'Sin acceso a la carpeta de la papelera.' -Confidence Low))
            continue
        }
        $iFiles = @($items | Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) -and -not ($_.Attributes -band [IO.FileAttributes]::Directory) })
        $rByKey = @{}
        foreach ($it in $items) { if ($it.Name.StartsWith('$R', [StringComparison]::OrdinalIgnoreCase)) { $rByKey[$it.Name.Substring(2).ToUpperInvariant()] = $it } }
        $paired = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $newestI = $null

        foreach ($i in $iFiles) {
            $res.ArtifactsReviewed++
            $key = $i.Name.Substring(2).ToUpperInvariant()
            $r = $rByKey[$key]
            if ($r) { [void]$paired.Add($key) }
            if (-not $newestI -or $i.CreationTimeUtc -gt $newestI) { $newestI = $i.CreationTimeUtc }
            try { $info = ConvertFrom-AmonRecycleInfoBytes -Bytes (Read-AmonFileBytes -Path $i.FullName -MaxBytes 64KB) }
            catch {
                $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $i.CreationTimeUtc -Path $i.FullName -Description "El archivo `$I no se pudo interpretar: $($_.Exception.Message)"))
                continue
            }
            $origName = [IO.Path]::GetFileName($info.OriginalPath)
            $ext = [IO.Path]::GetExtension($origName).ToLowerInvariant()
            $reason = $null
            if ($indicators | Where-Object { $_ -ieq $origName }) { $reason = 'coincide con un indicador' }
            elseif ($k = Test-AmonKeywordMatch -Text $info.OriginalPath -Keywords $keywords) { $reason = "palabra clave '$k'" }
            elseif ($instanceDirs | Where-Object { $_ -and $info.OriginalPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) { $reason = 'carpeta de Minecraft' }
            elseif ($interesting -contains $ext) { $reason = "extensión $ext" }
            $relevant = [bool]$reason -or $showAll
            $shownPath = if ($relevant) { $info.OriginalPath } else { "(elemento no relacionado $ext, ruta omitida por privacidad)" }

            $isDir = [bool]($r -and ($r.Attributes -band [IO.FileAttributes]::Directory))
            $dataSize = $null; $sizeComplete = $true
            if ($r) {
                if ($isDir) { $ds = Get-AmonDirectorySize -Path $r.FullName; $dataSize = $ds.Size; $sizeComplete = $ds.Complete }
                else { $dataSize = $r.Length }
            }
            $issues = [System.Collections.Generic.List[string]]::new()
            if (-not $r) {
                $activity.Add((New-AmonRecycleActivity -Category 'Archivo asociado ausente' -TimestampUtc $info.DeletedUtc -Path $shownPath -Description "Existe el `$I ($($i.Name)) pero no su contenido `$R: el contenido se eliminó por separado o el elemento se restauró de forma incompleta." -Confidence Medium))
                $issues.Add('contenido $R ausente')
            } elseif ($sizeComplete -and $null -ne $dataSize -and $dataSize -ne $info.DeclaredSize) {
                $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $info.DeletedUtc -Path $shownPath -Description "Tamaño declarado en `$I: $($info.DeclaredSize) bytes; tamaño real del `$R: $dataSize bytes." -Confidence Medium))
                $issues.Add('tamaño distinto al declarado')
            }
            if (-not $info.DeletedUtc) {
                $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $i.CreationTimeUtc -Path $shownPath -Description 'La fecha de eliminación del $I es nula o inválida.'))
                $issues.Add('fecha inválida')
            } elseif ($info.DeletedUtc -gt $now.AddDays(1)) {
                $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $info.DeletedUtc -Path $shownPath -Description 'La fecha de eliminación está en el futuro respecto al reloj del sistema.'))
                $issues.Add('fecha futura')
            } elseif ([Math]::Abs(($info.DeletedUtc - $i.CreationTimeUtc).TotalMinutes) -gt 10) {
                $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $info.DeletedUtc -Path $shownPath -Description ("La fecha de eliminación registrada ({0}) no coincide con la creación del archivo `$I ({1}); puede deberse a copiar la papelera entre equipos o a fechas alteradas." -f (Format-AmonTimestamp $info.DeletedUtc), (Format-AmonTimestamp $i.CreationTimeUtc)) -Confidence Low))
                $issues.Add('fecha de $I distinta')
            }
            $inWindow = Test-AmonInWindow -Context $Context -Utc $info.DeletedUtc
            if ($inWindow) {
                $activity.Add((New-AmonRecycleActivity -Category 'Eliminación registrada' -TimestampUtc $info.DeletedUtc -Path $shownPath -Description $(if ($relevant) { "Enviado a la papelera ($reason)." } else { 'Elemento no relacionado enviado a la papelera.' }) -Confidence High))
            }
            if (-not $relevant) {
                $unrelated++
                $extKey = if ($ext) { $ext } else { '(sin extensión)' }
                if ($byExt.ContainsKey($extKey)) { $byExt[$extKey]++ } else { $byExt[$extKey] = 1 }
                continue
            }
            $res.Artifacts.Add([pscustomobject]@{
                    OriginalPath = $info.OriginalPath; OriginalName = $origName; DeletedUtc = $info.DeletedUtc; DeclaredSize = $info.DeclaredSize
                    InfoFile = $i.FullName; DataFile = $(if ($r) { $r.FullName } else { $null }); DataExists = [bool]$r; DataIsDirectory = $isDir
                    DataSize = $dataSize; Version = $info.Version; Relevance = $reason; Issues = @($issues); Folder = $folder
                })
            if ($info.DeletedUtc) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $info.DeletedUtc -Type 'Archivo enviado a la papelera' -Kind Deletion -Source 'RecycleBin ($I)' -Path $info.OriginalPath -Confidence High -Description "Registrado en $($i.Name); motivo de relevancia: $reason"))
            }
            if ($r -and -not $isDir -and $script:ScanExtensions -contains $ext) {
                Add-AmonEvidencePath -Context $Context -Path $r.FullName -Source 'RecycleBin' -Reason "contenido eliminado de $origName"
            }
            if ($inWindow) {
                $strong = $reason -like 'palabra clave*' -or $reason -like 'coincide*' -or $reason -eq 'carpeta de Minecraft'
                $res.Findings.Add((New-AmonFinding -Module 'RecycleBin' -Category 'RelevantDeletion' -Title "Eliminación registrada: $origName" -Status DETECTED -Severity $(if ($strong) { 'Medium' } else { 'Low' }) -Confidence High `
                            -Path $info.OriginalPath -TimestampUtc $info.DeletedUtc -Indicator $origName -IndicatorType 'filename' `
                            -Justification ("El archivo se envió a la papelera el {0} ({1}). Registrar una eliminación no demuestra intención ni contenido malicioso." -f (Format-AmonTimestamp $info.DeletedUtc), $reason) `
                            -FalsePositives @('Limpieza normal de descargas, actualizaciones de mods o desinstalaciones.') `
                            -Evidence @(New-AmonEvidence -Source 'RecycleBin' -Kind Deletion -Path $i.FullName -TimestampUtc $info.DeletedUtc -Description "$($i.Name): ruta original $($info.OriginalPath); contenido $(if ($r) { 'presente en ' + $r.Name } else { 'ausente' })") `
                            -Data @{ DataFile = $(if ($r) { $r.FullName } else { $null }); Issues = @($issues) }))
            }
        }

        # Contenido sin metadatos ($R sin $I)
        foreach ($k in $rByKey.Keys) {
            if ($paired.Contains($k)) { continue }
            $r = $rByKey[$k]
            $res.ArtifactsReviewed++
            $activity.Add((New-AmonRecycleActivity -Category 'Inconsistencia de metadatos' -TimestampUtc $r.LastWriteTimeUtc -Path $r.FullName -Description 'Contenido $R sin su archivo de metadatos $I: no se conoce la ruta original ni la fecha de eliminación.' -Confidence Medium))
            $res.Findings.Add((New-AmonFinding -Module 'RecycleBin' -Category 'OrphanRecycleData' -Title "Contenido de papelera sin metadatos: $($r.Name)" -Status INCONCLUSIVE -Severity Low -Confidence Medium `
                        -Path $r.FullName -TimestampUtc $r.LastWriteTimeUtc -Indicator $r.Name -IndicatorType 'filename' `
                        -Justification 'Falta el $I correspondiente. Puede ocurrir por eliminación manual de metadatos, errores del sistema de archivos o herramientas de limpieza; los artefactos no permiten saber cuál.' `
                        -FalsePositives @('Corrupción del sistema de archivos o papelera copiada parcialmente.')))
            $ext = $r.Extension.ToLowerInvariant()
            if (-not ($r.Attributes -band [IO.FileAttributes]::Directory) -and $script:ScanExtensions -contains $ext) {
                Add-AmonEvidencePath -Context $Context -Path $r.FullName -Source 'RecycleBin' -Reason 'contenido $R sin metadatos'
            }
        }

        # Actividad del contenedor
        $dirInfo = [IO.DirectoryInfo]$folder
        $lw = $dirInfo.LastWriteTimeUtc
        if (Test-AmonInWindow -Context $Context -Utc $lw) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $lw -Type 'Contenedor de la papelera modificado' -Kind Modification -Source 'RecycleBin (carpeta)' -Path $folder -Confidence Low -Description 'Última escritura en la carpeta $Recycle.Bin del usuario.'))
            if (-not $newestI) {
                $activity.Add((New-AmonRecycleActivity -Category 'Evidencia insuficiente' -TimestampUtc $lw -Path $folder -Description ("La papelera está vacía y su contenedor se modificó el {0}. Es compatible con vaciarla, restaurar o eliminar los últimos elementos; los artefactos no permiten determinar qué ocurrió ni quién lo hizo." -f (Format-AmonTimestamp $lw)) -Confidence Low))
            } elseif (($lw - $newestI).TotalMinutes -gt 2) {
                $activity.Add((New-AmonRecycleActivity -Category 'Evidencia insuficiente' -TimestampUtc $lw -Path $folder -Description ("El contenedor se modificó ({0}) después de la última eliminación registrada ({1}). Es compatible con un vaciado parcial, una restauración o la eliminación permanente de elementos; sin el USN Journal no se puede precisar." -f (Format-AmonTimestamp $lw), (Format-AmonTimestamp $newestI)) -Confidence Low))
            }
        }
    }

    if (-not @($activity | Where-Object { Test-AmonInWindow -Context $Context -Utc $_.TimestampUtc }).Count) {
        $activity.Add((New-AmonRecycleActivity -Category 'Evidencia insuficiente' -Description "No hay operaciones de papelera registradas en el periodo analizado ($($Context.Days) días)." -Confidence Low))
    }
    $res.Data['UnrelatedCount'] = $unrelated
    $res.Data['UnrelatedByExtension'] = $byExt
    if ($unrelated) { $res.Limitations.Add("$unrelated elemento(s) sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('Solo se analiza la papelera del usuario actual. Los archivos borrados con Mayús+Supr o desde la consola no pasan por la papelera: el USN Journal puede registrarlos.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('ConvertFrom-AmonRecycleInfoBytes', 'Get-AmonRecycleBinFolders', 'Invoke-AmonRecycleBinAnalysis')
