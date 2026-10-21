#Requires -Version 5.1
<#
    Amon SS - modules/Recent.psm1
    Accesos recientes del Explorador (%APPDATA%\Microsoft\Windows\Recent\*.lnk).

      * Parser propio de MS-SHLLINK: destino (LinkInfo local o de red), argumentos, fechas y
        tamaño del destino guardados en la cabecera, serie del volumen.
      * Fechas del propio .lnk: creación ≈ primera apertura, modificación ≈ última apertura.

    Privacidad: solo se muestran accesos relacionados con Minecraft, archivos JAR/ejecutables/
    comprimidos o indicadores; el resto se cuenta. No se recopilan documentos personales.
    Limitación: las Jump Lists (AutomaticDestinations) no se interpretan.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

# Sin comprimidos: "Fotos.zip" abierto recientemente es un dato personal, no de la revisión.
# Un comprimido sigue apareciendo si su ruta contiene una palabra clave o un indicador.
$script:RelevantExtensions = @('.jar', '.exe', '.dll')
$script:LinkClsid = [guid]'00021401-0000-0000-C000-000000000046'

function Get-AmonAnsiEncoding {
    try { return [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) }
    catch { return [Text.Encoding]::GetEncoding(28591) }
}

function Read-AmonNullTerminated {
    param([byte[]]$Bytes, [int]$Offset, [switch]$Unicode)
    if ($Offset -lt 0 -or $Offset -ge $Bytes.Length) { return $null }
    if ($Unicode) {
        $end = $Offset
        while ($end + 1 -lt $Bytes.Length -and -not ($Bytes[$end] -eq 0 -and $Bytes[$end + 1] -eq 0)) { $end += 2 }
        return [Text.Encoding]::Unicode.GetString($Bytes, $Offset, $end - $Offset)
    }
    $end = [Array]::IndexOf($Bytes, [byte]0, $Offset)
    if ($end -lt 0) { $end = $Bytes.Length }
    return (Get-AmonAnsiEncoding).GetString($Bytes, $Offset, $end - $Offset)
}

function ConvertFrom-AmonLnkBytes {
    <#
    .SYNOPSIS
        Interpreta un acceso directo de Windows (.lnk).
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -lt 76 -or [BitConverter]::ToUInt32($Bytes, 0) -ne 0x4C) { throw 'No es un archivo LNK (cabecera inválida).' }
    $clsid = New-Object byte[] 16; [Array]::Copy($Bytes, 4, $clsid, 0, 16)
    if ((New-Object guid (, $clsid)) -ne $script:LinkClsid) { throw 'CLSID de LNK inválido.' }
    $flags = [BitConverter]::ToUInt32($Bytes, 20)
    $unicode = ($flags -band 0x80) -ne 0
    $r = [ordered]@{
        Flags = $flags; TargetPath = $null; NetworkPath = $null; RelativePath = $null; WorkingDirectory = $null; Arguments = $null
        TargetCreatedUtc = (ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 28)))
        TargetAccessedUtc = (ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 36)))
        TargetModifiedUtc = (ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 44)))
        TargetSize = [BitConverter]::ToUInt32($Bytes, 52); DriveSerial = $null; VolumeLabel = $null; DriveType = $null
    }
    $pos = 76
    if ($flags -band 0x1) { $pos += 2 + [BitConverter]::ToUInt16($Bytes, $pos) }
    if (($flags -band 0x2) -and $pos + 28 -le $Bytes.Length) {
        $li = $pos
        $liSize = [BitConverter]::ToUInt32($Bytes, $li)
        $liHeader = [BitConverter]::ToUInt32($Bytes, $li + 4)
        $liFlags = [BitConverter]::ToUInt32($Bytes, $li + 8)
        $volOff = [BitConverter]::ToUInt32($Bytes, $li + 12)
        $baseOff = [BitConverter]::ToUInt32($Bytes, $li + 16)
        $netOff = [BitConverter]::ToUInt32($Bytes, $li + 20)
        $suffixOff = [BitConverter]::ToUInt32($Bytes, $li + 24)
        $baseUni = 0; $suffixUni = 0
        if ($liHeader -ge 0x24) { $baseUni = [BitConverter]::ToUInt32($Bytes, $li + 28); $suffixUni = [BitConverter]::ToUInt32($Bytes, $li + 32) }
        $suffix = if ($suffixUni) { Read-AmonNullTerminated $Bytes ($li + $suffixUni) -Unicode } else { Read-AmonNullTerminated $Bytes ($li + $suffixOff) }
        if ($liFlags -band 1) {
            $base = if ($baseUni) { Read-AmonNullTerminated $Bytes ($li + $baseUni) -Unicode } else { Read-AmonNullTerminated $Bytes ($li + $baseOff) }
            $r.TargetPath = if ($suffix) { $base.TrimEnd('\') + '\' + $suffix } else { $base }
            $v = $li + $volOff
            if ($v + 16 -le $Bytes.Length) {
                $r.DriveType = [BitConverter]::ToUInt32($Bytes, $v + 4)
                $r.DriveSerial = ([BitConverter]::ToUInt32($Bytes, $v + 8)).ToString('X8')
                $labelOff = [BitConverter]::ToUInt32($Bytes, $v + 12)
                if ($labelOff -eq 0x14 -and $v + 20 -le $Bytes.Length) { $r.VolumeLabel = Read-AmonNullTerminated $Bytes ($v + [BitConverter]::ToUInt32($Bytes, $v + 16)) -Unicode }
                else { $r.VolumeLabel = Read-AmonNullTerminated $Bytes ($v + $labelOff) }
            }
        }
        if (($liFlags -band 2) -and $li + $netOff + 12 -le $Bytes.Length) {
            $c = $li + $netOff
            $net = Read-AmonNullTerminated $Bytes ($c + [BitConverter]::ToUInt32($Bytes, $c + 8))
            $r.NetworkPath = if ($suffix) { $net.TrimEnd('\') + '\' + $suffix } else { $net }
            if (-not $r.TargetPath) { $r.TargetPath = $r.NetworkPath }
        }
        $pos = $li + $liSize
    }
    foreach ($pair in @(@(0x4, $null), @(0x8, 'RelativePath'), @(0x10, 'WorkingDirectory'), @(0x20, 'Arguments'), @(0x40, $null))) {
        if (-not ($flags -band $pair[0])) { continue }
        if ($pos + 2 -gt $Bytes.Length) { break }
        $count = [BitConverter]::ToUInt16($Bytes, $pos); $pos += 2
        $len = if ($unicode) { $count * 2 } else { $count }
        if ($pos + $len -gt $Bytes.Length) { break }
        $s = if ($unicode) { [Text.Encoding]::Unicode.GetString($Bytes, $pos, $len) } else { (Get-AmonAnsiEncoding).GetString($Bytes, $pos, $len) }
        if ($pair[1]) { $r[$pair[1]] = $s }
        $pos += $len
    }
    return [pscustomobject]$r
}

function Invoke-AmonRecentAnalysis {
    <#
    .SYNOPSIS
        Revisa los accesos recientes relevantes y devuelve un AmonSS.ModuleResult.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [string]$Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Recent'))
    $res = New-AmonModuleResult -Module 'Recent' -DisplayName 'Recent Files'
    $res.Scope.Add($Path)
    try { $files = @(([IO.DirectoryInfo]$Path).GetFiles('*.lnk')) }
    catch { $res.Warnings.Add("No se pudo leer $Path : $($_.Exception.Message)"); return Complete-AmonModuleResult -Result $res -Status Failed }
    $keywords = @($Context.Keywords); $indicators = @($Context.IndicatorNames)
    $unrelated = 0; $errors = 0
    foreach ($f in $files) {
        if (Test-AmonCancel -Context $Context) { break }
        $res.ArtifactsReviewed++
        try { $lnk = ConvertFrom-AmonLnkBytes -Bytes (Read-AmonFileBytes -Path $f.FullName -MaxBytes 1MB) } catch { $errors++; continue }
        $target = if ($lnk.TargetPath) { $lnk.TargetPath } else { $f.BaseName }
        $name = [IO.Path]::GetFileName($target)
        $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
        $reason = $null
        if ($indicators | Where-Object { $_ -ieq $name }) { $reason = 'coincide con un indicador' }
        elseif ($k = Test-AmonKeywordMatch -Text "$target $($f.Name)" -Keywords $keywords) { $reason = "palabra clave '$k'" }
        elseif ($script:RelevantExtensions -contains $ext) { $reason = "extensión $ext" }
        if (-not $reason) { $unrelated++; continue }
        # Un acceso directo a \\servidor\... no se comprueba: no se genera tráfico de red.
        $exists = $false
        if (Test-AmonLocalPath -Path $target) { try { $exists = [IO.File]::Exists($target) -or [IO.Directory]::Exists($target) } catch { } }
        $res.Artifacts.Add([pscustomobject]@{
                LnkName = $f.Name; LnkPath = $f.FullName; TargetPath = $target; TargetExists = $exists; Arguments = $lnk.Arguments
                FirstOpenedUtc = $f.CreationTimeUtc; LastOpenedUtc = $f.LastWriteTimeUtc; TargetModifiedUtc = $lnk.TargetModifiedUtc
                TargetCreatedUtc = $lnk.TargetCreatedUtc; TargetSize = $lnk.TargetSize; DriveSerial = $lnk.DriveSerial; Relevance = $reason
            })
        foreach ($t in @(@('Primera apertura registrada (Recent)', $f.CreationTimeUtc), @('Última apertura registrada (Recent)', $f.LastWriteTimeUtc))) {
            if (Test-AmonInWindow -Context $Context -Utc $t[1]) {
                $res.Events.Add((New-AmonEvent -TimestampUtc $t[1] -Type $t[0] -Kind Presence -Source 'Recent (.lnk)' -Path $target -Confidence Medium -Description "Acceso directo $($f.Name); $reason"))
            }
        }
        if ($exists -and $ext -in @('.jar', '.exe', '.dll', '.zip')) { Add-AmonEvidencePath -Context $Context -Path $target -Source 'Recent' -Reason "abierto desde el Explorador ($reason)" }
        if ($reason -eq 'coincide con un indicador') {
            $res.Findings.Add((New-AmonFinding -Module 'Recent' -Category 'ExecutionEvidence' -Title "Archivo señalado abierto desde el Explorador: $name" -Status DETECTED -Severity Medium -Confidence Medium `
                        -Path $target -TimestampUtc $f.LastWriteTimeUtc -Indicator $name -IndicatorType 'filename' `
                        -Justification ("Windows creó el acceso reciente {0} (primera apertura {1}, última {2}). Abrir un JAR suele ejecutarlo con Java, pero también puede abrirse con un compresor." -f $f.Name, (Format-AmonTimestamp $f.CreationTimeUtc), (Format-AmonTimestamp $f.LastWriteTimeUtc)) `
                        -FalsePositives @('Coincidencia por nombre; abrir no equivale a ejecutar.')))
        } elseif ($reason -like 'palabra clave*' -and $Context.Signatures -and ($Context.Signatures.Keywords | Where-Object { $target.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
            $res.Findings.Add((New-AmonFinding -Module 'Recent' -Category 'KeywordName' -Title "Acceso reciente con nombre relacionado: $name" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -Path $target -TimestampUtc $f.LastWriteTimeUtc -Indicator $reason -IndicatorType 'keyword' `
                        -Justification 'La ruta abierta contiene una palabra clave de un cliente. Un nombre no prueba nada por sí solo.' -FalsePositives @('Coincidencia casual de nombre.')))
        }
    }
    if ($errors) { $res.Warnings.Add("$errors acceso(s) directo(s) no se pudieron interpretar.") }
    $res.Data['UnrelatedCount'] = $unrelated
    if ($unrelated) { $res.Limitations.Add("$unrelated acceso(s) reciente(s) sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('Las Jump Lists (AutomaticDestinations/CustomDestinations) no se interpretan. Windows puede limitar o desactivar el historial de Recent por configuración.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('ConvertFrom-AmonLnkBytes', 'Invoke-AmonRecentAnalysis')
