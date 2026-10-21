BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule RecycleBin

    function New-RecycleInfoBytes([string]$OriginalPath, [long]$Size, [datetime]$DeletedUtc, [int]$Version = 2) {
        $path = [Text.Encoding]::Unicode.GetBytes($OriginalPath + [char]0)
        if ($Version -eq 1) {
            $b = New-Object byte[] 544
            [Array]::Copy([BitConverter]::GetBytes([int64]1), 0, $b, 0, 8)
            [Array]::Copy([BitConverter]::GetBytes($Size), 0, $b, 8, 8)
            [Array]::Copy([BitConverter]::GetBytes($DeletedUtc.ToUniversalTime().ToFileTimeUtc()), 0, $b, 16, 8)
            [Array]::Copy($path, 0, $b, 24, [Math]::Min($path.Length, 520))
            return , $b
        }
        $b = New-Object byte[] (28 + $path.Length)
        [Array]::Copy([BitConverter]::GetBytes([int64]2), 0, $b, 0, 8)
        [Array]::Copy([BitConverter]::GetBytes($Size), 0, $b, 8, 8)
        [Array]::Copy([BitConverter]::GetBytes($DeletedUtc.ToUniversalTime().ToFileTimeUtc()), 0, $b, 16, 8)
        [Array]::Copy([BitConverter]::GetBytes([int]($path.Length / 2)), 0, $b, 24, 4)
        [Array]::Copy($path, 0, $b, 28, $path.Length)
        return , $b
    }

    function New-RecyclePair([string]$Folder, [string]$Id, [string]$Ext, [string]$OriginalPath, [datetime]$DeletedUtc, [int]$DataBytes = 10, [long]$DeclaredSize = -1, [switch]$NoData) {
        if ($DeclaredSize -lt 0) { $DeclaredSize = $DataBytes }
        $i = Join-Path $Folder ('$I' + $Id + $Ext)
        [IO.File]::WriteAllBytes($i, (New-RecycleInfoBytes $OriginalPath $DeclaredSize $DeletedUtc))
        [IO.File]::SetCreationTimeUtc($i, $DeletedUtc.ToUniversalTime())
        [IO.File]::SetLastWriteTimeUtc($i, $DeletedUtc.ToUniversalTime())
        if (-not $NoData) { [IO.File]::WriteAllBytes((Join-Path $Folder ('$R' + $Id + $Ext)), (New-Object byte[] $DataBytes)) }
    }
}

Describe 'Papelera: estructura $I' -Tag 'Unit' {
    It 'interpreta $I versión 2 (Windows 10/11)' {
        $d = [datetime]'2026-10-19T18:00:00Z'
        $r = ConvertFrom-AmonRecycleInfoBytes -Bytes (New-RecycleInfoBytes 'C:\Users\S\Downloads\cheat.jar' 12345 $d)
        $r.Version | Should -Be 2
        $r.OriginalPath | Should -Be 'C:\Users\S\Downloads\cheat.jar'
        $r.DeclaredSize | Should -Be 12345
        $r.DeletedUtc | Should -Be $d.ToUniversalTime()
    }

    It 'interpreta $I versión 1 (Vista/7/8)' {
        $r = ConvertFrom-AmonRecycleInfoBytes -Bytes (New-RecycleInfoBytes 'D:\old\file.exe' 77 ([datetime]'2026-01-01T00:00:00Z') -Version 1)
        $r.Version | Should -Be 1
        $r.OriginalPath | Should -Be 'D:\old\file.exe'
    }

    It 'rechaza un $I con versión desconocida' {
        { ConvertFrom-AmonRecycleInfoBytes -Bytes (New-Object byte[] 40) } | Should -Throw
    }
}

Describe 'Papelera: análisis de una carpeta de usuario' -Tag 'Unit' {
    BeforeAll {
        $script:folder = Join-Path $TestDrive '$Recycle.Bin\S-1-5-21-1000'
        New-Item -ItemType Directory -Path $script:folder -Force | Out-Null
        $now = [datetime]::UtcNow
        New-RecyclePair $script:folder 'ABC123' '.jar' 'C:\Users\S\Downloads\cheat.jar' $now.AddDays(-1)
        New-RecyclePair $script:folder 'DEF456' '.txt' 'C:\Users\S\Documents\privado.txt' $now.AddDays(-2)
        New-RecyclePair $script:folder 'GHI789' '.exe' 'C:\Users\S\Desktop\tool.exe' $now.AddDays(-3) -NoData
        New-RecyclePair $script:folder 'MNO111' '.jar' 'C:\Users\S\AppData\Roaming\.minecraft\mods\x.jar' $now.AddDays(-1) -DataBytes 10 -DeclaredSize 999
        [IO.File]::WriteAllBytes((Join-Path $script:folder '$RJKL000.dll'), (New-Object byte[] 5))
        [IO.Directory]::SetLastWriteTimeUtc($script:folder, $now)
        $script:ctx = New-AmonTestContext
        $script:res = Invoke-AmonRecycleBinAnalysis -Context $script:ctx -Folders @($script:folder)
        $script:activity = $script:res.Data['Activity']
    }

    It 'registra la eliminación de un JAR relevante y lo prepara para escanear sin restaurarlo' {
        ($script:activity | Where-Object { $_.Category -eq 'Eliminación registrada' -and $_.Path -like '*cheat.jar' }) | Should -Not -BeNullOrEmpty
        ($script:ctx.EvidencePaths | ForEach-Object Path) | Should -Contain (Join-Path $script:folder '$RABC123.jar')
        Test-Path (Join-Path $script:folder '$RABC123.jar') | Should -BeTrue
    }

    It 'no muestra archivos personales no relacionados (solo los cuenta)' {
        ($script:res.Artifacts | ForEach-Object OriginalPath) | Should -Not -Contain 'C:\Users\S\Documents\privado.txt'
        $script:res.Data['UnrelatedCount'] | Should -Be 1
    }

    It 'distingue un archivo asociado ausente' {
        ($script:activity | Where-Object { $_.Category -eq 'Archivo asociado ausente' -and $_.Path -like '*tool.exe' }) | Should -Not -BeNullOrEmpty
    }

    It 'distingue metadatos ausentes ($R sin $I)' {
        ($script:activity | Where-Object { $_.Category -eq 'Inconsistencia de metadatos' -and $_.Path -like '*$RJKL000.dll' }) | Should -Not -BeNullOrEmpty
    }

    It 'detecta un tamaño declarado que no coincide con el contenido' {
        ($script:activity | Where-Object { $_.Category -eq 'Inconsistencia de metadatos' -and $_.Path -like '*x.jar' }) | Should -Not -BeNullOrEmpty
    }

    It 'señala modificaciones del contenedor posteriores al último borrado sin afirmar intención' {
        $a = $script:activity | Where-Object { $_.Category -eq 'Evidencia insuficiente' -and $_.Description -match 'contenedor' }
        $a | Should -Not -BeNullOrEmpty
        $a.Description | Should -Not -Match 'deliberad'
    }

    It 'genera eventos de eliminación para la línea temporal' {
        @($script:res.Events | Where-Object Kind -EQ 'Deletion').Count | Should -BeGreaterThan 0
    }
}

Describe 'Papelera: sistema real' -Tag 'Integration' {
    It 'lee la papelera del usuario actual en solo lectura' {
        $res = Invoke-AmonRecycleBinAnalysis -Context (New-AmonTestContext)
        $res.Status | Should -BeIn @('Completed', 'Partial')
    }
}
