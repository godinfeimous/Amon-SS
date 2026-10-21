#Requires -Version 5.1
<#
    Amon SS - modules/Timeline.psm1
    Línea temporal forense unificada a partir de los eventos de todos los módulos.

    Cada fila procede de un artefacto concreto (Prefetch, $I, USN, log, evento 4688...). No se
    interpolan ni se inventan tiempos. Por defecto se muestra la ventana de la revisión
    (7 días); el intervalo puede cambiarse.
#>

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -DisableNameChecking

function Get-AmonOffsetLabel {
    param([datetime]$Local)
    $off = [TimeZoneInfo]::Local.GetUtcOffset($Local)
    $sign = '+'; if ($off.Ticks -lt 0) { $sign = '-' }
    return ('UTC{0}{1:hh\:mm}' -f $sign, $off.Duration())
}

function New-AmonTimeline {
    <#
    .SYNOPSIS
        Construye la línea temporal (filas ordenadas cronológicamente, sin duplicados).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Context, $SinceUtc, $UntilUtc)
    $since = ConvertTo-AmonUtc $SinceUtc; if (-not $since) { $since = $Context.SinceUtc }
    $until = ConvertTo-AmonUtc $UntilUtc; if (-not $until) { $until = [datetime]::UtcNow.AddMinutes(5) }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rows = [System.Collections.Generic.List[object]]::new()
    $indicators = $Context.IndicatorNames
    foreach ($r in @($Context.Results.Values)) {
        foreach ($e in $r.Events) {
            $t = $e.TimestampUtc
            if ($null -eq $t -or $t -lt $since -or $t -gt $until) { continue }
            $key = '{0}|{1}|{2}' -f [long]($t.Ticks / 10000000), $e.Type, $e.Path
            if (-not $seen.Add($key)) { continue }
            $local = $t.ToLocalTime()
            $leaf = $null
            if ($e.Path) { try { $leaf = [IO.Path]::GetFileName($e.Path) } catch { } }
            $rows.Add([pscustomobject]@{
                    PSTypeName = 'AmonSS.TimelineRow'
                    TimestampUtc = $t
                    Date = $local.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                    Time = $local.ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                    TimeZone = (Get-AmonOffsetLabel $local)
                    Type = $e.Type; Kind = $e.Kind; Source = $e.Source; Module = $r.Module
                    Path = $e.Path; Indicator = $e.Indicator; Confidence = $e.Confidence; Description = $e.Description
                    Highlight = [bool](($leaf -and $indicators.Contains($leaf)) -or $e.Indicator)
                })
        }
    }
    return @($rows | Sort-Object TimestampUtc)
}

function Get-AmonTimelineSummary {
    # Recuento por día y por fuente para la vista resumida.
    param([object[]]$Rows = @())
    [pscustomobject]@{
        Total = $Rows.Count
        ByDay = @($Rows | Group-Object Date | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Date = $_.Name; Events = $_.Count; Highlighted = @($_.Group | Where-Object Highlight).Count } })
        BySource = @($Rows | Group-Object Source | Sort-Object Count -Descending | ForEach-Object { [pscustomobject]@{ Source = $_.Name; Events = $_.Count } })
    }
}

Export-ModuleMember -Function @('New-AmonTimeline', 'Get-AmonTimelineSummary')
