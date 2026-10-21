BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    $script:Start = Join-Path (Get-AmonTestRoot) 'Start-AmonSS.ps1'
    $script:Exe = (Get-Process -Id $PID).Path
}

Describe 'Punto de entrada: modo interactivo con entrada redirigida' -Tag 'Integration' {
    It 'sin consentimiento no analiza nada' {
        $ErrorActionPreference = 'Continue'
        $out = "n`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -NoAnimation 2>&1
        ($out -join "`n") | Should -Match 'Sin consentimiento'
        ($out -join "`n") | Should -Not -Match 'MAIN MENU'
    }

    It 'con consentimiento muestra el menú, sale limpiamente y no filtra objetos a la salida' {
        $ErrorActionPreference = 'Continue'
        $out = "s`nPrueba`n08`n00`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -NoAnimation 2>&1
        $text = $out -join "`n"
        $text | Should -Match 'MAIN MENU'
        $text | Should -Match 'RECENT FILES'
        $text | Should -Match 'Sesión cerrada'
        $text | Should -Not -Match '@\{'
    }
}

Describe 'Punto de entrada: menú principal' -Tag 'Integration' {
    It 'un Enter vacío en el menú principal no cierra la sesión' {
        $ErrorActionPreference = 'Continue'
        $out = "s`nPrueba`n`n08`n00`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -NoAnimation 2>&1
        ($out -join "`n") | Should -Match 'RECENT FILES'
    }

    It 'no construye código a partir de lo que escribe el usuario' {
        # Una ruta con comillas tipográficas (’) rompía [scriptblock]::Create y permitía inyectar código.
        (Get-Content -LiteralPath $script:Start -Raw) | Should -Not -Match '\[scriptblock\]::Create'
    }
}

Describe 'Punto de entrada: modo no interactivo' -Tag 'Integration' {
    It 'sin -Consent no analiza nada y termina con código 2' {
        # stderr de un ejecutable con 2>&1 se convierte en ErrorRecord: no debe detener la prueba.
        $ErrorActionPreference = 'Continue'
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan Minecraft 2>&1
        $LASTEXITCODE | Should -Be 2
        ($out -join ' ') | Should -Match 'Consent'
    }

    It '-VerifyManifest termina con 1 si un reporte fue alterado' {
        $ErrorActionPreference = 'Continue'
        $dir = Join-Path $TestDrive 'verify-out'
        $null = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan RecycleBin -Consent -Report 'txt' -OutputPath $dir -NoAnimation 2>&1
        $manifest = (Get-ChildItem $dir -Filter 'AMON-*.sha256' | Select-Object -First 1).FullName
        $null = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -VerifyManifest $manifest -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        Add-Content -LiteralPath ($manifest -replace '\.sha256$', '.txt') -Value 'alterado'
        $null = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -VerifyManifest $manifest -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 1
    }

    It '-Scan Temp ejecuta antes Minecraft y Firmas (de ahí salen sus indicadores)' {
        $ErrorActionPreference = 'Continue'
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan Temp -Consent -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        $text = $out -join "`n"
        $text | Should -Match 'Cheat Signature Scanner'
        $text | Should -Match 'Temp Indicator Sweep'
    }

    It 'rechaza formatos de reporte no válidos' {
        $ErrorActionPreference = 'Continue'
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan Minecraft -Consent -Report 'pdf' 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        ($out -join ' ') | Should -Match 'pdf'
    }

    It 'ejecuta un módulo, correlaciona y exporta reportes verificables (listas separadas por comas)' {
        $dir = Join-Path $TestDrive 'out'
        $null = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan RecycleBin -Consent -ConsentNote 'Prueba Pester' -Report 'json,txt' -OutputPath $dir -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        $json = Get-ChildItem $dir -Filter 'AMON-*.json' | Select-Object -First 1
        $json | Should -Not -BeNullOrEmpty
        $model = Get-Content $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        @($model.Modules | ForEach-Object Module) | Should -Contain 'RecycleBin'
        @($model.Modules | ForEach-Object Module) | Should -Contain 'Correlation'
        ($model.AuthorizedScope -join ' ') | Should -Match 'Prueba Pester'
        $manifest = Get-ChildItem $dir -Filter 'AMON-*.sha256' | Select-Object -First 1
        $verify = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -VerifyManifest $manifest.FullName -NoAnimation 2>&1
        ($verify -join ' ') | Should -Match 'ÍNTEGRO'
    }
}
