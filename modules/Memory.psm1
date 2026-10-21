#Requires -Version 5.1
<#
    Amon SS - modules/Memory.psm1
    Busca firmas de clientes en la memoria de los procesos Java en ejecución (javaw.exe,
    java.exe). Es la prueba más directa de que un cliente está CARGADO en este momento, también
    si se inyectó sin dejar un JAR en disco (ghost clients).

      * Patrones: nombres de paquete y clases de entrada de las firmas (en forma interna de la
        JVM, con '/', y en forma Java, con '.') y cadenas largas y específicas (al menos
        $script:MinStringLength caracteres) en ASCII/UTF-8 y UTF-16LE.
      * Solo lectura (OpenProcess + VirtualQueryEx + ReadProcessMemory, en AmonNative.cs). No se
        suspende ni se modifica el proceso y no se guarda nada de su memoria: solo qué firmas
        aparecen y en qué dirección.
      * Límites: $script:MaxBytesPerProcess bytes y $script:MaxSecondsPerProcess segundos por
        proceso (Minecraft puede reservar varios GB).
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Signatures.psm1') -DisableNameChecking

$script:MinStringLength = 10
$script:MinPackageLength = 8
$script:MaxBytesPerProcess = 3GB
$script:MaxSecondsPerProcess = 60

function Get-AmonMemoryPatterns {
    <#
    .SYNOPSIS
        Construye los patrones de memoria a partir del conjunto de firmas.
        Devuelve @{ Matcher; Map } donde Map[i] = { Indicator; Form }.
    #>
    param([Parameter(Mandatory = $true)]$Set)
    Import-AmonNative
    $bytes = [System.Collections.Generic.List[byte[]]]::new()
    $map = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $add = {
        param($ind, [string]$text, [string]$form, [string]$enc)
        if (-not $text -or -not $seen.Add("$enc|$text")) { return }
        $b = if ($enc -eq 'utf16le') { [Text.Encoding]::Unicode.GetBytes($text) } else { [Text.Encoding]::UTF8.GetBytes($text) }
        $bytes.Add($b); $map.Add([pscustomobject]@{ Indicator = $ind; Form = $form; Encoding = $enc })
    }
    foreach ($ind in $Set.Indicators) {
        # En memoria solo indicadores medios o fuertes: uno débil (dominio, nombre corto) puede
        # aparecer en el chat o en la lista de servidores y daría falsos positivos.
        if ($ind.Strength -eq 'weak') { continue }
        switch ($ind.Type) {
            'package' {
                $v = $ind.Value.Trim().TrimEnd('/', '.')
                if ($v.Length -lt $script:MinPackageLength) { continue }
                & $add $ind ($v.Replace('.', '/') + '/') 'paquete (forma interna)' 'ascii'
                & $add $ind ($v.Replace('/', '.') + '.') 'paquete' 'ascii'
            }
            'entrypoint' {
                & $add $ind $ind.Value 'clase' 'ascii'
                & $add $ind $ind.Value.Replace('.', '/') 'clase (forma interna)' 'ascii'
            }
            'string' {
                if ($ind.Match -eq 'regex' -or $ind.Value.Length -lt $script:MinStringLength) { continue }
                & $add $ind $ind.Value 'cadena' 'ascii'
                & $add $ind $ind.Value 'cadena' 'utf16le'
            }
            'memory' {
                # Cadenas documentadas específicamente para memoria (herramientas SS públicas).
                if ($ind.Value.Length -lt $script:MinStringLength) { continue }
                & $add $ind $ind.Value 'cadena en memoria' 'ascii'
                & $add $ind $ind.Value 'cadena en memoria' 'utf16le'
            }
        }
    }
    $matcher = if ($bytes.Count) { New-Object AmonSS.Native.PatternMatcher (, $bytes.ToArray()) } else { $null }
    return [pscustomobject]@{ Matcher = $matcher; Map = $map.ToArray() }
}

function Get-AmonJavaProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -Property ProcessId, Name, ExecutablePath, CreationDate -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ ProcessId = [int]$_.ProcessId; Name = [string]$_.Name; Path = [string]$_.ExecutablePath; CreationUtc = $(if ($_.CreationDate) { ([datetime]$_.CreationDate).ToUniversalTime() } else { $null }) }
        })
}

function Invoke-AmonMemoryAnalysis {
    <#
    .SYNOPSIS
        Escanea la memoria de los procesos Java y devuelve un AmonSS.ModuleResult.
    .PARAMETER Processes
        Procesos a escanear (ProcessId, Name, Path); por defecto, java.exe y javaw.exe vivos.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [object[]]$Processes, $Set)
    $res = New-AmonModuleResult -Module 'Memory' -DisplayName 'Java Memory Scanner'
    $res.Scope.Add('Memoria de java.exe / javaw.exe en ejecución (solo coincidencias con firmas; no se guarda su contenido).')
    if (-not $Set) { $Set = if ($Context.Signatures) { $Context.Signatures } else { Get-AmonSignatureSet } }
    if ($null -eq $Processes) {
        try { $Processes = @(Get-AmonJavaProcesses) }
        catch { $res.Errors.Add("No se pudo enumerar los procesos: $($_.Exception.Message)"); return Complete-AmonModuleResult -Result $res -Status Failed }
    }
    if (-not @($Processes).Count) {
        $res.Limitations.Add('No había ningún proceso de Java en ejecución: abre Minecraft antes de la revisión para poder escanear su memoria.')
        return Complete-AmonModuleResult -Result $res -Status Skipped
    }
    $patterns = Get-AmonMemoryPatterns -Set $Set
    if (-not $patterns.Matcher) { $res.Warnings.Add('Las firmas no contienen patrones aptos para memoria.'); return Complete-AmonModuleResult -Result $res -Status Skipped }
    $res.Data['Patterns'] = $patterns.Map.Count
    $i = 0
    foreach ($p in @($Processes)) {
        if (Test-AmonCancel -Context $Context) { break }
        $i++
        Update-AmonProgress -Context $Context -Percent (100.0 * ($i - 1) / @($Processes).Count) -Detail "$($p.Name) PID $($p.ProcessId)" -Count $res.ArtifactsReviewed
        $deadline = [datetime]::UtcNow.AddSeconds($script:MaxSecondsPerProcess)
        if ($Context.Deadline -and $Context.Deadline -lt $deadline) { $deadline = $Context.Deadline }
        $scan = [AmonSS.Native.ProcessMemory]::Scan([int]$p.ProcessId, $patterns.Matcher, $script:MaxBytesPerProcess, $deadline)
        $res.ArtifactsReviewed++
        $res.Artifacts.Add([pscustomobject]@{
                ProcessId = $p.ProcessId; Name = $p.Name; Path = $p.Path; ScannedMB = [Math]::Round($scan.BytesScanned / 1MB); Regions = $scan.Regions
                Matches = $scan.Patterns.Length; Truncated = $scan.Truncated; TimedOut = $scan.TimedOut; Error = $scan.Error
            })
        if ($scan.Error) { $res.Warnings.Add("$($p.Name) PID $($p.ProcessId): $($scan.Error)"); continue }
        if ($scan.Truncated -or $scan.TimedOut) { $res.Limitations.Add("$($p.Name) PID $($p.ProcessId): memoria escaneada parcialmente ($([Math]::Round($scan.BytesScanned / 1MB)) MB) por límite de $(if ($scan.TimedOut) { 'tiempo' } else { 'tamaño' }).") }
        $hits = [ordered]@{}
        for ($k = 0; $k -lt $scan.Patterns.Length; $k++) {
            $pm = $patterns.Map[$scan.Patterns[$k]]
            $key = $pm.Indicator.ClientId + '|' + $pm.Indicator.Id
            if ($hits.Contains($key)) { continue }
            $hits[$key] = [pscustomobject]@{ ClientId = $pm.Indicator.ClientId; Indicator = $pm.Indicator; Type = $pm.Indicator.Type; Value = $pm.Indicator.Value; Scope = 'memory'
                Location = ('memoria de {0} PID {1} ({2}, {3}, dirección 0x{4:X})' -f $p.Name, $p.ProcessId, $pm.Form, $pm.Encoding, $scan.Addresses[$k]) }
        }
        foreach ($d in (Get-AmonSignatureDetections -Hits @($hits.Values) -Set $Set)) {
            $ev = @($d.Matches | ForEach-Object { New-AmonEvidence -Source 'Memory' -Kind Signature -Path $p.Path -Description ("{0} '{1}' en {2}. Fuente: {3} ({4}{5})." -f $_.Type, $_.Value, $_.Location, $_.Indicator.Source, $_.Indicator.Provenance, $(if ($_.Indicator.Validated) { ', validada' } else { ', sin validar' })) })
            $res.Findings.Add((New-AmonFinding -Module 'Memory' -Category 'ClientMemory' -Title "$($d.ClientName): firmas en la memoria de $($p.Name)" -Status $d.Status -Severity $d.Severity -Confidence $d.Confidence `
                        -Path $p.Path -TimestampUtc $p.CreationUtc -Indicator (@($d.Matches | Select-Object -First 2 | ForEach-Object { $_.Value }) -join ', ') -IndicatorType 'memory' -Client $d.ClientName -ClientId $d.ClientId `
                        -Source 'Memory' -Justification ("El proceso {0} (PID {1}) contiene ahora mismo en memoria firmas de {2}: el cliente está cargado en el juego, haya o no un JAR en disco. {3}" -f $p.Name, $p.ProcessId, $d.ClientName, $d.Justification) `
                        -FalsePositives @(@('Un mod legítimo que incluya el mismo paquete.') + @($d.FalsePositives)) -Evidence $ev -Data @{ Execution = $true; ProcessId = $p.ProcessId }))
            $res.Events.Add((New-AmonEvent -TimestampUtc ([datetime]::UtcNow) -Type 'Firmas de cliente en memoria' -Kind Execution -Source 'Memory' -Path $p.Path -Indicator $d.ClientName -Confidence $d.Confidence))
        }
    }
    $res.Limitations.Add('La memoria solo muestra lo cargado ahora: si el juego se reinició o el cliente se descargó, ya no aparece.')
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @('Get-AmonMemoryPatterns', 'Get-AmonJavaProcesses', 'Invoke-AmonMemoryAnalysis')
