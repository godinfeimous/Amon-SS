#Requires -Version 5.1
<#
    Amon SS - modules/Prefetch.psm1
    Analizador de Prefetch (C:\Windows\Prefetch\*.pf) para Windows 7 a 11.

      * Formatos SCCA v17 (XP), v23 (Vista/7), v26 (8.1), v30 (10) y v31 (11).
      * Prefetch comprimido "MAM" (XPRESS Huffman) mediante RtlDecompressBufferEx (ntdll).
      * Campos: ejecutable, hash, contador de ejecuciones, hasta 8 últimas ejecuciones,
        archivos referenciados y volúmenes con sus directorios.
      * Traduce \VOLUME{…-serie}\ y \DEVICE\HarddiskVolumeN\ a letras de unidad.

    Privacidad: solo se muestran los Prefetch relacionados con Minecraft, launchers o
    indicadores ya encontrados; del resto únicamente se informa el recuento.
    Prefetch prueba que un ejecutable se ejecutó, no que se usaran trampas.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:VolumeEntrySize = @{ 17 = 40; 23 = 104; 26 = 104; 30 = 96; 31 = 96 }
$script:ManagedJarFragments = @('\LIBRARIES\', '\.LUNARCLIENT\OFFLINE\', '\.LUNARCLIENT\JRE\', '\.LUNARCLIENT\SHARED\', '\RUNTIME\')

function ConvertFrom-AmonPrefetchBytes {
    <#
    .SYNOPSIS
        Interpreta un Prefetch descomprimido (cabecera "SCCA").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes, [string]$FileName)
    if ($Bytes.Length -lt 84) { throw 'Archivo demasiado pequeño para ser Prefetch.' }
    $sig = [Text.Encoding]::ASCII.GetString($Bytes, 4, 4)
    if ($sig -ne 'SCCA') { throw "Firma '$sig' no válida: no es un archivo Prefetch." }
    $version = [int][BitConverter]::ToUInt32($Bytes, 0)
    if (-not $script:VolumeEntrySize.ContainsKey($version)) { throw "Versión de Prefetch no soportada: $version" }
    $u32 = { param($o) if ($o + 4 -le $Bytes.Length) { [BitConverter]::ToUInt32($Bytes, $o) } else { 0 } }
    $i64 = { param($o) if ($o + 8 -le $Bytes.Length) { [BitConverter]::ToInt64($Bytes, $o) } else { 0 } }

    $exe = [Text.Encoding]::Unicode.GetString($Bytes, 16, 60)
    $nul = $exe.IndexOf([char]0); if ($nul -ge 0) { $exe = $exe.Substring(0, $nul) }
    $fi = 84
    $metricsOffset = & $u32 ($fi + 0)
    $fnOffset = & $u32 ($fi + 16)
    $fnSize = & $u32 ($fi + 20)
    $volOffset = & $u32 ($fi + 24)
    $volCount = & $u32 ($fi + 28)

    $runTimes = [System.Collections.Generic.List[datetime]]::new()
    $runCount = 0
    switch ($version) {
        17 { $t = ConvertFrom-AmonFileTime (& $i64 ($fi + 36)); if ($t) { $runTimes.Add($t) }; $runCount = & $u32 ($fi + 60) }
        23 { $t = ConvertFrom-AmonFileTime (& $i64 ($fi + 44)); if ($t) { $runTimes.Add($t) }; $runCount = & $u32 ($fi + 68) }
        default {
            for ($k = 0; $k -lt 8; $k++) { $t = ConvertFrom-AmonFileTime (& $i64 ($fi + 44 + $k * 8)); if ($t) { $runTimes.Add($t) } }
            if ($version -ge 30 -and $metricsOffset -eq 0x128) { $runCount = & $u32 ($fi + 116) } else { $runCount = & $u32 ($fi + 124) }
            # Comprobación de coherencia: si el valor es absurdo, se prueba la otra variante.
            if ($version -ge 30 -and ($runCount -eq 0 -or $runCount -gt 1000000)) {
                $alt = if ($metricsOffset -eq 0x128) { & $u32 ($fi + 124) } else { & $u32 ($fi + 116) }
                if ($alt -gt 0 -and $alt -le 1000000) { $runCount = $alt }
            }
        }
    }

    $names = @()
    if ($fnOffset -gt 0 -and $fnSize -gt 0 -and ($fnOffset + $fnSize) -le $Bytes.Length) {
        $names = @([Text.Encoding]::Unicode.GetString($Bytes, [int]$fnOffset, [int]$fnSize).Split([char]0) | Where-Object { $_ })
    }

    $volumes = [System.Collections.Generic.List[object]]::new()
    $entry = $script:VolumeEntrySize[$version]
    for ($v = 0; $v -lt [Math]::Min($volCount, 32); $v++) {
        $b = [int]$volOffset + $v * $entry
        if ($b + 36 -gt $Bytes.Length) { break }
        $devOff = & $u32 $b; $devChars = & $u32 ($b + 4)
        $created = ConvertFrom-AmonFileTime (& $i64 ($b + 8))
        $serial = (& $u32 ($b + 16)).ToString('X8')
        $dirOff = & $u32 ($b + 28); $dirCount = & $u32 ($b + 32)
        $dev = $null
        $devStart = [int]$volOffset + [int]$devOff
        if ($devChars -gt 0 -and ($devStart + $devChars * 2) -le $Bytes.Length) { $dev = [Text.Encoding]::Unicode.GetString($Bytes, $devStart, [int]$devChars * 2) }
        $dirs = [System.Collections.Generic.List[string]]::new()
        $p = [int]$volOffset + [int]$dirOff
        for ($d = 0; $d -lt [Math]::Min($dirCount, 4096); $d++) {
            if ($p + 2 -gt $Bytes.Length) { break }
            $n = [BitConverter]::ToUInt16($Bytes, $p)
            if ($p + 2 + $n * 2 -gt $Bytes.Length) { break }
            $dirs.Add([Text.Encoding]::Unicode.GetString($Bytes, $p + 2, $n * 2))
            $p += 2 + ($n + 1) * 2
        }
        $volumes.Add([pscustomobject]@{ DevicePath = $dev; Serial = $serial; CreatedUtc = $created; Directories = $dirs.ToArray() })
    }

    [pscustomobject]@{
        PSTypeName     = 'AmonSS.Prefetch'
        FileName       = $FileName
        Version        = $version
        ExecutableName = $exe
        Hash           = (& $u32 76).ToString('X8')
        RunCount       = [int]$runCount
        LastRunTimes   = @($runTimes | Sort-Object -Descending)
        FileNames      = $names
        Volumes        = $volumes.ToArray()
        Compressed     = $false
    }
}

function Read-AmonPrefetchFile {
    # Lee un .pf en solo lectura, lo descomprime si es MAM y lo interpreta.
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = Read-AmonFileBytes -Path $Path -MaxBytes 16MB
    $compressed = $false
    if ($bytes.Length -ge 8 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x41 -and $bytes[2] -eq 0x4D) {
        Import-AmonNative
        $bytes = [AmonSS.Native.Compression]::DecompressMam($bytes)
        $compressed = $true
    }
    $pf = ConvertFrom-AmonPrefetchBytes -Bytes $bytes -FileName ([IO.Path]::GetFileName($Path))
    $pf.Compressed = $compressed
    return $pf
}

function Get-AmonVolumeMap {
    # Serie de volumen (8 hex) y dispositivo NT -> letra de unidad.
    $map = @{}
    try {
        Import-AmonNative
        # Solo discos locales (2 = extraíble, 3 = fijo): una unidad de red desconectada puede
        # bloquear la consulta varios segundos y Prefetch solo referencia volúmenes locales.
        foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 2 OR DriveType = 3' -OperationTimeoutSec 15 -ErrorAction Stop)) {
            if ($d.VolumeSerialNumber) { $map[([string]$d.VolumeSerialNumber).ToUpperInvariant()] = $d.DeviceID }
            $dev = [AmonSS.Native.Volumes]::QueryDosDevice($d.DeviceID)
            if ($dev) { $map[$dev.ToUpperInvariant()] = $d.DeviceID }
        }
    } catch { }
    return $map
}

function Convert-AmonPrefetchPath {
    param([Parameter(Mandatory = $true)][string]$Path, [hashtable]$VolumeMap = @{})
    if ($Path -match '^\\VOLUME\{[0-9A-Fa-f]+-([0-9A-Fa-f]{8})\}(.*)$') {
        $letter = $VolumeMap[$Matches[1].ToUpperInvariant()]
        if ($letter) { return $letter + $Matches[2] }
        return $Path
    }
    if ($Path -match '^(\\DEVICE\\HARDDISKVOLUME\d+)(\\.*)$') {
        $letter = $VolumeMap[$Matches[1].ToUpperInvariant()]
        if ($letter) { return $letter + $Matches[2] }
    }
    return $Path
}

function Get-AmonPrefetchStatus {
    # EnablePrefetcher: 0 desactivado, 1 aplicaciones, 2 arranque, 3 ambos.
    try {
        $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name EnablePrefetcher -ErrorAction Stop).EnablePrefetcher
        return [int]$v
    } catch { return $null }
}

function Invoke-AmonPrefetchAnalysis {
    <#
    .SYNOPSIS
        Analiza Prefetch y devuelve un AmonSS.ModuleResult con los artefactos relevantes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string]$Path = (Join-Path $env:SystemRoot 'Prefetch'), [hashtable]$VolumeMap, [switch]$All)
    $res = New-AmonModuleResult -Module 'Prefetch' -DisplayName 'Prefetch Analyzer'
    $res.RequiresAdmin = $true
    $res.Scope.Add($Path)
    $status = Get-AmonPrefetchStatus
    $res.Data['EnablePrefetcher'] = $status
    if ($status -eq 0) { $res.Limitations.Add('Prefetch está desactivado en este equipo (EnablePrefetcher = 0): no se generan nuevos registros de ejecución.') }

    try { $files = @([IO.Directory]::GetFiles($Path, '*.pf')) }
    catch [System.UnauthorizedAccessException] {
        $res.Warnings.Add('Windows solo permite leer C:\Windows\Prefetch a administradores. Ejecuta Amon SS como administrador para incluir este módulo.')
        return Complete-AmonModuleResult -Result $res -Status NoAccess
    } catch {
        $res.Warnings.Add("No se pudo enumerar $Path : $($_.Exception.Message)")
        return Complete-AmonModuleResult -Result $res -Status Failed
    }
    if (-not $VolumeMap) { $VolumeMap = Get-AmonVolumeMap }
    $removable = @(try { [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Removable' } | ForEach-Object { $_.Name.TrimEnd('\') } } catch { })
    $launchers = @($Context.Settings.launcherProcessNames | ForEach-Object { ([string]$_).ToUpperInvariant() })
    $keywords = @($Context.Keywords)
    $indicators = @($Context.IndicatorNames)
    $errors = 0; $n = [Math]::Max(1, $files.Count); $i = 0; $omitted = 0
    foreach ($f in $files) {
        if (Test-AmonCancel -Context $Context) { break }
        $i++
        if ($i % 25 -eq 0) { Update-AmonProgress -Context $Context -Percent (100.0 * $i / $n) -Detail ([IO.Path]::GetFileName($f)) -Count $res.ArtifactsReviewed }
        $res.ArtifactsReviewed++
        try { $pf = Read-AmonPrefetchFile -Path $f } catch { $errors++; continue }
        $exeUpper = $pf.ExecutableName.ToUpperInvariant()
        $isLauncher = [bool]($launchers | Where-Object { $_.StartsWith($exeUpper) -or $exeUpper.StartsWith($_) })
        $isJava = $exeUpper -in @('JAVA.EXE', 'JAVAW.EXE')
        $kwExe = Test-AmonKeywordMatch -Text $pf.ExecutableName -Keywords $keywords
        $tool = Get-AmonToolByFileName -Context $Context -Name $pf.ExecutableName
        # Decisión barata sobre los nombres en bruto unidos en una cadena: un Prefetch puede citar
        # cientos de archivos y hay hasta ~1024, así que solo los relevantes pagan la conversión
        # de rutas y el análisis por archivo.
        $joined = ($pf.FileNames -join "`n") + "`n"
        $indNames = @($indicators | Where-Object { $joined.IndexOf('\' + $_ + "`n", [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        # Programa ejecutado desde una unidad extraíble o desde un volumen que ya no está
        # conectado (BAM no registra ejecuciones desde USB; Prefetch sí guarda el volumen).
        $exeRaw = $pf.FileNames | Where-Object { $_.EndsWith('\' + $pf.ExecutableName, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        $detached = $null
        if ($exeRaw -and $pf.LastRunTimes.Count -and (Test-AmonInWindow -Context $Context -Utc $pf.LastRunTimes[0])) {
            if ($exeRaw -match '^\\VOLUME\{[0-9A-Fa-f]+-([0-9A-Fa-f]{8})\}' -and -not $VolumeMap.ContainsKey($Matches[1].ToUpperInvariant())) { $detached = "volumen $($Matches[1].ToUpperInvariant()) que ya no está conectado" }
            elseif ($exeRaw -match '^\\VOLUME\{[0-9A-Fa-f]+-([0-9A-Fa-f]{8})\}' -and $removable -contains [string]$VolumeMap[$Matches[1].ToUpperInvariant()]) { $detached = "unidad extraíble $($VolumeMap[$Matches[1].ToUpperInvariant()]) (volumen $($Matches[1].ToUpperInvariant()))" }
        }
        $relevant = $All -or $isLauncher -or $isJava -or $kwExe -or $tool -or $detached -or $indNames.Count
        if (-not $relevant) { $omitted++; continue }

        $fileFacts = Get-AmonFileFacts -Path $f
        $paths = @($pf.FileNames | ForEach-Object { Convert-AmonPrefetchPath -Path $_ -VolumeMap $VolumeMap })
        $indHits = @($paths | Where-Object { $p = $_; $indNames | Where-Object { $p.EndsWith('\' + $_, [StringComparison]::OrdinalIgnoreCase) } })
        $kwPaths = @($paths | Where-Object { Test-AmonKeywordMatch -Text $_ -Keywords $keywords } | Select-Object -First 50)

        $exePath = $paths | Where-Object { [IO.Path]::GetFileName($_).ToUpperInvariant().StartsWith($exeUpper) } | Select-Object -First 1
        $jars = @($paths | Where-Object { $_.EndsWith('.JAR', [StringComparison]::OrdinalIgnoreCase) })
        $nonLib = @($jars | Where-Object {
                $u = $_.ToUpperInvariant()
                -not ($script:ManagedJarFragments | Where-Object { $u.Contains($_) }) -and $u -notmatch '\\VERSIONS\\[^\\]+\\[^\\]+\.JAR$'
            })
        $res.Artifacts.Add([pscustomobject]@{
                ExecutableName = $pf.ExecutableName; PrefetchFile = $f; Hash = $pf.Hash; Version = $pf.Version; Compressed = $pf.Compressed
                RunCount = $pf.RunCount; LastRunUtc = $(if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null })
                LastRunTimes = $pf.LastRunTimes; ExecutablePath = $exePath; ReferencedJars = $nonLib; JarCount = $jars.Count
                IndicatorMatches = $indHits; KeywordPaths = $kwPaths; FileCount = $pf.FileNames.Count
                PrefetchCreatedUtc = $fileFacts.CreatedUtc; PrefetchModifiedUtc = $fileFacts.ModifiedUtc
            })
        foreach ($t in $pf.LastRunTimes) {
            if (Test-AmonInWindow -Context $Context -Utc $t) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $t -Type 'Ejecución registrada en Prefetch' -Kind Execution -Source 'Prefetch' -Path $(if ($exePath) { $exePath } else { $pf.ExecutableName }) -Confidence High -Description "$($pf.ExecutableName) (contador total: $($pf.RunCount))"))
            }
        }
        foreach ($j in $nonLib) { Add-AmonEvidencePath -Context $Context -Path $j -Source 'Prefetch' -Reason "JAR referenciado por $($pf.ExecutableName)" }
        foreach ($hit in $indHits) {
            $res.Findings.Add((New-AmonFinding -Module 'Prefetch' -Category 'ExecutionEvidence' -Title "Prefetch de $($pf.ExecutableName) referencia un archivo señalado" -Status DETECTED -Severity Medium -Confidence Medium `
                        -Path $hit -TimestampUtc $(if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null }) -Indicator ([IO.Path]::GetFileName($hit)) -IndicatorType 'filename' `
                        -Justification "El Prefetch $([IO.Path]::GetFileName($f)) muestra que $($pf.ExecutableName) cargó este archivo, que coincide por nombre con un indicador encontrado por otro módulo. Las últimas ejecuciones registradas: $(@($pf.LastRunTimes | Select-Object -First 3 | ForEach-Object { Format-AmonTimestamp $_ }) -join ', ')." `
                        -FalsePositives @('La coincidencia es por nombre de archivo; confirma con el hash del archivo si todavía existe.') `
                        -Evidence @(New-AmonEvidence -Source 'Prefetch' -Kind Execution -Path $f -TimestampUtc $(if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null }) -Description "$([IO.Path]::GetFileName($f)): $($pf.RunCount) ejecuciones registradas")))
        }
        if ($detached) {
            $res.Findings.Add((New-AmonFinding -Module 'Prefetch' -Category 'DetachedVolumeExecution' -Title "Programa ejecutado desde una unidad externa: $($pf.ExecutableName)" -Status INCONCLUSIVE -Severity Medium -Confidence High `
                        -Path $(if ($exePath) { $exePath } else { $exeRaw }) -TimestampUtc $pf.LastRunTimes[0] -Indicator $detached -IndicatorType 'volume' `
                        -Justification ("Según {0}, {1} se ejecutó desde un {2}; última ejecución: {3}. Ejecutar desde un USB y retirarlo es una forma de no dejar el archivo en el equipo." -f [IO.Path]::GetFileName($f), $pf.ExecutableName, $detached, (Format-AmonTimestamp $pf.LastRunTimes[0])) `
                        -FalsePositives @('Programas portables legítimos, instaladores desde un pendrive o discos externos de juegos.')))
        }
        if ($tool) {
            $lastRun = if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null }
            $res.Findings.Add((New-AmonToolFinding -Module 'Prefetch' -Indicator $tool -Path $(if ($exePath) { $exePath } else { $f }) -TimestampUtc $lastRun `
                        -What "Ejecución de $($tool.ClientName) registrada en Prefetch" `
                        -Detail ("Prefetch {0}: {1} ejecuciones; últimas: {2}." -f [IO.Path]::GetFileName($f), $pf.RunCount, (@($pf.LastRunTimes | Select-Object -First 3 | ForEach-Object { Format-AmonTimestamp $_ }) -join ', '))))
            if ($exePath) { Add-AmonEvidencePath -Context $Context -Path $exePath -Source 'Prefetch' -Reason "herramienta conocida ($($tool.ClientName))" }
        } elseif ($kwExe -and -not $isLauncher -and -not $isJava) {
            $res.Findings.Add((New-AmonFinding -Module 'Prefetch' -Category 'KeywordName' -Title "Ejecutable con nombre relacionado: $($pf.ExecutableName)" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -Path $(if ($exePath) { $exePath } else { $f }) -TimestampUtc $(if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null }) -Indicator "palabra clave '$kwExe'" -IndicatorType 'keyword' `
                        -Justification 'El nombre del ejecutable contiene una palabra clave de la investigación. Prefetch prueba que se ejecutó, no qué hacía.' -FalsePositives @('Coincidencia casual de nombre.')))
            if ($exePath) { Add-AmonEvidencePath -Context $Context -Path $exePath -Source 'Prefetch' -Reason "palabra clave '$kwExe'" }
        }
        if ($isJava) {
            foreach ($j in ($nonLib | Where-Object { $_ -match '\\(DOWNLOADS|DESKTOP|ESCRITORIO|DESCARGAS|TEMP|DOCUMENTS|DOCUMENTOS)\\' })) {
                $res.Findings.Add((New-AmonFinding -Module 'Prefetch' -Category 'JarOutsideMinecraft' -Title 'Java cargó un JAR desde una carpeta personal' -Status INCONCLUSIVE -Severity Low -Confidence Medium `
                            -Path $j -TimestampUtc $(if ($pf.LastRunTimes.Count) { $pf.LastRunTimes[0] } else { $null }) -Indicator ([IO.Path]::GetFileName($j)) -IndicatorType 'path' `
                            -Justification "Según $([IO.Path]::GetFileName($f)), $($pf.ExecutableName) cargó este JAR fuera de las carpetas de Minecraft. Se escanea con las firmas si todavía existe." `
                            -FalsePositives @('Instaladores (Fabric, Forge, OptiFine) y herramientas Java legítimas se ejecutan desde Descargas.')))
            }
        }
    }
    if ($errors) { $res.Warnings.Add("$errors archivo(s) Prefetch no se pudieron interpretar (formato dañado o no soportado).") }
    $res.Data['Omitted'] = $omitted
    $res.Data['Total'] = $files.Count
    if ($omitted) { $res.Limitations.Add("$omitted Prefetch de programas no relacionados con la revisión se omitieron por privacidad.") }
    $res.Limitations.Add('Prefetch guarda como máximo 8 ejecuciones por programa y Windows elimina los más antiguos al superar el límite; su ausencia no prueba que algo no se ejecutara.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @(
    'ConvertFrom-AmonPrefetchBytes', 'Read-AmonPrefetchFile', 'Get-AmonVolumeMap', 'Convert-AmonPrefetchPath',
    'Get-AmonPrefetchStatus', 'Invoke-AmonPrefetchAnalysis'
)
