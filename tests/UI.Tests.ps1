BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-Module (Join-Path (Get-AmonTestRoot) 'modules\UI.psm1') -Force -DisableNameChecking
}

Describe 'UI: medición de texto' -Tag 'Unit' {
    It 'ignora las secuencias ANSI al medir el ancho visible' {
        $e = [char]27
        Get-AmonVisibleLength -Text "$e[38;2;168;85;247mAMON$e[0m SS" | Should -Be 7
    }

    It 'trunca texto largo con elipsis respetando el ancho exacto' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 100 -NoAnimation
        $t = Format-AmonText -Text 'hello world' -Width 8
        $t.Length | Should -Be 8
        $t | Should -BeLike 'hello w*'
    }

    It 'acorta rutas largas por el medio conservando unidad y nombre de archivo' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 100 -NoAnimation
        $p = 'C:\Users\someone\AppData\Roaming\.minecraft\mods\subdir\very-long-mod-name-1.2.3.jar'
        $r = Format-AmonPath -Path $p -Width 48
        $r.Length | Should -BeLessOrEqual 48
        $r | Should -BeLike 'C:\*'
        $r | Should -BeLike '*very-long-mod-name-1.2.3.jar'
    }

    It 'no modifica rutas que ya caben' {
        Format-AmonPath -Path 'C:\a\b.jar' -Width 40 | Should -Be 'C:\a\b.jar'
    }
}

Describe 'UI: color' -Tag 'Unit' {
    It 'convierte hex a RGB' {
        $c = ConvertFrom-AmonHexColor -Hex '#A855F7'
        $c.R | Should -Be 168; $c.G | Should -Be 85; $c.B | Should -Be 247
    }

    It 'interpola un degradado entre paradas' {
        $stops = @('#000000', '#FF0000', '#FFFFFF')
        (Get-AmonGradientColor -Stops $stops -T 0).R | Should -Be 0
        (Get-AmonGradientColor -Stops $stops -T 0.5).R | Should -Be 255
        (Get-AmonGradientColor -Stops $stops -T 0.5).G | Should -Be 0
        (Get-AmonGradientColor -Stops $stops -T 1).G | Should -Be 255
    }
}

Describe 'UI: temas y glifos' -Tag 'Unit' {
    It 'Classic Terminal usa colores de consola' {
        $saved = $env:NO_COLOR
        try {
            $env:NO_COLOR = $null
            Initialize-AmonUI -Theme ClassicTerminal -GlyphMode Ascii -Width 90 -NoAnimation
            $s = Get-AmonUIState
            $s.ColorMode | Should -Be 'Console'
            $s.Glyphs.TL | Should -Be '+'
        } finally { $env:NO_COLOR = $saved }
    }

    It 'respeta la convención NO_COLOR' {
        $saved = $env:NO_COLOR
        try {
            $env:NO_COLOR = '1'
            Initialize-AmonUI -Theme FullPurple -GlyphMode Full -Width 90 -NoAnimation
            (Get-AmonUIState).ColorMode | Should -Be 'None'
        } finally { $env:NO_COLOR = $saved }
    }

    It 'Full Purple usa caracteres Unicode decorativos' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 90 -NoAnimation
        $s = Get-AmonUIState
        $s.Glyphs.TL | Should -Be ([string][char]0x2554)
        $s.Glyphs.Diamond | Should -Be ([string][char]0x25C6)
    }

    It 'el modo seguro sustituye glifos fuera de WGL4' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Safe -ColorMode None -Width 90 -NoAnimation
        (Get-AmonUIState).Glyphs.Star | Should -Not -Be ([string][char]0x2726)
    }
}

Describe 'UI: componentes renderizados' -Tag 'Unit' {
    BeforeEach {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 80 -NoAnimation
    }

    It 'una caja tiene todas sus líneas del mismo ancho aunque haya rutas largas' {
        $lines = Format-AmonBox -Title 'RESULTADO' -Lines @(
            'corto',
            ('C:\' + ('carpeta\' * 30) + 'archivo.jar')
        )
        $widths = $lines | ForEach-Object { Get-AmonVisibleLength $_ } | Select-Object -Unique
        @($widths).Count | Should -Be 1
        $widths | Should -BeLessOrEqual 80
    }

    It 'una tabla mantiene la alineación con valores largos' {
        $rows = @(
            [pscustomobject]@{ Name = 'javaw.exe'; Path = 'C:\Program Files\Java\jdk-21\bin\javaw.exe' },
            [pscustomobject]@{ Name = 'x'; Path = ('D:\' + ('x' * 200)) }
        )
        $lines = Format-AmonTable -Rows $rows -Columns @(
            @{ Header = 'NOMBRE'; Property = 'Name' },
            @{ Header = 'RUTA'; Property = 'Path'; IsPath = $true }
        ) -Title 'PROCESOS'
        $widths = $lines | ForEach-Object { Get-AmonVisibleLength $_ } | Select-Object -Unique
        @($widths).Count | Should -Be 1
        $widths | Should -BeLessOrEqual 80
    }

    It 'la barra de progreso refleja el porcentaje' {
        $bar = Format-AmonProgressBar -Percent 80 -BarWidth 20
        $bar | Should -Be (([string][char]0x2588 * 16) + ([string][char]0x2591 * 4))
    }

    It 'el banner contiene el nombre y el subtítulo y es rectangular' {
        $lines = Format-AmonBanner -Version '1.0.0' -BuildDate '2026-10-20'
        ($lines -join "`n") | Should -Match 'ADVANCED MINECRAFT FORENSIC SUITE'
        ($lines -join "`n") | Should -Match '1\.0\.0'
        @($lines | ForEach-Object { Get-AmonVisibleLength $_ } | Select-Object -Unique).Count | Should -Be 1
    }

    It 'en terminales estrechas el banner usa la versión compacta' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 50 -NoAnimation
        $lines = Format-AmonBanner -Version '1.0.0' -BuildDate '2026-10-20'
        ($lines -join "`n") | Should -Match 'A M O N'
        $lines | ForEach-Object { Get-AmonVisibleLength $_ | Should -BeLessOrEqual 50 }
    }

    It 'el menú muestra todas las opciones con su clave' {
        $lines = Format-AmonMenu -Title 'MAIN MENU' -Items @(
            @{ Key = '01'; Label = 'FULL FORENSIC SCAN' },
            @{ Key = '00'; Label = 'EXIT'; Hollow = $true }
        )
        ($lines -join "`n") | Should -Match '\[01\]'
        ($lines -join "`n") | Should -Match 'EXIT'
    }

    It 'un hallazgo muestra estado, ruta y hash' {
        $f = [pscustomobject]@{
            Status = 'DETECTED'; Title = 'Meteor Client'; Confidence = 'High'; Severity = 'High'
            Path = 'C:\x\mods\meteor.jar'; Sha256 = ('a' * 64); Indicator = 'meteordevelopment/meteorclient/'
            Source = 'Signatures'; Justification = 'Paquete Java del cliente'; FalsePositives = @('ninguno conocido')
            TimestampUtc = [datetime]'2026-10-19T10:00:00Z'; Client = 'Meteor Client'; Module = 'Signatures'
        }
        $text = (Format-AmonFinding -Finding $f) -join "`n"
        $text | Should -Match 'DETECTED'
        $text | Should -Match 'meteor\.jar'
        $text | Should -Match ('a' * 16)
    }

    It 'una evidencia de una sola línea se muestra completa (no como un carácter)' {
        $f = [pscustomobject]@{ Status = 'DETECTED'; Title = 'x'; Confidence = 'Low'; Evidence = @('latest.log: mod cargado') }
        ((Format-AmonFinding -Finding $f) -join "`n") | Should -Match 'latest\.log: mod cargado'
    }

    It 'un título de sección ocupa una sola línea (no se parte en fragmentos)' {
        $lines = @(Format-AmonSection -Title 'FULL FORENSIC SCAN')
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match 'FULL FORENSIC SCAN'
        Get-AmonVisibleLength $lines[1] | Should -BeLessOrEqual 80
    }

    It 'elimina secuencias de control de datos no confiables' {
        $e = [char]27
        ConvertTo-AmonSafeText "evil$e[2Jname.jar" | Should -Be 'evil[2Jname.jar'
    }

    It 'una caja conserva los colores pero no borra pantalla, mueve el cursor ni cambia el título' {
        Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode TrueColor -Width 80 -NoAnimation
        $e = [char]27; $bel = [char]7
        $lines = Format-AmonBox -Title "JAVA $e[2J" -Lines @("ok $e[38;2;1;2;3mcolor$e[0m", "x$e[2J$e[H$e]0;falso$bel y")
        $all = $lines -join "`n"
        $all | Should -Not -Match '\x1B\[2J'
        $all | Should -Not -Match '\x1B\[H'
        $all | Should -Not -Match '\x1B\]'
        $all | Should -Not -Match '\x07'
        $all | Should -Match '\x1B\[38;2;1;2;3m'
    }
}
