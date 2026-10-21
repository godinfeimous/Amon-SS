#Requires -Version 5.1
<#
    Amon SS - modules/Processes.psm1
    Inspector de procesos (solo lectura) mediante Get-CimInstance Win32_Process.

      * Procesos relevantes: Java, launchers reconocidos y procesos que coinciden con
        palabras clave o indicadores ya encontrados. El resto no se muestra.
      * Para Java: clase principal, -jar, -javaagent, -Dfabric.addMods, classpath fuera de
        librerías, versión, gameDir y usuario. Los tokens de sesión se ocultan.
      * Firma digital (Authenticode) del ejecutable y de las DLL candidatas cargadas en Java.

    No se finalizan procesos, no se leen memorias y no se guardan argumentos de procesos
    ajenos a la investigación.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

$script:SignatureCache = @{}
# Nativas legítimas conocidas: LWJGL/GLFW/OpenAL (Minecraft), JNA, superposiciones (OBS, Steam,
# RivaTuner, Discord) y las de Simple Voice Chat (opus4j, rnnoise4j, speex4j, lame4j de henkelmax).
# Es una lista por nombre y por tanto evadible: solo reduce ruido de un indicador heurístico.
$script:AllowedModuleNames = @(
    'lwjgl*', 'glfw*', 'openal*', 'jemalloc*', 'jinput*', 'jnidispatch*', 'jna*',
    'graphics-hook*', 'gameoverlayrenderer*', 'rtsshooks*', 'discordhook*',
    'libopus4j*', 'librnnoise4j*', 'libspeex4j*', 'liblame4j*'
)
# Carpetas gestionadas por launchers (sus propias nativas).
$script:LauncherNativeFragments = @('\.lunarclient\offline\', '\.lunarclient\jre\')
$script:ValueOptions = @('-cp', '-classpath', '--class-path', '-p', '--module-path', '--add-opens', '--add-exports', '--add-modules', '--add-reads', '-jar')

function Split-AmonCommandLine {
    # Tokeniza según las reglas de CommandLineToArgvW (comillas y barras invertidas).
    param([AllowEmptyString()][string]$CommandLine)
    $tokens = [System.Collections.Generic.List[string]]::new()
    if (-not $CommandLine) { return @() }
    $sb = New-Object System.Text.StringBuilder
    $inQ = $false; $has = $false; $i = 0
    while ($i -lt $CommandLine.Length) {
        $c = $CommandLine[$i]
        if ($c -eq '\') {
            $n = 0
            while ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq '\') { $n++; $i++ }
            if ($i -lt $CommandLine.Length -and $CommandLine[$i] -eq '"') {
                [void]$sb.Append('\' * [int][Math]::Floor($n / 2))
                if ($n % 2 -eq 1) { [void]$sb.Append('"'); $i++ }
            } else { [void]$sb.Append('\' * $n) }
            $has = $true
            continue
        }
        if ($c -eq '"') { $inQ = -not $inQ; $has = $true; $i++; continue }
        if ([char]::IsWhiteSpace($c) -and -not $inQ) {
            if ($has) { $tokens.Add($sb.ToString()); [void]$sb.Clear(); $has = $false }
            $i++; continue
        }
        [void]$sb.Append($c); $has = $true; $i++
    }
    if ($has) { $tokens.Add($sb.ToString()) }
    return $tokens.ToArray()
}

function ConvertFrom-AmonJavaCommandLine {
    <#
    .SYNOPSIS
        Extrae los datos forenses relevantes de la línea de comandos de un proceso Java.
    #>
    param([AllowEmptyString()][string]$CommandLine)
    $t = @(Split-AmonCommandLine $CommandLine)
    $r = [ordered]@{
        Executable = $(if ($t.Count) { $t[0] } else { $null }); MainClass = $null; Jar = $null; JavaAgents = @(); AddedMods = @()
        ClassPath = @(); NonLibraryClassPath = @(); BootClassPath = $false; GameDir = $null; Version = $null; Username = $null
        AssetIndex = $null; SafeCommandLine = (Protect-AmonCommandLine $CommandLine)
    }
    $programArgs = @()
    $i = 1
    while ($i -lt $t.Count) {
        $tok = $t[$i]
        if ($null -eq $r.MainClass -and $null -eq $r.Jar) {
            if ($tok -in $script:ValueOptions) {
                $val = if ($i + 1 -lt $t.Count) { $t[$i + 1] } else { $null }
                if ($tok -eq '-jar') { $r.Jar = $val; $programArgs = @($t | Select-Object -Skip ($i + 2)); break }
                if ($tok -in @('-cp', '-classpath', '--class-path')) { $r.ClassPath = @($val -split ';' | Where-Object { $_ }) }
                $i += 2; continue
            }
            if ($tok -like '-javaagent:*') {
                $v = $tok.Substring(11); $eq = $v.IndexOf('='); if ($eq -gt 0) { $v = $v.Substring(0, $eq) }
                $r.JavaAgents += $v
            } elseif ($tok -like '-Dfabric.addMods=*') {
                $r.AddedMods += @($tok.Substring(17) -split ';' | Where-Object { $_ })
            } elseif ($tok -like '-Xbootclasspath*') {
                $r.BootClassPath = $true
            } elseif (-not $tok.StartsWith('-')) {
                $r.MainClass = $tok
                $programArgs = @($t | Select-Object -Skip ($i + 1))
                break
            }
            $i++; continue
        }
        $i++
    }
    for ($k = 0; $k -lt $programArgs.Count - 1; $k++) {
        switch ($programArgs[$k]) {
            '--gameDir' { $r.GameDir = $programArgs[$k + 1] }
            '--version' { $r.Version = $programArgs[$k + 1] }
            '--username' { $r.Username = $programArgs[$k + 1] }
            '--assetIndex' { $r.AssetIndex = $programArgs[$k + 1] }
        }
    }
    $r.NonLibraryClassPath = @($r.ClassPath | Where-Object {
            $_ -like '*.jar' -and $_ -notmatch '(?i)\\libraries\\' -and $_ -notmatch '(?i)\\versions\\' -and $_ -notmatch '(?i)\\(jre|runtime|jdk[^\\]*)\\' -and $_ -notmatch '(?i)\\\.lunarclient\\(offline|jre|shared)\\'
        })
    return [pscustomobject]$r
}

function Get-AmonSignatureInfo {
    # Estado Authenticode con caché por ruta.
    param([string]$Path)
    if (-not $Path) { return [pscustomobject]@{ Status = 'Sin ruta'; Signer = $null; IsSigned = $false } }
    if ($script:SignatureCache.ContainsKey($Path)) { return $script:SignatureCache[$Path] }
    $info = [pscustomobject]@{ Status = 'Desconocido'; Signer = $null; IsSigned = $false }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $signer = $null
        if ($s.SignerCertificate) {
            $subject = $s.SignerCertificate.Subject
            if ($subject -match 'CN="([^"]+)"') { $signer = $Matches[1] }
            elseif ($subject -match 'CN=([^,]+)') { $signer = $Matches[1].Trim() }
            else { $signer = $subject }
        }
        $info = [pscustomobject]@{ Status = [string]$s.Status; Signer = $signer; IsSigned = ($s.Status -eq 'Valid') }
    } catch { $info.Status = 'Ilegible' }
    $script:SignatureCache[$Path] = $info
    return $info
}

function Test-AmonModuleSuspicious {
    <#
    .SYNOPSIS
        ¿Una DLL cargada en Java merece revisión? Sin firma válida, fuera de Windows/Java y en
        una ubicación escribible por el usuario, salvo nativas conocidas (LWJGL, superposiciones).
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$Signed, [string]$JavaHome)
    if ($Signed) { return $false }
    $p = $Path.ToLowerInvariant()
    $win = ([string]$env:SystemRoot).ToLowerInvariant()
    if (-not $win) { $win = 'c:\windows' }
    if ($p.StartsWith($win + '\') -or $p.StartsWith('c:\windows\')) { return $false }
    if ($JavaHome -and $p.StartsWith($JavaHome.ToLowerInvariant())) { return $false }
    $name = [IO.Path]::GetFileName($p)
    foreach ($a in $script:AllowedModuleNames) { if ($name -like $a) { return $false } }
    foreach ($f in $script:LauncherNativeFragments) { if ($p.Contains($f)) { return $false } }
    return [bool]($p -match '\\users\\|\\programdata\\|\\temp\\|\\appdata\\')
}

function Get-AmonProcessSnapshot {
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            ProcessId = [int]$_.ProcessId; ParentProcessId = [int]$_.ParentProcessId; Name = [string]$_.Name
            ExecutablePath = [string]$_.ExecutablePath; CommandLine = [string]$_.CommandLine
            CreationUtc = $(if ($_.CreationDate) { ([datetime]$_.CreationDate).ToUniversalTime() } else { $null })
        }
    }
}

function Test-AmonRuntimeAgent {
    # instrument.dll es la parte nativa de java.lang.instrument y la JVM solo la carga cuando hay
    # un agente Java. Si la línea de comandos no declara ninguno (-javaagent, -agentpath,
    # -agentlib), el agente se añadió con el proceso ya en marcha.
    param([string[]]$Modules = @(), [string]$CommandLine)
    $loaded = @($Modules | Where-Object { $_ -and [IO.Path]::GetFileName($_) -ieq 'instrument.dll' }).Count -gt 0
    return ($loaded -and ([string]$CommandLine) -notmatch '(?i)-(javaagent|agentpath|agentlib)[:=]')
}

function Invoke-AmonProcessAnalysis {
    <#
    .SYNOPSIS
        Inspecciona procesos relevantes y devuelve un AmonSS.ModuleResult.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, [object[]]$Snapshot)
    $res = New-AmonModuleResult -Module 'Processes' -DisplayName 'Process Inspector'
    $res.Scope.Add('Procesos en ejecución (Win32_Process): Java, launchers e indicadores.')
    try { if (-not $Snapshot) { $Snapshot = @(Get-AmonProcessSnapshot) } }
    catch { $res.Errors.Add("No se pudo consultar Win32_Process: $($_.Exception.Message)"); return Complete-AmonModuleResult -Result $res -Status Failed }
    $res.ArtifactsReviewed = $Snapshot.Count
    $byPid = @{}; foreach ($p in $Snapshot) { $byPid[$p.ProcessId] = $p }
    $launchers = @($Context.Settings.launcherProcessNames)
    $clientKeywords = if ($Context.Signatures) { @($Context.Signatures.Keywords) } else { @() }
    $keywords = @($Context.Keywords)
    $indicators = @($Context.IndicatorNames)

    $relevant = @($Snapshot | Where-Object {
            $_.Name -in $launchers -or
            (Test-AmonKeywordMatch -Text $_.Name -Keywords $keywords) -or
            ($_.ExecutablePath -and (Test-AmonKeywordMatch -Text $_.ExecutablePath -Keywords $keywords)) -or
            (Get-AmonToolByFileName -Context $Context -Name $_.Name) -or
            ($indicators.Count -and (Test-AmonKeywordMatch -Text ([string]$_.CommandLine) -Keywords $indicators))
        })
    $k = 0
    foreach ($p in $relevant) {
        if (Test-AmonCancel -Context $Context) { break }
        $k++
        Update-AmonProgress -Context $Context -Percent (100.0 * $k / [Math]::Max(1, $relevant.Count)) -Detail $p.Name -Count $k
        $sig = Get-AmonSignatureInfo -Path $p.ExecutablePath
        $parent = $byPid[$p.ParentProcessId]
        $isJava = $p.Name -in @('java.exe', 'javaw.exe')
        $kind = if ($isJava) { 'Java' } elseif ($p.Name -in $launchers) { 'Launcher' } else { 'Coincidencia' }
        $java = $null; $details = ''
        if ($isJava) {
            $java = ConvertFrom-AmonJavaCommandLine -CommandLine $p.CommandLine
            $parts = @()
            if ($java.MainClass) { $parts += "main: $($java.MainClass)" }
            if ($java.Jar) { $parts += "-jar $($java.Jar)" }
            if ($java.Version) { $parts += "versión: $($java.Version)" }
            if ($java.GameDir) { $parts += "gameDir: $($java.GameDir)" }
            if ($java.JavaAgents.Count) { $parts += "agentes: $($java.JavaAgents -join ', ')" }
            $details = $parts -join ' | '
        }
        $res.Artifacts.Add([pscustomobject]@{
                Name = $p.Name; ProcessId = $p.ProcessId; ParentProcessId = $p.ParentProcessId
                ParentName = $(if ($parent) { $parent.Name } else { '(no disponible)' }); Path = $p.ExecutablePath; StartUtc = $p.CreationUtc
                Kind = $kind; SignatureStatus = $sig.Status; Signer = $sig.Signer; Details = $details
                CommandLine = $(if ($java) { $java.SafeCommandLine } else { Protect-AmonCommandLine $p.CommandLine })
                Username = $(if ($java) { $java.Username } else { $null }); Modules = @()
            })
        $artifact = $res.Artifacts[$res.Artifacts.Count - 1]
        if ($p.CreationUtc -and (Test-AmonInWindow -Context $Context -Utc $p.CreationUtc)) {
            $res.Events.Add((New-AmonEvent -TimestampUtc $p.CreationUtc -Type 'Proceso iniciado (sigue en ejecución)' -Kind Execution -Source 'Processes' -Path $p.ExecutablePath -Confidence High -Description "$($p.Name) PID $($p.ProcessId)$(if ($details) { ' - ' + $details })"))
        }
        if ($tool = Get-AmonToolByFileName -Context $Context -Name $p.Name) {
            $res.Findings.Add((New-AmonToolFinding -Module 'Processes' -Indicator $tool -Path $p.ExecutablePath -TimestampUtc $p.CreationUtc `
                        -What "$($tool.ClientName) en ejecución (PID $($p.ProcessId))" -Detail "El proceso $($p.Name) está abierto ahora mismo (iniciado el $(Format-AmonTimestamp $p.CreationUtc))."))
            if ($p.ExecutablePath) { Add-AmonEvidencePath -Context $Context -Path $p.ExecutablePath -Source 'Processes' -Reason "herramienta conocida ($($tool.ClientName))" }
        }
        foreach ($kw in $clientKeywords) {
            if ($p.Name.IndexOf($kw, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$p.ExecutablePath).IndexOf($kw, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'KeywordName' -Title "Proceso con nombre relacionado: $($p.Name)" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                            -Path $p.ExecutablePath -TimestampUtc $p.CreationUtc -Indicator "palabra clave '$kw'" -IndicatorType 'keyword' `
                            -Justification 'El nombre o la ruta del proceso contiene una palabra clave de un cliente. Por sí solo no prueba nada.' -FalsePositives @('Coincidencia casual de nombre.')))
                if ($p.ExecutablePath) { Add-AmonEvidencePath -Context $Context -Path $p.ExecutablePath -Source 'Processes' -Reason "palabra clave '$kw'" }
                break
            }
        }
        if (-not $isJava) { continue }

        if ($java.GameDir) { Add-AmonIndicator -Context $Context -Keyword $java.GameDir }
        foreach ($a in $java.JavaAgents) {
            $own = $a -match '(?i)\\\.lunarclient\\'
            $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'JavaAgentProcess' -Title "Agente Java en el proceso $($p.Name) (PID $($p.ProcessId))" -Status $(if ($own) { 'INFO' } else { 'INCONCLUSIVE' }) -Severity $(if ($own) { 'Info' } else { 'Medium' }) -Confidence Medium `
                        -Path $a -TimestampUtc $p.CreationUtc -Indicator "-javaagent:$a" -IndicatorType 'javaagent' `
                        -Justification $(if ($own) { 'Agente propio del launcher Lunar Client.' } else { 'Un agente Java puede modificar las clases del juego al arrancar; es el mecanismo de varios clientes inyectados. El JAR del agente se escanea con las firmas.' }) `
                        -FalsePositives @('Perfiladores, depuradores y algunos launchers usan agentes propios.')))
            Add-AmonEvidencePath -Context $Context -Path $a -Source 'Processes' -Reason '-javaagent'
        }
        foreach ($j in (@($java.AddedMods) + @($java.NonLibraryClassPath) + @($java.Jar) | Where-Object { $_ })) {
            Add-AmonEvidencePath -Context $Context -Path $j -Source 'Processes' -Reason "JAR en la línea de comandos de PID $($p.ProcessId)"
        }
        if ($Context.Signatures) {
            foreach ($ja in $Context.Signatures.JvmArgs) {
                if (([string]$p.CommandLine).IndexOf($ja.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    # Un argumento sin validar no basta para afirmar que el indicador está presente.
                    $jaStatus = if ($ja.Validated) { 'DETECTED' } else { 'INCONCLUSIVE' }
                    $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'ClientProcess' -Title "$($ja.ClientName): argumento JVM en proceso en ejecución" -Status $jaStatus -Severity Medium -Confidence $(if ($ja.Validated) { 'Medium' } else { 'Low' }) `
                                -Path $p.ExecutablePath -TimestampUtc $p.CreationUtc -Indicator $ja.Value -IndicatorType 'jvmArg' -Client $ja.ClientName -ClientId $ja.ClientId `
                                -Justification "La línea de comandos del PID $($p.ProcessId) contiene '$($ja.Value)' ($($ja.Source))." -Data @{ Execution = $true }))
                }
            }
        }
        if ($sig.Status -ne 'Valid') {
            $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'UnsignedJava' -Title "Ejecutable de Java sin firma válida (PID $($p.ProcessId))" -Status INFO -Severity Info -Confidence Medium `
                        -Path $p.ExecutablePath -Indicator "Authenticode: $($sig.Status)" -IndicatorType 'signature' `
                        -Justification 'Las distribuciones oficiales de Java están firmadas. Un runtime sin firma suele ser uno empaquetado por un launcher, pero conviene revisar su origen.' `
                        -FalsePositives @('Runtimes empaquetados por launchers o compilaciones propias de OpenJDK.')))
        }

        # DLL cargadas en Java (lista de módulos del proceso; no se lee su memoria)
        $javaHome = if ($p.ExecutablePath) { Split-Path -Parent (Split-Path -Parent $p.ExecutablePath) } else { $null }
        try {
            $mods = @((Get-Process -Id $p.ProcessId -ErrorAction Stop).Modules | ForEach-Object { $_.FileName } | Where-Object { $_ })
            $hook = $mods | Where-Object { [IO.Path]::GetFileName($_) -like 'JNativeHook*.dll' } | Select-Object -First 1
            if ($hook) {
                $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'GlobalInputHook' -Title "Programa Java que captura teclado y ratón en ejecución (PID $($p.ProcessId))" -Status INCONCLUSIVE -Severity Medium -Confidence High `
                            -Path $hook -TimestampUtc $p.CreationUtc -Indicator ([IO.Path]::GetFileName($hook)) -IndicatorType 'module' `
                            -Justification "El proceso $($p.Name) (PID $($p.ProcessId)) tiene cargada la librería JNativeHook, que instala un gancho global de teclado y ratón: es la base de muchos autoclickers en Java. Línea de comandos: $(Protect-AmonCommandLine ([string]$p.CommandLine))" `
                            -FalsePositives @('Programas Java legítimos de atajos de teclado o accesibilidad.')))
                foreach ($j in (@($java.Jar) + @($java.NonLibraryClassPath) | Where-Object { $_ })) { Add-AmonEvidencePath -Context $Context -Path $j -Source 'Processes' -Reason 'programa Java con JNativeHook' }
            }
            if (Test-AmonRuntimeAgent -Modules $mods -CommandLine $p.CommandLine) {
                $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'RuntimeAgent' -Title "Agente Java cargado con el juego ya en marcha (PID $($p.ProcessId))" -Status INCONCLUSIVE -Severity Medium -Confidence Medium `
                            -Path $p.ExecutablePath -TimestampUtc $p.CreationUtc -Indicator 'instrument.dll cargada sin -javaagent' -IndicatorType 'module' `
                            -Justification 'La JVM solo carga instrument.dll para ejecutar agentes Java, y la línea de comandos no declara ninguno: alguien añadió un agente después de arrancar el juego. Es una forma de inyectar clientes; revisa la memoria y los programas ejecutados.' `
                            -FalsePositives @('Perfiladores y herramientas de monitorización de Java (VisualVM, JProfiler...).', 'Algunos launchers o mods que cargan agentes en caliente.')))
            }
            $flagged = @()
            foreach ($m in $mods) {
                if (-not (Test-AmonModuleSuspicious -Path $m -Signed $false -JavaHome $javaHome)) { continue }
                $ms = Get-AmonSignatureInfo -Path $m
                if (Test-AmonModuleSuspicious -Path $m -Signed $ms.IsSigned -JavaHome $javaHome) { $flagged += [pscustomobject]@{ Path = $m; Signature = $ms.Status } }
            }
            $artifact.Modules = @($flagged | ForEach-Object Path)
            foreach ($fm in $flagged) {
                $res.Findings.Add((New-AmonFinding -Module 'Processes' -Category 'UnsignedModule' -Title "DLL sin firma cargada en $($p.Name) (PID $($p.ProcessId))" -Status INCONCLUSIVE -Severity Low -Confidence Low `
                            -Path $fm.Path -Sha256 (Get-AmonFileHash -Path $fm.Path -Context $Context) -TimestampUtc $p.CreationUtc -Indicator "Authenticode: $($fm.Signature)" -IndicatorType 'module' `
                            -Justification 'Biblioteca nativa sin firma válida, cargada desde una carpeta de usuario dentro del proceso del juego. Puede ser una librería legítima de un mod o un inyector; se escanea con las firmas.' `
                            -FalsePositives @('Nativas de mods (chat de voz, grabación de repeticiones, Discord RPC) y superposiciones de terceros.')))
                Add-AmonEvidencePath -Context $Context -Path $fm.Path -Source 'Processes' -Reason "DLL cargada en PID $($p.ProcessId)"
            }
        } catch {
            $res.Warnings.Add("No se pudieron listar los módulos del PID $($p.ProcessId) ($($_.Exception.Message)); si el juego se ejecuta como administrador, Amon SS también debe hacerlo.")
        }
    }
    $res.Data['RelevantCount'] = $relevant.Count
    $res.Data['TotalProcesses'] = $Snapshot.Count
    if (-not @($relevant | Where-Object { $_.Name -in @('java.exe', 'javaw.exe') }).Count) {
        $res.Limitations.Add('No hay procesos Java en ejecución: solo se pueden analizar artefactos de ejecuciones pasadas.')
    }
    return Complete-AmonModuleResult -Result $res
}

Export-ModuleMember -Function @(
    'Split-AmonCommandLine', 'ConvertFrom-AmonJavaCommandLine', 'Get-AmonSignatureInfo', 'Test-AmonModuleSuspicious',
    'Test-AmonRuntimeAgent', 'Get-AmonProcessSnapshot', 'Invoke-AmonProcessAnalysis'
)
