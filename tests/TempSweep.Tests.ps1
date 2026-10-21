BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule TempSweep
}

Describe 'Temp: rastros de herramientas y de indicadores' -Tag 'Unit' {
    It 'sin indicadores no busca nombres ajenos, pero sí la DLL de JNativeHook (captura global de teclado y ratón)' {
        $tmp = Join-Path $TestDrive 'tmp1'
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'JNativeHook-2.1.0.x86_64.dll') -Value 'x'
        Set-Content -LiteralPath (Join-Path $tmp 'documento.zip') -Value 'x'
        $r = Invoke-AmonTempSweep -Context (New-AmonTestContext) -Path $tmp
        $f = $r.Findings | Where-Object Category -EQ 'GlobalInputHook'
        $f.Status | Should -Be 'INCONCLUSIVE'
        $f.Path | Should -Match 'JNativeHook-2\.1\.0\.x86_64\.dll$'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match 'documento'
    }

    It 'con indicadores encuentra copias por nombre y por SHA-256' {
        $tmp = Join-Path $TestDrive 'tmp2'
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Set-Content -LiteralPath (Join-Path $tmp 'cheat.jar') -Value 'contenido'
        $ctx = New-AmonTestContext
        [void]$ctx.IndicatorNames.Add('cheat.jar')
        $r = Invoke-AmonTempSweep -Context $ctx -Path $tmp
        ($r.Findings | Where-Object Category -EQ 'TempIndicator').Path | Should -Match 'cheat\.jar$'
    }
}
