#Requires -Version 5.1
<#
    Amon SS - modules/UserAssist.psm1
    HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{GUID}\Count

      * Nombres codificados en ROT13 (solo letras A-Z/a-z).
      * Datos de Windows 7+ (72 bytes): contador de ejecuciones (+4), veces con foco (+8),
        tiempo con foco en ms (+12) y última ejecución FILETIME (+60).
      * Resolución de prefijos {GUID} de carpetas conocidas (Program Files, Descargas, ...).

    Solo lectura del registro. Privacidad: se muestran únicamente entradas relacionadas con la
    revisión; el resto se cuenta.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:Categories = @{
    '{CEBFF5CD-ACE2-4F4F-9178-9926F41749EA}' = 'Ejecutables'
    '{F4E57C4B-2036-45F0-A9AB-443BCFE33D9F}' = 'Accesos directos'
}

function ConvertFrom-AmonRot13 {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    $chars = $Text.ToCharArray()
    for ($i = 0; $i -lt $chars.Length; $i++) {
        $c = [int]$chars[$i]
        if ($c -ge 65 -and $c -le 90) { $chars[$i] = [char](65 + (($c - 65 + 13) % 26)) }
        elseif ($c -ge 97 -and $c -le 122) { $chars[$i] = [char](97 + (($c - 97 + 13) % 26)) }
    }
    return -join $chars
}

function ConvertFrom-AmonUserAssistData {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -ge 68) {
        return [pscustomobject]@{
            RunCount = [int][BitConverter]::ToUInt32($Bytes, 4); FocusCount = [int][BitConverter]::ToUInt32($Bytes, 8)
            FocusSeconds = [int]([BitConverter]::ToUInt32($Bytes, 12) / 1000); LastRunUtc = (ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 60)))
        }
    }
    if ($Bytes.Length -ge 16) {
        # Formato de Windows XP: el contador empieza en 5.
        $count = [int][BitConverter]::ToUInt32($Bytes, 4); if ($count -ge 5) { $count -= 5 }
        return [pscustomobject]@{ RunCount = $count; FocusCount = $null; FocusSeconds = $null; LastRunUtc = (ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($Bytes, 8))) }
    }
    return $null
}

function Resolve-AmonKnownFolderPath {
    param([string]$Path)
    if ($Path -notmatch '^(\{[0-9A-Fa-f\-]{36}\})(.*)$') { return $Path }
    $guid = $Matches[1].ToUpperInvariant(); $rest = $Matches[2]
    $pf64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $map = @{
        '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}' = [Environment]::SystemDirectory
        '{6D809377-6AF0-444B-8957-A3773F02200E}' = $pf64
        '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}' = ${env:ProgramFiles(x86)}
        '{F38BF404-1D43-42F2-9305-67DE0B28FC23}' = $env:SystemRoot
        '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}' = (Join-Path $env:SystemRoot 'SysWOW64')
        '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}' = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
        '{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}' = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
        '{9E3995AB-1F9C-4F13-B827-48B24B6C7174}' = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned')
        '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}' = [Environment]::GetFolderPath('Desktop')
        '{374DE290-123F-4565-9164-39C4925E467B}' = (Join-Path $env:USERPROFILE 'Downloads')
        '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}' = [Environment]::GetFolderPath('MyDocuments')
        '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}' = $env:LOCALAPPDATA
        '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}' = $env:APPDATA
        '{62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}' = $env:ProgramData
        '{5E6C858F-0E22-4760-9AFE-EA3317B67173}' = $env:USERPROFILE
    }
    $base = $map[$guid]
    if (-not $base) { return $Path }
    return $base.TrimEnd('\') + $rest
}

function Get-AmonUserAssistRaw {
    # Lee los valores en bruto (nombre ROT13 decodificado + bytes) de las claves Count.
    $out = [System.Collections.Generic.List[object]]::new()
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
        $guid = $k.PSChildName.ToUpperInvariant()
        $cat = if ($script:Categories.ContainsKey($guid)) { $script:Categories[$guid] } else { "Otra ($guid)" }
        $count = Get-Item -LiteralPath (Join-Path $k.PSPath 'Count') -ErrorAction SilentlyContinue
        if (-not $count) { continue }
        foreach ($n in $count.GetValueNames()) {
            $v = $count.GetValue($n)
            if ($v -is [byte[]]) { $out.Add([pscustomobject]@{ Category = $cat; Name = (ConvertFrom-AmonRot13 $n); Data = $v }) }
        }
    }
    return $out.ToArray()
}

function Invoke-AmonUserAssistAnalysis {
    <#
    .SYNOPSIS
        Analiza UserAssist del usuario actual y devuelve un AmonSS.ModuleResult.
    .PARAMETER RawEntries
        Entradas ya leídas (Category, Name decodificado, Data); se usa en pruebas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [object[]]$RawEntries)
    $res = New-AmonModuleResult -Module 'UserAssist' -DisplayName 'UserAssist'
    $res.Scope.Add('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist')
    if ($null -eq $RawEntries) { $RawEntries = @(Get-AmonUserAssistRaw) }
    $keywords = @($Context.Keywords); $indicators = @($Context.IndicatorNames)
    $unrelated = 0
    foreach ($e in $RawEntries) {
        if (Test-AmonCancel -Context $Context) { break }
        if ($e.Name -like 'UEME_CTL*') { continue }
        $res.ArtifactsReviewed++
        $resolved = Resolve-AmonKnownFolderPath $e.Name
        $leaf = [IO.Path]::GetFileName($resolved)
        $reason = $null
        if ($indicators | Where-Object { $_ -ieq $leaf }) { $reason = 'coincide con un indicador' }
        elseif ($k = Test-AmonKeywordMatch -Text $resolved -Keywords $keywords) { $reason = "palabra clave '$k'" }
        elseif ($resolved -like '*.jar') { $reason = 'archivo JAR' }
        if (-not $reason) { $unrelated++; continue }
        $d = ConvertFrom-AmonUserAssistData -Bytes $e.Data
        if (-not $d) { continue }
        $res.Artifacts.Add([pscustomobject]@{
                Name = $e.Name; ResolvedPath = $resolved; Category = $e.Category; RunCount = $d.RunCount; FocusCount = $d.FocusCount
                FocusSeconds = $d.FocusSeconds; LastRunUtc = $d.LastRunUtc; Relevance = $reason
            })
        if ($d.LastRunUtc -and (Test-AmonInWindow -Context $Context -Utc $d.LastRunUtc)) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $d.LastRunUtc -Type 'Última ejecución registrada en UserAssist' -Kind Execution -Source 'UserAssist' -Path $resolved -Confidence Medium -Description "$($e.Category); ejecuciones: $($d.RunCount); $reason"))
        }
        if ($resolved -match '^[A-Za-z]:\\' -and [IO.Path]::GetExtension($resolved) -in @('.jar', '.exe') -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            if ($reason -ne 'archivo JAR' -or $resolved -notmatch '(?i)\\\.minecraft\\') { Add-AmonEvidencePath -Context $Context -Path $resolved -Source 'UserAssist' -Reason $reason }
        }
        if ($reason -eq 'coincide con un indicador') {
            $res.Findings.Add((New-AmonFinding -Module 'UserAssist' -Category 'ExecutionEvidence' -Title "Ejecución de un archivo señalado registrada en UserAssist: $leaf" -Status DETECTED -Severity Medium -Confidence Medium `
                        -Path $resolved -TimestampUtc $d.LastRunUtc -Indicator $leaf -IndicatorType 'filename' `
                        -Justification "UserAssist registra $($d.RunCount) ejecución(es) desde el Explorador; la última el $(Format-AmonTimestamp $d.LastRunUtc)." -FalsePositives @('Coincidencia por nombre de archivo.')))
        } elseif ($Context.Signatures -and ($Context.Signatures.Keywords | Where-Object { $resolved.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
            $res.Findings.Add((New-AmonFinding -Module 'UserAssist' -Category 'KeywordName' -Title "Programa con nombre relacionado en UserAssist: $leaf" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -Path $resolved -TimestampUtc $d.LastRunUtc -Indicator $reason -IndicatorType 'keyword' `
                        -Justification 'El nombre contiene una palabra clave de un cliente. Un nombre no prueba nada por sí solo.' -FalsePositives @('Coincidencia casual de nombre.')))
        }
    }
    $res.Data['UnrelatedCount'] = $unrelated
    if ($unrelated) { $res.Limitations.Add("$unrelated entrada(s) de UserAssist sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('UserAssist solo registra programas iniciados desde el Explorador (no desde consola ni launchers) y puede desactivarse por configuración.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('ConvertFrom-AmonRot13', 'ConvertFrom-AmonUserAssistData', 'Resolve-AmonKnownFolderPath', 'Get-AmonUserAssistRaw', 'Invoke-AmonUserAssistAnalysis')
