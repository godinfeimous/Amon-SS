@{
    # Reglas de PSScriptAnalyzer para Amon SS.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # La interfaz escribe directamente en la consola por diseño (colores ANSI y Write-Host de respaldo).
        'PSAvoidUsingWriteHost',
        # Los nombres en plural describen colecciones del dominio forense (p. ej. Get-AmonRecycleBinFolders).
        'PSUseSingularNouns',
        # Las funciones New-/Set- internas no modifican el sistema: crean objetos en memoria o cambian ajustes propios.
        'PSUseShouldProcessForStateChangingFunctions',
        # Los scripts se distribuyen en UTF-8 con BOM (lo comprueba tools\Repair-Encoding.ps1 -Check).
        'PSUseBOMForUnicodeEncodedFile'
    )
}
