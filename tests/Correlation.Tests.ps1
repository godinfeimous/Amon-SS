BeforeAll {
    . (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')
    Import-AmonTestModule Jar, Signatures, Correlation, Timeline, Reports
    $script:Set = Get-AmonSignatureSet -Path (Join-Path (Get-AmonTestRoot) 'signatures')

    function New-CorrContext {
        $c = New-AmonTestContext
        $c.Signatures = $script:Set
        return $c
    }
    function Add-Result($Context, [string]$Module, [object[]]$Findings = @(), [object[]]$Events = @(), [hashtable]$Data = @{}, [object[]]$Artifacts = @()) {
        $r = New-AmonModuleResult -Module $Module
        foreach ($f in $Findings) { $r.Findings.Add($f) }
        foreach ($e in $Events) { $r.Events.Add($e) }
        foreach ($a in $Artifacts) { $r.Artifacts.Add($a) }
        foreach ($k in $Data.Keys) { $r.Data[$k] = $Data[$k] }
        $Context.Results[$Module] = (Complete-AmonModuleResult -Result $r)
    }
    $script:jar = 'C:\Users\S\AppData\Roaming\.minecraft\mods\meteor-client-0.5.8.jar'
}

Describe 'Correlación de evidencias' -Tag 'Unit' {
    It 'correlaciona una firma de JAR con la carga del cliente en el log' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @(
            (New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Meteor Client' -Status DETECTED -Confidence High -Severity High -Client 'Meteor Client' -ClientId 'meteor-client' -Path $script:jar -Sha256 ('a' * 64)),
            (New-AmonFinding -Module Signatures -Category ClientLog -Title 'Meteor Client: evidencia en log' -Status DETECTED -Confidence High -Severity High -Client 'Meteor Client' -ClientId 'meteor-client' -Path 'C:\mc\logs\latest.log' -Data @{ Execution = $true })
        )
        $c = Invoke-AmonCorrelation -Context $ctx
        $v = $c.ClientVerdicts | Where-Object ClientId -EQ 'meteor-client'
        $v.Status | Should -Be 'CORRELATED'
        $f = $c.Correlated | Where-Object ClientId -EQ 'meteor-client'
        $f.Status | Should -Be 'CORRELATED'
        $f.Confidence | Should -Be 'High'
        $f.Justification | Should -Match 'log'
    }

    It 'una firma sin otras fuentes queda como DETECTED' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Wurst' -Status DETECTED -Confidence High -Client 'Wurst' -ClientId 'wurst' -Path 'C:\x\wurst.jar'))
        (Invoke-AmonCorrelation -Context $ctx).ClientVerdicts | Where-Object ClientId -EQ 'wurst' | ForEach-Object Status | Should -Be 'DETECTED'
    }

    It 'limita a confianza media una correlación basada en firmas no validadas' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Doomsday Client' -Status DETECTED -Confidence Medium -Client 'Doomsday Client' -ClientId 'doomsday' -Path 'C:\Users\S\Downloads\abc123.jar'))
        Add-Result $ctx 'Prefetch' @((New-AmonFinding -Module Prefetch -Category JarOutsideMinecraft -Title 'Java cargó un JAR' -Status INCONCLUSIVE -Confidence Medium -Path 'C:\USERS\S\DOWNLOADS\ABC123.JAR'))
        $c = Invoke-AmonCorrelation -Context $ctx
        ($c.ClientVerdicts | Where-Object ClientId -EQ 'doomsday').Status | Should -Be 'CORRELATED'
        ($c.Correlated | Where-Object ClientId -EQ 'doomsday').Confidence | Should -Be 'Medium'
    }

    It 'un cliente sin firmas verificables queda fuera de cobertura: ni sospechoso ni descartado' {
        $ctx = New-CorrContext
        $ctx.Signatures = [pscustomobject]@{ Clients = @([pscustomobject]@{ Id = 'sin-firmas'; Name = 'Sin Firmas'; Category = 'cheat-client'; Indicators = @(); FalsePositives = @() }); ClientIndex = @{} }
        $c = Invoke-AmonCorrelation -Context $ctx
        $v = $c.ClientVerdicts | Where-Object ClientId -EQ 'sin-firmas'
        $v.Status | Should -Be 'NOT COVERED'
        $v.Justification | Should -Match 'verificables'
        $c.Summary.Inconclusive | Should -Be 0
        $c.Summary.NotCovered | Should -Be 1
        $c.Conclusion | Should -Not -Match 'Indicadores débiles'
    }

    It 'el resultado global resume la revisión en una sola palabra' {
        (Invoke-AmonCorrelation -Context (New-CorrContext)).Outcome | Should -Be 'SIN INDICADORES'
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Wurst' -Status DETECTED -Confidence High -Client 'Wurst' -ClientId 'wurst' -Path 'C:\x\wurst.jar'))
        (Invoke-AmonCorrelation -Context $ctx).Outcome | Should -Be 'INDICADORES ENCONTRADOS'
        $ctx2 = New-CorrContext
        Add-Result $ctx2 'Signatures' @((New-AmonFinding -Module Signatures -Category ClientConfig -Title 'Wurst: configuración' -Status INCONCLUSIVE -Confidence Low -Client 'Wurst' -ClientId 'wurst' -Path 'C:\mc\wurst'))
        (Invoke-AmonCorrelation -Context $ctx2).Outcome | Should -Be 'REVISAR A MANO'
    }

    It 'una coincidencia solo de nombre no cambia el resultado ni el veredicto del cliente' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Recent' @((New-AmonFinding -Module Recent -Category KeywordName -Title 'Nombre relacionado' -Status INCONCLUSIVE -Confidence Low -Client 'Wurst' -ClientId 'wurst' -Path 'C:\Users\S\Documents\wurst-rezepte.exe'))
        $c = Invoke-AmonCorrelation -Context $ctx
        $c.Outcome | Should -Be 'SIN INDICADORES'
        $v = $c.ClientVerdicts | Where-Object ClientId -EQ 'wurst'
        $v.Status | Should -Be 'NOT DETECTED'
        $v.Justification | Should -Match 'nombre'
    }

    It 'sin indicadores declara NOT DETECTED dentro del alcance y no emite veredicto automático' {
        $c = Invoke-AmonCorrelation -Context (New-CorrContext)
        ($c.ClientVerdicts | Where-Object ClientId -EQ 'meteor-client').Status | Should -Be 'NOT DETECTED'
        ($c.ClientVerdicts | Where-Object ClientId -EQ 'meteor-client').Justification | Should -Match 'alcance'
        $c.Conclusion | Should -Match 'revisión humana'
    }

    It 'no inventa relaciones entre hallazgos sin claves comunes' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Wurst' -Status DETECTED -Confidence High -Client 'Wurst' -ClientId 'wurst' -Path 'C:\x\wurst.jar'))
        Add-Result $ctx 'RecycleBin' @((New-AmonFinding -Module RecycleBin -Category RelevantDeletion -Title 'Eliminación registrada: otro.jar' -Status DETECTED -Confidence High -Path 'C:\Users\S\Downloads\otro.jar'))
        $c = Invoke-AmonCorrelation -Context $ctx
        ($c.ClientVerdicts | Where-Object ClientId -EQ 'wurst').Status | Should -Be 'DETECTED'
        @($c.Correlated).Count | Should -Be 0
    }

    It 'relaciona la papelera con el USN Journal como actividad correlacionada' {
        $ctx = New-CorrContext
        $act = [System.Collections.Generic.List[object]]::new()
        Add-Result $ctx 'RecycleBin' -Data @{ Activity = $act } -Artifacts @([pscustomobject]@{ OriginalName = 'cheat.jar'; OriginalPath = 'C:\Users\S\Downloads\cheat.jar'; DeletedUtc = [datetime]::UtcNow.AddHours(-2) })
        $usnAct = [System.Collections.Generic.List[object]]::new()
        $usnAct.Add([pscustomobject]@{ TimestampUtc = [datetime]::UtcNow.AddHours(-2); Operation = 'Enviado a la papelera'; OriginalName = 'cheat.jar'; OriginalFolder = 'C:\Users\S\Downloads'; RecycledAs = 'C:\$Recycle.Bin\S\$R1.jar'; Drive = 'C:'; Source = 'USN Journal' })
        Add-Result $ctx 'USNJournal' -Data @{ RecycleActivity = $usnAct }
        $null = Invoke-AmonCorrelation -Context $ctx
        ($ctx.Results['RecycleBin'].Data['Activity'] | Where-Object Category -EQ 'Actividad correlacionada') | Should -Not -BeNullOrEmpty
    }

    It 'no duplica la actividad correlacionada de la papelera al correlacionar varias veces' {
        $ctx = New-CorrContext
        $act = [System.Collections.Generic.List[object]]::new()
        Add-Result $ctx 'RecycleBin' -Data @{ Activity = $act } -Artifacts @([pscustomobject]@{ OriginalName = 'cheat.jar'; OriginalPath = 'C:\Users\S\Downloads\cheat.jar'; DeletedUtc = [datetime]::UtcNow.AddHours(-2) })
        $usnAct = [System.Collections.Generic.List[object]]::new()
        $usnAct.Add([pscustomobject]@{ TimestampUtc = [datetime]::UtcNow.AddHours(-2); Operation = 'Enviado a la papelera'; OriginalName = 'cheat.jar'; OriginalFolder = 'C:\Users\S\Downloads'; RecycledAs = 'C:\$Recycle.Bin\S\$R1.jar'; Drive = 'C:'; Source = 'USN Journal' })
        Add-Result $ctx 'USNJournal' -Data @{ RecycleActivity = $usnAct }
        1..3 | ForEach-Object { $null = Invoke-AmonCorrelation -Context $ctx }
        @($ctx.Results['RecycleBin'].Data['Activity'] | Where-Object Category -EQ 'Actividad correlacionada').Count | Should -Be 1
    }

    It 'la sesión del propio log no cuenta como segunda fuente' {
        $ctx = New-CorrContext
        $log = 'C:\mc\logs\latest.log'
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category ClientLog -Title 'Meteor Client: evidencia en log' -Status DETECTED -Confidence High -Client 'Meteor Client' -ClientId 'meteor-client' -Path $log -Data @{ Execution = $true }))
        Add-Result $ctx 'Minecraft' -Events @((New-AmonEvent -TimestampUtc ([datetime]::UtcNow.AddHours(-1)) -Type 'Sesión de Minecraft' -Kind Execution -Source 'Minecraft (log)' -Path $log))
        Add-Result $ctx 'USNJournal' -Events @((New-AmonEvent -TimestampUtc ([datetime]::UtcNow.AddHours(-1)) -Type 'USN: Renombrado' -Kind Rename -Source 'USN Journal (C:)' -Path 'C:\otra\logs\latest.log'))
        ((Invoke-AmonCorrelation -Context $ctx).ClientVerdicts | Where-Object ClientId -EQ 'meteor-client').Status | Should -Be 'DETECTED'
    }

    It 'un proceso javaw.exe no se une con cualquier Prefetch de javaw.exe' {
        $ctx = New-CorrContext
        Add-Result $ctx 'Processes' @((New-AmonFinding -Module Processes -Category ClientProcess -Title 'Meteor Client: proceso' -Status DETECTED -Confidence Medium -Client 'Meteor Client' -ClientId 'meteor-client' -Path 'C:\Program Files\Java\bin\javaw.exe'))
        Add-Result $ctx 'Prefetch' -Events @((New-AmonEvent -TimestampUtc ([datetime]::UtcNow.AddHours(-1)) -Type 'Ejecución registrada en Prefetch' -Kind Execution -Source 'Prefetch' -Path 'C:\PROGRAM FILES\JAVA\BIN\JAVAW.EXE'))
        ((Invoke-AmonCorrelation -Context $ctx).ClientVerdicts | Where-Object ClientId -EQ 'meteor-client').Status | Should -Be 'DETECTED'
    }

    It 'los registros USN de varias unidades son una sola fuente' {
        $ctx = New-CorrContext
        $jar = 'C:\Users\S\Downloads\abc123.jar'
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Wurst' -Status DETECTED -Confidence High -Client 'Wurst' -ClientId 'wurst' -Path $jar))
        Add-Result $ctx 'USNJournal' -Events @(
            (New-AmonEvent -TimestampUtc ([datetime]::UtcNow.AddHours(-1)) -Type 'USN: Creado' -Kind Presence -Source 'USN Journal (C:)' -Path $jar),
            (New-AmonEvent -TimestampUtc ([datetime]::UtcNow.AddHours(-2)) -Type 'USN: Eliminado' -Kind Deletion -Source 'USN Journal (D:)' -Path 'D:\copia\abc123.jar'))
        $c = Invoke-AmonCorrelation -Context $ctx
        ($c.Correlated | Where-Object ClientId -EQ 'wurst').Data['Kinds'] | Sort-Object | Should -Be @('Archivo con firma', 'USN Journal')
    }
}

Describe 'Línea temporal unificada' -Tag 'Unit' {
    BeforeAll {
        $script:tctx = New-CorrContext
        $now = [datetime]::UtcNow
        Add-Result $script:tctx 'Prefetch' -Events @(
            (New-AmonEvent -TimestampUtc $now.AddHours(-1) -Type 'Ejecución registrada en Prefetch' -Source 'Prefetch' -Kind Execution -Path 'C:\x\javaw.exe'),
            (New-AmonEvent -TimestampUtc $now.AddDays(-30) -Type 'Antigua' -Source 'Prefetch' -Kind Execution -Path 'C:\x\old.exe')
        )
        Add-Result $script:tctx 'RecycleBin' -Events @(
            (New-AmonEvent -TimestampUtc $now.AddHours(-3) -Type 'Archivo enviado a la papelera' -Source 'RecycleBin' -Kind Deletion -Path 'C:\Users\S\Downloads\cheat.jar'),
            (New-AmonEvent -TimestampUtc $now.AddHours(-3) -Type 'Archivo enviado a la papelera' -Source 'RecycleBin' -Kind Deletion -Path 'C:\Users\S\Downloads\cheat.jar')
        )
        [void]$script:tctx.IndicatorNames.Add('cheat.jar')
    }

    It 'ordena cronológicamente, filtra la ventana y elimina duplicados' {
        $t = @(New-AmonTimeline -Context $script:tctx)
        $t.Count | Should -Be 2
        $t[0].Path | Should -Match 'cheat\.jar'
        $t[1].Path | Should -Match 'javaw\.exe'
    }

    It 'incluye fecha, hora y zona horaria locales' {
        $row = @(New-AmonTimeline -Context $script:tctx)[0]
        $row.Date | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $row.Time | Should -Match '^\d{2}:\d{2}:\d{2}$'
        $row.TimeZone | Should -Match '^UTC[+-]\d{2}:\d{2}$'
    }

    It 'permite cambiar el intervalo manualmente' {
        @(New-AmonTimeline -Context $script:tctx -SinceUtc ([datetime]::UtcNow.AddDays(-40)) -UntilUtc ([datetime]::UtcNow)).Count | Should -Be 3
    }

    It 'resalta los eventos ligados a indicadores' {
        (@(New-AmonTimeline -Context $script:tctx) | Where-Object Path -Match 'cheat').Highlight | Should -BeTrue
    }
}

Describe 'Reportes de evidencias' -Tag 'Unit' {
    BeforeAll {
        $script:rctx = New-CorrContext
        $script:rctx.AuthorizedScope.Add('Consentimiento verbal del jugador registrado por el revisor.')
        Add-Result $script:rctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title 'Meteor <script>alert(1)</script>' -Status DETECTED -Confidence High -Client 'Meteor Client' -ClientId 'meteor-client' -Path 'C:\mods\<script>.jar' -Sha256 ('b' * 64) -TimestampUtc ([datetime]::UtcNow) -Justification 'Paquete Java.' -Evidence @(New-AmonEvidence -Source 'Signatures' -Description 'paquete' -Kind Signature)))
        $script:corr = Invoke-AmonCorrelation -Context $script:rctx
        $script:model = New-AmonReportModel -Context $script:rctx -Correlation $script:corr -Timeline @(New-AmonTimeline -Context $script:rctx)
        $script:dir = Join-Path $TestDrive 'reports'
        $script:export = Export-AmonReport -Model $script:model -Directory $script:dir -Formats @('json', 'txt', 'html')
    }

    It 'exporta JSON, TXT, HTML y el manifiesto de integridad' {
        foreach ($ext in 'json', 'txt', 'html', 'sha256') { Test-Path (Join-Path $script:dir "$($script:model.ReviewId).$ext") | Should -BeTrue }
    }

    It 'el JSON contiene revisión, hallazgos con hash y fechas ISO 8601' {
        $raw = Get-Content (Join-Path $script:dir "$($script:model.ReviewId).json") -Raw -Encoding UTF8
        $raw | Should -Not -Match '\\/Date\('
        # Se comprueba el texto: PowerShell 7 convierte las fechas ISO en DateTime al leer el JSON.
        $raw | Should -Match '"TimestampUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $j = $raw | ConvertFrom-Json
        $j.ReviewId | Should -Be $script:model.ReviewId
        $j.Findings[0].Sha256 | Should -Be ('b' * 64)
        $j.AuthorizedScope | Should -Contain 'Consentimiento verbal del jugador registrado por el revisor.'
    }

    It 'verifica la integridad y detecta modificaciones' {
        $manifest = Join-Path $script:dir "$($script:model.ReviewId).sha256"
        (Test-AmonReportIntegrity -ManifestPath $manifest | Where-Object { -not $_.Valid }) | Should -BeNullOrEmpty
        Add-Content -Path (Join-Path $script:dir "$($script:model.ReviewId).txt") -Value 'alterado'
        $bad = Test-AmonReportIntegrity -ManifestPath $manifest | Where-Object { -not $_.Valid }
        $bad.File | Should -Match '\.txt$'
    }

    It 'el HTML escapa datos no confiables' {
        $html = Get-Content (Join-Path $script:dir "$($script:model.ReviewId).html") -Raw -Encoding UTF8
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'el TXT no contiene secuencias de control ni líneas falsificadas desde los datos' {
        $e = [char]27
        $ctx = New-CorrContext
        Add-Result $ctx 'Signatures' @((New-AmonFinding -Module Signatures -Category CheatSignature -Title "Wurst$e[2J" -Status DETECTED -Confidence High -Client 'Wurst' -ClientId 'wurst' -Path "C:\mods\x$e]0;titulo$([char]7).jar`r`n  [CORRELATED] FORJADO"))
        $corr = Invoke-AmonCorrelation -Context $ctx
        $model = New-AmonReportModel -Context $ctx -Correlation $corr -Timeline @()
        $dir = Join-Path $TestDrive 'reports-ctl'
        $null = Export-AmonReport -Model $model -Directory $dir -Formats @('txt')
        $txt = Get-Content (Join-Path $dir "$($model.ReviewId).txt") -Raw -Encoding UTF8
        $txt | Should -Not -Match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'
        $txt | Should -Not -Match '(?m)^\s+\[CORRELATED\] FORJADO'
    }

    It 'exportar otra vez no sobrescribe un reporte ya exportado (su hash puede estar anotado)' {
        $dir = Join-Path $TestDrive 'reports-twice'
        $a = Export-AmonReport -Model $script:model -Directory $dir -Formats @('txt')
        $hashA = (Get-FileHash $a.Manifest).Hash
        $b = Export-AmonReport -Model $script:model -Directory $dir -Formats @('txt')
        $b.Manifest | Should -Not -Be $a.Manifest
        (Get-FileHash $a.Manifest).Hash | Should -Be $hashA
        (Test-AmonReportIntegrity -ManifestPath $a.Manifest | Where-Object { -not $_.Valid }) | Should -BeNullOrEmpty
    }

    It 'el TXT incluye la conclusión para revisión humana y las limitaciones' {
        $txt = Get-Content (Join-Path $script:dir "$($script:model.ReviewId).txt") -Raw -Encoding UTF8
        $txt | Should -Match 'REVISIÓN HUMANA'
        $txt | Should -Match 'LIMITACIONES'
    }
}
