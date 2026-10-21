BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Jar, Signatures, Memory
    $script:Set = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')
}

Describe 'Memoria: patrones' -Tag 'Unit' {
    It 'genera la forma interna (/) y la forma Java (.) de los paquetes' {
        $p = Get-AmonMemoryPatterns -Set $script:Set
        $meteor = @($p.Map | Where-Object { $_.Indicator.ClientId -eq 'meteor-client' -and $_.Indicator.Type -eq 'package' })
        $meteor.Count | Should -BeGreaterThan 1
        ($meteor | ForEach-Object Form) | Should -Contain 'paquete (forma interna)'
        ($meteor | ForEach-Object Form) | Should -Contain 'paquete'
    }

    It 'no usa cadenas cortas ni indicadores débiles, que en memoria darían falsos positivos' {
        $p = Get-AmonMemoryPatterns -Set $script:Set
        @($p.Map | Where-Object { $_.Indicator.Type -eq 'string' -and $_.Indicator.Value.Length -lt 10 }).Count | Should -Be 0
        @($p.Map | Where-Object { $_.Indicator.Strength -eq 'weak' }).Count | Should -Be 0
    }

    It 'sin procesos de Java lo indica y no inventa nada' {
        $r = Invoke-AmonMemoryAnalysis -Context (New-AmonTestContext) -Processes @() -Set $script:Set
        $r.Status | Should -Be 'Skipped'
        $r.Findings.Count | Should -Be 0
    }
}

Describe 'Memoria: proceso real' -Tag 'Integration' {
    It 'detecta un cliente cuyas clases están en la memoria de otro proceso' {
        $exe = (Get-Process -Id $PID).Path
        # El proceso hijo guarda nombres de paquete y clase de Meteor (como haría la JVM al cargarlo).
        $child = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-Command', "`$a = 'meteordevelopment/meteorclient/systems/modules/Modules'; `$b = 'meteordevelopment.meteorclient.MeteorClient'; Start-Sleep -Seconds 40") -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Seconds 3
            $r = Invoke-AmonMemoryAnalysis -Context (New-AmonTestContext) -Set $script:Set -Processes @([pscustomobject]@{ ProcessId = $child.Id; Name = 'powershell.exe'; Path = $exe; CreationUtc = [datetime]::UtcNow })
            $f = $r.Findings | Where-Object ClientId -EQ 'meteor-client'
            $f | Should -Not -BeNullOrEmpty
            $f.Category | Should -Be 'ClientMemory'
            $f.Status | Should -Be 'DETECTED'
            ($f.Evidence | ForEach-Object Description) -join ' ' | Should -Match 'memoria de powershell\.exe'
        } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'un proceso sin firmas no produce hallazgos' {
        $exe = (Get-Process -Id $PID).Path
        $child = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 40') -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Seconds 3
            $r = Invoke-AmonMemoryAnalysis -Context (New-AmonTestContext) -Set $script:Set -Processes @([pscustomobject]@{ ProcessId = $child.Id; Name = 'powershell.exe'; Path = $exe; CreationUtc = [datetime]::UtcNow })
            @($r.Findings).Count | Should -Be 0
            $r.Artifacts[0].ScannedMB | Should -BeGreaterThan 1
        } finally { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
    }
}
