BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Update
}

Describe 'Actualizaciones: validación local' -Tag 'Unit' {
    It 'compara versiones con o sin prefijo v' {
        Compare-AmonVersion 'v1.2.0' '1.0.0' | Should -BeGreaterThan 0
        Compare-AmonVersion '1.0.0' '1.0.0' | Should -Be 0
    }

    It 'una etiqueta sin número de versión no rompe la comparación' {
        Compare-AmonVersion 'nightly' '1.0.0' | Should -BeNullOrEmpty
        Compare-AmonVersion 'v2' '1.0.0' | Should -BeNullOrEmpty
    }

    It 'valida el nombre del repositorio antes de guardarlo' {
        Test-AmonRepositoryName 'propietario/Amon-SS' | Should -BeTrue
        foreach ($r in 'Amon-SS', 'a/b/c', 'https://github.com/a/b', 'a b/c', '') { Test-AmonRepositoryName $r | Should -BeFalse -Because "'$r' no es propietario/repositorio" }
    }
}
