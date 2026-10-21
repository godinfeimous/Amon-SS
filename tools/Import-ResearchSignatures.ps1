<#
.SYNOPSIS
    Incorpora a signatures\ los indicadores con fuente de una propuesta de investigación.
.DESCRIPTION
    Lee un JSON de propuesta (array de {clientId, clientName, category, type, value, strength,
    provenance, validated, source, note, encodings, scopes}) y lo fusiona con las definiciones:
      * a un cliente existente se le añaden los indicadores que no tenga ya (mismo tipo y valor);
        si una firma aportada por el usuario aparece en la propuesta con fuente pública, pasa a
        "secondary" con esa fuente;
      * los clientes nuevos se escriben en el archivo de su grupo (ghost-clients.json,
        autoclickers.json o macros.json) o en <id>.json.
    Reglas para no introducir falsos positivos (se aplican aquí, no a mano):
      * se descartan los valores de Excluded (cadenas cortas y genéricas, dominios que ya no son
        del cliente, modid que comparten mods legítimos);
      * config/path con AppData/, Documents/ o .slinky se resuelven desde el perfil del usuario;
      * los programas de macros y AutoHotkey se marcan con la categoría macro (solo información).
    No inventa nada: cada indicador conserva su fuente, procedencia y nota originales.
.EXAMPLE
    .\tools\Import-ResearchSignatures.ps1 -Proposal .\docs\research\02-indicadores-propuestos.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Proposal,
    [string]$SignaturesPath
)
$ErrorActionPreference = 'Stop'
if (-not $SignaturesPath) { $SignaturesPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\signatures' }
$SignaturesPath = (Resolve-Path -LiteralPath $SignaturesPath).Path

$Excluded = @(
    # Doomsday: referencias de una letra a clases ofuscadas, demasiado genéricas.
    'net/java/l', 'net/java/m', 'net/java/r', 'net/java/h', 'net/java/i', 'net/java/k', 'net/java/y', 'net/java/f', 'net/java/s', 'net/java/g', 'net/java/t',
    'future/api',                # corto y genérico
    'whiteout.gg',               # el dominio ya aloja otro producto
    'keystrokes', 'inertia', 'icb',  # modid compartidos con mods legítimos o demasiado cortos
    '"durationMs":', 'MacroClient:Delete'  # contenido de archivos que no se escanean
)
$MacroIds = @('autohotkey', 'logitech-ghub', 'logitech-lgs', 'razer-synapse', 'steelseries', 'roccat-swarm', 'redragon', 'asus-armoury', 'corsair-icue')
$GroupFile = @{
    'generic-autoclicker' = 'autoclickers.json'; 'op-autoclicker' = 'autoclickers.json'; 'speed-autoclicker' = 'autoclickers.json'; 'jnativehook' = 'autoclickers.json'
    'entropy' = 'ghost-clients.json'; 'koid' = 'ghost-clients.json'; 'whiteout' = 'ghost-clients.json'; 'asteria' = 'ghost-clients.json'; 'xenon' = 'ghost-clients.json'
    'gypsy' = 'ghost-clients.json'; 'virgin' = 'ghost-clients.json'; 'dream' = 'ghost-clients.json'; 'krypton' = 'ghost-clients.json'; 'catlean' = 'ghost-clients.json'
}
foreach ($m in $MacroIds) { $GroupFile[$m] = 'macros.json' }
# Palabras clave solo para nombres distintivos (una palabra común daría falsos positivos en rutas).
# Sin 'gamesense' (SteelSeries GG tiene un módulo GameSense) ni nombres comunes como tenacity, rise o sigma.
$Keywords = @{ 'fdpclient' = @('fdpclient'); 'slinky' = @('slinky'); 'dqrkis' = @('dqrkis'); 'catlean' = @('catlean'); 'novoline' = @('novoline'); 'generic-autoclicker' = @('autoclicker', 'auto clicker', 'autoclick') }

function ConvertTo-Ordered($o) {
    if ($o -is [System.Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Ordered $p.Value }; return $h }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return , @($o | ForEach-Object { ConvertTo-Ordered $_ }) }
    return $o
}

# Definiciones actuales: id de cliente -> @{ File; Def; Container }
$files = @{}; $index = @{}
foreach ($f in Get-ChildItem -LiteralPath $SignaturesPath -Filter '*.json' | Where-Object Name -NE 'schema.json') {
    $data = ConvertTo-Ordered (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json)
    $files[$f.Name] = $data
    $defs = if ($data.Contains('clients')) { @($data['clients']) } else { @($data) }
    foreach ($d in $defs) { $index[$d['id']] = @{ File = $f.Name; Def = $d } }
}

$added = 0; $skipped = 0; $promoted = 0; $new = 0
$dirty = [System.Collections.Generic.HashSet[string]]::new()
foreach ($p in (Get-Content -LiteralPath $Proposal -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    if ($p.value -in $Excluded) { $skipped++; continue }
    $cid = [string]$p.clientId
    if (-not $index.ContainsKey($cid)) {
        $cat = if ($cid -in $MacroIds) { 'macro' } elseif ($p.category -in @('cheat-client', 'dual-use', 'autoclicker', 'macro')) { [string]$p.category } else { 'cheat-client' }
        $def = [ordered]@{
            schemaVersion = 1; id = $cid; name = [string]$p.clientName; category = $cat
            description = $(switch ($cat) { 'macro' { 'Software de macros o automatización: tenerlo instalado es normal; se informa para revisar las macros a mano.' } 'autoclicker' { 'Autoclicker externo.' } 'dual-use' { 'Herramienta o librería de uso dual: también tiene usos legítimos.' } default { 'Cliente de trampas.' } })
            openSource = $false; loaders = @(); references = @(); keywords = @($Keywords[$cid] | Where-Object { $_ }); falsePositives = @()
            notes = 'Indicadores de la investigación del 2026-10-21 (docs/research/02-clientes-y-ghost-clients.md); cada uno cita su fuente.'
            indicators = @()
        }
        $file = if ($GroupFile.ContainsKey($cid)) { $GroupFile[$cid] } else { "$cid.json" }
        if (-not $files.ContainsKey($file)) { $files[$file] = if ($GroupFile.ContainsKey($cid)) { [ordered]@{ clients = @() } } else { $def } }
        if ($files[$file].Contains('clients')) { $files[$file]['clients'] = @($files[$file]['clients']) + @($def) }
        $index[$cid] = @{ File = $file; Def = $def }
        [void]$dirty.Add($file)
        $new++
    }
    $def = $index[$cid].Def
    $existing = @($def['indicators'])
    $dup = $existing | Where-Object { $_['type'] -eq $p.type -and $_['value'] -ceq $p.value } | Select-Object -First 1
    if ($dup) {
        if ($dup['provenance'] -eq 'user-provided') {
            $dup['provenance'] = 'secondary'; $dup['source'] = [string]$p.source
            $dup['note'] = (([string]$dup['note']) + ' Aportada por el usuario y confirmada después en una herramienta SS pública: ' + [string]$p.note).Trim()
            $promoted++; [void]$dirty.Add($index[$cid].File)
        }
        continue
    }
    $n = 1; while ($existing | Where-Object { $_['id'] -eq "$cid.$($p.type).$n" }) { $n++ }
    $ind = [ordered]@{ id = "$cid.$($p.type).$n"; type = [string]$p.type; value = [string]$p.value; strength = [string]$p.strength; provenance = [string]$p.provenance; validated = [bool]$p.validated; source = [string]$p.source }
    if ($p.note) { $ind['note'] = [string]$p.note }
    if ($p.type -in @('config', 'path')) { $ind['relativeTo'] = if ([string]$p.value -match '^(AppData/|Documents/|\.slinky)') { 'userHome' } else { 'gameDir' } }
    if ($p.type -eq 'log' -and [string]$p.value -match '\\d') { $ind['match'] = 'regex' }
    if ($p.encodings) { $ind['encodings'] = @($p.encodings) }
    if ($p.scopes) { $ind['scopes'] = @($p.scopes) }
    $def['indicators'] = @($existing) + @($ind)
    if ($Keywords.ContainsKey($cid)) { $def['keywords'] = @(@($def['keywords']) + @($Keywords[$cid]) | Where-Object { $_ } | Select-Object -Unique) }
    if ($def['notes'] -match '^Sin indicadores verificables') { $def['notes'] = 'Indicadores de la investigación del 2026-10-21 (docs/research/02-clientes-y-ghost-clients.md): herramientas SS públicas y código publicado; cada uno cita su fuente.' }
    $added++; [void]$dirty.Add($index[$cid].File)
}

# Mismo formato que los archivos escritos a mano: 2 espacios, un indicador por línea y los
# caracteres no ASCII tal cual (ConvertTo-Json de PowerShell 5.1 escaparía < > ' &).
function ConvertTo-JsonText([object]$v) {
    if ($null -eq $v) { return 'null' }
    if ($v -is [bool]) { return $(if ($v) { 'true' } else { 'false' }) }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return [string]$v }
    $s = [string]$v
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $s.ToCharArray()) {
        switch ($c) {
            '"' { [void]$sb.Append('\"') } '\' { [void]$sb.Append('\\') }
            default { if ([int]$c -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) } }
        }
    }
    [void]$sb.Append('"'); return $sb.ToString()
}
function Format-Inline($v) {
    if ($v -is [System.Collections.IDictionary]) { return '{ ' + ((@($v.Keys) | ForEach-Object { (ConvertTo-JsonText $_) + ': ' + (Format-Inline $v[$_]) }) -join ', ') + ' }' }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return '[' + ((@($v) | ForEach-Object { Format-Inline $_ }) -join ', ') + ']' }
    return ConvertTo-JsonText $v
}
function Format-Client($d, [string]$pad) {
    $lines = @()
    $keys = @($d.Keys)
    for ($k = 0; $k -lt $keys.Count; $k++) {
        $key = $keys[$k]; $v = $d[$key]; $comma = if ($k -lt $keys.Count - 1) { ',' } else { '' }
        if ($key -eq 'indicators') {
            $items = @($v)
            if (-not $items.Count) { $lines += "$pad  `"indicators`": []$comma"; continue }
            $lines += "$pad  `"indicators`": ["
            for ($i = 0; $i -lt $items.Count; $i++) { $lines += "$pad    " + (Format-Inline $items[$i]) + $(if ($i -lt $items.Count - 1) { ',' } else { '' }) }
            $lines += "$pad  ]$comma"
        } elseif ($v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and ((Format-Inline $v).Length -gt 100)) {
            $items = @($v)
            $lines += "$pad  $(ConvertTo-JsonText $key): ["
            for ($i = 0; $i -lt $items.Count; $i++) { $lines += "$pad    " + (Format-Inline $items[$i]) + $(if ($i -lt $items.Count - 1) { ',' } else { '' }) }
            $lines += "$pad  ]$comma"
        } else { $lines += "$pad  $(ConvertTo-JsonText $key): $(Format-Inline $v)$comma" }
    }
    return @("$pad{") + $lines + @("$pad}")
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($name in $dirty) {
    $data = $files[$name]
    if ($data.Contains('clients')) {
        $out = @('{', '  "clients": [')
        $cl = @($data['clients'])
        for ($i = 0; $i -lt $cl.Count; $i++) {
            $block = @(Format-Client $cl[$i] '    ')
            if ($i -lt $cl.Count - 1) { $block[-1] += ',' }
            $out += $block
        }
        $out += @('  ]', '}')
    } else { $out = @(Format-Client $data '') }
    [IO.File]::WriteAllText((Join-Path $SignaturesPath $name), ($out -join "`n") + "`n", $utf8)
}
Write-Host ("Añadidos {0} | descartados {1} | promovidos de user-provided {2} | clientes nuevos {3}" -f $added, $skipped, $promoted, $new)
