#Requires -Version 5.1
<#
    Amon SS - modules/UI.psm1
    Motor de interfaz de terminal: banner, menús, cajas, tablas, barras de progreso,
    tarjetas de hallazgos y avisos.

    Diseño:
      * Las funciones Format-* devuelven líneas de texto (con secuencias ANSI si el modo de
        color lo permite). Son puras y se prueban con Pester.
      * Las funciones Write-* / Show-* pintan esas líneas. Si la consola no soporta VT, el
        escritor traduce los colores a Write-Host -ForegroundColor.
      * Todo dato que venga de artefactos (rutas, nombres, líneas de log) pasa por
        ConvertTo-AmonSafeText para eliminar caracteres de control: un nombre de archivo con
        secuencias ANSI no puede alterar la terminal del revisor.
#>

$script:Esc = [char]27
$script:UI = $null

$script:GlyphSets = @{
    Full  = @{
        TL = '╔'; TR = '╗'; BL = '╚'; BR = '╝'; H = '═'; V = '║'; LT = '╠'; RT = '╣'; X = '╬'; VL = '╟'; VR = '╢'
        STL = '┌'; STR = '┐'; SBL = '└'; SBR = '┘'; SH = '─'; SV = '│'; SLT = '├'; SRT = '┤'; SX = '┼'
        Diamond = '◆'; DiamondHollow = '◇'; DiamondDot = '◈'; Star = '✦'; StarHollow = '✧'
        Arrow = '▸'; Dot = '●'; Square = '▣'; BarFull = '█'; BarEmpty = '░'; Ellipsis = '…'
    }
    # Subconjunto WGL4: lo que suelen tener Consolas / Lucida Console en conhost.
    Safe  = @{
        TL = '╔'; TR = '╗'; BL = '╚'; BR = '╝'; H = '═'; V = '║'; LT = '╠'; RT = '╣'; X = '╬'; VL = '╟'; VR = '╢'
        STL = '┌'; STR = '┐'; SBL = '└'; SBR = '┘'; SH = '─'; SV = '│'; SLT = '├'; SRT = '┤'; SX = '┼'
        Diamond = '♦'; DiamondHollow = '◊'; DiamondDot = '♦'; Star = '♦'; StarHollow = '◊'
        Arrow = '►'; Dot = '●'; Square = '■'; BarFull = '█'; BarEmpty = '░'; Ellipsis = '…'
    }
    Ascii = @{
        TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '='; V = '|'; LT = '+'; RT = '+'; X = '+'; VL = '+'; VR = '+'
        STL = '+'; STR = '+'; SBL = '+'; SBR = '+'; SH = '-'; SV = '|'; SLT = '+'; SRT = '+'; SX = '+'
        Diamond = '*'; DiamondHollow = 'o'; DiamondDot = '@'; Star = '*'; StarHollow = '+'
        Arrow = '>'; Dot = '*'; Square = '#'; BarFull = '#'; BarEmpty = '.'; Ellipsis = '...'
    }
}

# Letras del banner (estilo "ANSI Shadow"). Se ensamblan por columnas para garantizar
# que todas las filas tengan el mismo ancho.
$script:ArtLetters = @{
    'A' = @(' █████╗ ', '██╔══██╗', '███████║', '██╔══██║', '██║  ██║', '╚═╝  ╚═╝')
    'M' = @('███╗   ███╗', '████╗ ████║', '██╔████╔██║', '██║╚██╔╝██║', '██║ ╚═╝ ██║', '╚═╝     ╚═╝')
    'O' = @(' ██████╗ ', '██╔═══██╗', '██║   ██║', '██║   ██║', '╚██████╔╝', ' ╚═════╝ ')
    'N' = @('███╗   ██╗', '████╗  ██║', '██╔██╗ ██║', '██║╚██╗██║', '██║ ╚████║', '╚═╝  ╚═══╝')
    'S' = @('███████╗', '██╔════╝', '███████╗', '╚════██║', '███████║', '╚══════╝')
    ' ' = @('    ', '    ', '    ', '    ', '    ', '    ')
}
$script:AsciiLetters = @{
    'A' = @('    _    ', '   / \   ', '  / _ \  ', ' / ___ \ ', '/_/   \_\')
    'M' = @(' __  __ ', '|  \/  |', '| |\/| |', '| |  | |', '|_|  |_|')
    'O' = @('  ___  ', ' / _ \ ', '| | | |', '| |_| |', ' \___/ ')
    'N' = @(' _   _ ', '| \ | |', '|  \| |', '| |\  |', '|_| \_|')
    'S' = @(' ____  ', '/ ___| ', '\___ \ ', ' ___) |', '|____/ ')
    ' ' = @('   ', '   ', '   ', '   ', '   ')
}

$script:SgrToConsole = @{
    30 = 'Black'; 31 = 'DarkRed'; 32 = 'DarkGreen'; 33 = 'DarkYellow'; 34 = 'DarkBlue'; 35 = 'DarkMagenta'; 36 = 'DarkCyan'; 37 = 'Gray'
    90 = 'DarkGray'; 91 = 'Red'; 92 = 'Green'; 93 = 'Yellow'; 94 = 'Blue'; 95 = 'Magenta'; 96 = 'Cyan'; 97 = 'White'
}
$script:ConsoleToSgr = @{}
foreach ($k in $script:SgrToConsole.Keys) { $script:ConsoleToSgr[$script:SgrToConsole[$k]] = $k }

$script:StatusStyle = @{
    'CORRELATED'   = @{ Glyph = 'DiamondDot'; Token = 'finding'; Bold = $true }
    'DETECTED'     = @{ Glyph = 'Dot'; Token = 'finding'; Bold = $true }
    'INCONCLUSIVE' = @{ Glyph = 'DiamondHollow'; Token = 'warning'; Bold = $true }
    'NOT DETECTED' = @{ Glyph = 'Dot'; Token = 'success'; Bold = $false }
    'INFO'         = @{ Glyph = 'Arrow'; Token = 'secondary'; Bold = $false }
}
$script:ConfidenceEs = @{ 'High' = 'ALTA'; 'Medium' = 'MEDIA'; 'Low' = 'BAJA' }

# Tema mínimo integrado por si config/themes.json no está disponible.
$script:FallbackTheme = @{
    displayName = 'Full Purple'; colorMode = 'TrueColor'; glyphs = 'auto'; boxStyle = 'double'
    gradientBanner = $true; animations = $true; blackBackground = $true
    palette = @{
        frame = '#6D28D9'; frameDim = '#3B0764'; title = '#A855F7'; accent = '#C084FC'; secondary = '#C4B5FD'
        primary = '#F5F3FF'; muted = '#8B7FA8'; warning = '#FACC15'; finding = '#F43F5E'; success = '#4ADE80'; shadow = '#3B0764'
    }
    bannerGradient = @('#5B21B6', '#7C3AED', '#A855F7', '#D8B4FE')
    consoleColors = @{
        frame = 'DarkMagenta'; frameDim = 'DarkMagenta'; title = 'Magenta'; accent = 'Magenta'; secondary = 'Gray'
        primary = 'White'; muted = 'DarkGray'; warning = 'Yellow'; finding = 'Red'; success = 'Green'; shadow = 'DarkMagenta'
    }
}

#region Estado e inicialización

function ConvertTo-AmonUIHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-AmonUIHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-AmonUIHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-AmonUIHashtable $_ })
    }
    return $InputObject
}

function Get-AmonConsoleWidth {
    $w = 0
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width } catch { $w = 0 }
    if ($w -lt 20) { try { $w = [Console]::WindowWidth } catch { $w = 0 } }
    if ($w -lt 20) { $w = 100 }
    return $w
}

function Test-AmonVirtualTerminal {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        return [bool]$Host.UI.SupportsVirtualTerminal
    } catch { return $false }
}

function Get-AmonThemeNames {
    param([string]$ThemesPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\themes.json'))
    try {
        $data = Get-Content -LiteralPath $ThemesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data.themes.PSObject.Properties | ForEach-Object { $_.Name })
    } catch { return @('FullPurple') }
}

function Initialize-AmonUI {
    <#
    .SYNOPSIS
        Configura tema, glifos, color y ancho de la interfaz.
    .PARAMETER GlyphMode
        Auto detecta la terminal: Windows Terminal / VS Code / ConEmu => Full; conhost => Safe.
    .PARAMETER ColorMode
        TrueColor (ANSI 24 bits), Console (16 colores) o None. Auto respeta NO_COLOR.
    #>
    [CmdletBinding()]
    param(
        [string]$Theme = 'FullPurple',
        [ValidateSet('Auto', 'Full', 'Safe', 'Ascii')][string]$GlyphMode = 'Auto',
        [ValidateSet('Auto', 'TrueColor', 'Console', 'None')][string]$ColorMode = 'Auto',
        [int]$Width = 0,
        [switch]$NoAnimation,
        [string]$ThemesPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\themes.json')
    )

    $themeData = $null
    try {
        $all = Get-Content -LiteralPath $ThemesPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $prop = $all.themes.PSObject.Properties | Where-Object { $_.Name -eq $Theme } | Select-Object -First 1
        if (-not $prop) { $prop = $all.themes.PSObject.Properties | Where-Object { $_.Name -eq $all.default } | Select-Object -First 1 }
        if ($prop) { $themeData = ConvertTo-AmonUIHashtable $prop.Value; $Theme = $prop.Name }
    } catch { $themeData = $null }
    if (-not $themeData) { $themeData = $script:FallbackTheme; $Theme = 'FullPurple' }

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $true }
    $vt = Test-AmonVirtualTerminal

    if ($ColorMode -eq 'Auto') {
        if ($env:NO_COLOR) { $ColorMode = 'None' }
        elseif ($themeData.colorMode -eq 'Console') { $ColorMode = 'Console' }
        elseif ($redirected) { $ColorMode = 'None' }
        elseif ($vt) { $ColorMode = 'TrueColor' }
        else { $ColorMode = 'Console' }
    }

    if ($GlyphMode -eq 'Auto') {
        $pref = [string]$themeData.glyphs
        if ($env:AMON_GLYPHS -in @('Full', 'Safe', 'Ascii')) { $GlyphMode = $env:AMON_GLYPHS }
        elseif ($pref -in @('full', 'safe', 'ascii')) { $GlyphMode = (Get-Culture).TextInfo.ToTitleCase($pref) }
        elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode' -or $env:ConEmuANSI -eq 'ON' -or $env:TERM -like 'xterm*') { $GlyphMode = 'Full' }
        else { $GlyphMode = 'Safe' }
    }

    $prevEncoding = $null
    if ($GlyphMode -ne 'Ascii' -and -not $redirected) {
        try {
            $prevEncoding = [Console]::OutputEncoding
            if ($prevEncoding.CodePage -ne 65001) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) }
        } catch { $prevEncoding = $null }
    }

    $boxStyle = 'Double'
    if ($themeData.boxStyle -eq 'single') { $boxStyle = 'Single' }

    $prev = $script:UI
    $script:UI = [pscustomobject]@{
        Theme              = $Theme
        ThemeName          = [string]$themeData.displayName
        Palette            = $themeData.palette
        ConsoleColors      = $themeData.consoleColors
        Gradient           = @($themeData.bannerGradient)
        GradientBanner     = [bool]$themeData.gradientBanner
        BlackBackground    = [bool]$themeData.blackBackground
        ColorMode          = $ColorMode
        GlyphMode          = $GlyphMode
        Glyphs             = $script:GlyphSets[$GlyphMode]
        BoxStyle           = $boxStyle
        FixedWidth         = $Width
        Width              = $(if ($Width -gt 0) { $Width } else { Get-AmonConsoleWidth })
        VT                 = $vt
        Redirected         = $redirected
        Animations         = ([bool]$themeData.animations -and -not $NoAnimation -and -not $redirected)
        CodeCache          = @{}
        ProgressActive     = $false
        LastProgressTick   = 0
        LastProgressBucket = -1
        PrevOutputEncoding = $(if ($prev -and $prev.PrevOutputEncoding) { $prev.PrevOutputEncoding } else { $prevEncoding })
        PrevBackground     = $(if ($prev) { $prev.PrevBackground } else { $null })
        PrevForeground     = $(if ($prev) { $prev.PrevForeground } else { $null })
    }
}

function Assert-AmonUI {
    if (-not $script:UI) { Initialize-AmonUI }
    elseif ($script:UI.FixedWidth -le 0) { $script:UI.Width = Get-AmonConsoleWidth }
}

function Get-AmonUIState { Assert-AmonUI; return $script:UI }

function Get-AmonGlyph {
    param([Parameter(Mandatory = $true)][string]$Name)
    Assert-AmonUI
    return [string]$script:UI.Glyphs[$Name]
}

function Get-AmonPanelWidth {
    Assert-AmonUI
    $w = [Math]::Min($script:UI.Width - 1, 112)
    return [Math]::Max($w, 40)
}

function Restore-AmonConsole {
    # Devuelve la consola a su estado original (codificación y colores).
    if (-not $script:UI) { return }
    Complete-AmonProgress
    try { if ($script:UI.PrevOutputEncoding) { [Console]::OutputEncoding = $script:UI.PrevOutputEncoding } } catch { }
    try {
        if ($null -ne $script:UI.PrevBackground) { $Host.UI.RawUI.BackgroundColor = $script:UI.PrevBackground }
        if ($null -ne $script:UI.PrevForeground) { $Host.UI.RawUI.ForegroundColor = $script:UI.PrevForeground }
    } catch { }
}

#endregion

#region Texto y color

function ConvertTo-AmonSafeText {
    # Elimina caracteres de control C0/C1 (incluido ESC) de datos no confiables.
    param([AllowNull()][AllowEmptyString()][object]$Text)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    $s = $s -replace "[\r\n\t]", ' '
    return [regex]::Replace($s, '[\x00-\x1F\x7F-\x9F]', '')
}

function ConvertTo-AmonTerminalLine {
    # Defensa en profundidad para líneas que ya llevan color: conserva solo SGR (ESC[...m) y
    # elimina cualquier otro control (borrado de pantalla, cursor, OSC, BEL...). Los datos no
    # confiables deben pasar además por ConvertTo-AmonSafeText antes de colorearse.
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return [regex]::Replace($Text, '(\x1B\[[0-9;]*m)|[\x00-\x1F\x7F-\x9F]', { param($m) if ($m.Groups[1].Success) { $m.Value } else { '' } })
}

function Get-AmonVisibleLength {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return ([regex]::Replace($Text, "\x1B\[[0-9;?]*[A-Za-z]", '')).Length
}

function ConvertFrom-AmonHexColor {
    param([Parameter(Mandatory = $true)][string]$Hex)
    $h = $Hex.TrimStart('#')
    if ($h.Length -ne 6) { throw "Color hexadecimal inválido: $Hex" }
    [pscustomobject]@{
        R = [Convert]::ToInt32($h.Substring(0, 2), 16)
        G = [Convert]::ToInt32($h.Substring(2, 2), 16)
        B = [Convert]::ToInt32($h.Substring(4, 2), 16)
    }
}

function Get-AmonGradientColor {
    # Interpolación lineal por tramos entre las paradas de color.
    param([Parameter(Mandatory = $true)][string[]]$Stops, [Parameter(Mandatory = $true)][double]$T)
    if ($Stops.Count -eq 1) { return ConvertFrom-AmonHexColor $Stops[0] }
    $t = [Math]::Max(0.0, [Math]::Min(1.0, $T))
    $segments = $Stops.Count - 1
    $pos = $t * $segments
    $i = [Math]::Min([int][Math]::Floor($pos), $segments - 1)
    $local = $pos - $i
    $a = ConvertFrom-AmonHexColor $Stops[$i]
    $b = ConvertFrom-AmonHexColor $Stops[$i + 1]
    [pscustomobject]@{
        R = [int][Math]::Round($a.R + ($b.R - $a.R) * $local)
        G = [int][Math]::Round($a.G + ($b.G - $a.G) * $local)
        B = [int][Math]::Round($a.B + ($b.B - $a.B) * $local)
    }
}

function Get-AmonNearestConsoleSgr {
    param([int]$R, [int]$G, [int]$B)
    $table = @(
        @(30, 0, 0, 0), @(31, 128, 0, 0), @(32, 0, 128, 0), @(33, 128, 128, 0), @(34, 0, 0, 128), @(35, 128, 0, 128), @(36, 0, 128, 128), @(37, 192, 192, 192),
        @(90, 128, 128, 128), @(91, 255, 0, 0), @(92, 0, 255, 0), @(93, 255, 255, 0), @(94, 0, 0, 255), @(95, 255, 0, 255), @(96, 0, 255, 255), @(97, 255, 255, 255)
    )
    $best = 97; $bestD = [double]::MaxValue
    foreach ($e in $table) {
        $d = [Math]::Pow($R - $e[1], 2) + [Math]::Pow($G - $e[2], 2) + [Math]::Pow($B - $e[3], 2)
        if ($d -lt $bestD) { $bestD = $d; $best = $e[0] }
    }
    return $best
}

function Get-AmonRgbCode {
    param([Parameter(Mandatory = $true)]$Rgb)
    Assert-AmonUI
    switch ($script:UI.ColorMode) {
        'TrueColor' { return "$($script:Esc)[38;2;$($Rgb.R);$($Rgb.G);$($Rgb.B)m" }
        'Console' { return "$($script:Esc)[$(Get-AmonNearestConsoleSgr $Rgb.R $Rgb.G $Rgb.B)m" }
        default { return '' }
    }
}

function Get-AmonColorCode {
    # Devuelve @{ Open; Close } para un token de la paleta. Se cachea por token.
    param([Parameter(Mandatory = $true)][string]$Token, [switch]$Bold)
    Assert-AmonUI
    $key = "$Token|$([bool]$Bold)"
    if ($script:UI.CodeCache.ContainsKey($key)) { return $script:UI.CodeCache[$key] }
    $open = ''; $close = ''
    switch ($script:UI.ColorMode) {
        'TrueColor' {
            $hex = $script:UI.Palette[$Token]
            if ($hex) {
                $c = ConvertFrom-AmonHexColor $hex
                $open = "$($script:Esc)[38;2;$($c.R);$($c.G);$($c.B)m"
                $close = "$($script:Esc)[39m"
            }
        }
        'Console' {
            $name = $script:UI.ConsoleColors[$Token]
            if ($name -and $script:ConsoleToSgr.ContainsKey($name)) {
                $open = "$($script:Esc)[$($script:ConsoleToSgr[$name])m"
                $close = "$($script:Esc)[39m"
            }
        }
    }
    if ($Bold -and $script:UI.ColorMode -ne 'None') {
        $open = "$($script:Esc)[1m" + $open
        $close = $close + "$($script:Esc)[22m"
    }
    $code = @{ Open = $open; Close = $close }
    $script:UI.CodeCache[$key] = $code
    return $code
}

function Format-AmonColor {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][string]$Token, [switch]$Bold)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $c = Get-AmonColorCode -Token $Token -Bold:$Bold
    return $c.Open + $Text + $c.Close
}

function Format-AmonText {
    # Ajusta texto plano a un ancho exacto: trunca con elipsis y rellena.
    param(
        [AllowNull()][AllowEmptyString()][object]$Text,
        [Parameter(Mandatory = $true)][int]$Width,
        [ValidateSet('Left', 'Right', 'Center')][string]$Align = 'Left',
        [switch]$NoPad
    )
    $s = ConvertTo-AmonSafeText $Text
    if ($Width -le 0) { return '' }
    $ell = Get-AmonGlyph 'Ellipsis'
    if ($s.Length -gt $Width) {
        if ($Width -le $ell.Length) { $s = $s.Substring(0, $Width) }
        else { $s = $s.Substring(0, $Width - $ell.Length) + $ell }
    }
    if ($NoPad) { return $s }
    switch ($Align) {
        'Right' { return $s.PadLeft($Width) }
        'Center' {
            $left = [int][Math]::Floor(($Width - $s.Length) / 2)
            return (' ' * $left + $s).PadRight($Width)
        }
        default { return $s.PadRight($Width) }
    }
}

function Format-AmonPath {
    # Acorta una ruta por el medio: conserva la raíz y el nombre del archivo.
    param([AllowNull()][AllowEmptyString()][string]$Path, [Parameter(Mandatory = $true)][int]$Width)
    $p = ConvertTo-AmonSafeText $Path
    if ($p.Length -le $Width) { return $p }
    $ell = Get-AmonGlyph 'Ellipsis'
    $parts = $p -split '\\'
    if ($parts.Count -lt 3) { return ($ell + $p.Substring($p.Length - ($Width - $ell.Length))) }
    if ($p.StartsWith('\\')) {
        $root = '\\' + $parts[2] + '\'
        $startIndex = 3
    } else {
        $root = $parts[0] + '\'
        $startIndex = 1
    }
    $file = $parts[$parts.Count - 1]
    $minimal = $root + $ell + '\' + $file
    if ($minimal.Length -gt $Width) {
        $keep = $Width - $ell.Length
        if ($keep -le 0) { return $ell.Substring(0, [Math]::Min($ell.Length, $Width)) }
        return $ell + $p.Substring($p.Length - $keep)
    }
    $result = $minimal
    for ($i = $parts.Count - 2; $i -ge $startIndex; $i--) {
        $tail = ($parts[$i..($parts.Count - 1)]) -join '\'
        $candidate = $root + $ell + '\' + $tail
        if ($candidate.Length -le $Width) { $result = $candidate } else { break }
    }
    return $result
}

function Limit-AmonAnsiText {
    # Trunca texto que ya contiene secuencias ANSI sin romperlas.
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][int]$Width)
    if ((Get-AmonVisibleLength $Text) -le $Width) { return $Text }
    $ell = Get-AmonGlyph 'Ellipsis'
    $limit = [Math]::Max(0, $Width - $ell.Length)
    $sb = New-Object System.Text.StringBuilder
    $visible = 0; $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq $script:Esc -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '[') {
            $j = $i + 2
            while ($j -lt $Text.Length -and -not [char]::IsLetter($Text[$j])) { $j++ }
            [void]$sb.Append($Text.Substring($i, [Math]::Min($j - $i + 1, $Text.Length - $i)))
            $i = $j + 1
            continue
        }
        if ($visible -ge $limit) { $i++; continue }
        [void]$sb.Append($ch); $visible++; $i++
    }
    [void]$sb.Append($ell)
    if ($script:UI.ColorMode -ne 'None') { [void]$sb.Append("$($script:Esc)[39m$($script:Esc)[22m") }
    return $sb.ToString()
}

function Add-AmonPadding {
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][int]$Width)
    $len = Get-AmonVisibleLength $Text
    if ($len -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $len))
}

function Format-AmonFitLine {
    # Ajusta una línea (con o sin ANSI) al ancho interior de un panel.
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ((Get-AmonVisibleLength $Text) -le $Width) { return Add-AmonPadding $Text $Width }
    if ($Text.IndexOf($script:Esc) -lt 0 -and $Text -match '^\s*([A-Za-z]:\\|\\\\)') {
        $indent = $Text.Length - $Text.TrimStart().Length
        return Add-AmonPadding ((' ' * $indent) + (Format-AmonPath -Path $Text.TrimStart() -Width ($Width - $indent))) $Width
    }
    return Add-AmonPadding (Limit-AmonAnsiText -Text $Text -Width $Width) $Width
}

function Split-AmonWrap {
    # Ajuste de línea por palabras; corta palabras más largas que el ancho.
    param([AllowEmptyString()][string]$Text, [Parameter(Mandatory = $true)][int]$Width)
    $clean = (ConvertTo-AmonSafeText $Text).Trim()
    if (-not $clean) { return @('') }
    $lines = [System.Collections.Generic.List[string]]::new()
    $current = ''
    foreach ($word in ($clean -split '\s+')) {
        while ($word.Length -gt $Width) {
            if ($current) { $lines.Add($current); $current = '' }
            $lines.Add($word.Substring(0, $Width))
            $word = $word.Substring($Width)
        }
        if (-not $word) { continue }
        if (-not $current) { $current = $word }
        elseif (($current.Length + 1 + $word.Length) -le $Width) { $current += ' ' + $word }
        else { $lines.Add($current); $current = $word }
    }
    if ($current) { $lines.Add($current) }
    return $lines.ToArray()
}

function Format-AmonLocalTime {
    param([AllowNull()]$Utc)
    if ($null -eq $Utc) { return '' }
    $d = [datetime]$Utc
    if ($d.Kind -eq [DateTimeKind]::Unspecified) { $d = [datetime]::SpecifyKind($d, [DateTimeKind]::Utc) }
    $local = $d.ToLocalTime()
    $offset = [TimeZoneInfo]::Local.GetUtcOffset($local)
    $sign = '+'; if ($offset.Ticks -lt 0) { $sign = '-' }
    return ('{0} UTC{1}{2:hh\:mm}' -f $local.ToString('yyyy-MM-dd HH:mm:ss'), $sign, $offset.Duration())
}

#endregion

#region Componentes (Format-*)

function Get-AmonFrame {
    param([ValidateSet('Auto', 'Double', 'Single')][string]$Style = 'Auto')
    Assert-AmonUI
    if ($Style -eq 'Auto') { $Style = $script:UI.BoxStyle }
    $g = $script:UI.Glyphs
    if ($Style -eq 'Single') {
        return @{ TL = $g.STL; TR = $g.STR; BL = $g.SBL; BR = $g.SBR; H = $g.SH; V = $g.SV; LT = $g.SLT; RT = $g.SRT; VL = $g.SLT; VR = $g.SRT; IH = $g.SH; IX = $g.SX; IV = $g.SV }
    }
    return @{ TL = $g.TL; TR = $g.TR; BL = $g.BL; BR = $g.BR; H = $g.H; V = $g.V; LT = $g.LT; RT = $g.RT; VL = $g.VL; VR = $g.VR; IH = $g.SH; IX = $g.SX; IV = $g.SV }
}

function Format-AmonTopBorder {
    param([string]$Title, [int]$Width, [hashtable]$Frame, [string]$FrameToken = 'frame', [string]$TitleToken = 'title', [switch]$Center, [string]$RightLabel, [string]$RightToken = 'secondary', [switch]$Plain)
    $d = Get-AmonGlyph 'Diamond'
    if (-not $Title) { return Format-AmonColor ($Frame.TL + ($Frame.H * ($Width - 2)) + $Frame.TR) $FrameToken }
    $maxTitle = [Math]::Max(4, $Width - 14 - $(if ($RightLabel) { $RightLabel.Length + 4 } else { 0 }))
    $t = Format-AmonText -Text $Title -Width $maxTitle -NoPad
    if ($Plain) {
        $titleSeg = ' ' + (Format-AmonColor $t $TitleToken -Bold) + ' '
        $titleLen = $t.Length + 2
    } else {
        $titleSeg = ' ' + (Format-AmonColor $d 'accent') + ' ' + (Format-AmonColor $t $TitleToken -Bold) + ' ' + (Format-AmonColor $d 'accent') + ' '
        $titleLen = $t.Length + 2 * $d.Length + 4
    }
    $rightSeg = ''; $rightLen = 0
    if ($RightLabel) {
        $rightSeg = ' ' + (Format-AmonColor $RightLabel $RightToken -Bold) + ' '
        $rightLen = $RightLabel.Length + 2
    }
    $fill = $Width - 2 - $titleLen - $rightLen
    if ($Center -and -not $RightLabel) {
        $left = [int][Math]::Floor($fill / 2); $right = $fill - $left
    } else {
        $left = 2; $right = $fill - 2
        if ($RightLabel) { $right = [Math]::Max(0, $fill - 4); $left = 2 }
    }
    $line = (Format-AmonColor ($Frame.TL + ($Frame.H * $left)) $FrameToken) + $titleSeg + (Format-AmonColor ($Frame.H * $right) $FrameToken)
    if ($RightLabel) { $line += $rightSeg + (Format-AmonColor ($Frame.H * ($fill - $left - $right)) $FrameToken) }
    return $line + (Format-AmonColor $Frame.TR $FrameToken)
}

function Format-AmonBox {
    <#
    .SYNOPSIS
        Caja decorativa. Una línea '---' dibuja un separador interior.
    #>
    param(
        [string]$Title,
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines = @(),
        [int]$Width = 0,
        [ValidateSet('Auto', 'Double', 'Single')][string]$Style = 'Auto',
        [string]$FrameToken = 'frame',
        [string]$TitleToken = 'title',
        [string]$RightLabel,
        [string]$RightToken = 'secondary',
        [switch]$CenterTitle,
        [switch]$PlainTitle
    )
    $w = if ($Width -gt 0) { $Width } else { Get-AmonPanelWidth }
    $f = Get-AmonFrame -Style $Style
    $inner = $w - 4
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add((Format-AmonTopBorder -Title (ConvertTo-AmonSafeText $Title) -Width $w -Frame $f -FrameToken $FrameToken -TitleToken $TitleToken -Center:$CenterTitle -RightLabel (ConvertTo-AmonSafeText $RightLabel) -RightToken $RightToken -Plain:$PlainTitle))
    $v = Format-AmonColor $f.V $FrameToken
    foreach ($line in $Lines) {
        if ($line -eq '---') {
            $out.Add((Format-AmonColor ($f.VL + ($f.IH * ($w - 2)) + $f.VR) $FrameToken))
            continue
        }
        $out.Add($v + ' ' + (Format-AmonFitLine -Text (ConvertTo-AmonTerminalLine $line) -Width $inner) + ' ' + $v)
    }
    $out.Add((Format-AmonColor ($f.BL + ($f.H * ($w - 2)) + $f.BR) $FrameToken))
    return $out.ToArray()
}

function Format-AmonArtLine {
    # Colorea una línea del banner: bloques con degradado diagonal y sombras en tono oscuro.
    param([string]$Line, [int]$Row, [int]$Rows)
    Assert-AmonUI
    if ($script:UI.ColorMode -eq 'None') { return $Line }
    $sb = New-Object System.Text.StringBuilder
    $len = $Line.Length
    $block = (Get-AmonGlyph 'BarFull')
    $ascii = ($script:UI.GlyphMode -eq 'Ascii')
    $prevCode = $null
    for ($x = 0; $x -lt $len; $x++) {
        $ch = $Line[$x]
        if ($ch -eq ' ') { $code = '' }
        elseif ($ascii -or [string]$ch -eq $block) {
            if ($script:UI.GradientBanner -and $script:UI.ColorMode -eq 'TrueColor') {
                $t = ($x + $Row * 3) / [double]([Math]::Max(1, $len + $Rows * 3))
                $code = Get-AmonRgbCode (Get-AmonGradientColor -Stops $script:UI.Gradient -T $t)
            } else { $code = (Get-AmonColorCode 'title').Open }
        } else { $code = (Get-AmonColorCode 'shadow').Open }
        if ($code -ne $prevCode) {
            if ($code) { [void]$sb.Append($code) } elseif ($prevCode) { [void]$sb.Append("$($script:Esc)[39m") }
            $prevCode = $code
        }
        [void]$sb.Append($ch)
    }
    if ($prevCode) { [void]$sb.Append("$($script:Esc)[39m") }
    return $sb.ToString()
}

function Format-AmonGradientText {
    # Colorea cada carácter visible a lo largo del degradado del tema.
    param([Parameter(Mandatory = $true)][string]$Text)
    Assert-AmonUI
    if ($script:UI.ColorMode -ne 'TrueColor' -or -not $script:UI.GradientBanner) { return Format-AmonColor $Text 'title' -Bold }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("$($script:Esc)[1m")
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -ne ' ') { [void]$sb.Append((Get-AmonRgbCode (Get-AmonGradientColor -Stops $script:UI.Gradient -T ($i / [double][Math]::Max(1, $Text.Length - 1))))) }
        [void]$sb.Append($Text[$i])
    }
    [void]$sb.Append("$($script:Esc)[39m$($script:Esc)[22m")
    return $sb.ToString()
}

function Get-AmonArtRows {
    param([switch]$Ascii)
    $set = if ($Ascii) { $script:AsciiLetters } else { $script:ArtLetters }
    $rows = $set['A'].Count
    $result = @()
    for ($r = 0; $r -lt $rows; $r++) {
        $line = ''
        foreach ($ch in 'AMON SS'.ToCharArray()) { $line += $set[[string]$ch][$r] }
        $result += $line
    }
    return $result
}

function Get-AmonOSLabel {
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $build = [int]$cv.CurrentBuildNumber
        $name = 'WINDOWS'
        if ($build -ge 22000) { $name = 'WINDOWS 11' } elseif ($build -ge 10240) { $name = 'WINDOWS 10' }
        $ed = switch ([string]$cv.EditionID) {
            'Professional' { 'PRO' } 'Core' { 'HOME' } 'Enterprise' { 'ENTERPRISE' } 'Education' { 'EDUCATION' }
            default { ([string]$cv.EditionID).ToUpperInvariant() }
        }
        return ("$name $ed  BUILD $build").Trim()
    } catch { return 'WINDOWS' }
}

function Format-AmonBanner {
    param(
        [string]$Version = '0.0.0',
        [string]$BuildDate = '',
        [string]$Status = 'READY',
        [string]$System = 'WINDOWS',
        [string]$Mode = 'LOCAL FORENSIC',
        [string]$Privilege = '',
        [string]$PrivilegeToken = 'primary'
    )
    Assert-AmonUI
    $w = Get-AmonPanelWidth
    $f = Get-AmonFrame -Style 'Double'
    $inner = $w - 4
    $v = Format-AmonColor $f.V 'frame'
    $lines = [System.Collections.Generic.List[string]]::new()
    $wrap = { param($content) $lines.Add($v + ' ' + (Format-AmonFitLine -Text $content -Width $inner) + ' ' + $v) }
    $center = {
        param($plainLength, $colored)
        $left = [int][Math]::Floor(($inner - $plainLength) / 2)
        if ($left -lt 0) { $left = 0 }
        (' ' * $left) + $colored
    }

    $lines.Add((Format-AmonColor ($f.TL + ($f.H * ($w - 2)) + $f.TR) 'frame'))
    & $wrap ''
    $isAscii = ($script:UI.GlyphMode -eq 'Ascii')
    $art = Get-AmonArtRows -Ascii:$isAscii
    $star = Get-AmonGlyph 'Star'
    if ($art[0].Length -le ($inner - 2)) {
        for ($r = 0; $r -lt $art.Count; $r++) {
            & $wrap (& $center $art[$r].Length (Format-AmonArtLine -Line $art[$r] -Row $r -Rows $art.Count))
        }
    } else {
        $compact = 'A M O N   S S'
        $title = (Format-AmonColor $star 'accent') + '  ' + (Format-AmonGradientText -Text $compact) + '  ' + (Format-AmonColor $star 'accent')
        & $wrap (& $center ($compact.Length + 4 + 2 * $star.Length) $title)
    }
    & $wrap ''
    $sub = 'ADVANCED MINECRAFT FORENSIC SUITE'
    $subLine = (Format-AmonColor $star 'accent') + '  ' + (Format-AmonColor $sub 'secondary' -Bold) + '  ' + (Format-AmonColor $star 'accent')
    & $wrap (& $center ($sub.Length + 4 + 2 * $star.Length) $subLine)
    & $wrap ''
    $lines.Add((Format-AmonColor ($f.LT + ($f.H * ($w - 2)) + $f.RT) 'frame'))

    $dia = Get-AmonGlyph 'Diamond'
    $verText = "v$Version"; if ($BuildDate) { $verText += "  $BuildDate" }
    $items = @(
        @('STATUS', $Status, 'success'),
        @('VERSION', $verText, 'primary'),
        @('SYSTEM', $System, 'primary'),
        @('THEME', $script:UI.ThemeName.ToUpperInvariant(), 'accent'),
        @('MODE', $Mode, 'primary')
    )
    if ($Privilege) { $items += , @('PRIVILEGE', $Privilege, $PrivilegeToken) }
    $cell = {
        param($item, $width)
        $label = $item[0].PadRight(9)
        $valWidth = [Math]::Max(4, $width - $label.Length - $dia.Length - 4)
        (Format-AmonColor $dia 'accent') + ' ' + (Format-AmonColor $label 'secondary') + ' : ' + (Format-AmonColor (Format-AmonText -Text $item[1] -Width $valWidth -NoPad) $item[2] -Bold)
    }
    if ($inner -ge 74) {
        $colW = [int][Math]::Floor($inner / 2)
        for ($i = 0; $i -lt $items.Count; $i += 2) {
            $left = Add-AmonPadding (& $cell $items[$i] ($colW - 1)) $colW
            $right = ''
            if (($i + 1) -lt $items.Count) { $right = & $cell $items[$i + 1] ($inner - $colW) }
            & $wrap ($left + $right)
        }
    } else {
        foreach ($it in $items) { & $wrap (& $cell $it $inner) }
    }
    $lines.Add((Format-AmonColor ($f.BL + ($f.H * ($w - 2)) + $f.BR) 'frame'))
    return $lines.ToArray()
}

function Format-AmonMenu {
    param(
        [string]$Title = 'MAIN MENU',
        [Parameter(Mandatory = $true)][object[]]$Items,
        [int]$Width = 0
    )
    Assert-AmonUI
    $w = if ($Width -gt 0) { $Width } else { Get-AmonPanelWidth }
    $inner = $w - 4
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('')
    $labelWidth = 0
    foreach ($it in $Items) { if ($it.Label -and $it.Label.Length -gt $labelWidth) { $labelWidth = $it.Label.Length } }
    foreach ($it in $Items) {
        if ($it.Separator) { $lines.Add(''); continue }
        $glyph = if ($it.Hollow) { Get-AmonGlyph 'DiamondHollow' } else { Get-AmonGlyph 'Diamond' }
        $key = Format-AmonColor ('[' + $it.Key + ']') 'title' -Bold
        $text = ' ' + $key + ' ' + (Format-AmonColor $glyph 'accent') + ' ' + (Format-AmonColor $it.Label.PadRight($labelWidth) 'primary' -Bold)
        $used = 1 + $it.Key.Length + 2 + 1 + $glyph.Length + 1 + $labelWidth
        if ($it.Description -and ($inner - $used) -ge 18) {
            $text += '   ' + (Format-AmonColor (Format-AmonText -Text $it.Description -Width ($inner - $used - 3) -NoPad) 'muted')
        }
        $lines.Add($text)
    }
    $lines.Add('')
    return Format-AmonBox -Title $Title -Lines $lines.ToArray() -Width $w -Style 'Double' -CenterTitle
}

function Get-AmonCellValue {
    param($Row, $Column)
    $p = $Column.Property
    if ($p -is [scriptblock]) { $val = & $p $Row }
    elseif ($Row -is [System.Collections.IDictionary]) { $val = $Row[$p] }
    else { $val = $Row.$p }
    if ($val -is [datetime]) { return Format-AmonLocalTime $val }
    if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) { return (@($val) -join ', ') }
    return [string]$val
}

function Format-AmonTable {
    <#
    .SYNOPSIS
        Tabla con marco doble. Columnas: @{ Header; Property (nombre o scriptblock);
        Width; MinWidth; IsPath; Align; Token (nombre o scriptblock que recibe la fila) }.
    #>
    param(
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter(Mandatory = $true)][object[]]$Columns,
        [string]$Title,
        [int]$MaxRows = 0,
        [int]$Width = 0,
        [string]$EmptyText = 'Sin resultados dentro del alcance analizado.'
    )
    Assert-AmonUI
    $w = if ($Width -gt 0) { $Width } else { Get-AmonPanelWidth }
    $f = Get-AmonFrame -Style 'Double'
    $n = $Columns.Count
    $avail = $w - 4 - ($n - 1) * 3
    $rowsAll = @($Rows)
    $shown = $rowsAll
    if ($MaxRows -gt 0 -and $rowsAll.Count -gt $MaxRows) { $shown = $rowsAll[0..($MaxRows - 1)] }

    # Valores ya convertidos a texto seguro.
    $cells = @()
    foreach ($r in $shown) {
        $vals = @()
        foreach ($c in $Columns) { $vals += , (ConvertTo-AmonSafeText (Get-AmonCellValue $r $c)) }
        $cells += , $vals
    }

    $widths = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) {
        $c = $Columns[$i]
        if ($c.Width) { $widths[$i] = [int]$c.Width; continue }
        $m = ([string]$c.Header).Length
        foreach ($vals in $cells) { if ($vals[$i].Length -gt $m) { $m = $vals[$i].Length } }
        $widths[$i] = [Math]::Min($m, 80)
    }
    $total = ($widths | Measure-Object -Sum).Sum
    # Reducir: primero rutas, luego la columna más ancha, hasta el mínimo de cada una.
    $guard = 0
    while ($total -gt $avail -and $guard -lt 2000) {
        $guard++
        $idx = -1; $best = -1
        for ($i = 0; $i -lt $n; $i++) {
            $min = if ($Columns[$i].MinWidth) { [int]$Columns[$i].MinWidth } else { [Math]::Min(6, ([string]$Columns[$i].Header).Length + 1) }
            if ($widths[$i] -le $min) { continue }
            $score = $widths[$i] + $(if ($Columns[$i].IsPath) { 1000 } else { 0 })
            if ($score -gt $best) { $best = $score; $idx = $i }
        }
        if ($idx -lt 0) { break }
        $widths[$idx]--; $total--
    }
    if ($total -lt $avail) {
        # Repartir el espacio sobrante en la columna de ruta (o la última).
        $grow = $n - 1
        for ($i = 0; $i -lt $n; $i++) { if ($Columns[$i].IsPath) { $grow = $i; break } }
        $widths[$grow] += ($avail - $total)
    } elseif ($total -gt $avail) {
        $widths[$n - 1] = [Math]::Max(1, $widths[$n - 1] - ($total - $avail))
    }

    $v = Format-AmonColor $f.V 'frame'
    $sep = ' ' + (Format-AmonColor $f.IV 'frameDim') + ' '
    $out = [System.Collections.Generic.List[string]]::new()
    $right = ''
    if ($rowsAll.Count) { $right = "$($rowsAll.Count) filas" }
    $out.Add((Format-AmonTopBorder -Title $Title -Width $w -Frame $f -RightLabel $right))
    $hdr = @()
    for ($i = 0; $i -lt $n; $i++) { $hdr += Format-AmonColor (Format-AmonText -Text $Columns[$i].Header -Width $widths[$i]) 'title' -Bold }
    $out.Add($v + ' ' + ($hdr -join $sep) + ' ' + $v)
    $segs = @(); for ($i = 0; $i -lt $n; $i++) { $segs += ($f.IH * $widths[$i]) }
    $out.Add((Format-AmonColor ($f.VL + $f.IH + ($segs -join ($f.IH + $f.IX + $f.IH)) + $f.IH + $f.VR) 'frame'))
    if (-not $cells.Count) {
        $out.Add($v + ' ' + (Format-AmonColor (Format-AmonText -Text $EmptyText -Width ($w - 4)) 'muted') + ' ' + $v)
    }
    $ri = 0
    foreach ($vals in $cells) {
        $row = $shown[$ri]; $ri++
        $parts = @()
        for ($i = 0; $i -lt $n; $i++) {
            $c = $Columns[$i]
            $txt = if ($c.IsPath) { (Format-AmonPath -Path $vals[$i] -Width $widths[$i]).PadRight($widths[$i]) } else { Format-AmonText -Text $vals[$i] -Width $widths[$i] -Align $(if ($c.Align) { $c.Align } else { 'Left' }) }
            $token = 'primary'
            if ($c.Token -is [scriptblock]) { $tk = & $c.Token $row; if ($tk) { $token = $tk } }
            elseif ($c.Token) { $token = $c.Token }
            elseif ($i -gt 0) { $token = 'secondary' }
            $parts += Format-AmonColor $txt $token
        }
        $out.Add($v + ' ' + ($parts -join $sep) + ' ' + $v)
    }
    if ($rowsAll.Count -gt $shown.Count) {
        $more = "$($rowsAll.Count - $shown.Count) filas más en el reporte exportado."
        $out.Add($v + ' ' + (Format-AmonColor (Format-AmonText -Text ((Get-AmonGlyph 'Arrow') + ' ' + $more) -Width ($w - 4)) 'muted') + ' ' + $v)
    }
    $out.Add((Format-AmonColor ($f.BL + ($f.H * ($w - 2)) + $f.BR) 'frame'))
    return $out.ToArray()
}

function Format-AmonProgressBar {
    param([double]$Percent, [int]$BarWidth = 20, [switch]$Colored)
    Assert-AmonUI
    $pct = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $filled = [int][Math]::Round($pct / 100.0 * $BarWidth)
    $full = Get-AmonGlyph 'BarFull'; $empty = Get-AmonGlyph 'BarEmpty'
    if (-not $Colored -or $script:UI.ColorMode -eq 'None') {
        return ($full * $filled) + ($empty * ($BarWidth - $filled))
    }
    $sb = New-Object System.Text.StringBuilder
    if ($script:UI.ColorMode -eq 'TrueColor') {
        for ($i = 0; $i -lt $filled; $i++) {
            [void]$sb.Append((Get-AmonRgbCode (Get-AmonGradientColor -Stops $script:UI.Gradient -T ($i / [double][Math]::Max(1, $BarWidth - 1)))))
            [void]$sb.Append($full)
        }
    } else {
        [void]$sb.Append((Get-AmonColorCode 'accent').Open).Append($full * $filled)
    }
    [void]$sb.Append((Get-AmonColorCode 'frameDim').Open).Append($empty * ($BarWidth - $filled)).Append("$($script:Esc)[39m")
    return $sb.ToString()
}

function Format-AmonFinding {
    <#
    .SYNOPSIS
        Tarjeta de hallazgo con estado, confianza, firma, ruta, hash, fecha y justificación.
    #>
    param([Parameter(Mandatory = $true)]$Finding, [int]$Width = 0)
    Assert-AmonUI
    $w = if ($Width -gt 0) { $Width } else { Get-AmonPanelWidth }
    $status = [string]$Finding.Status
    $style = $script:StatusStyle[$status]; if (-not $style) { $style = $script:StatusStyle['INFO'] }
    $glyph = Get-AmonGlyph $style.Glyph
    $title = "$glyph $status"
    if ($Finding.Title) { $title += "  $($Finding.Title)" }
    $conf = $script:ConfidenceEs[[string]$Finding.Confidence]
    $right = ''; if ($conf) { $right = "CONFIANZA $conf" }
    $inner = $w - 4
    $labelW = 13
    $valW = $inner - $labelW
    $lines = [System.Collections.Generic.List[string]]::new()
    $add = {
        param($label, $value, $token, [switch]$IsPath, [switch]$Wrap)
        if ($null -eq $value -or ([string]$value) -eq '') { return }
        $lab = Format-AmonColor $label.PadRight($labelW) 'muted'
        if ($IsPath) { $lines.Add($lab + (Format-AmonColor (Format-AmonPath -Path $value -Width $valW) $token)); return }
        if ($Wrap) {
            $first = $true
            foreach ($wl in (Split-AmonWrap -Text $value -Width $valW)) {
                if ($first) { $lines.Add($lab + (Format-AmonColor $wl $token)); $first = $false }
                else { $lines.Add((' ' * $labelW) + (Format-AmonColor $wl $token)) }
            }
            return
        }
        $lines.Add($lab + (Format-AmonColor (Format-AmonText -Text $value -Width $valW -NoPad) $token))
    }
    & $add 'Cliente' $Finding.Client 'primary'
    & $add 'Indicador' $Finding.Indicator 'accent' -Wrap
    & $add 'Ruta' $Finding.Path 'primary' -IsPath
    if ($Finding.Sha256) {
        $h = [string]$Finding.Sha256
        if ($h.Length -gt $valW) { $h = $h.Substring(0, [Math]::Max(8, $valW - 1 - 8)) + (Get-AmonGlyph 'Ellipsis') + $h.Substring($h.Length - 8) }
        & $add 'SHA-256' $h 'secondary'
    }
    if ($Finding.TimestampUtc) { & $add 'Fecha' (Format-AmonLocalTime $Finding.TimestampUtc) 'secondary' }
    $src = $Finding.Source; if (-not $src) { $src = $Finding.Module }
    & $add 'Fuente' $src 'secondary' -Wrap
    & $add 'Motivo' $Finding.Justification 'primary' -Wrap
    if ($Finding.PSObject.Properties['Evidence'] -and $Finding.Evidence) {
        $first = $true
        foreach ($e in @($Finding.Evidence)) {
            $txt = if ($e -is [string]) { $e } elseif ($e.Description) { [string]$e.Description } else { [string]$e }
            $wrapLines = @(Split-AmonWrap -Text $txt -Width ($valW - 2))
            for ($k = 0; $k -lt $wrapLines.Count; $k++) {
                $prefix = if ($k -eq 0) { (Get-AmonGlyph 'Arrow') + ' ' } else { '  ' }
                $label = if ($first) { 'Evidencias'.PadRight($labelW) } else { ' ' * $labelW }
                $lines.Add((Format-AmonColor $label 'muted') + (Format-AmonColor ($prefix + $wrapLines[$k]) 'secondary'))
                $first = $false
            }
        }
    }
    if ($Finding.FalsePositives) { & $add 'Posibles FP' (@($Finding.FalsePositives) -join '; ') 'muted' -Wrap }
    return Format-AmonBox -Title $title -Lines $lines.ToArray() -Width $w -Style 'Single' -FrameToken $style.Token -TitleToken $style.Token -RightLabel $right -RightToken $style.Token -PlainTitle
}

#endregion

#region Escritura en consola (Write-* / Show-*)

function Write-AmonSegments {
    # Traduce nuestras secuencias SGR a Write-Host para consolas sin VT.
    param([string]$Text)
    $pattern = "\x1B\[([0-9;]*)m"
    $pos = 0
    $fg = $null
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        if ($m.Index -gt $pos) {
            $chunk = $Text.Substring($pos, $m.Index - $pos)
            if ($fg) { Write-Host $chunk -NoNewline -ForegroundColor $fg } else { Write-Host $chunk -NoNewline }
        }
        $codes = $m.Groups[1].Value -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }
        $codes = @($codes)
        if ($codes.Count -ge 5 -and $codes[0] -eq 38 -and $codes[1] -eq 2) {
            $fg = $script:SgrToConsole[(Get-AmonNearestConsoleSgr $codes[2] $codes[3] $codes[4])]
        } else {
            foreach ($c in $codes) {
                if ($c -eq 0 -or $c -eq 39) { $fg = $null }
                elseif ($script:SgrToConsole.ContainsKey($c)) { $fg = $script:SgrToConsole[$c] }
            }
        }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Text.Length) {
        $chunk = $Text.Substring($pos)
        if ($fg) { Write-Host $chunk -NoNewline -ForegroundColor $fg } else { Write-Host $chunk -NoNewline }
    }
}

function Write-AmonLines {
    param([AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines = @(), [switch]$NoNewline)
    Assert-AmonUI
    Complete-AmonProgress
    $text = ($Lines -join [Environment]::NewLine)
    if (-not $NoNewline) { $text += [Environment]::NewLine }
    if ($script:UI.ColorMode -eq 'None' -or ($script:UI.VT -and -not $script:UI.Redirected)) {
        [Console]::Out.Write($text)
    } else {
        Write-AmonSegments $text
    }
}

function Clear-AmonScreen {
    Assert-AmonUI
    if ($script:UI.Redirected) { return }
    try {
        if ($script:UI.BlackBackground) {
            if ($null -eq $script:UI.PrevBackground) {
                $script:UI.PrevBackground = $Host.UI.RawUI.BackgroundColor
                $script:UI.PrevForeground = $Host.UI.RawUI.ForegroundColor
            }
            $Host.UI.RawUI.BackgroundColor = 'Black'
            $Host.UI.RawUI.ForegroundColor = 'Gray'
        }
        [Console]::Clear()
    } catch { }
}

function Show-AmonBanner {
    param(
        [string]$Version = '0.0.0', [string]$BuildDate = '', [string]$Status = 'READY',
        [string]$System = (Get-AmonOSLabel), [string]$Mode = 'LOCAL FORENSIC',
        [string]$Privilege = '', [string]$PrivilegeToken = 'primary', [switch]$Clear
    )
    Assert-AmonUI
    if ($Clear) { Clear-AmonScreen }
    $lines = Format-AmonBanner -Version $Version -BuildDate $BuildDate -Status $Status -System $System -Mode $Mode -Privilege $Privilege -PrivilegeToken $PrivilegeToken
    if ($script:UI.Animations) {
        # Una sola entrada orquestada: revelado de arriba abajo en ~150 ms.
        foreach ($l in $lines) { Write-AmonLines @($l); Start-Sleep -Milliseconds 9 }
    } else {
        Write-AmonLines $lines
    }
}

function Show-AmonMenu {
    param([string]$Title = 'MAIN MENU', [Parameter(Mandatory = $true)][object[]]$Items)
    Write-AmonLines (Format-AmonMenu -Title $Title -Items $Items)
}

function Write-AmonBox {
    param(
        [string]$Title, [AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines = @(),
        [ValidateSet('Auto', 'Double', 'Single')][string]$Style = 'Auto',
        [string]$FrameToken = 'frame', [string]$TitleToken = 'title', [string]$RightLabel
    )
    Write-AmonLines (Format-AmonBox -Title $Title -Lines $Lines -Style $Style -FrameToken $FrameToken -TitleToken $TitleToken -RightLabel $RightLabel)
}

function Write-AmonTable {
    param(
        [AllowEmptyCollection()][object[]]$Rows = @(), [Parameter(Mandatory = $true)][object[]]$Columns,
        [string]$Title, [int]$MaxRows = 0, [string]$EmptyText = 'Sin resultados dentro del alcance analizado.'
    )
    Write-AmonLines (Format-AmonTable -Rows $Rows -Columns $Columns -Title $Title -MaxRows $MaxRows -EmptyText $EmptyText)
}

function Write-AmonFinding {
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Finding)
    process { Write-AmonLines (Format-AmonFinding -Finding $Finding) }
}

function Write-AmonStatus {
    <#
    .SYNOPSIS
        Línea de estado: "● Etiqueta        VALOR   detalle".
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Value = '',
        [ValidateSet('Ok', 'Warn', 'Error', 'Info', 'Busy', 'Skip')][string]$State = 'Info',
        [string]$Detail = ''
    )
    Assert-AmonUI
    $map = @{
        Ok = @('Dot', 'success'); Warn = @('DiamondHollow', 'warning'); Error = @('Dot', 'finding')
        Info = @('Arrow', 'secondary'); Busy = @('DiamondDot', 'accent'); Skip = @('DiamondHollow', 'muted')
    }
    $g = $map[$State]
    $w = Get-AmonPanelWidth
    $labelW = [Math]::Min(30, [Math]::Max(16, [int]($w * 0.32)))
    $line = '  ' + (Format-AmonColor (Get-AmonGlyph $g[0]) $g[1]) + ' ' + (Format-AmonColor (Format-AmonText -Text $Label -Width $labelW) 'primary')
    if ($Value) { $line += ' ' + (Format-AmonColor (ConvertTo-AmonSafeText $Value) $g[1] -Bold) }
    if ($Detail) {
        $used = 4 + $labelW + 1 + $Value.Length + 2
        $line += '  ' + (Format-AmonColor (Format-AmonText -Text $Detail -Width ([Math]::Max(8, $w - $used)) -NoPad) 'muted')
    }
    Write-AmonLines @((Limit-AmonAnsiText -Text $line -Width $w))
}

function Write-AmonWarning {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Label = 'ADVERTENCIA')
    Assert-AmonUI
    $w = Get-AmonPanelWidth
    $prefix = '  ' + (Get-AmonGlyph 'DiamondHollow') + ' ' + $Label + '  '
    $wrapped = @(Split-AmonWrap -Text $Message -Width ([Math]::Max(20, $w - $prefix.Length)))
    $out = @()
    for ($i = 0; $i -lt $wrapped.Count; $i++) {
        if ($i -eq 0) {
            $out += '  ' + (Format-AmonColor (Get-AmonGlyph 'DiamondHollow') 'warning') + ' ' + (Format-AmonColor $Label 'warning' -Bold) + '  ' + (Format-AmonColor $wrapped[$i] 'primary')
        } else {
            $out += (' ' * $prefix.Length) + (Format-AmonColor $wrapped[$i] 'primary')
        }
    }
    Write-AmonLines $out
}

function Write-AmonSection {
    param([Parameter(Mandatory = $true)][string]$Title, [string]$Subtitle)
    Write-AmonLines (Format-AmonSection -Title $Title -Subtitle $Subtitle)
}

function Format-AmonSection {
    param([Parameter(Mandatory = $true)][string]$Title, [string]$Subtitle)
    Assert-AmonUI
    $w = Get-AmonPanelWidth
    $plain = '  ' + (Get-AmonGlyph 'DiamondDot') + ' ' + $Title + ' '
    $rule = (Get-AmonGlyph 'SH') * [Math]::Max(0, $w - $plain.Length)
    # Ojo: en PowerShell la coma de array tiene más precedencia que '+'; se construye por partes.
    $head = '  ' + (Format-AmonColor (Get-AmonGlyph 'DiamondDot') 'accent') + ' ' + (Format-AmonColor $Title 'title' -Bold) + ' ' + (Format-AmonColor $rule 'frameDim')
    $lines = @('', $head)
    if ($Subtitle) {
        foreach ($s in @(Split-AmonWrap -Text $Subtitle -Width ($w - 4))) { $lines += '    ' + (Format-AmonColor $s 'muted') }
    }
    return $lines
}

function Write-AmonFooter {
    param([string]$Text = '', [string]$Version = '')
    Assert-AmonUI
    $w = Get-AmonPanelWidth
    $h = Get-AmonGlyph 'H'; $s = Get-AmonGlyph 'StarHollow'
    $brand = " $s AMON SS"; if ($Version) { $brand += " v$Version" }; $brand += " $s "
    $t = ''; if ($Text) { $t = ' ' + (Format-AmonText -Text $Text -Width ([Math]::Max(0, $w - $brand.Length - 10)) -NoPad) + ' ' }
    $rest = [Math]::Max(0, $w - 3 - $brand.Length - $t.Length)
    Write-AmonLines @((Format-AmonColor ($h * 3) 'frameDim') + (Format-AmonColor $brand 'accent') + (Format-AmonColor $t 'muted') + (Format-AmonColor ($h * $rest) 'frameDim'))
}

function Write-AmonProgress {
    <#
    .SYNOPSIS
        Barra de progreso de dos líneas que se redibuja en el sitio (si hay VT).
        Se limita a ~14 refrescos por segundo para no frenar el escaneo.
    #>
    param(
        [double]$Percent, [string]$Activity = '', [string]$Detail = '', [int]$Count = -1, [switch]$Force
    )
    Assert-AmonUI
    $now = [Environment]::TickCount
    $pct = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    if (-not $Force -and $script:UI.ProgressActive -and [Math]::Abs($now - $script:UI.LastProgressTick) -lt 70 -and $pct -lt 100) { return }
    $script:UI.LastProgressTick = $now
    $w = Get-AmonPanelWidth
    $barW = [Math]::Max(10, [Math]::Min(36, $w - 40))
    $pctText = ('{0,3:0}%' -f $pct)
    $line1 = '  ' + (Format-AmonColor (Get-AmonGlyph 'DiamondDot') 'accent') + ' ' + (Format-AmonColor '[' 'frame') + (Format-AmonProgressBar -Percent $pct -BarWidth $barW -Colored) + (Format-AmonColor ']' 'frame') + ' ' + (Format-AmonColor $pctText 'primary' -Bold) + '  ' + (Format-AmonColor (Format-AmonText -Text $Activity -Width ([Math]::Max(8, $w - $barW - 16)) -NoPad) 'title' -Bold)
    $info = ''
    if ($Count -ge 0) { $info = "$Count artefactos revisados" }
    if ($Detail) { if ($info) { $info += '  ' + (Get-AmonGlyph 'Arrow') + ' ' } ; $info += (ConvertTo-AmonSafeText $Detail) }
    $line2 = '    ' + (Format-AmonColor (Get-AmonGlyph 'Arrow') 'frame') + ' ' + (Format-AmonColor (Format-AmonText -Text $info -Width ($w - 8) -NoPad) 'muted')
    $line1 = Limit-AmonAnsiText -Text $line1 -Width ($w - 1)
    $line2 = Limit-AmonAnsiText -Text $line2 -Width ($w - 1)
    if ($script:UI.VT -and -not $script:UI.Redirected -and $script:UI.ColorMode -ne 'None') {
        $e = $script:Esc
        if ($script:UI.ProgressActive) { [Console]::Out.Write("`r$e[1A$e[2K" + $line1 + "`n$e[2K" + $line2) }
        else { [Console]::Out.Write($line1 + "`n" + $line2) }
        $script:UI.ProgressActive = $true
    } else {
        # Sin VT: una línea por cada 25 % para no inundar la salida.
        $bucket = [int][Math]::Floor($pct / 25)
        if ($Force -or $bucket -ne $script:UI.LastProgressBucket) {
            $script:UI.LastProgressBucket = $bucket
            if ($script:UI.ColorMode -eq 'None') { [Console]::Out.WriteLine((Remove-AmonAnsiInternal $line1)) }
            else { Write-AmonSegments ($line1 + [Environment]::NewLine) }
        }
    }
}

function Remove-AmonAnsiInternal { param([string]$Text) [regex]::Replace($Text, "\x1B\[[0-9;?]*[A-Za-z]", '') }

function Complete-AmonProgress {
    if (-not $script:UI) { return }
    if ($script:UI.ProgressActive) {
        [Console]::Out.Write([Environment]::NewLine)
        $script:UI.ProgressActive = $false
    }
    $script:UI.LastProgressBucket = -1
}

function Write-AmonCountUp {
    # Contador animado breve (≤250 ms) para cifras de resumen; sin animación imprime directo.
    param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][int]$Value, [string]$Token = 'primary', [string]$Suffix = '')
    Assert-AmonUI
    $prefix = '  ' + (Format-AmonColor (Get-AmonGlyph 'Diamond') 'accent') + ' ' + (Format-AmonColor $Label.PadRight(30) 'secondary') + ' '
    if ($script:UI.Animations -and $script:UI.VT -and $Value -gt 0) {
        $frames = 8
        for ($i = 1; $i -le $frames; $i++) {
            # Desaceleración (ease-out cúbico): rápido al inicio, aterriza suave.
            $t = 1 - [Math]::Pow(1 - ($i / [double]$frames), 3)
            $n = [int][Math]::Round($Value * $t)
            [Console]::Out.Write("`r" + $prefix + (Format-AmonColor ([string]$n) $Token -Bold) + (Format-AmonColor $Suffix 'muted'))
            Start-Sleep -Milliseconds 28
        }
        [Console]::Out.Write([Environment]::NewLine)
    } else {
        Write-AmonLines @($prefix + (Format-AmonColor ([string]$Value) $Token -Bold) + (Format-AmonColor $Suffix 'muted'))
    }
}

function Read-AmonInput {
    param([string]$Prompt = 'Selecciona una opción')
    Assert-AmonUI
    Complete-AmonProgress
    $text = '  ' + (Format-AmonColor (Get-AmonGlyph 'Arrow') 'accent') + ' ' + (Format-AmonColor $Prompt 'secondary') + (Format-AmonColor ' : ' 'frame')
    Write-AmonLines @($text) -NoNewline
    try {
        if ([Console]::IsInputRedirected) { $line = [Console]::In.ReadLine() } else { $line = Read-Host }
    } catch { $line = $null }
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Read-AmonConfirm {
    param([Parameter(Mandatory = $true)][string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { '[S/n]' } else { '[s/N]' }
    $ans = Read-AmonInput -Prompt "$Prompt $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return ($ans -match '^(s|si|sí|y|yes)$')
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-AmonUI', 'Get-AmonUIState', 'Get-AmonGlyph', 'Get-AmonPanelWidth', 'Get-AmonConsoleWidth', 'Get-AmonThemeNames',
    'Restore-AmonConsole', 'Clear-AmonScreen', 'Get-AmonOSLabel',
    'ConvertTo-AmonSafeText', 'Get-AmonVisibleLength', 'ConvertFrom-AmonHexColor', 'Get-AmonGradientColor',
    'Get-AmonColorCode', 'Format-AmonColor', 'Format-AmonText', 'Format-AmonPath', 'Limit-AmonAnsiText', 'Add-AmonPadding',
    'Split-AmonWrap', 'Format-AmonLocalTime',
    'Format-AmonBox', 'Format-AmonBanner', 'Format-AmonMenu', 'Format-AmonTable', 'Format-AmonProgressBar', 'Format-AmonFinding',
    'Write-AmonLines', 'Show-AmonBanner', 'Show-AmonMenu', 'Write-AmonBox', 'Write-AmonTable', 'Write-AmonStatus',
    'Write-AmonProgress', 'Complete-AmonProgress', 'Write-AmonFinding', 'Write-AmonWarning', 'Write-AmonFooter',
    'Write-AmonSection', 'Format-AmonSection', 'Write-AmonCountUp', 'Read-AmonInput', 'Read-AmonConfirm'
)
