BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    $script:Start = Join-Path (Get-AmonTestRoot) 'Start-AmonSS.ps1'
    $script:Exe = (Get-Process -Id $PID).Path
}

Describe 'Punto de entrada: revisión automática (entrada redirigida)' -Tag 'Integration' {
    # Con la entrada redirigida cada "tecla" llega como una línea. -Modules acota el escaneo para
    # que la prueba sea rápida; -OutputPath evita escribir en la carpeta de reportes del usuario.
    It 'arranca sola: sin consentimiento, escanea, exporta el reporte y sale con una tecla' {
        $ErrorActionPreference = 'Continue'
        $dir = Join-Path $TestDrive 'auto'
        $out = "`nq`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Modules Recent -OutputPath $dir -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        $text = $out -join "`n"
        $text | Should -Not -Match 'CONSENTIMIENTO'
        $text | Should -Match 'DETECTION & CORRELATION'
        $text | Should -Not -Match '@\{'
        @(Get-ChildItem $dir -Filter 'AMON-*.html').Count | Should -Be 1
        @(Get-ChildItem $dir -Filter 'AMON-*.sha256').Count | Should -Be 1
    }

    It 'un Enter en el menú final no cierra; D muestra el detalle y Q sale' {
        $ErrorActionPreference = 'Continue'
        $out = "`n`nd`nq`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Modules Recent -OutputPath (Join-Path $TestDrive 'auto2') -NoAnimation 2>&1
        ($out -join "`n") | Should -Match 'RECENT FILES'
    }

    It 'el menú avanzado se maneja con una sola tecla por opción' {
        $ErrorActionPreference = 'Continue'
        $out = "`nm`n7`nq`nq`n" | & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Modules Recent -OutputPath (Join-Path $TestDrive 'auto3') -NoAnimation 2>&1
        $text = $out -join "`n"
        $text | Should -Match 'MÁS OPCIONES'
        $text | Should -Match 'USERASSIST'
    }
}

Describe 'Punto de entrada: seguridad del menú' -Tag 'Integration' {

    It 'no construye código a partir de lo que escribe el usuario' {
        # Una ruta con comillas tipográficas (’) rompía [scriptblock]::Create y permitía inyectar código.
        (Get-Content -LiteralPath $script:Start -Raw) | Should -Not -Match '\[scriptblock\]::Create'
    }
}

Describe 'Punto de entrada: modo no interactivo' -Tag 'Integration' {
    It 'no necesita -Consent: el consentimiento lo cubren los términos de la SS del servidor' {
        # stderr de un ejecutable con 2>&1 se convierte en ErrorRecord: no debe detener la prueba.
        $ErrorActionPreference = 'Continue'
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File $script:Start -Scan Recent -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join ' ') | Should -Match 'Recent Files'
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
