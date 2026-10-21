#Requires -Version 5.1
<#
    Amon SS - modules/ExecutionArtifacts.psm1
    Rastros de ejecución en el registro de Windows 10/11, de solo lectura:

      * ShimCache (AppCompatCache): HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\
        AppCompatCache, valor AppCompatCache. Cabecera de 0x34 bytes y entradas '10ts' con la
        ruta (UTF-16), la última modificación del archivo (FILETIME) y datos. El orden es de más
        reciente a más antiguo. Prueba que el sistema vio el archivo, NO que se ejecutara, y solo
        se escribe en el registro al apagar: lo ocurrido desde el último arranque no aparece.
        Se lee sin administrador.
      * BAM (Background Activity Moderator): HKLM\SYSTEM\CurrentControlSet\Services\bam\State\
        UserSettings\<SID>. Cada valor es la ruta de un ejecutable (\Device\HarddiskVolumeN\...)
        y sus primeros 8 bytes, la última ejecución (FILETIME). Requiere administrador.

    Privacidad: solo se muestran ejecutables relacionados con la revisión (indicadores,
    herramientas conocidas o palabras clave de clientes) y, en BAM, los ejecutados dentro del
    periodo desde carpetas de usuario que no tienen firma válida o ya no existen (para revisar).
    El resto se cuenta.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Prefetch.psm1') -DisableNameChecking

$script:ShimCacheKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache'
$script:BamRoots = @('HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings', 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\UserSettings')
$script:SignatureCache = @{}

#region Relevancia compartida

$script:KeywordRegex = @{}

function Get-AmonKeywordRegex {
    # Una sola expresión regular por lista de palabras clave (miles de rutas por módulo: un bucle
    # de IndexOf por palabra clave en PowerShell es demasiado lento). Se rehace si la lista cambia.
    param([string]$Name, [object]$Keywords)
    # Las listas solo crecen (Add-AmonIndicator): el número de elementos basta para saber si cambió.
    $count = @($Keywords).Count
    $c = $script:KeywordRegex[$Name]
    if ($c -and $c.Count -eq $count -and [object]::ReferenceEquals($c.Source, $Keywords)) { return $c.Regex }
    $list = @($Keywords | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object Length -Descending)
    $rx = if ($list.Count) { [regex]::new((($list | ForEach-Object { [regex]::Escape($_) }) -join '|'), 'IgnoreCase, CultureInvariant') } else { $null }
    $script:KeywordRegex[$Name] = @{ Count = $count; Source = $Keywords; Regex = $rx }
    return $rx
}

function Get-AmonExecutableRelevance {
    # Por qué interesa un ejecutable a la revisión: indicador concreto, herramienta conocida
    # (firma de tipo filename), palabra clave de un cliente o palabra clave general.
    param([Parameter(Mandatory = $true)]$Context, [AllowEmptyString()][string]$Path)
    if (-not $Path) { return $null }
    $leaf = [IO.Path]::GetFileName($Path)
    if (-not $leaf) { return $null }
    if ($Context.IndicatorNames.Contains($leaf)) { return [pscustomobject]@{ Kind = 'indicator'; Reason = 'coincide con un indicador'; Indicator = $null } }
    if ($tool = Get-AmonToolByFileName -Context $Context -Name $leaf) { return [pscustomobject]@{ Kind = 'tool'; Reason = "herramienta conocida ($($tool.ClientName))"; Indicator = $tool } }
    if ($Context.Signatures) {
        $rx = Get-AmonKeywordRegex -Name 'client' -Keywords $Context.Signatures.Keywords
        if ($rx) { $m = $rx.Match($leaf); if ($m.Success) { return [pscustomobject]@{ Kind = 'client-keyword'; Reason = "palabra clave de cliente '$($m.Value)'"; Indicator = $null } } }
    }
    $rx = Get-AmonKeywordRegex -Name 'all' -Keywords $Context.Keywords
    if ($rx) { $m = $rx.Match($Path); if ($m.Success) { return [pscustomobject]@{ Kind = 'keyword'; Reason = "palabra clave '$($m.Value)'"; Indicator = $null } } }
    return $null
}

function Test-AmonReviewLocation {
    # Dónde suele acabar una herramienta descargada, usada y borrada: Descargas, Escritorio,
    # Documentos, Temp u otra unidad. AppData queda fuera: los programas que se actualizan solos
    # (Discord, Roblox, launchers) dejan allí versiones antiguas que ya no existen.
    param([string]$Path)
    if (-not (Test-AmonUserWritablePath -Path $Path)) { return $false }
    $p = $Path.ToUpperInvariant()
    if (-not $p.StartsWith(($env:SystemDrive + '\').ToUpperInvariant())) { return ($p -notmatch '\\APPDATA\\(LOCAL|ROAMING|LOCALLOW)\\' -or $p -match '\\APPDATA\\LOCAL\\TEMP\\') }
    return ($p -match '\\(DOWNLOADS|DESCARGAS|DESKTOP|ESCRITORIO|DOCUMENTS|DOCUMENTOS)\\' -or $p -match '\\APPDATA\\LOCAL\\TEMP\\' -or $p -match '^[A-Z]:\\USERS\\[^\\]+\\[^\\]+\.(EXE|BAT|CMD|PS1|VBS)$')
}

function Get-AmonCachedSignature {
    # Firma Authenticode de un archivo local, con caché (es lenta y se repite entre módulos).
    param([string]$Path)
    if ($script:SignatureCache.ContainsKey($Path)) { return $script:SignatureCache[$Path] }
    $r = [pscustomobject]@{ Status = 'Missing'; Signer = $null }
    if ((Test-AmonLocalPath -Path $Path) -and [IO.File]::Exists($Path)) {
        try {
            $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $signer = $null
            if ($s.SignerCertificate -and $s.SignerCertificate.Subject -match 'CN=("[^"]+"|[^,]+)') { $signer = $Matches[1].Trim('"') }
            $r = [pscustomobject]@{ Status = [string]$s.Status; Signer = $signer }
        } catch { $r = [pscustomobject]@{ Status = 'Unknown'; Signer = $null } }
    }
    $script:SignatureCache[$Path] = $r
    return $r
}

function Add-AmonExecutableFinding {
    # Hallazgo común para un ejecutable relevante visto por un artefacto de ejecución.
    param($Result, $Context, [string]$Module, [string]$Artifact, [string]$Category, [string]$Path, $TimestampUtc, $Relevance, [string]$What, [string]$Caveat)
    $leaf = [IO.Path]::GetFileName($Path)
    switch ($Relevance.Kind) {
        'indicator' {
            $Result.Findings.Add((New-AmonFinding -Module $Module -Category $Category -Title "$($What): $leaf" -Status DETECTED -Severity Medium -Confidence Medium `
                        -Path $Path -TimestampUtc $TimestampUtc -Indicator $leaf -IndicatorType 'filename' `
                        -Justification "$Artifact registra un archivo cuyo nombre coincide con un indicador de otro módulo. $Caveat" -FalsePositives @('Coincidencia por nombre de archivo.')))
        }
        'tool' {
            # ShimCache solo prueba presencia: su hallazgo no se marca como ejecución.
            $Result.Findings.Add((New-AmonToolFinding -Module $Module -Indicator $Relevance.Indicator -Path $Path -TimestampUtc $TimestampUtc -What "$($What): $leaf ($($Relevance.Indicator.ClientName))" -Detail "$Artifact registra '$leaf'. $Caveat" `
                        -Category $(if ($Category -eq 'ShimCacheEntry') { 'ShimCacheEntry' } else { 'ToolExecution' }) -NotExecution:($Category -eq 'ShimCacheEntry')))
        }
        'client-keyword' {
            $Result.Findings.Add((New-AmonFinding -Module $Module -Category 'KeywordName' -Title "Nombre relacionado con un cliente en $($Artifact): $leaf" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                        -Path $Path -TimestampUtc $TimestampUtc -Indicator $Relevance.Reason -IndicatorType 'keyword' `
                        -Justification "El nombre contiene una palabra clave de un cliente. Un nombre no prueba nada por sí solo. $Caveat" -FalsePositives @('Coincidencia casual de nombre.')))
        }
    }
}

function Add-AmonReviewFinding {
    # Para revisar: ejecutado en el periodo desde una carpeta de usuario y sin firma válida, o ya
    # borrado. Es información para el revisor (estado INFO, no cuenta como indicio de trampas).
    # Devuelve la firma si añadió el hallazgo, o $null si el ejecutable no cumple las condiciones.
    param($Result, [string]$Module, [string]$Artifact, [string]$Path, $LastRunUtc, $Context)
    if (-not (Test-AmonReviewLocation -Path $Path)) { return $null }
    # Las herramientas de SS del propio staff no se listan para revisar.
    if ($Context -and (Get-AmonScreenshareTool -Context $Context -Text $Path)) { return $null }
    $sig = Get-AmonCachedSignature -Path $Path
    if ($sig.Status -eq 'Valid') { return $null }
    $Result.Findings.Add((New-AmonFinding -Module $Module -Category 'RecentUnsignedExecutable' -Title "Ejecutado desde una carpeta de usuario: $([IO.Path]::GetFileName($Path))" -Status INFO -Severity Low -Confidence Low `
                -Path $Path -TimestampUtc $LastRunUtc -Indicator $(if ($sig.Status -eq 'Missing') { 'ya no existe' } else { "firma: $($sig.Status)" }) -IndicatorType 'execution' `
                -Justification ("{0} {1} {2} Es información para revisar, no un indicio de trampas por sí sola." -f $Artifact, $(if ($LastRunUtc) { "registra su última ejecución el $(Format-AmonTimestamp $LastRunUtc)." } else { 'muestra que se lanzó hace poco (sin hora).' }), $(if ($sig.Status -eq 'Missing') { 'El archivo ya no existe en esa ruta.' } else { 'No tiene una firma digital válida.' })) `
                -FalsePositives @('Programas portables, instaladores y juegos legítimos suelen estar sin firmar.')))
    return $sig
}

#endregion

#region ShimCache

function ConvertFrom-AmonShimCache {
    <#
    .SYNOPSIS
        Interpreta el valor AppCompatCache de Windows 10/11. Devuelve las entradas con ruta de
        archivo (las de apps empaquetadas, sin ruta, se omiten) en orden de la caché.
    #>
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -lt 0x38) { throw 'ShimCache demasiado corto.' }
    $offset = [int][BitConverter]::ToUInt32($Bytes, 0)
    if ($offset -notin @(0x30, 0x34) -or [Text.Encoding]::ASCII.GetString($Bytes, $offset, 4) -ne '10ts') { throw 'Formato de ShimCache no reconocido (se esperaba Windows 10/11, entradas 10ts).' }
    $out = [System.Collections.Generic.List[object]]::new()
    $pos = 0
    while ($offset + 12 -le $Bytes.Length) {
        if ([Text.Encoding]::ASCII.GetString($Bytes, $offset, 4) -ne '10ts') { break }
        $size = [int][BitConverter]::ToUInt32($Bytes, $offset + 8)
        $body = $offset + 12
        if ($size -lt 14 -or $body + $size -gt $Bytes.Length) { break }
        $plen = [BitConverter]::ToUInt16($Bytes, $body)
        if (2 + $plen + 8 -le $size) {
            $path = [Text.Encoding]::Unicode.GetString($Bytes, $body + 2, $plen)
            $ft = [BitConverter]::ToInt64($Bytes, $body + 2 + $plen)
            if ($path -match '^([A-Za-z]:\\|\\\\)') {
                $out.Add([pscustomobject]@{ Position = $pos; Path = $path; ModifiedUtc = (ConvertFrom-AmonFileTime $ft) })
            }
        }
        $pos++
        $offset = $body + $size
    }
    return $out.ToArray()
}

function Invoke-AmonShimCacheAnalysis {
    <#
    .SYNOPSIS
        Revisa ShimCache y devuelve un AmonSS.ModuleResult.
    .PARAMETER RawBytes
        Valor AppCompatCache ya leído; se usa en pruebas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [byte[]]$RawBytes)
    $res = New-AmonModuleResult -Module 'ShimCache' -DisplayName 'ShimCache (AppCompatCache)'
    $res.Scope.Add('HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache')
    if (-not $RawBytes) {
        try { $RawBytes = [byte[]](Get-ItemProperty -LiteralPath $script:ShimCacheKey -Name AppCompatCache -ErrorAction Stop).AppCompatCache }
        catch { $res.Warnings.Add("No se pudo leer AppCompatCache: $($_.Exception.Message)"); return Complete-AmonModuleResult -Result $res -Status Failed }
    }
    try { $entries = @(ConvertFrom-AmonShimCache -Bytes $RawBytes) }
    catch { $res.Warnings.Add($_.Exception.Message); return Complete-AmonModuleResult -Result $res -Status Failed }
    $res.ArtifactsReviewed = $entries.Count
    $unrelated = 0
    $caveat = 'En Windows 10/11 ShimCache no prueba que se ejecutara: indica que el sistema vio el archivo; la fecha es la de su última modificación.'
    foreach ($e in $entries) {
        if (Test-AmonCancel -Context $Context) { break }
        $rel = Get-AmonExecutableRelevance -Context $Context -Path $e.Path
        if (-not $rel) { $unrelated++; continue }
        $exists = (Test-AmonLocalPath -Path $e.Path) -and [IO.File]::Exists($e.Path)
        $res.Artifacts.Add([pscustomobject]@{ Position = $e.Position; Path = $e.Path; ModifiedUtc = $e.ModifiedUtc; Exists = $exists; Relevance = $rel.Reason })
        if ($e.ModifiedUtc -and (Test-AmonInWindow -Context $Context -Utc $e.ModifiedUtc)) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $e.ModifiedUtc -Type 'Archivo registrado en ShimCache (última modificación)' -Kind Presence -Source 'ShimCache' -Path $e.Path -Confidence Low -Description "Posición $($e.Position) en la caché; $($rel.Reason)"))
        }
        if ($exists -and [IO.Path]::GetExtension($e.Path) -in @('.exe', '.jar', '.dll')) { Add-AmonEvidencePath -Context $Context -Path $e.Path -Source 'ShimCache' -Reason $rel.Reason }
        Add-AmonExecutableFinding -Result $res -Context $Context -Module 'ShimCache' -Artifact 'ShimCache' -Category 'ShimCacheEntry' -Path $e.Path -TimestampUtc $e.ModifiedUtc `
            -Relevance $rel -What 'Archivo señalado registrado en ShimCache' -Caveat ($caveat + $(if (-not $exists) { ' El archivo ya no existe en esa ruta.' }))
    }
    $res.Data['UnrelatedCount'] = $unrelated
    if ($unrelated) { $res.Limitations.Add("$unrelated entrada(s) de ShimCache sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('ShimCache se guarda en el registro al apagar el equipo: lo ocurrido desde el último arranque no aparece. Indica que el sistema vio el archivo, no que se ejecutara.')
    return Complete-AmonModuleResult -Result $res
}

#endregion

#region BAM

function Get-AmonBamRaw {
    # Valores de BAM de todos los usuarios (requiere administrador).
    # Windows 10 1809+ usa bam\State\UserSettings; las versiones anteriores, bam\UserSettings.
    # Una raíz que no existe se salta; la falta de permisos (SecurityException) sí se propaga.
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($root in $script:BamRoots) {
        $keys = $null
        try { $keys = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop) }
        catch [System.Management.Automation.ItemNotFoundException] { continue }
        foreach ($k in $keys) {
            foreach ($n in $k.GetValueNames()) {
                $v = $k.GetValue($n)
                if ($v -is [byte[]]) { $out.Add([pscustomobject]@{ Sid = $k.PSChildName; Name = $n; Data = $v }) }
            }
        }
        if ($out.Count) { break }
    }
    return $out.ToArray()
}

function Invoke-AmonBamAnalysis {
    <#
    .SYNOPSIS
        Revisa BAM y devuelve un AmonSS.ModuleResult.
    .PARAMETER RawEntries
        Valores ya leídos (Sid, Name, Data); se usa en pruebas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [object[]]$RawEntries, [hashtable]$VolumeMap)
    $res = New-AmonModuleResult -Module 'BAM' -DisplayName 'BAM (Background Activity Moderator)'
    $res.RequiresAdmin = $true
    $res.Scope.Add('HKLM\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings')
    if ($null -eq $RawEntries) {
        try { $RawEntries = @(Get-AmonBamRaw) }
        catch [System.Security.SecurityException] {
            $res.Warnings.Add('Windows solo permite leer BAM a administradores. Ejecuta Amon SS como administrador para incluir este módulo.')
            return Complete-AmonModuleResult -Result $res -Status NoAccess
        } catch {
            if (-not $Context.IsAdmin) {
                $res.Warnings.Add('Windows solo permite leer BAM a administradores. Ejecuta Amon SS como administrador para incluir este módulo.')
                return Complete-AmonModuleResult -Result $res -Status NoAccess
            }
            $res.Warnings.Add("No se pudo leer BAM: $($_.Exception.Message)"); return Complete-AmonModuleResult -Result $res -Status Failed
        }
    }
    if (-not $VolumeMap) { $VolumeMap = Get-AmonVolumeMap }
    $unrelated = 0; $review = 0
    foreach ($e in $RawEntries) {
        if (Test-AmonCancel -Context $Context) { break }
        if ($e.Name -notmatch '^\\Device\\' -or $e.Data.Length -lt 8) { continue }
        $res.ArtifactsReviewed++
        $path = Convert-AmonPrefetchPath -Path $e.Name -VolumeMap $VolumeMap
        $last = ConvertFrom-AmonFileTime ([BitConverter]::ToInt64($e.Data, 0))
        $inWindow = $last -and (Test-AmonInWindow -Context $Context -Utc $last)
        $rel = Get-AmonExecutableRelevance -Context $Context -Path $path
        $sig = $null
        if (-not $rel -and $inWindow) {
            $sig = Add-AmonReviewFinding -Result $res -Module 'BAM' -Artifact 'BAM' -Path $path -LastRunUtc $last -Context $Context
            if ($sig) { $review++; $rel = [pscustomobject]@{ Kind = 'review'; Reason = 'para revisar'; Indicator = $null } }
        }
        if (-not $rel -or (-not $inWindow -and $rel.Kind -in @('keyword', 'review'))) { $unrelated++; continue }
        if (-not $sig) { $sig = Get-AmonCachedSignature -Path $path }
        $res.Artifacts.Add([pscustomobject]@{ Sid = $e.Sid; Path = $path; LastRunUtc = $last; Exists = ($sig.Status -ne 'Missing'); Signature = $sig.Status; Signer = $sig.Signer; Relevance = $rel.Reason })
        if ($inWindow) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $last -Type 'Última ejecución registrada en BAM' -Kind Execution -Source 'BAM' -Path $path -Confidence Medium -Description $rel.Reason))
        }
        if ($sig.Status -ne 'Missing' -and [IO.Path]::GetExtension($path) -in @('.exe', '.dll')) { Add-AmonEvidencePath -Context $Context -Path $path -Source 'BAM' -Reason $rel.Reason }
        if ($rel.Kind -ne 'review') {
            Add-AmonExecutableFinding -Result $res -Context $Context -Module 'BAM' -Artifact 'BAM' -Category 'ExecutionEvidence' -Path $path -TimestampUtc $last -Relevance $rel `
                -What 'Ejecución registrada en BAM' -Caveat ("Última ejecución: {0}.{1}" -f (Format-AmonTimestamp $last), $(if ($sig.Status -eq 'Missing') { ' El archivo ya no existe.' } else { '' }))
        }
    }
    $res.Data['UnrelatedCount'] = $unrelated
    $res.Data['ReviewCount'] = $review
    if ($unrelated) { $res.Limitations.Add("$unrelated ejecutable(s) de BAM sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('BAM guarda solo la última ejecución de cada programa y Windows borra las entradas antiguas (unos 7 días).')
    return Complete-AmonModuleResult -Result $res
}

#endregion

#region PCA y MUICache

$script:PcaDir = Join-Path $env:SystemRoot 'appcompat\pca'
$script:PcaStoreKey = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store'
$script:MuiCacheKey = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'

function Read-AmonSharedFileBytes {
    # PcaSvc mantiene abiertos sus archivos: se leen compartiendo lectura y escritura.
    param([Parameter(Mandatory = $true)][string]$Path)
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); return , $ms.ToArray() } finally { $fs.Dispose() }
}

function Get-AmonPcaRaw {
    <#
    .SYNOPSIS
        Lee las fuentes del Asistente de compatibilidad de programas (sin administrador):
        PcaAppLaunchDic.txt (ANSI), PcaGeneralDb0/1.txt (UTF-16LE), la clave Store y MUICache.
    #>
    $raw = @{ Launch = @(); General = @(); Store = @(); MuiCache = @(); Windows11 = $false }
    $launch = Join-Path $script:PcaDir 'PcaAppLaunchDic.txt'
    if (Test-Path -LiteralPath $launch) {
        $raw.Windows11 = $true
        $raw.Launch = @([Text.Encoding]::GetEncoding(1252).GetString((Read-AmonSharedFileBytes -Path $launch)) -split "`r?`n" | Where-Object { $_ })
    }
    foreach ($n in 'PcaGeneralDb0.txt', 'PcaGeneralDb1.txt') {
        $p = Join-Path $script:PcaDir $n
        if (Test-Path -LiteralPath $p) { $raw.General += @([Text.Encoding]::Unicode.GetString((Read-AmonSharedFileBytes -Path $p)) -split "`r?`n" | Where-Object { $_ }) }
    }
    $k = Get-Item -LiteralPath $script:PcaStoreKey -ErrorAction SilentlyContinue
    if ($k) { $raw.Store = @($k.GetValueNames() | Where-Object { $_ -match '^[A-Za-z]:\\' }) }
    $m = Get-Item -LiteralPath $script:MuiCacheKey -ErrorAction SilentlyContinue
    if ($m) { $raw.MuiCache = @($m.GetValueNames() | Where-Object { $_ -match '\.FriendlyAppName$' } | ForEach-Object { $_ -replace '\.FriendlyAppName$', '' } | Where-Object { $_ -match '^[A-Za-z]:\\' }) }
    $raw.ExplorerTraces = @(Get-AmonExplorerTraces)
    return $raw
}

function Get-AmonExplorerTraces {
    # Trazas "TRACE,0000,0000,PcaClient,MonitorProcess,<ruta>,Time,<n>" de la memoria privada de
    # explorer.exe (mismo usuario, sin administrador): programas lanzados desde el último inicio
    # del Explorador, también si ya se borraron. No llevan hora. Solo se extraen esas rutas.
    $out = [System.Collections.Generic.List[string]]::new()
    Import-AmonNative
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        try { if ((Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop).Sid -ne $me) { continue } } catch { continue }
        try {
            foreach ($t in [AmonSS.Native.ProcessMemory]::ExtractAfter([int]$p.ProcessId, [Text.Encoding]::ASCII.GetBytes(',MonitorProcess,'), [byte][char]',', 520, 5000, 2GB, [datetime]::UtcNow.AddSeconds(45))) {
                if ($t -match '^[A-Za-z]:\\' -and -not $out.Contains($t)) { $out.Add($t) }
            }
        } catch { }
    }
    return $out.ToArray()
}

function ConvertFrom-AmonPcaTime {
    param([string]$Text)
    $d = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($Text.Trim(), 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$d)
    if ($ok) { return $d } else { return $null }
}

function Expand-AmonPcaPath {
    # PcaGeneralDb normaliza las rutas: variables (%USERPROFILE%...) y sin letra de unidad.
    param([string]$Path)
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    if ($p -match '^\\[^\\]') { $p = $env:SystemDrive + $p }
    return $p
}

function Invoke-AmonPcaAnalysis {
    <#
    .SYNOPSIS
        Revisa PCA (Windows 11 22H2+), Compatibility Assistant\Store y MUICache.
    .PARAMETER Raw
        Datos ya leídos (Launch, General, Store, MuiCache); se usa en pruebas.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [hashtable]$Raw)
    $res = New-AmonModuleResult -Module 'PCA' -DisplayName 'PCA & MUICache'
    $res.Scope.Add("$script:PcaDir; HKCU ...\Compatibility Assistant\Store; HKCU ...\Shell\MuiCache")
    if (-not $Raw) {
        try { $Raw = Get-AmonPcaRaw } catch { $res.Warnings.Add("No se pudieron leer los datos de PCA: $($_.Exception.Message)") ; $Raw = @{ Launch = @(); General = @(); Store = @(); MuiCache = @() } }
        if (-not $Raw.Windows11) { $res.Limitations.Add('Este Windows no tiene PcaAppLaunchDic.txt (existe desde Windows 11 22H2): no hay horas de última ejecución de PCA; se revisan PcaGeneralDb si existe, Store, MUICache y las trazas del Explorador.') }
    }
    $unrelated = 0; $review = 0; $truncated = 0
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # 1. PcaAppLaunchDic: ruta|última ejecución (UTC). Solo lanzamientos desde la interfaz gráfica.
    foreach ($line in @($Raw.Launch | Where-Object { $_ })) {
        $res.ArtifactsReviewed++
        $i = $line.LastIndexOf('|')
        if ($i -lt 0) { $truncated++; continue }
        $path = $line.Substring(0, $i); $last = ConvertFrom-AmonPcaTime $line.Substring($i + 1)
        $inWindow = $last -and (Test-AmonInWindow -Context $Context -Utc $last)
        $rel = Get-AmonExecutableRelevance -Context $Context -Path $path
        if (-not $rel -and $inWindow -and (Add-AmonReviewFinding -Result $res -Module 'PCA' -Artifact 'PCA (PcaAppLaunchDic)' -Path $path -LastRunUtc $last -Context $Context)) {
            $review++; $rel = [pscustomobject]@{ Kind = 'review'; Reason = 'para revisar'; Indicator = $null }
        }
        if (-not $rel -or (-not $inWindow -and $rel.Kind -in @('keyword', 'review'))) { $unrelated++; continue }
        [void]$seen.Add($path)
        $res.Artifacts.Add([pscustomobject]@{ Source = 'PcaAppLaunchDic'; Path = $path; TimestampUtc = $last; Detail = 'última ejecución'; Relevance = $rel.Reason })
        if ($inWindow) { $res.Events.Add((New-AmonEvent -TimestampUtc $last -Type 'Última ejecución registrada por PCA' -Kind Execution -Source 'PCA' -Path $path -Confidence Medium -Description $rel.Reason)) }
        if ((Test-AmonLocalPath -Path $path) -and [IO.File]::Exists($path)) { Add-AmonEvidencePath -Context $Context -Path $path -Source 'PCA' -Reason $rel.Reason }
        if ($rel.Kind -ne 'review') {
            Add-AmonExecutableFinding -Result $res -Context $Context -Module 'PCA' -Artifact 'PCA' -Category 'ExecutionEvidence' -Path $path -TimestampUtc $last -Relevance $rel `
                -What 'Ejecución registrada por PCA' -Caveat ("Última ejecución desde la interfaz gráfica: {0}." -f (Format-AmonTimestamp $last))
        }
    }

    # 2. PcaGeneralDb: hora|tipo|ruta|descripción|fabricante|versión|ProgramId|mensaje.
    foreach ($line in @($Raw.General | Where-Object { $_ })) {
        $res.ArtifactsReviewed++
        $f = $line -split '\|'
        if ($f.Count -lt 8) { continue }
        $path = Expand-AmonPcaPath $f[2]
        $rel = Get-AmonExecutableRelevance -Context $Context -Path $path
        if (-not $rel -or $rel.Kind -eq 'keyword') { $unrelated++; continue }
        $t = ConvertFrom-AmonPcaTime $f[0]
        $kind = switch ($f[1]) { '0' { 'fallo del instalador' } '1' { 'driver bloqueado' } '2' { 'salida anormal del proceso' } '3' { 'PCA resolve' } default { "tipo $($f[1])" } }
        $res.Artifacts.Add([pscustomobject]@{ Source = 'PcaGeneralDb'; Path = $path; TimestampUtc = $t; Detail = "$kind; $($f[7])"; Relevance = $rel.Reason })
        if ($t -and (Test-AmonInWindow -Context $Context -Utc $t)) { $res.Events.Add((New-AmonEvent -TimestampUtc $t -Type "PCA: $kind" -Kind Execution -Source 'PCA' -Path $path -Confidence Medium -Description $f[7])) }
        if (-not $seen.Add($path)) { continue }
        Add-AmonExecutableFinding -Result $res -Context $Context -Module 'PCA' -Artifact 'PCA' -Category 'ExecutionEvidence' -Path $path -TimestampUtc $t -Relevance $rel `
            -What "Ejecución registrada por PCA ($kind)" -Caveat "Mensaje: $($f[7])."
    }

    # 3. Trazas PcaClient de explorer.exe: lanzados desde que se abrió el Explorador (sin hora).
    foreach ($path in @($Raw.ExplorerTraces | Where-Object { $_ })) {
        $res.ArtifactsReviewed++
        $rel = Get-AmonExecutableRelevance -Context $Context -Path $path
        if (-not $rel -and (Add-AmonReviewFinding -Result $res -Module 'PCA' -Artifact 'La memoria del Explorador (PcaClient)' -Path $path -LastRunUtc $null -Context $Context)) {
            $review++; $rel = [pscustomobject]@{ Kind = 'review'; Reason = 'para revisar'; Indicator = $null }
        }
        if (-not $rel -or $rel.Kind -eq 'keyword') { $unrelated++; continue }
        $res.Artifacts.Add([pscustomobject]@{ Source = 'explorer (PcaClient)'; Path = $path; TimestampUtc = $null; Detail = 'lanzado desde que se abrió el Explorador'; Relevance = $rel.Reason })
        if (-not $seen.Add($path) -or $rel.Kind -eq 'review') { continue }
        Add-AmonExecutableFinding -Result $res -Context $Context -Module 'PCA' -Artifact 'explorer.exe (PcaClient)' -Category 'ExecutionEvidence' -Path $path -TimestampUtc $null -Relevance $rel `
            -What 'Programa lanzado según la memoria del Explorador' -Caveat 'La traza PcaClient de explorer.exe prueba que se lanzó desde que se abrió el Explorador, pero no guarda la hora.'
    }

    # 4. Store y MUICache: rutas de ejecutables lanzados alguna vez, sin fecha por entrada.
    foreach ($src in @(@('Compatibility Assistant\Store', $Raw.Store), @('MUICache', $Raw.MuiCache))) {
        foreach ($path in @($src[1] | Where-Object { $_ })) {
            $res.ArtifactsReviewed++
            $rel = Get-AmonExecutableRelevance -Context $Context -Path $path
            if (-not $rel -or $rel.Kind -eq 'keyword') { $unrelated++; continue }
            $res.Artifacts.Add([pscustomobject]@{ Source = $src[0]; Path = $path; TimestampUtc = $null; Detail = 'lanzado alguna vez (sin fecha)'; Relevance = $rel.Reason })
            if (-not $seen.Add($path)) { continue }
            Add-AmonExecutableFinding -Result $res -Context $Context -Module 'PCA' -Artifact $src[0] -Category 'ExecutionEvidence' -Path $path -TimestampUtc $null -Relevance $rel `
                -What "Programa lanzado según $($src[0])" -Caveat 'Este registro prueba que se lanzó alguna vez desde la sesión del usuario, pero no guarda la fecha.'
        }
    }
    $res.Data['UnrelatedCount'] = $unrelated
    $res.Data['ReviewCount'] = $review
    if ($truncated) { $res.Limitations.Add("PcaAppLaunchDic.txt tiene $truncated línea(s) truncada(s): una ruta con caracteres no ANSI corta el registro y Windows puede dejar de anotar lanzamientos nuevos.") }
    if ($unrelated) { $res.Limitations.Add("$unrelated entrada(s) de PCA, Store y MUICache sin relación con la revisión se contaron pero no se muestran (privacidad).") }
    $res.Limitations.Add('PCA solo registra programas abiertos desde la interfaz gráfica (no desde consola, tareas ni scripts).')
    return Complete-AmonModuleResult -Result $res
}

#endregion

Export-ModuleMember -Function @(
    'Get-AmonExecutableRelevance', 'Test-AmonReviewLocation', 'Get-AmonCachedSignature',
    'ConvertFrom-AmonShimCache', 'Invoke-AmonShimCacheAnalysis', 'Get-AmonBamRaw', 'Invoke-AmonBamAnalysis',
    'Get-AmonPcaRaw', 'Get-AmonExplorerTraces', 'ConvertFrom-AmonPcaTime', 'Expand-AmonPcaPath', 'Invoke-AmonPcaAnalysis'
)
