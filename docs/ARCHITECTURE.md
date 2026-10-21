# Arquitectura

Amon SS es un conjunto de módulos de PowerShell 5.1 y 7 sin dependencias externas. `Start-AmonSS.ps1` gestiona la interfaz y la sesión (la revisión automática, los menús de una tecla y el modo no interactivo); cada módulo forense recibe un **contexto** compartido y devuelve un **resultado de módulo** con hallazgos, eventos y artefactos. El motor de correlación, la línea temporal y los reportes trabajan solo con esos resultados.

```text
Start-AmonSS.ps1 ── UI.psm1 / Views.psm1            (presentación)
      │
      └─ Orchestrator.psm1 ── catálogo y orden de investigación
              │
              ├─ Minecraft ─ Signatures ─ Processes ─ Memory ─ Prefetch ─ BAM ─ PCA ─ ShimCache
              │  Recent ─ UserAssist ─ Events ─ Tamper ─ TempSweep ─ RecycleBin ─ USNJournal
              │  Signatures (evidencias)
              │        (todos usan Core.psm1; Minecraft y Signatures usan Jar.psm1; Memory usa
              │         Signatures.psm1; BAM, PCA y ShimCache viven en ExecutionArtifacts.psm1)
              │
              ├─ Correlation.psm1 ─ veredicto por cliente y resultado global
              ├─ Timeline.psm1    ─ línea temporal
              └─ Reports.psm1     ─ TXT / JSON / HTML + manifiesto SHA-256

Core.psm1 ── Import-AmonNative ── Native/AmonNative.cs + Native/AmonZip.cs (Add-Type, una vez por proceso)
    │
    └─ Read-AmonVerifiedText ── Integrity.psd1 (solo en una release: .cs, signatures\*.json, config\settings.json)
```

## Mapa de módulos

| Módulo | Responsabilidad | Funciones principales |
| --- | --- | --- |
| `Core.psm1` | Versión, integridad del paquete, ajustes, contrato de datos, contexto, cancelación y tiempo máximo, lectura en solo lectura, rutas locales y de usuario, herramientas por nombre, hashes con caché, FILETIME, ocultación de secretos y compilación del código nativo | `Get-AmonSettings`, `Set-AmonSetting`, `Get-AmonIntegrityManifest`, `Read-AmonVerifiedText`, `Assert-AmonPackageFolder`, `New-AmonIntegrityManifest`, `Test-AmonPackageIntegrity`, `New-AmonFinding`, `New-AmonEvent`, `New-AmonEvidence`, `New-AmonModuleResult`, `New-AmonContext`, `Invoke-AmonModule`, `Test-AmonCancel`, `Test-AmonLocalPath`, `Test-AmonUserWritablePath`, `Get-AmonScreenshareTool`, `Get-AmonToolByFileName`, `New-AmonToolFinding`, `Add-AmonEvidencePath`, `Get-AmonFileHash`, `Protect-AmonCommandLine`, `Import-AmonNative` |
| `UI.psm1` | Motor de terminal: temas, color, glifos, banner, menús, cajas, tablas, tarjetas, progreso y entrada (líneas y teclas sueltas) | `Initialize-AmonUI`, `Format-AmonBanner`, `Format-AmonMenu`, `Format-AmonTable`, `Format-AmonFinding`, `Write-AmonProgress`, `Read-AmonInput`, `Read-AmonKey` |
| `Views.psm1` | Vista de terminal de cada módulo, del veredicto y de la línea temporal. Solo presenta resultados ya calculados | `Show-AmonResultView`, `Show-AmonVerdictView`, `Show-AmonTimelineView` |
| `Jar.psm1` | Inspección estática de JAR/ZIP: entradas, paquetes, metadatos de Fabric, Quilt, Forge, NeoForge, `mcmod.info`, LiteLoader, MANIFEST y JAR anidados | `Get-AmonJarInfo`, `Get-AmonJarInfoFromArchive` |
| `Minecraft.psm1` | Instancias, logs, mods instalados y cargados, perfiles de versión | `Find-AmonMinecraftInstance`, `Get-AmonMinecraftLogInfo`, `Invoke-AmonMinecraftAnalysis` |
| `Signatures.psm1` | Carga y validación de firmas (con el índice `FileNames`), escaneo de archivos, logs, configuraciones y perfiles, y reglas de confianza | `Get-AmonSignatureSet`, `Test-AmonSignatureSet`, `Get-AmonSignatureDetections`, `Invoke-AmonFileSignatureScan`, `Invoke-AmonSignatureAnalysis` |
| `Processes.psm1` | Procesos (`Win32_Process`), línea de comandos de Java, Authenticode, DLL cargadas, agentes en caliente, JNativeHook y herramientas por nombre | `ConvertFrom-AmonJavaCommandLine`, `Test-AmonRuntimeAgent`, `Invoke-AmonProcessAnalysis` |
| `Memory.psm1` | Patrones de memoria a partir de las firmas y escaneo de los procesos Java | `Get-AmonMemoryPatterns`, `Get-AmonJavaProcesses`, `Invoke-AmonMemoryAnalysis` |
| `Prefetch.psm1` | Parser SCCA v17/v23/v26/v30/v31, descompresión MAM, mapa de volúmenes, herramientas por nombre y unidades externas | `Read-AmonPrefetchFile`, `Get-AmonVolumeMap`, `Convert-AmonPrefetchPath`, `Invoke-AmonPrefetchAnalysis` |
| `ExecutionArtifacts.psm1` | Relevancia común de ejecutables, ShimCache, BAM, PCA y MUICache (incluidas las trazas de la memoria del Explorador) | `Get-AmonExecutableRelevance`, `Test-AmonReviewLocation`, `ConvertFrom-AmonShimCache`, `Invoke-AmonShimCacheAnalysis`, `Invoke-AmonBamAnalysis`, `Get-AmonPcaRaw`, `Get-AmonExplorerTraces`, `Invoke-AmonPcaAnalysis` |
| `Recent.psm1` | Parser MS-SHLLINK de `.lnk` | `ConvertFrom-AmonLnkBytes`, `Invoke-AmonRecentAnalysis` |
| `UserAssist.psm1` | UserAssist (ROT13, datos de 72 bytes, carpetas conocidas) | `Invoke-AmonUserAssistAnalysis` |
| `Events.psm1` | Eventos 4688, 1102, 104, 7045, Ntfs 501, Defender 1116/1117/5001/5007, Application Error 1000, auditoría y claves Run | `Get-AmonEventSources`, `Invoke-AmonEventAnalysis` |
| `Tamper.psm1` | Servicios forenses (estado, reinicios, 7040, 7031/7034) y cambios de la hora del sistema | `Get-AmonServiceSnapshot`, `Get-AmonTimeChangeEvents`, `Get-AmonServiceControlEvents`, `Invoke-AmonTamperAnalysis` |
| `TempSweep.psm1` | `%TEMP%`: DLL de JNativeHook siempre y copias de indicadores concretos | `Invoke-AmonTempSweep` |
| `RecycleBin.psm1` | `$I` v1/v2, `$R` y RECYCLE BIN ACTIVITY | `ConvertFrom-AmonRecycleInfoBytes`, `Invoke-AmonRecycleBinAnalysis` |
| `USNJournal.psm1` | USN Journal: volúmenes, filtro, interpretación y papelera reconstruida | `New-AmonUsnFilter`, `Invoke-AmonUsnAnalysis` |
| `Correlation.psm1` | Correlación de hallazgos, veredicto por cliente, resultado global y conclusión | `Invoke-AmonCorrelation` |
| `Timeline.psm1` | Línea temporal unificada y resumen por día y fuente | `New-AmonTimeline`, `Get-AmonTimelineSummary` |
| `Reports.psm1` | Modelo serializable, TXT, JSON, HTML, manifiesto y verificación | `New-AmonReportModel`, `Export-AmonReport`, `Test-AmonReportIntegrity` |
| `Update.psm1` | Consulta de releases, validación del repositorio y de la etiqueta, y descarga verificada por SHA-256, a petición | `Get-AmonLatestRelease`, `Test-AmonRepositoryName`, `Compare-AmonVersion`, `Install-AmonRelease` |
| `Orchestrator.psm1` | Catálogo de módulos, selección por defecto, alcance legible y escaneo completo | `Get-AmonModuleCatalog`, `Get-AmonDefaultModuleSelection`, `Get-AmonScanScope` (ya no lo usa `Start-AmonSS.ps1`), `Invoke-AmonFullScan` |
| `Native/AmonNative.cs` | `PatternMatcher` (Aho-Corasick), `JarNames`, `Compression` (MAM), `Usn`, `Volumes`, `ProcessMemory`, `AuditPolicy` | |
| `Native/AmonZip.cs` | `ZipContentScanner`: recorre las entradas de un ZIP con el autómata | |

`Start-AmonSS.ps1` importa los módulos en este orden, para que cada uno reutilice la instancia ya cargada de los anteriores: Core, UI, Jar, Minecraft, Signatures, Processes, Memory, Prefetch, ExecutionArtifacts, Recent, UserAssist, Events, Tamper, TempSweep, RecycleBin, USNJournal, Correlation, Timeline, Reports, Update, Views, Orchestrator.

## Ajustes

`Get-AmonSettings` lee `config\settings.json` (en una release, verificado frente a `Integrity.psd1`) y combina encima, de forma recursiva, `%LOCALAPPDATA%\AmonSS\settings.json` (las listas se reemplazan enteras; el archivo del usuario está fuera del paquete y no se verifica). El resultado es una tabla hash que queda en caché hasta `-Reload`. `Set-AmonSetting -Persist` escribe solo en el archivo del usuario, con rutas de clave separadas por puntos (`minecraft.extraInstancePaths`). Las claves se describen en [COMMANDS.md](COMMANDS.md#claves-de-configsettingsjson).

## Contrato de datos

Todos los objetos son `PSCustomObject` con un `PSTypeName` y fechas en UTC (`ConvertTo-AmonUtc`).

### Evidence (`AmonSS.Evidence`)

| Campo | Descripción |
| --- | --- |
| `Source` | Fuente legible (`Signatures`, `Prefetch`, `Minecraft (log)`...). |
| `Kind` | `Execution`, `Presence`, `Deletion`, `Modification`, `Creation`, `Rename`, `LogLoaded`, `Configuration`, `Signature`, `System` u `Other`. |
| `Description` | Texto de la evidencia. |
| `Path`, `TimestampUtc` | Opcionales. |

### Finding (`AmonSS.Finding`)

| Campo | Descripción |
| --- | --- |
| `Id` | `F-` más 10 caracteres hexadecimales. |
| `Module`, `Category` | Módulo de origen y categoría (`CheatSignature`, `RemovedMod`, `RelevantDeletion`...). Ver [MODULES.md](MODULES.md). |
| `Title` | Título. |
| `Status` | `DETECTED`, `CORRELATED`, `INCONCLUSIVE`, `NOT DETECTED` o `INFO`. |
| `Severity` | `Info`, `Low`, `Medium` o `High`. |
| `Confidence` | `Low`, `Medium` o `High`. |
| `Path`, `Sha256`, `TimestampUtc` | Datos del artefacto (el SHA-256 se guarda en minúsculas). |
| `Indicator`, `IndicatorType` | Qué coincidió y de qué tipo. |
| `Client`, `ClientId` | Cliente asociado (clave de correlación). |
| `Source` | Fuente, incluida la URL de la firma cuando procede. |
| `Justification` | Motivo legible del estado y la confianza. |
| `FalsePositives` | Falsos positivos conocidos. |
| `Evidence` | Lista de `AmonSS.Evidence`. |
| `Data` | Tabla hash con datos del módulo (por ejemplo, `Execution = $true` para evidencia de carga o ejecución). |

### Event (`AmonSS.Event`)

Una fila de la línea temporal. `New-AmonEvent` rechaza un evento sin fecha: solo puede crearse a partir de un artefacto real.

| Campo | Descripción |
| --- | --- |
| `TimestampUtc` | Obligatorio. |
| `Type` | Texto del evento ("Ejecución registrada en Prefetch"). |
| `Kind` | Los mismos valores que `Evidence.Kind`. |
| `Source` | Fuente (`Prefetch`, `USN Journal (C:)`, `Security 4688`...). |
| `Path`, `Indicator`, `Description`, `Sha256`, `Data` | Opcionales. |
| `Confidence` | `Low`, `Medium` (por defecto) o `High`. |

### ModuleResult (`AmonSS.ModuleResult`)

| Campo | Descripción |
| --- | --- |
| `Module`, `DisplayName` | Clave y nombre visible. |
| `Status` | `Running`, `Completed`, `Partial`, `NoAccess`, `Skipped`, `Failed` o `Cancelled`. |
| `StartedUtc`, `FinishedUtc`, `DurationMs` | Tiempos. |
| `ArtifactsReviewed` | Artefactos revisados (incluidos los que se omiten por privacidad). |
| `RequiresAdmin` | El módulo necesita elevación para estar completo. |
| `Findings`, `Events` | Listas de hallazgos y eventos. |
| `Artifacts` | Filas de las tablas de la vista (mods, procesos, Prefetch...). |
| `Warnings`, `Limitations`, `Errors` | Avisos, límites forenses de esta ejecución y errores. |
| `Scope` | Ubicaciones analizadas. |
| `Data` | Datos adicionales (instancias, journals, actividad de la papelera...). |

### Context (`AmonSS.Context`)

Estado compartido de una revisión, creado por `New-AmonContext`:

| Campo | Descripción |
| --- | --- |
| `ReviewId` | `AMON-AAAAMMDD-HHMMSS-XXXXXX` (6 caracteres hexadecimales aleatorios). |
| `StartedUtc`, `SinceUtc`, `UntilUtc`, `Days` | Ventana de análisis. |
| `FixedUntil` | `$true` si el contexto se creó con un fin explícito (`-UntilUtc`). Si no, `Invoke-AmonModule` y `Invoke-AmonCorrelation` adelantan `UntilUtc` a "ahora" cada vez que empiezan, para que lo ocurrido durante la revisión entre en la ventana. `Start-AmonSS.ps1` no fija el fin. |
| `IsAdmin`, `UserName`, `UserSid`, `ComputerName`, `TimeZone` | Identidad y entorno. |
| `Settings` | Ajustes efectivos. |
| `AuthorizedScope` | Constancia de la revisión (usuario, equipo, fecha y si fue como administrador; el consentimiento lo cubren los términos de la SS del servidor), referencia del revisor, módulos ejecutados en modo no interactivo y rutas extra revisadas (se copian al reporte). |
| `Keywords` | Palabras clave de relevancia; crecen durante la revisión. |
| `IndicatorNames`, `IndicatorHashes` | Nombres de archivo y SHA-256 de los archivos con una detección `DETECTED` de firmas, que usan los módulos siguientes. |
| `EvidencePaths` | Rutas locales citadas por artefactos que merecen la pasada de firmas sobre evidencias (`Add-AmonEvidencePath` descarta las que no pasan `Test-AmonLocalPath`). |
| `ExtraScanPaths` | Rutas adicionales que el revisor autoriza durante la sesión (`Más opciones > X`). Viajan como dato y se incluyen en cada escaneo de firmas posterior. |
| `ScannedPaths` | Archivos escaneados por completo con firmas. Un escaneo de firmas completo lo vacía al empezar; la pasada de evidencias omite los que contiene. Un escaneo cortado por límites, tiempo o cancelación no se añade. |
| `Instances` | Instancias de Minecraft descubiertas. |
| `Signatures` | Conjunto de firmas cargado (una vez por sesión). |
| `Results` | Resultados por módulo (diccionario ordenado). |
| `HashCache` | Caché de hashes. |
| `Deadline`, `ModuleTimedOut`, `CancelRequested` | Control de tiempo y cancelación. |
| `OnProgress` | Callback de progreso. |
| `Log` | Registro interno de la sesión. |

### Correlación (`AmonSS.Correlation`)

Lo devuelve `Invoke-AmonCorrelation`, que además guarda su resultado de módulo en `Context.Results['Correlation']`:

| Campo | Descripción |
| --- | --- |
| `ClientVerdicts` | Un veredicto por cliente de las firmas: `ClientId`, `Client`, `Category`, `Status` (`CORRELATED`, `DETECTED`, `INCONCLUSIVE`, `NOT DETECTED` o `NOT COVERED`), `Justification`, `Confidence`, `Paths` y `FindingIds`. `NOT COVERED` solo existe aquí, no en los hallazgos. |
| `Correlated` | Hallazgos `ClientCorrelation` y `FileActivityCorrelation`. |
| `Conclusion` | Conclusión para revisión humana. |
| `Outcome` | Resultado global de una palabra: `INDICADORES ENCONTRADOS`, `REVISAR A MANO` o `SIN INDICADORES` (ver [README](../README.md#estados-de-resultado)). También se guarda en `Result.Data['Outcome']` y en el modelo del reporte. |
| `Summary` | Recuentos: `Correlated`, `Detected`, `Inconclusive`, `NotDetected`, `NotCovered` (clientes por estado) y `Findings`. |
| `Result` | El `AmonSS.ModuleResult` de la correlación. |

## Orden de investigación

`Invoke-AmonFullScan` (`Orchestrator.psm1`) ejecuta los módulos seleccionados en este orden fijo:

1. Minecraft
2. Firmas
3. Procesos
4. Memoria de Java
5. Prefetch
6. BAM
7. PCA y MUICache
8. ShimCache
9. Recent
10. UserAssist
11. Eventos
12. Evasión (servicios y hora)
13. Temp (JNativeHook siempre; copias de indicadores, solo si los hay)
14. Papelera
15. USN Journal
16. Firmas sobre evidencias nuevas (`SignaturesEvidence`): JAR citados por Prefetch, ejecutables de BAM, PCA y ShimCache, Recent, UserAssist, procesos, eventos, `$R` de la papelera... Solo se ejecuta si Firmas está seleccionado.
17. Correlación final y línea temporal.

El orden importa: Minecraft llena `Context.Instances`; Firmas carga el conjunto de firmas, registra el nombre y el hash de los archivos con una detección `DETECTED` (`Add-AmonIndicator`; las `INCONCLUSIVE` no) y añade las palabras clave de los clientes; Procesos aporta los `--gameDir` vivos como palabras clave; los módulos de Windows usan esos indicadores, palabras clave y nombres de herramientas para decidir qué es relevante y añaden rutas de evidencia locales (`Add-AmonEvidencePath`), que la pasada final escanea si todavía existen. Los módulos que necesitan administrador se ejecutan igualmente y devuelven `NoAccess`, de modo que el reporte deja constancia.

## Integridad del paquete

Una release se distingue de una copia de desarrollo por dos cosas que añade `tools\Build-Release.ps1`: la marca `$script:AmonReleaseBuild = $true` en su `Core.psm1` y el manifiesto `Integrity.psd1` en la raíz, con el SHA-256 de todos los archivos del paquete (`New-AmonIntegrityManifest`). El manifiesto se genera después de firmar los scripts y se firma a su vez, si la release se firma.

- `Get-AmonIntegrityManifest` carga el manifiesto una vez. Si no existe y el Core es de release, lanza "Paquete incompleto: falta Integrity.psd1. ..."; en una copia de desarrollo devuelve `$null` y ninguna comprobación se aplica. `Start-AmonSS.ps1` lo llama antes de leer la configuración, así que una release sin manifiesto no arranca.
- Con manifiesto, `Start-AmonSS.ps1` ejecuta además `Test-AmonPackageIntegrity` al arrancar y termina con código `1` si hay archivos alterados o ausentes, o añadidos dentro de `modules\`, `config\` o `signatures\`. Sin esta comprobación previa, un archivo alterado que se lee dentro de un módulo solo haría fallar ese módulo (`Invoke-AmonModule` aísla los errores) y la revisión seguiría con resultados incompletos.
- `Read-AmonVerifiedBytes` y `Read-AmonVerifiedText` leen el archivo **una vez** y comprueban el hash de esos mismos bytes, que son los que se devuelven: no hay ventana entre comprobar y usar. Un archivo del paquete que no figura en el manifiesto ("... no figura en Integrity.psd1.") o cuyo hash no coincide ("... no coincide con Integrity.psd1.") lanza una excepción. Los archivos fuera del paquete (ajustes del usuario) no se comprueban.
- Se leen así los `.cs` (antes de compilarlos), cada `signatures\*.json` y `config\settings.json` (`Read-AmonJsonFile`).
- `Assert-AmonPackageFolder` comprueba que no falta ningún archivo del manifiesto en una carpeta ("... falta <ruta>."). `Get-AmonSignatureSet` lo usa con `signatures\*.json`, porque borrar una firma cambiaría los veredictos sin dar error; una firma añadida la rechaza la lectura verificada.
- `Test-AmonPackageIntegrity` (lo usa `Start-AmonSS.ps1 -VerifyPackage`) compara todos los archivos y devuelve una fila por archivo con su estado: `ÍNTEGRO`, `ALTERADO`, `AUSENTE` o `NO INCLUIDO`.

Los scripts (`.ps1`, `.psm1`) y `config\themes.json` se comprueban en la verificación completa del arranque, no en cada lectura: un script ya se está ejecutando cuando podría comprobarse a sí mismo, así que su protección real es la firma Authenticode de una release firmada. Amon SS no comprueba la firma Authenticode de `Integrity.psd1` (lo lee con `Import-PowerShellDataFile`); en entornos `AllSigned` la comprueba PowerShell al cargar los scripts firmados, no el manifiesto.

## Código nativo

`Import-AmonNative` (en `Core.psm1`) compila el C# con `Add-Type` **una vez por proceso**: si el tipo `AmonSS.Native.PatternMatcher` ya existe, no hace nada. Como .NET no permite descargar tipos compilados, un cambio en los `.cs` necesita un proceso de PowerShell nuevo.

1. Lee `AmonNative.cs` y `AmonZip.cs` con `Read-AmonVerifiedText`: en una release, compara el SHA-256 de esos bytes con `Integrity.psd1` y lanza "Integridad del paquete comprometida: ..." si no coinciden. Se compila exactamente el texto verificado (ver [Integridad del paquete](#integridad-del-paquete)). En una copia de desarrollo no hay manifiesto y no se comprueba nada.
2. Compila los dos archivos como una sola unidad. Como el escáner ZIP necesita `System.IO.Compression`, prueba tres conjuntos de referencias: las predeterminadas (PowerShell 7 ya la incluye), `System.IO.Compression` más `System.dll`, y la ruta del ensamblado de `ZipArchive` más `System.dll` (Windows PowerShell 5.1).
3. Si ninguno funciona, compila solo `AmonNative.cs` y guarda el error en `$script:ZipNativeError`. `Test-AmonNativeZip` devuelve entonces `$false`, y `Jar.psm1` y `Signatures.psm1` usan sus respaldos en PowerShell (`Get-AmonJarNamesSlow`, `Find-AmonEntryNameHitsSlow` y el bucle de entradas), que producen el mismo resultado más despacio.

Tipos nativos:

| Tipo | Uso |
| --- | --- |
| `PatternMatcher` | Autómata Aho-Corasick sobre bytes (`ScanBytes`, `ScanStream`, `ScanFile`) que devuelve el primer desplazamiento de cada patrón. |
| `JarNames` | `Summarize` (nombres, clases, paquetes principales, JAR anidados, metadatos) y `Match` (paquetes, entradas y clases) en una sola pasada. |
| `ZipContentScanner` | Recorre las entradas de un `ZipArchive` y las pasa por el autómata, respetando los límites. |
| `Compression` | `DecompressMam`: Prefetch MAM (XPRESS Huffman) con `RtlDecompressBufferEx` de ntdll. |
| `Usn` | `ReadJournal` (`FSCTL_QUERY_USN_JOURNAL` y `FSCTL_READ_USN_JOURNAL`), `ParseRecords` (`USN_RECORD_V2` y `V3`), filtro (`UsnFilter`), `TrimToNewest` (al superar el máximo de resultados conserva los registros más recientes), resolución de rutas por referencia de archivo, `GetFinalPath` y `GetFileReference` (referencia NTFS de 64 bits con `GetFileInformationByHandle`, que el filtro compara con la referencia del directorio padre de cada registro). |
| `Volumes` | `QueryDosDevice`: letra de unidad a dispositivo NT. |
| `ProcessMemory` | `Scan`: abre un proceso con `PROCESS_QUERY_INFORMATION \| PROCESS_VM_READ` (o `PROCESS_QUERY_LIMITED_INFORMATION \| PROCESS_VM_READ`), recorre sus regiones con `VirtualQueryEx`, lee con `ReadProcessMemory` las comprometidas y legibles (sin `PAGE_GUARD` ni `PAGE_NOACCESS`) en bloques de 4 MB y las pasa por el autómata, con el estado a cero en cada región; devuelve los patrones, sus direcciones, los bytes y regiones leídos y si se cortó por tamaño o por tiempo. `ExtractAfter`: en las regiones privadas de lectura y escritura, devuelve sin repetir el texto ASCII imprimible que sigue a un marcador hasta un byte de parada (lo usa PCA para las trazas `PcaClient` de `explorer.exe`). |
| `AuditPolicy` | `QuerySubcategory`: estado de la auditoría de creación de procesos con `AuditQuerySystemPolicy`. |

Ninguna función nativa escribe en el sistema: los archivos y volúmenes se abren con acceso de lectura, o sin acceso cuando solo se consulta un nombre, y los procesos solo con permisos de consulta y de lectura de memoria. `ProcessMemory` no suspende el proceso ni conserva su contenido: solo qué patrones aparecen y dónde, o el texto que sigue al marcador.

## Rendimiento

- **Una pasada para todas las cadenas.** Todas las firmas `string` y `hex` (en cada codificación) forman un único autómata Aho-Corasick con una tabla de transiciones densa de 256 columnas. El estado se conserva entre bloques de lectura, así que un patrón partido entre dos bloques también se detecta. Cada archivo se recorre una vez sea cual sea el número de firmas.
- **Bucle ZIP en C#.** La lista de nombres, los paquetes, los metadatos y el contenido de cada entrada se procesan en C# (`JarNames`, `ZipContentScanner`) en lugar de entrada por entrada en PowerShell.
- **Índices hash** para paquetes, entradas, clases, ids de mod, SHA-256 y MANIFEST.
- **Caché de hashes** por (algoritmo, ruta, tamaño, fecha de modificación) en `Context.HashCache`: Minecraft, Firmas y Temp no recalculan el mismo SHA-256.
- **La pasada de evidencias no repite trabajo:** omite los archivos que el escaneo de firmas ya revisó por completo (`Context.ScannedPaths`). El conjunto de firmas se carga una vez por sesión (`Context.Signatures`).
- **Filtrado del USN Journal en C#**, con caché de rutas resueltas; a PowerShell solo llegan los registros relevantes. Mientras se lee, cada vez que la lista llega al doble de `maxUsnResults` se recorta a ese máximo, y al terminar se recorta otra vez; siempre se conservan los registros más recientes.
- **Prefetch decide la relevancia antes de traducir rutas:** une los nombres en bruto en una sola cadena y busca en ella los indicadores; solo los Prefetch relevantes pagan la conversión de rutas y el análisis por archivo. En una medición con 401 `.pf` sintéticos, el módulo pasó de 43,3 s a 4,6 s en Windows PowerShell 5.1 y a 1,9 s en PowerShell 7.4.6. El mapa de volúmenes solo consulta discos locales (fijos y extraíbles), con un tiempo máximo de 15 s para la consulta CIM.
- **Memoria en C#.** El escáner de memoria lee y busca en C# (`ProcessMemory.Scan`) con el mismo autómata Aho-Corasick, en bloques de 4 MB y con un máximo de 3 GB y 60 s por proceso. Las trazas del Explorador se extraen también en C# (`ExtractAfter`), con un máximo de 2 GB y 45 s.
- **Una expresión regular por lista de palabras clave.** BAM, PCA y ShimCache comparan miles de rutas: en lugar de un bucle de `IndexOf` por palabra clave en PowerShell, construyen una sola expresión regular por lista (palabras clave de clientes y palabras clave de la revisión), que se rehace solo si la lista crece. Medido en el equipo del autor: PCA, entre 1,5 y 4,6 s según la memoria del Explorador; ShimCache, unos 0,6 s.
- **Firmas Authenticode con caché.** BAM y PCA comprueban la firma de cada ejecutable una sola vez por ruta (`Get-AmonCachedSignature`), y Procesos tiene su propia caché.
- **Pocas consultas CIM en evasión.** La instantánea de servicios del módulo de evasión hace 3 consultas CIM (todos los servicios, el controlador `bam` y los procesos que alojan los servicios forenses) en lugar de una por servicio; en el equipo del autor, el módulo tardó 1,6 s. La hora del último arranque es otra consulta (`Win32_OperatingSystem`), y el mapa de volúmenes solo se pide si hay un cambio de hora grande que traducir.
- **Límites configurables** (`limits` en `settings.json`) para tamaños de JAR, entradas, bytes descomprimidos, profundidad de anidamiento, logs, resultados del USN, filas de tabla y archivos de Temp.
- **Progreso limitado** a unos 14 refrescos por segundo; sin VT, una línea por cada 25 %.

## Cancelación y tiempo máximo

- `Invoke-AmonModule` fija `Context.Deadline` a `moduleTimeoutSeconds` (180 s por defecto) y aísla los errores: un módulo que lanza una excepción queda `Failed` con el error registrado y el escaneo continúa.
- Los bucles largos llaman a `Test-AmonCancel`, que comprueba el plazo y, si la consola entrega Ctrl+C como entrada (`[Console]::TreatControlCAsInput`, activado mientras dura un análisis), si se pulsó Ctrl+C. No hay hilos ni trabajos en segundo plano: la cancelación es cooperativa.
- Al agotarse el tiempo, el resultado pasa a `Partial` con la limitación correspondiente; con Ctrl+C pasa a `Cancelled` y el escaneo completo se detiene, conserva los resultados parciales y lo hace constar en el reporte.
- La lectura nativa del USN Journal recibe el mismo plazo y devuelve `TimedOut`. La lectura de memoria de un proceso recibe como plazo el menor entre 60 s y el del módulo, y la de las trazas del Explorador, 45 s. El escaneo del contenido de un JAR en C#, la lectura de memoria y las consultas a los registros de eventos no comprueban Ctrl+C por dentro: se interrumpen entre archivos, procesos o fuentes. Los JAR anidados sí comprueban la cancelación, el tiempo y el total descomprimido antes de abrir cada uno.
- Un error al interpretar un artefacto concreto (un log de Minecraft, un metadato de un JAR, un Prefetch dañado) se anota y no detiene el módulo.

## Interfaz

- Las funciones `Format-*` de `UI.psm1` son puras: devuelven líneas de texto (con secuencias ANSI si el modo de color lo permite) y se prueban con Pester. Las funciones `Write-*` y `Show-*` las pintan; sin soporte VT, `Write-AmonSegments` traduce los colores a `Write-Host -ForegroundColor`.
- Los menús de la revisión automática leen una sola tecla con `Read-AmonKey` (`[Console]::ReadKey`, sin Enter), con una lista de teclas aceptadas, un valor por defecto y un tiempo máximo opcional (10 s en el aviso de administrador). Con la entrada redirigida, cada tecla llega como una línea: se usa su primer carácter, una línea vacía es Enter y el fin de la entrada devuelve el valor por defecto. Las rutas se siguen pidiendo con `Read-AmonInput` y viajan como dato, nunca como texto de código.
- Todo dato que viene de artefactos pasa por `ConvertTo-AmonSafeText`, que elimina los caracteres de control C0/C1 (incluido ESC).
- Como defensa en profundidad, `Format-AmonBox` pasa cada línea por `ConvertTo-AmonTerminalLine`, que solo conserva las secuencias de color SGR (`ESC[...m`) y elimina cualquier otro control (borrado de pantalla, movimiento del cursor, OSC, BEL), y sanea el título y la etiqueta derecha de la caja.
- El reporte TXT aplica su propia limpieza a cada línea: sustituye los saltos de línea incrustados por espacios y elimina los caracteres de control, así que un dato no puede falsificar líneas del reporte.
- `Restore-AmonConsole` devuelve la consola a su codificación y colores originales al salir, incluso si hay un error (bloque `finally`).

## Qué recibe, qué produce y qué nunca hace cada módulo

| Módulo | Entradas | Salidas | Nunca |
| --- | --- | --- | --- |
| Minecraft | Ajustes, rutas de launchers, `--gameDir` de Java (CIM) | `Context.Instances` (sustituidas en cada análisis); instancias, sesiones, versiones y mods; hallazgos; eventos; rutas de evidencia (agentes, JAR de versión modificados) | Leer archivos de cuentas (`launcher_accounts*.json`, credenciales); ejecutar JAR; usar como instancia un `gameDir` de red |
| Signatures | Instancias, `scan.extraScanPaths`, `Context.ExtraScanPaths`, rutas de evidencia | Hallazgos por cliente; tabla de archivos escaneados; `IndicatorNames` e `IndicatorHashes` (solo detecciones `DETECTED`) y palabras clave | Ejecutar o cargar código de los archivos; modificar archivos |
| Processes | `Win32_Process`, lista de módulos de cada Java, Authenticode, nombres de herramientas | Procesos relevantes; hallazgos (agentes, JNativeHook, herramientas); eventos; rutas de evidencia | Finalizar procesos; leer su memoria; mostrar procesos no relacionados |
| Memory | Memoria de los `java.exe`/`javaw.exe` vivos, conjunto de firmas | Procesos escaneados; hallazgos `ClientMemory`; eventos | Escribir, suspender o volcar la memoria; guardar su contenido |
| Prefetch | `C:\Windows\Prefetch\*.pf`, mapa de volúmenes, `EnablePrefetcher` | Prefetch relevantes; ejecuciones; JAR referenciados; hallazgos | Mostrar Prefetch no relacionados (solo los cuenta); escribir en Prefetch |
| BAM | `HKLM\...\Services\bam\State\UserSettings\<SID>` | Ejecutables relevantes; eventos; hallazgos; rutas de evidencia | Mostrar ejecutables no relacionados (solo los cuenta); escribir en el registro |
| PCA | `C:\Windows\appcompat\pca\*.txt`, `Compatibility Assistant\Store`, `MuiCache`, memoria del `explorer.exe` del usuario | Entradas relevantes; eventos; hallazgos; rutas de evidencia | Mostrar entradas no relacionadas; guardar la memoria del Explorador (solo las rutas tras el marcador) |
| ShimCache | Valor `AppCompatCache` | Entradas relevantes; eventos; hallazgos; rutas de evidencia | Presentar la caché como prueba de ejecución; mostrar entradas no relacionadas |
| Recent | `%APPDATA%\Microsoft\Windows\Recent\*.lnk` | Accesos relevantes; eventos; hallazgos | Mostrar documentos personales (solo los cuenta); interpretar Jump Lists; comprobar destinos de red |
| UserAssist | `HKCU\...\Explorer\UserAssist\{GUID}\Count` | Entradas relevantes; eventos; hallazgos | Escribir en el registro |
| Events | Registros Security, System, Ntfs/Operational, Application y Defender; política de auditoría; claves Run | Eventos y entradas; hallazgos; rutas de evidencia (drivers, DLL de caídas) | Cambiar la auditoría; vaciar o escribir registros |
| Tamper | `Win32_Service`, `Win32_SystemDriver`, `Win32_Process`, `Win32_OperatingSystem`, registro System | Servicios forenses; hallazgos; eventos | Iniciar, detener o reconfigurar servicios; cambiar la hora |
| Temp | `%TEMP%` (primer nivel para JNativeHook; hasta 3 niveles si hay indicadores) | DLL de JNativeHook; coincidencias por nombre o SHA-256 | Revisar el resto de Temp sin indicadores concretos |
| RecycleBin | `$Recycle.Bin\<SID>` de cada unidad fija | Elementos relevantes; RECYCLE BIN ACTIVITY; hallazgos; rutas `$R` para escanear | Restaurar, mover o eliminar nada; atribuir intención |
| USNJournal | USN Journal de la unidad del sistema y de las instancias | Journals; registros relevantes; actividad de papelera reconstruida; hallazgos | Modificar, truncar ni eliminar el journal; exponer registros no relevantes |
| Correlation | Hallazgos, eventos y mods de todos los módulos | Hallazgos `CORRELATED`, veredicto por cliente (con `NOT COVERED`), resultado global, conclusión y filas "Actividad correlacionada" de la papelera (rehechas en cada correlación) | Relacionar hallazgos solo por proximidad temporal o por un nombre genérico; emitir sanciones |
| Timeline | Eventos de todos los módulos | Filas ordenadas, sin duplicados, con hora local y zona | Interpolar o inventar horas |
| Reports | Contexto, correlación y línea temporal | TXT, JSON, HTML y manifiesto `.sha256` | Copiar contenido de archivos; cargar recursos externos en el HTML |
| Update | Repositorio configurado y SHA-256 aportado por el operador | Nueva versión en `%LOCALAPPDATA%\AmonSS\versions\<versión>` | Actualizar sin petición ni sin hash; tocar la instalación actual o las políticas |

El detalle funcional de cada módulo está en [MODULES.md](MODULES.md).
