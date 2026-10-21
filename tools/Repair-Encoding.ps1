<#
.SYNOPSIS
    Normaliza los scripts del repositorio a UTF-8 con BOM.
.DESCRIPTION
    Windows PowerShell 5.1 interpreta los .ps1/.psm1/.psd1 sin BOM con la página de códigos
    ANSI del sistema, lo que corrompe los glifos (╔ ◆ ✦) y los acentos de la interfaz.
    Este script añade el BOM a los archivos que no lo tengan. Con -Check solo informa y
    devuelve código 1 si encuentra archivos sin BOM (lo usa la CI).
#>
[CmdletBinding()]
param([switch]$Check)

$root = Split-Path -Parent $PSScriptRoot
$bom = [byte[]](0xEF, 0xBB, 0xBF)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$bad = @()

Get-ChildItem -Path $root -Recurse -File -Include *.ps1, *.psm1, *.psd1 |
    Where-Object { $_.FullName -notmatch '\\(\.git|release)\\' } |
    ForEach-Object {
        $bytes = [IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq $bom[0] -and $bytes[1] -eq $bom[1] -and $bytes[2] -eq $bom[2]
        if (-not $hasBom) {
            $bad += $_.FullName
            if (-not $Check) {
                # Los archivos se escriben en UTF-8: se decodifican así y se reescriben con BOM.
                $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes)
                [IO.File]::WriteAllText($_.FullName, $text, $utf8Bom)
            }
        }
    }

if ($Check) {
    if ($bad.Count) { $bad | ForEach-Object { Write-Host "Sin BOM: $_" }; exit 1 }
    Write-Host 'Todos los scripts tienen UTF-8 con BOM.'
} else {
    Write-Host ("Archivos corregidos: {0}" -f $bad.Count)
}
