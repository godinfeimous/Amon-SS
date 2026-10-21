BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Core
    $script:Exe = (Get-Process -Id $PID).Path

    function New-PackageCopy([string]$Name, [switch]$ReleaseBuild, [switch]$NoManifest) {
        # Copia mínima del paquete con su manifiesto, como la que genera Build-Release.
        $copy = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path $copy -Force | Out-Null
        foreach ($item in 'Start-AmonSS.ps1', 'config', 'modules', 'signatures') { Copy-Item -LiteralPath (Join-Path (Get-AmonTestRoot) $item) -Destination $copy -Recurse -Force }
        if ($ReleaseBuild) {
            $core = Join-Path $copy 'modules\Core.psm1'
            $text = [IO.File]::ReadAllText($core).Replace('$script:AmonReleaseBuild = $false', '$script:AmonReleaseBuild = $true')
            [IO.File]::WriteAllText($core, $text, [Text.UTF8Encoding]::new($true))
        }
        if (-not $NoManifest) { New-AmonIntegrityManifest -Root $copy | Out-Null }
        return $copy
    }

    function Invoke-InCopy([string]$Copy, [string]$Script) {
        # En un proceso nuevo: los tipos C# compilados en este proceso no se pueden recargar.
        $cmd = "`$ErrorActionPreference = 'Stop'; try { Import-Module '$Copy\modules\Core.psm1' -DisableNameChecking; Import-Module '$Copy\modules\Jar.psm1' -DisableNameChecking; Import-Module '$Copy\modules\Signatures.psm1' -DisableNameChecking; $Script } catch { 'ERROR: ' + `$_.Exception.Message }"
        return ((& $script:Exe -NoProfile -Command $cmd 2>&1) -join ' ')
    }
}

Describe 'Integridad del paquete' -Tag 'Integration' {
    It 'un paquete íntegro se verifica entero y carga sus firmas' {
        $copy = New-PackageCopy 'ok' -ReleaseBuild
        $out = Invoke-InCopy $copy "`$bad = @(Test-AmonPackageIntegrity | Where-Object { -not `$_.Valid }); 'MALOS=' + `$bad.Count; 'CLIENTES=' + (Get-AmonSignatureSet).Clients.Count"
        $out | Should -Match 'MALOS=0'
        $out | Should -Match 'CLIENTES=[1-9]'
    }

    It 'una firma alterada impide cargar el conjunto de firmas' {
        $copy = New-PackageCopy 'sig'
        Add-Content -LiteralPath (Join-Path $copy 'signatures\wurst.json') -Value ' '
        $out = Invoke-InCopy $copy "(Get-AmonSignatureSet).Clients.Count"
        $out | Should -Match 'ERROR: Integridad del paquete comprometida: signatures/wurst\.json'
    }

    It 'un archivo de firmas añadido o eliminado se rechaza' {
        $copy = New-PackageCopy 'added'
        Copy-Item (Join-Path $copy 'signatures\wurst.json') (Join-Path $copy 'signatures\zz-extra.json')
        Invoke-InCopy $copy "(Get-AmonSignatureSet).Clients.Count" | Should -Match 'zz-extra\.json no figura'
        $copy2 = New-PackageCopy 'removed'
        Remove-Item -LiteralPath (Join-Path $copy2 'signatures\wurst.json')
        Invoke-InCopy $copy2 "(Get-AmonSignatureSet).Clients.Count" | Should -Match 'falta.*signatures/wurst\.json'
    }

    It 'no compila código C# alterado' {
        $copy = New-PackageCopy 'cs'
        Add-Content -LiteralPath (Join-Path $copy 'modules\Native\AmonNative.cs') -Value '// alterado'
        $out = Invoke-InCopy $copy "Import-AmonNative; 'COMPILADO'"
        $out | Should -Match 'Integridad del paquete comprometida: modules/Native/AmonNative\.cs'
        $out | Should -Not -Match 'COMPILADO'
    }

    It 'una release sin manifiesto no se ejecuta; una copia de desarrollo sí' {
        $rel = New-PackageCopy 'nomanifest' -ReleaseBuild -NoManifest
        Invoke-InCopy $rel "Import-AmonNative; 'COMPILADO'" | Should -Match 'falta Integrity\.psd1'
        $dev = New-PackageCopy 'dev' -NoManifest
        Invoke-InCopy $dev "Import-AmonNative; 'COMPILADO'" | Should -Match 'COMPILADO'
    }

    It 'una release con un archivo alterado no llega a analizar nada' {
        $ErrorActionPreference = 'Continue'
        $copy = New-PackageCopy 'startup' -ReleaseBuild
        Add-Content -LiteralPath (Join-Path $copy 'modules\Native\AmonZip.cs') -Value '// alterado'
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'Start-AmonSS.ps1') -Scan Minecraft -Consent -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join ' ') | Should -Match 'Integridad del paquete comprometida.*AmonZip\.cs'
        ($out -join ' ') | Should -Not -Match 'Minecraft Analysis'
    }

    It '-VerifyPackage termina con 0 si el paquete está íntegro y con 1 si no' {
        $ErrorActionPreference = 'Continue'
        $copy = New-PackageCopy 'verify'
        $null = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'Start-AmonSS.ps1') -VerifyPackage -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 0
        Add-Content -LiteralPath (Join-Path $copy 'config\settings.json') -Value ' '
        $out = & $script:Exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'Start-AmonSS.ps1') -VerifyPackage -NoAnimation 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join ' ') | Should -Match 'settings\.json'
    }
}
