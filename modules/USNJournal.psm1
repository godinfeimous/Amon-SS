#Requires -Version 5.1
<#
    Amon SS - modules/USNJournal.psm1
    Analizador de solo lectura del USN Journal de NTFS ($Extend\$UsnJrnl:$J).

      * Lee el journal con FSCTL_QUERY_USN_JOURNAL / FSCTL_READ_USN_JOURNAL (requiere
        administrador). Nunca lo modifica, trunca ni elimina.
      * Filtra en C# por relevancia (privacidad y rendimiento): JAR, $I/$R de la papelera,
        borrados de .pf/.log/ejecutables, palabras clave, indicadores y carpetas de las instancias.
      * Reconstruye rutas con la ubicación ACTUAL del directorio padre (OpenFileById); si el
        padre ya no existe solo se conoce el nombre.
      * Reconstruye envíos a la papelera (nombre y carpeta originales) aunque luego se vaciara.

    El journal es circular: si los registros más antiguos ya se sobrescribieron se indica.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:ReasonFlags = @(
    @(0x1L, 'DATA_OVERWRITE'), @(0x2L, 'DATA_EXTEND'), @(0x4L, 'DATA_TRUNCATION'), @(0x10L, 'NAMED_DATA_OVERWRITE'),
    @(0x20L, 'NAMED_DATA_EXTEND'), @(0x40L, 'NAMED_DATA_TRUNCATION'), @(0x100L, 'FILE_CREATE'), @(0x200L, 'FILE_DELETE'),
    @(0x400L, 'EA_CHANGE'), @(0x800L, 'SECURITY_CHANGE'), @(0x1000L, 'RENAME_OLD_NAME'), @(0x2000L, 'RENAME_NEW_NAME'),
    @(0x4000L, 'INDEXABLE_CHANGE'), @(0x8000L, 'BASIC_INFO_CHANGE'), @(0x10000L, 'HARD_LINK_CHANGE'), @(0x20000L, 'COMPRESSION_CHANGE'),
    @(0x40000L, 'ENCRYPTION_CHANGE'), @(0x80000L, 'OBJECT_ID_CHANGE'), @(0x100000L, 'REPARSE_POINT_CHANGE'), @(0x200000L, 'STREAM_CHANGE'),
    @(0x400000L, 'TRANSACTED_CHANGE'), @(0x800000L, 'INTEGRITY_CHANGE'), @(0x1000000L, 'DESIRED_STORAGE_CLASS_CHANGE'), @(0x80000000L, 'CLOSE')
)

function ConvertTo-AmonUsnReason {
    # Normaliza a 32 bits sin signo (los literales hex grandes son negativos en PowerShell).
    param([int64]$Reason)
    return ($Reason -band 0xFFFFFFFFL)
}

function ConvertTo-AmonUsnReasonText {
    param([Parameter(Mandatory = $true)][int64]$Reason)
    $r = ConvertTo-AmonUsnReason $Reason
    return @($script:ReasonFlags | Where-Object { ($r -band $_[0]) -ne 0 } | ForEach-Object { $_[1] })
}

function Get-AmonUsnOperation {
    param([Parameter(Mandatory = $true)][int64]$Reason)
    $r = ConvertTo-AmonUsnReason $Reason
    if ($r -band 0x200L) { return 'Eliminación' }
    if ($r -band 0x1000L) { return 'Renombrado (nombre anterior)' }
    if ($r -band 0x2000L) { return 'Renombrado (nombre nuevo)' }
    if ($r -band 0x100L) { return 'Creación' }
    if ($r -band 0x77L) { return 'Modificación de datos' }
    if ($r -band 0x8000L) { return 'Cambio de atributos o fechas' }
    if ($r -band 0x800L) { return 'Cambio de seguridad' }
    return 'Otro'
}

function ConvertFrom-AmonUsnRecord {
    param([Parameter(Mandatory = $true)]$Record, [string]$Drive)
    $op = Get-AmonUsnOperation -Reason $Record.Reason
    if ($Record.ParentPath) {
        $path = Join-Path $Record.ParentPath $Record.FileName
        $rel = 'Reconstruida con la ubicación actual del directorio padre'
    } else {
        $path = $Record.FileName
        $rel = 'Solo nombre: el directorio padre ya no existe o no se pudo resolver'
    }
    [pscustomobject]@{
        PSTypeName = 'AmonSS.UsnRecord'
        TimestampUtc = $Record.TimestampUtc; Drive = $Drive; Usn = $Record.Usn; FileName = $Record.FileName
        ParentPath = $Record.ParentPath; Path = $path; PathReliability = $rel; Operation = $op
        Reasons = ((ConvertTo-AmonUsnReasonText -Reason $Record.Reason) -join ' | '); Reason = $Record.Reason
        FileReference = $Record.FileReference; ParentReference = $Record.ParentReference
        PreviousName = $Record.PreviousName; PreviousParentPath = $Record.PreviousParentPath; Attributes = $Record.Attributes
    }
}

function Test-AmonUsnNameRelevant {
    # Nombre relevante: extensión de interés, indicador concreto o palabra clave de la revisión.
    param($Context, [string]$Name, [string]$Folder)
    if (-not $Name) { return $false }
    $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
    if (@($Context.Settings.interestingExtensions) -contains $ext) { return $true }
    if ($Context.IndicatorNames.Contains($Name)) { return $true }
    return [bool](Test-AmonKeywordMatch -Text "$Folder\$Name" -Keywords @($Context.Keywords))
}

function Get-AmonUsnTargetVolumes {
    # Unidad del sistema + unidades donde están realmente las instancias (resolviendo junctions).
    param($Context)
    $letters = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($env:SystemDrive) { [void]$letters.Add($env:SystemDrive.TrimEnd('\')) }
    foreach ($inst in $Context.Instances) {
        foreach ($p in @($inst.GameDir, ([AmonSS.Native.Usn]::GetFinalPath($inst.GameDir)))) {
            if ($p -and $p -match '^([A-Za-z]:)') { [void]$letters.Add($Matches[1].ToUpperInvariant()) }
        }
    }
    $out = @()
    foreach ($l in $letters) {
        try { $di = New-Object IO.DriveInfo($l); if ($di.IsReady -and $di.DriveFormat -in @('NTFS', 'ReFS')) { $out += $l } } catch { }
    }
    return $out
}

function New-AmonUsnFilter {
    param($Context)
    $f = New-Object AmonSS.Native.UsnFilter
    $f.MinTimestampUtc = $Context.SinceUtc
    $f.MaxTimestampUtc = $Context.UntilUtc.AddMinutes(10)
    $f.NameContains = [string[]]@(@($Context.Keywords) + @($Context.IndicatorNames) | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique)
    $f.Extensions = [string[]]@('.jar')
    # Borrados en todo el volumen solo de Prefetch y ejecutables/scripts. Comprimidos, logs y
    # DLL quedan fuera: exponen nombres personales o son ruido de Windows Update. Los logs de
    # Minecraft entran por las carpetas de las instancias.
    $f.DeleteOnlyExtensions = [string[]]@('.pf', '.exe', '.bat', '.cmd', '.ps1', '.vbs')
    $f.NamePrefixes = [string[]]@('$I', '$R')
    $refs = [System.Collections.Generic.List[uint64]]::new()
    # La carpeta Prefetch no se vigila entera: cada programa que se abre actualiza su .pf.
    $dirs = @()
    foreach ($inst in $Context.Instances) { $dirs += @($inst.GameDir) + @($inst.ModsDirs) + @($inst.LogDirs) + @($inst.VersionsDir) + @($inst.ConfigDir) }
    foreach ($d in ($dirs | Where-Object { $_ } | Select-Object -Unique)) {
        $ref = [AmonSS.Native.Usn]::GetFileReference($d)
        if ($ref -ne 0) { $refs.Add($ref) }
    }
    $f.ParentReferences = $refs.ToArray()
    $f.MaxResults = [int]$Context.Settings.limits.maxUsnResults
    return $f
}

function Invoke-AmonUsnAnalysis {
    <#
    .SYNOPSIS
        Analiza el USN Journal y devuelve un AmonSS.ModuleResult.
    .PARAMETER ScanResults
        Resultados ya leídos (hashtable unidad -> AmonSS.Native.UsnScanResult); se usa en pruebas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string[]]$Volumes, [hashtable]$ScanResults)
    $res = New-AmonModuleResult -Module 'USNJournal' -DisplayName 'NTFS / USN Journal'
    $res.RequiresAdmin = $true
    Import-AmonNative
    $recycle = [System.Collections.Generic.List[object]]::new()
    $journals = [System.Collections.Generic.List[object]]::new()
    $res.Data['RecycleActivity'] = $recycle
    $res.Data['Journals'] = $journals

    if (-not $ScanResults) {
        if (-not $Context.IsAdmin) {
            $res.Warnings.Add('Windows solo permite leer el USN Journal a administradores. Ejecuta Amon SS como administrador para incluir este módulo.')
            return Complete-AmonModuleResult -Result $res -Status NoAccess
        }
        if (-not $Volumes) { $Volumes = @(Get-AmonUsnTargetVolumes -Context $Context) }
        $filter = New-AmonUsnFilter -Context $Context
        $ScanResults = @{}
        $vi = 0
        foreach ($v in $Volumes) {
            if (Test-AmonCancel -Context $Context) { break }
            $vi++
            Update-AmonProgress -Context $Context -Percent (80.0 * ($vi - 1) / [Math]::Max(1, $Volumes.Count)) -Detail "Leyendo journal de $v" -Count $res.ArtifactsReviewed
            $deadline = if ($Context.Deadline) { $Context.Deadline } else { [datetime]::UtcNow.AddMinutes(3) }
            $ScanResults[$v] = [AmonSS.Native.Usn]::ReadJournal($v, $filter, $deadline)
        }
    }

    $sentToBin = @{}
    $hiddenNames = 0
    $prefetchHidden = 0; $prefetchHiddenUtc = $null
    $prefetchDeleted = [System.Collections.Generic.List[object]]::new()
    $logsDeleted = [System.Collections.Generic.List[object]]::new()
    $indicators = @($Context.IndicatorNames)
    $keywords = @($Context.Keywords)
    $partial = $false
    foreach ($drive in @($ScanResults.Keys | Sort-Object)) {
        $scan = $ScanResults[$drive]
        $res.Scope.Add("USN Journal de $drive")
        if ($scan.Error) {
            $res.Warnings.Add("${drive}: $($scan.Error)"); $partial = $true
            if ($scan.ErrorCode -eq 1179) { $res.Limitations.Add("El USN Journal no está activo en $drive.") }
            continue
        }
        $res.ArtifactsReviewed += [int]$scan.TotalRecords
        $first = if ($scan.FirstTimestampUtc -ne [datetime]::MinValue) { $scan.FirstTimestampUtc } else { $null }
        $jidDate = $null
        if ($scan.Journal) { $jidDate = ConvertFrom-AmonFileTime ([int64]$scan.Journal.JournalId) }
        $journals.Add([pscustomobject]@{
                Drive = $drive; JournalId = $(if ($scan.Journal) { '0x{0:X16}' -f $scan.Journal.JournalId } else { $null }); JournalIdAsDateUtc = $jidDate
                MaximumSizeMB = $(if ($scan.Journal) { [Math]::Round($scan.Journal.MaximumSize / 1MB, 1) } else { $null })
                TotalRecords = $scan.TotalRecords; Matched = $scan.Records.Count; FirstRecordUtc = $first
                LastRecordUtc = $(if ($scan.LastTimestampUtc -ne [datetime]::MinValue) { $scan.LastTimestampUtc } else { $null })
                Truncated = $scan.Truncated; TimedOut = $scan.TimedOut
            })
        if ($scan.Truncated) { $res.Limitations.Add("${drive}: se alcanzó el máximo de registros relevantes ($($Context.Settings.limits.maxUsnResults)); se muestran los más recientes."); $partial = $true }
        if ($scan.TimedOut) { $res.Limitations.Add("${drive}: la lectura se detuvo por límite de tiempo; el journal se leyó parcialmente."); $partial = $true }
        if ($first -and $first -gt $Context.SinceUtc.AddHours(1)) {
            $res.Limitations.Add(("El journal de {0} solo cubre desde {1}: los cambios anteriores dentro del periodo ya se sobrescribieron (el journal es circular) y no se pueden analizar." -f $drive, (Format-AmonTimestamp $first)))
        }
        if ($jidDate -and (Test-AmonInWindow -Context $Context -Utc $jidDate) -and $first -and [Math]::Abs(($first - $jidDate).TotalDays) -lt 1) {
            $res.Findings.Add((New-AmonFinding -Module 'USNJournal' -Category 'JournalRecent' -Title "USN Journal de $drive con fecha de creación reciente" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -TimestampUtc $jidDate -Indicator ('Journal ID ' + ('0x{0:X16}' -f $scan.Journal.JournalId)) -IndicatorType 'journal' `
                        -Justification ("El identificador del journal equivale a {0} y el registro más antiguo es de {1}: el journal pudo crearse o recrearse recientemente. La interpretación del identificador como fecha es aproximada." -f (Format-AmonTimestamp $jidDate), (Format-AmonTimestamp $first)) `
                        -FalsePositives @('Formatear el volumen, actualizaciones de Windows, chkdsk o herramientas de mantenimiento recrean el journal.')))
        }

        foreach ($raw in $scan.Records) {
            $rec = ConvertFrom-AmonUsnRecord -Record $raw -Drive $drive
            # Privacidad: los renombrados a $R exponen el nombre original de CUALQUIER archivo
            # enviado a la papelera; solo se conserva si es relevante para la revisión.
            if ($rec.PreviousName -and -not (Test-AmonUsnNameRelevant -Context $Context -Name $rec.PreviousName -Folder $rec.PreviousParentPath)) {
                $rec.PreviousName = $null; $rec.PreviousParentPath = $null
                $hiddenNames++
            }
            $name = [string]$rec.FileName
            # El nombre de un .pf delata qué programa se usó: los no relacionados solo se cuentan.
            if ($name.EndsWith('.pf', [StringComparison]::OrdinalIgnoreCase) -and -not (Test-AmonKeywordMatch -Text $name -Keywords (@($keywords) + @($indicators)))) {
                if ($rec.Operation -eq 'Eliminación') {
                    $prefetchHidden++
                    if (-not $prefetchHiddenUtc -or $rec.TimestampUtc -gt $prefetchHiddenUtc) { $prefetchHiddenUtc = $rec.TimestampUtc }
                }
                continue
            }
            $res.Artifacts.Add($rec)
            $kind = switch -Wildcard ($rec.Operation) { 'Eliminación' { 'Deletion' } 'Renombrado*' { 'Rename' } 'Creación' { 'Creation' } 'Modificación*' { 'Modification' } default { 'Modification' } }
            $conf = if ($rec.ParentPath) { 'Medium' } else { 'Low' }
            $res.Events.Add((New-AmonEvent -TimestampUtc $rec.TimestampUtc -Type "USN: $($rec.Operation)" -Kind $kind -Source "USN Journal ($drive)" -Path $rec.Path -Confidence $conf -Description $(if ($rec.PreviousName) { "Nombre anterior: $($rec.PreviousName)" } else { $rec.Reasons })))

            $isRecycleName = $name.StartsWith('$R', [StringComparison]::OrdinalIgnoreCase) -or $name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase)
            if ($isRecycleName -and $rec.Operation -eq 'Renombrado (nombre nuevo)' -and $rec.PreviousName) {
                $entry = [pscustomobject]@{
                    TimestampUtc = $rec.TimestampUtc; Operation = 'Enviado a la papelera'; OriginalName = $rec.PreviousName
                    OriginalFolder = $rec.PreviousParentPath; RecycledAs = $rec.Path; Drive = $drive; Source = 'USN Journal'
                }
                $recycle.Add($entry)
                $sentToBin[$name.Substring(2).ToUpperInvariant()] = $entry
            } elseif ($isRecycleName -and $rec.Operation -eq 'Eliminación') {
                $prev = $sentToBin[$name.Substring(2).ToUpperInvariant()]
                $recycle.Add([pscustomobject]@{
                        TimestampUtc = $rec.TimestampUtc; Operation = 'Purgado de la papelera'; OriginalName = $(if ($prev) { $prev.OriginalName } else { $null })
                        OriginalFolder = $(if ($prev) { $prev.OriginalFolder } else { $null }); RecycledAs = $rec.Path; Drive = $drive; Source = 'USN Journal'
                    })
            } elseif ($name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) -and $rec.Operation -eq 'Creación') {
                $recycle.Add([pscustomobject]@{ TimestampUtc = $rec.TimestampUtc; Operation = 'Metadatos de papelera creados'; OriginalName = $null; OriginalFolder = $null; RecycledAs = $rec.Path; Drive = $drive; Source = 'USN Journal' })
            }
            if ($name.EndsWith('.pf', [StringComparison]::OrdinalIgnoreCase) -and $rec.Operation -eq 'Eliminación') { $prefetchDeleted.Add($rec) }
            if ($rec.Operation -eq 'Eliminación' -and ($name -ieq 'latest.log' -or $name -match '^\d{4}-\d{2}-\d{2}-\d+\.log(\.gz)?$' -or ($name -like '*.log' -and (Test-AmonKeywordMatch -Text $rec.Path -Keywords @('minecraft', 'lunarclient', '\logs\'))))) { $logsDeleted.Add($rec) }
            $relevantName = if ($rec.PreviousName) { "$name $($rec.PreviousName)" } else { $name }
            $indHit = $indicators | Where-Object { $relevantName.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1
            if ($indHit -and $rec.Operation -in @('Eliminación', 'Renombrado (nombre nuevo)', 'Renombrado (nombre anterior)')) {
                $res.Findings.Add((New-AmonFinding -Module 'USNJournal' -Category 'IndicatorFileChange' -Title "Cambio registrado en un archivo señalado: $indHit" -Status DETECTED -Severity Medium -Confidence $conf `
                            -Path $rec.Path -TimestampUtc $rec.TimestampUtc -Indicator $indHit -IndicatorType 'filename' `
                            -Justification "El USN Journal registra '$($rec.Operation)' sobre un archivo cuyo nombre coincide con un indicador de otro módulo. Ruta: $($rec.PathReliability.ToLowerInvariant())." `
                            -FalsePositives @('Coincidencia por nombre; actualizaciones o reinstalaciones legítimas.') `
                            -Evidence @(New-AmonEvidence -Source "USN Journal ($drive)" -Kind $(if ($kind -eq 'Rename') { 'Rename' } else { 'Deletion' }) -Path $rec.Path -TimestampUtc $rec.TimestampUtc -Description "$($rec.Reasons); USN $($rec.Usn)")))
            }
        }
    }

    foreach ($e in $recycle | Where-Object { $_.Operation -eq 'Enviado a la papelera' -and $_.OriginalName }) {
        $ext = [IO.Path]::GetExtension($e.OriginalName).ToLowerInvariant()
        $kw = Test-AmonKeywordMatch -Text ("$($e.OriginalFolder)\$($e.OriginalName)") -Keywords $keywords
        if ($kw -or $ext -in @('.jar', '.exe', '.dll')) {
            $purged = $recycle | Where-Object { $_.Operation -eq 'Purgado de la papelera' -and $_.OriginalName -eq $e.OriginalName } | Select-Object -First 1
            $res.Findings.Add((New-AmonFinding -Module 'USNJournal' -Category 'RecycleUsn' -Title "Envío a la papelera registrado en el journal: $($e.OriginalName)" -Status DETECTED -Severity Low -Confidence High `
                        -Path $(if ($e.OriginalFolder) { Join-Path $e.OriginalFolder $e.OriginalName } else { $e.OriginalName }) -TimestampUtc $e.TimestampUtc -Indicator $e.OriginalName -IndicatorType 'filename' `
                        -Justification ("El journal registra el renombrado a {0} el {1}{2}. Describe la operación; no demuestra intención." -f $e.RecycledAs, (Format-AmonTimestamp $e.TimestampUtc), $(if ($purged) { " y su eliminación definitiva el $(Format-AmonTimestamp $purged.TimestampUtc)" } else { '' })) `
                        -FalsePositives @('Limpieza normal de archivos descargados o desinstalación de mods.') -Data @{ Purged = [bool]$purged }))
        }
    }
    if ($prefetchDeleted.Count -or $prefetchHidden) {
        $names = @($prefetchDeleted | Select-Object -First 15 | ForEach-Object FileName)
        if ($prefetchHidden) { $names += "$prefetchHidden de programas no relacionados (nombres omitidos)" }
        $pfUtc = @(@($prefetchDeleted | ForEach-Object TimestampUtc) + @($prefetchHiddenUtc) | Where-Object { $_ } | Sort-Object -Descending)[0]
        $res.Findings.Add((New-AmonFinding -Module 'USNJournal' -Category 'PrefetchDeleted' -Title "Eliminación de $($prefetchDeleted.Count + $prefetchHidden) archivo(s) Prefetch" -Status INCONCLUSIVE -Severity Low -Confidence Medium `
                    -Path (Join-Path $env:SystemRoot 'Prefetch') -TimestampUtc $pfUtc -Indicator ($names -join ', ') -IndicatorType 'filename' `
                    -Justification 'El journal registra borrados de archivos .pf. Borrar Prefetch es una técnica antiforense conocida, pero Windows también los elimina por sí mismo.' `
                    -FalsePositives @('Windows rota los Prefetch al superar su límite (1024) y al desinstalar programas.', 'Herramientas de limpieza y optimización.')))
    }
    if ($logsDeleted.Count) {
        $res.Findings.Add((New-AmonFinding -Module 'USNJournal' -Category 'MinecraftLogDeleted' -Title "Eliminación de $($logsDeleted.Count) log(s) de Minecraft o launchers" -Status INCONCLUSIVE -Severity Low -Confidence Medium `
                    -Path $logsDeleted[0].Path -TimestampUtc $logsDeleted[0].TimestampUtc -Indicator (@($logsDeleted | Select-Object -First 10 | ForEach-Object FileName) -join ', ') -IndicatorType 'filename' `
                    -Justification 'Se borraron logs de juego o de launcher dentro del periodo. Los launchers rotan logs automáticamente, por lo que debe valorarse junto a otras evidencias.' `
                    -FalsePositives @('Rotación automática de logs al iniciar el juego.', 'Limpieza manual de espacio.')))
    }
    if ($hiddenNames) { $res.Limitations.Add("$hiddenNames nombre(s) original(es) de elementos enviados a la papelera sin relación con la revisión se ocultaron (privacidad).") }
    $res.Limitations.Add('Las rutas se reconstruyen con la ubicación actual del directorio padre: si el directorio se movió después, la ruta mostrada es la actual.')
    $res.Limitations.Add('Solo se muestran registros relevantes para la revisión; el resto del journal se cuenta pero no se expone.')
    if ($partial) { return Complete-AmonModuleResult -Result $res -Status Partial }
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @(
    'ConvertTo-AmonUsnReasonText', 'Get-AmonUsnOperation', 'ConvertFrom-AmonUsnRecord', 'Get-AmonUsnTargetVolumes',
    'New-AmonUsnFilter', 'Invoke-AmonUsnAnalysis'
)
