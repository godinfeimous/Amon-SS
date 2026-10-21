# Pruebas

La batería usa **Pester 5** (`tests\*.Tests.ps1`) y está pensada para ejecutarse igual en Windows PowerShell 5.1 y en PowerShell 7.

## Cómo ejecutarlas

Requisito: Pester 5.5 o posterior dentro de la serie 5.x (el proyecto usa 5.7.1):

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -SkipPublisherCheck
```

Desde la raíz del repositorio:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AmonTests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AmonTests.ps1 -Integration
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AmonTests.ps1 -Integration -Admin
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AmonTests.ps1 -Integration -OutputXml resultados.xml
pwsh -NoProfile -File tests\Invoke-AmonTests.ps1 -Integration
```

| Parámetro | Efecto |
| --- | --- |
| (ninguno) | Solo las pruebas `Unit`. |
| `-Integration` | Añade las pruebas `Integration`. |
| `-Admin` | Añade las pruebas `Admin` (ejecuta la consola como administrador). |
| `-OutputXml <ruta>` | Guarda los resultados en formato NUnit XML. |
| `-Path <rutas>` | Ejecuta solo los archivos o carpetas indicados. |

El script busca Pester entre las versiones 5.5.0 y 6.0.0, muestra la versión de Pester y de PowerShell y las etiquetas activas, usa salida detallada y termina con código `1` si alguna prueba falla (`0` si todas pasan).

Desde VS Code, `.vscode\launch.json` incluye la configuración "Pruebas Pester (unitarias + integración)".

## Etiquetas

| Etiqueta | Significado | Toca el sistema |
| --- | --- | --- |
| `Unit` | Fixtures sintéticos en la carpeta temporal de Pester (`$TestDrive`) o en memoria | No |
| `Integration` | Lectura del Windows real (procesos, papelera propia, Recent, UserAssist, eventos, USN Journal, referencia NTFS) y pruebas que lanzan procesos nuevos de PowerShell sobre `Start-AmonSS.ps1` o sobre copias del paquete en `$TestDrive` | Solo lectura (fuera de `$TestDrive`) |
| `Admin` | Necesitan elevación: Prefetch real | Solo lectura |

Pruebas `Integration` y `Admin` actuales:

- Procesos: inspecciona los procesos reales sin modificarlos.
- Papelera: lee la papelera del usuario actual.
- USN Journal: sin privilegios comprueba que el módulo informa `NoAccess`; con privilegios, que lee el journal (`Completed` o `Partial`).
- Recent, UserAssist y eventos: se leen sin errores (`Completed` o `Partial`).
- Referencia NTFS: `GetFileReference` devuelve el mismo identificador que `fsutil file queryFileID` para un archivo de `$TestDrive` (si `fsutil` no devuelve un identificador, la prueba se marca como omitida).
- Punto de entrada (`Start.Tests.ps1`): ejecuta `Start-AmonSS.ps1` en procesos nuevos, con la entrada redirigida en modo interactivo y en modo no interactivo (un escaneo `RecycleBin` con reportes en `$TestDrive`).
- Integridad del paquete (`Integrity.Tests.ps1`): crea copias mínimas del paquete en `$TestDrive`, con y sin `Integrity.psd1`, y las prueba en procesos nuevos (los tipos C# no se pueden recargar en el mismo proceso).
- Prefetch real (`Admin`): interpreta los Prefetch del equipo y revisa más de cero archivos.

Para comprobar los módulos de administrador con datos reales fuera de Pester, `tools\Invoke-AmonAdminCheck.ps1` resume Prefetch, USN Journal y eventos desde una consola elevada (ver [INSTALL.md](INSTALL.md#ejecutar-como-administrador)).

## Fixtures sintéticos

Ninguna prueba unitaria depende de artefactos reales. Los fixtures se generan en cada ejecución:

| Fixture | Dónde | Qué reproduce |
| --- | --- | --- |
| Prefetch SCCA v30 | `tests\Helpers\PrefetchFixture.ps1` (`New-AmonTestPrefetchBytes`) | Cabecera `SCCA`, nombre del ejecutable, hasta 8 últimas ejecuciones, contador de ejecuciones en las dos variantes de v30, cadenas de archivos y una entrada de volumen con ruta `\VOLUME{...}`, serie y directorios. Estructura según la documentación pública del formato. |
| Prefetch MAM real | `ConvertTo-AmonTestMam` | Comprime el fixture con `RtlCompressBuffer` (XPRESS Huffman) de ntdll y añade la cabecera `MAM\x04` con el tamaño: prueba la descompresión real con `RtlDecompressBufferEx`, no una simulación. |
| `$I` v1 y v2 | `tests\RecycleBin.Tests.ps1` | v1 de 544 bytes (Vista/7/8) y v2 con longitud de ruta (Windows 10/11); parejas `$I`/`$R` en una carpeta temporal, con `$R` ausente, `$R` sin `$I`, tamaños que no coinciden y fechas fijadas. |
| LNK | `tests\WindowsArtifacts.Tests.ps1` (`New-LnkBytes`) | `ShellLinkHeader` con su CLSID, `LinkInfo` con `VolumeID` (tipo, serie, etiqueta) y `LocalBasePath`, fechas y tamaño del destino, y argumentos Unicode opcionales. |
| UserAssist | `New-UserAssistData` | Estructura de 72 bytes: contador (+4), veces con foco (+8), milisegundos con foco (+12) y última ejecución FILETIME (+60). |
| `USN_RECORD_V2` | `tests\USNJournal.Tests.ps1` (`New-UsnV2Bytes`) | Registros binarios consecutivos con referencias de archivo y padre, USN, fecha, motivos y nombre UTF-16, alineados a 8 bytes, que se interpretan con el parser nativo. También registros inyectados (`AmonSS.Native.UsnRecordInfo`) para el análisis completo: envíos a la papelera, purgas, borrados de Prefetch y logs, y journal que no cubre el periodo. |
| JAR en memoria | `tests\Helpers\TestBootstrap.ps1` (`New-AmonTestJarBytes`, `New-AmonTestJar`) | ZIP construidos con `System.IO.Compression`: `fabric.mod.json`, `mods.toml`, `neoforge.mods.toml`, `mcmod.info`, MANIFEST con `Premain-Class`, clases (`CAFEBABE...`), JAR anidados y contenido comprimido que no se ve en bruto. |
| Logs `.gz` | `New-AmonTestGzip` | Logs rotados comprimidos con GZip para probar la lectura y la fecha de sesión deducida del nombre. |
| Logs de texto | `tests\Minecraft.Tests.ps1` | Listas de mods de Fabric (formato actual, con `Setting user`, y formato antiguo), Forge y Lunar Client (`[LC]` y recursos cargados). |
| Eventos inyectados | `Invoke-AmonEventAnalysis -Injected` | Fuentes de eventos simuladas: 4688, 1102, auditoría desactivada y claves Run. |
| Instancias | `Invoke-AmonMinecraftAnalysis -Roots` | Árboles `Roaming`, `Home` y `Local` falsos con `.minecraft`, perfiles de Lunar e instancias de Prism. |
| Copias del paquete | `tests\Integrity.Tests.ps1` (`New-PackageCopy`) | Copia mínima (`Start-AmonSS.ps1`, `config`, `modules`, `signatures`) en `$TestDrive`, opcionalmente con la marca de release en `Core.psm1` y con `Integrity.psd1` generado por `New-AmonIntegrityManifest`, como la que produce `Build-Release.ps1`. |

Otras utilidades de `TestBootstrap.ps1`: `Import-AmonTestModule` (recarga Core y los módulos pedidos), `New-AmonTestContext` (contexto con un archivo de ajustes de usuario inexistente, para no depender de los ajustes del equipo), `ConvertTo-AmonFileTimeBytes`, `Write-AmonBytesAt` y `Remove-AmonAnsi`.

## Qué se prueba

| Archivo | Áreas |
| --- | --- |
| `Core.Tests.ps1` | Hallazgos y eventos, FILETIME, hashes SHA-256 y SHA-1, lectura de archivos abiertos por otro proceso, límites de lectura, ocultación de secretos, palabras clave, rutas locales frente a rutas de red (`Test-AmonLocalPath` y rutas de evidencia), ventana temporal que avanza sin fin explícito y fin explícito respetado, ajustes combinados y persistidos, aislamiento de errores y tiempo máximo de módulo |
| `Correlation.Tests.ps1` | Correlación firma más log, `DETECTED` sin otras fuentes, confianza media con firmas no validadas, clientes sin firmas como `INCONCLUSIVE`, `NOT DETECTED`, ausencia de relaciones inventadas, papelera más USN sin duplicar la actividad correlacionada, sesión del propio log que no cuenta como segunda fuente, `javaw.exe` que no se une con cualquier Prefetch, USN de varias unidades como una sola fuente, línea temporal (orden, ventana, duplicados, zona horaria, resaltado), reportes (formatos, JSON con ISO 8601, verificación de integridad, escape HTML, TXT sin secuencias de control ni líneas falsificadas, conclusión) |
| `Integrity.Tests.ps1` | Paquete íntegro (se verifica entero y carga sus firmas), firma alterada, añadida o borrada, `.cs` alterado que no se compila, release sin manifiesto que no se ejecuta frente a copia de desarrollo que sí, y códigos de salida de `-VerifyPackage` |
| `Jar.Tests.ps1` | Metadatos de Fabric, Forge (sin ids de dependencias), NeoForge, `mcmod.info`, javaagent, JAR anidados, metadato con deflate dañado que no impide leer el resto y archivos que no son ZIP |
| `Minecraft.Tests.ps1` | Logs (Fabric, Forge, `.gz`, Lunar, fecha imposible en el nombre), descubrimiento de instancias, mods instalados frente a cargados, mods eliminados, id de mod con caracteres comodín y perfiles de versión (`-javaagent`, clase principal, SHA-1) |
| `Native.Tests.ps1` | Aho-Corasick (varios patrones, mayúsculas, barras invertidas, patrones partidos entre bloques, límite de bytes, patrones vacíos) y referencia NTFS (`GetFileReference` frente a `fsutil file queryFileID`, etiqueta `Integration`) |
| `Prefetch.Tests.ps1` | Parser SCCA (variantes de v30), MAM, rechazo de datos no válidos, rutas `\VOLUME{...}` y módulo sobre una carpeta sintética |
| `Processes.Tests.ps1` | Línea de comandos de Java (gameDir con espacios, agentes, `-Dfabric.addMods`, classpath, `-jar`, token oculto), clasificación de DLL y argumentos JVM de clientes (sin validar `INCONCLUSIVE`, validado `DETECTED`) |
| `RecycleBin.Tests.ps1` | `$I` v1, v2 y desconocido; eliminaciones relevantes, privacidad, `$R` ausente, `$R` sin `$I`, tamaño incoherente y contenedor modificado |
| `Signatures.Tests.ps1` | Validez de las definiciones, campos obligatorios ausentes, cadenas exactas de Doomsday, Nova y Prestige, clientes sin indicadores, Meteor con confianza alta, cadenas en clases comprimidas, límites de confianza, JAR anidados y su límite total descomprimido, subcadenas, mod legítimo sin detección y módulo completo sobre una instancia (rutas adicionales de la sesión, detecciones no concluyentes que no se registran como indicador, análisis repetidos que vuelven a escanear sin duplicar instancias) |
| `Start.Tests.ps1` | Punto de entrada: sin consentimiento no analiza nada, menú interactivo con entrada redirigida, Enter vacío que no cierra la sesión, ausencia de código construido a partir de la entrada del usuario, código `2` sin `-Consent`, código `1` de `-VerifyManifest` con un reporte alterado, formatos de reporte no válidos y exportación verificable |
| `UI.Tests.ps1` | Medición de texto con ANSI, truncado, rutas, color, `NO_COLOR`, temas y glifos, cajas, tablas, banner (normal y compacto), menú, tarjetas, limpieza de caracteres de control y cajas que conservan el color pero no borran la pantalla, mueven el cursor ni cambian el título |
| `Update.Tests.ps1` | Comparación de versiones (con o sin prefijo `v`, etiquetas que no son versión) y validación del nombre del repositorio |
| `USNJournal.Tests.ps1` | Motivos, `USN_RECORD_V2`, nombre original de lo enviado a la papelera, recorte que conserva los registros más recientes, filtro sin la carpeta Prefetch ni borrados de comprimidos o logs, purgas, borrados de Prefetch y logs, `.pf` no relacionado contado sin nombre, cobertura del journal, privacidad (documentos y comprimidos personales) y fiabilidad de rutas |
| `WindowsArtifacts.Tests.ps1` | LNK, ROT13, datos de 72 bytes, carpetas conocidas, eventos 1102 frente a papelera, auditoría desactivada y claves Run |

## Estado verificado

Ejecución del 2026-10-21 en el equipo del autor: Windows 11 Pro build 26200, sesión **sin elevar**, Pester 5.7.1, con `-Integration`.

| Entorno | Descubiertas | Superadas | Fallidas | No ejecutadas |
| --- | --- | --- | --- | --- |
| Windows PowerShell 5.1.26100 | 199 | 198 | 0 | 1 (`Admin`: Prefetch real) |
| PowerShell 7.4.6 | 199 | 198 | 0 | 1 (`Admin`: Prefetch real) |

Los resultados incluyen `Integrity.Tests.ps1`, `Update.Tests.ps1` y la prueba de la referencia NTFS de `Native.Tests.ps1`.

Ejecuciones reales en el mismo equipo y sesión sin elevar:

- Escaneo completo no interactivo en unos **32 s con PowerShell 5.1** (tras la revisión de código; antes, 40 s). El tiempo con PowerShell 7 (41 s) es de la ejecución anterior.
- **6 instancias** de Minecraft: la vanilla (`.minecraft`) y 5 perfiles de Lunar Client.
- **171 JAR de las instancias** y 3 archivos citados por otros módulos escaneados con firmas **sin ningún falso positivo**.
- **12 perfiles de versión** verificados con el SHA-1 que declara Mojang.

**No verificado en un sistema real:** Prefetch, USN Journal y el registro de Seguridad no se ejecutaron sobre datos reales porque la sesión no estaba elevada. Solo los cubren las pruebas sintéticas descritas arriba (y, en el caso del USN Journal, la prueba de integración que comprueba que sin privilegios informa `NoAccess`). Falta ejecutarlos como administrador, por ejemplo con:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AmonTests.ps1 -Integration -Admin
```

y con un escaneo completo elevado.

## Integración continua (GitHub Actions)

`.github\workflows\ci.yml` se ejecuta en cada push a `main`, en cada pull request y a mano (`workflow_dispatch`):

| Trabajo | Entorno | Pasos |
| --- | --- | --- |
| Codificación y firmas (`checks`) | `windows-latest`, `pwsh` | `tools\Repair-Encoding.ps1 -Check` (todos los `.ps1`, `.psm1` y `.psd1` en UTF-8 con BOM) y PSScriptAnalyzer con `PSScriptAnalyzerSettings.psd1`: se muestran los errores y los avisos, pero **solo los errores bloquean**. |
| Pester (`tests`) | `windows-latest`, matriz `powershell` (Windows PowerShell 5.1) y `pwsh` (PowerShell 7) | Depende de `checks`. Instala Pester 5.7.1 y ejecuta `tests\Invoke-AmonTests.ps1 -Integration` con salida NUnit, que se sube como artefacto `test-results-<shell>`. Al lanzarlo a mano se puede marcar la opción `admin` para añadir `-Admin`. |

`PSScriptAnalyzerSettings.psd1` analiza los niveles Error y Warning, y excluye `PSAvoidUsingWriteHost` (la interfaz escribe en la consola a propósito), `PSUseSingularNouns`, `PSUseShouldProcessForStateChangingFunctions` (las funciones `New-`/`Set-` internas no modifican el sistema) y `PSUseBOMForUnicodeEncodedFile` (el BOM lo comprueba `Repair-Encoding.ps1`).

`.github\workflows\release.yml` se ejecuta al publicar una etiqueta `v*.*.*`: comprueba que la etiqueta coincide con la versión de `modules\Core.psm1`, ejecuta `tools\Build-Release.ps1` (que vuelve a pasar las pruebas unitarias, valida las firmas y genera `Integrity.psd1`) y publica el ZIP, `SHA256SUMS.txt` e `INSTALL-CMD.txt` con las notas de la versión. `Build-Release.ps1` solo ejecuta las pruebas `Unit`: las de `Integrity.Tests.ps1` son `Integration` y se ejecutan en el trabajo de Pester de `ci.yml`.

## Escribir pruebas nuevas

- Carga el entorno en `BeforeAll` con `. (Join-Path $PSScriptRoot 'Helpers\TestBootstrap.ps1')` e `Import-AmonTestModule <Módulos>`.
- Etiqueta cada `Describe` con `Unit`, `Integration` o `Admin`. Las pruebas `Unit` no deben leer el sistema real: usa `$TestDrive`, los parámetros de inyección de los módulos (`-Roots`, `-Snapshot`, `-RawEntries`, `-Injected`, `-ScanResults`, `-Folders`, `-Path`, `-VolumeMap`) o los generadores de fixtures.
- Las pruebas `Integration` y `Admin` deben ser de solo lectura y aceptar los estados `Completed`, `Partial` o `NoAccess` según los privilegios.
- Los tipos C# no se pueden recargar en el mismo proceso. Si una prueba necesita compilar código nativo distinto, lánzala en un proceso nuevo, como hacen las pruebas de `Integrity.Tests.ps1`.
- Guarda los archivos en UTF-8 con BOM (`tools\Repair-Encoding.ps1` lo corrige).
