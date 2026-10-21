# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versionado [SemVer](https://semver.org/lang/es/).

## [1.1.0] - 2026-10-21

### Añadido

- **Java Memory Scanner** (`modules\Memory.psm1`, sin administrador): busca las firmas en la memoria de los `java.exe`/`javaw.exe` en ejecución con `OpenProcess` (`PROCESS_QUERY_INFORMATION | PROCESS_VM_READ`), `VirtualQueryEx` y `ReadProcessMemory` (clase C# `ProcessMemory` de `AmonNative.cs`). Solo recorre regiones comprometidas y legibles, no guarda nada del contenido y se limita a 3 GB y 60 s por proceso. Patrones: paquetes de las firmas en forma interna (`a/b/`) y Java (`a.b.`), clases de entrada en las dos formas, cadenas `string` de 10 o más caracteres y el tipo nuevo `memory`, en ASCII y UTF-16LE. Aplica las mismas reglas de confianza que el escáner de archivos (`Get-AmonSignatureDetections`). Categoría `ClientMemory`, que sirve de ancla de correlación y cuenta como ejecución. Sin Java abierto queda `OMITIDO` y pide abrir Minecraft antes de la revisión.
- **BAM** (`modules\ExecutionArtifacts.psm1`, requiere administrador): `HKLM\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings\<SID>` (o la ruta antigua `bam\UserSettings`), con la última ejecución en los 8 primeros bytes (FILETIME) y las rutas `\Device\HarddiskVolumeN` traducidas a letra de unidad.
- **PCA & MUICache** (sin administrador): `C:\Windows\appcompat\pca\PcaAppLaunchDic.txt` (ANSI, `ruta|AAAA-MM-DD HH:MM:SS.fff` en UTC; Windows 11 22H2 o posterior; solo lanzamientos desde la interfaz gráfica; avisa de las líneas truncadas), `PcaGeneralDb0.txt`/`PcaGeneralDb1.txt` (UTF-16LE, 8 campos; el tipo 2 es una salida anormal del proceso), `Compatibility Assistant\Store` y `MuiCache` de HKCU (sin fecha), y las trazas `TRACE,...,PcaClient,MonitorProcess,<ruta>` de la memoria del `explorer.exe` del mismo usuario (sin hora; la función nativa `ExtractAfter` solo extrae el texto que sigue al marcador).
- **ShimCache** (sin administrador): `AppCompatCache` de Windows 10/11 (cabecera `0x34`, entradas `10ts`). No prueba ejecución y Windows solo lo escribe al apagar.
- Reglas comunes de BAM, PCA y ShimCache: solo se muestran los ejecutables relevantes (indicador concreto, herramienta conocida por nombre de archivo o palabra clave) y el resto se cuenta. En BAM y PCA, además, un hallazgo `INFO` "Ejecutado desde una carpeta de usuario" (`RecentUnsignedExecutable`) para los ejecutables del periodo lanzados desde Descargas, Escritorio, Documentos, Temp u otra unidad que no tienen firma válida o ya no existen (AppData queda fuera por los programas que se actualizan solos). Las herramientas de SS conocidas (`knownScreenshareTools`, de momento Ocean) no se listan como "para revisar".
- **Bypass & Tamper Check** (`modules\Tamper.psm1`, sin administrador): servicios SysMain, PcaSvc, DPS y EventLog y el controlador `bam` detenidos o deshabilitados (`ServiceDisabled`, `INCONCLUSIVE`: muchos tweaks lo hacen) o reiniciados más de 10 minutos después del arranque (`ServiceRestarted`, por la hora del proceso que los aloja y solo si no es compartido); eventos 7040 de cambio del tipo de inicio (`ServiceStartTypeChanged`, `DETECTED`) y 7031/7034 de caída (`ServiceCrashed`) dentro del periodo; y cambios de la hora del sistema de 2 minutos o más (System, Kernel-General id 1, con el programa que la cambió: `SystemTimeChanged`, `DETECTED`). El evento 7036 no se usa porque Windows 11 ya no lo registra (comprobado en la build 26200).
- Eventos nuevos en Windows Event Analysis, sin administrador: 7045, servicio o driver instalado desde una carpeta de usuario (`DriverInstalled`, `INCONCLUSIVE`; `INFO` "Driver de la herramienta de SS" si coincide con `knownScreenshareTools`); Ntfs/Operational 501, USN Journal eliminado por un proceso distinto de SearchIndexer (`UsnJournalDeleted`, `DETECTED`, severidad alta); Defender 5007, exclusión añadida (`DefenderExclusion`, `INCONCLUSIVE`), y 5001, protección en tiempo real desactivada (`DefenderDisabled`, `INCONCLUSIVE`); Application Error 1000 de Java o de un launcher con el módulo culpable fuera del runtime y de Windows (`JavaCrashForeignModule`, `INCONCLUSIVE`; la DLL se escanea con las firmas).
- Procesos: `instrument.dll` cargada sin `-javaagent`, `-agentpath` ni `-agentlib` en la línea de comandos indica un agente Java cargado en caliente (`RuntimeAgent`, `INCONCLUSIVE`); un módulo `JNativeHook*.dll` cargado indica un programa Java que captura el teclado y el ratón (`GlobalInputHook`, `INCONCLUSIVE`); un proceso cuyo nombre coincide con una firma `filename` es una herramienta en ejecución (`ToolExecution`).
- Prefetch: herramientas por nombre de archivo (firmas `filename`, también con el nombre truncado a 29 caracteres) como `ToolExecution`, y programas ejecutados dentro del periodo desde un volumen que ya no está conectado o desde una unidad extraíble (`DetachedVolumeExecution`, `INCONCLUSIVE`; BAM no registra las ejecuciones desde USB).
- Firmas: tipos de indicador `filename` (nombre exacto de un ejecutable o DLL; índice `FileNames` que usan Prefetch, BAM, PCA, ShimCache y Procesos) y `memory` (cadenas para el escáner de memoria, 10 o más caracteres); categorías `autoclicker`, `macro`, `injector` y `bypass`, además de `cheat-client`, `dual-use` y `framework`. Un nombre de herramienta validado o de fuerza media o fuerte da `DETECTED` (`New-AmonToolFinding`); uno débil sin validar, `INCONCLUSIVE`.
- Estado de veredicto `NOT COVERED` ("no comprobables por archivo") y resultado global de una palabra (`Correlation.Outcome`, también en los reportes TXT, JSON y HTML): `INDICADORES ENCONTRADOS`, `REVISAR A MANO` o `SIN INDICADORES`. `Summary.NotCovered` cuenta los clientes sin cobertura.
- Core: `Test-AmonUserWritablePath`, `Get-AmonScreenshareTool`, `Get-AmonToolByFileName` y `New-AmonToolFinding`. Ajustes nuevos: `modules.Memory`, `modules.BAM`, `modules.PCA`, `modules.ShimCache` y `modules.Tamper` (activados) y `knownScreenshareTools`.
- `Read-AmonKey` (`UI.psm1`): lectura de una tecla sin Enter, con tiempo máximo opcional. Con la entrada redirigida, cada tecla llega como una línea.
- Parámetros `-NoElevate` (no ofrece reabrir como administrador) y `-Elevated` (interno). `-Scan` admite `Memory`, `BAM`, `PCA`, `ShimCache` y `Tamper`.
- `tools\Invoke-AmonAdminCheck.ps1` también resume BAM.
- Pruebas: `tests\ExecutionArtifacts.Tests.ps1` (ShimCache, BAM, PCA y evasión), `tests\Memory.Tests.ps1` y `tests\TempSweep.Tests.ps1`; `Native.Tests.ps1` añade el escaneo de memoria entre procesos y la extracción tras un marcador; casos nuevos en las pruebas de procesos, firmas, artefactos de Windows y correlación.
- **Firmas de la investigación del 2026-10-21:** de 25 clientes y 148 indicadores a 55 clientes y herramientas y 285 indicadores, todos con fuente (`docs/research/`). Vape, Raven, Inertia, Sigma, Rise y Novoline ya tienen indicadores (ninguno queda `NOT COVERED`). Clientes nuevos con fuente primaria: Raven bS (paquetes `keystrokesmod/module/` y `keystrokesmod/script/`, `mixins.raven.json`), Inertia (ICB), FDPClient, GameSense, Slinky y Breeze; con fuentes secundarias: Argon, Tenacity, Drip, Dqrkis, Krypton, Catlean, Dream, Entropy, Koid, Asteria, Xenon, Gypsy y Virgin. Autoclickers (JNativeHook, Speed AutoClicker, OP Auto Clicker, clickers conocidos) y programas de macros (G HUB, LGS, iCUE, Synapse, SteelSeries, ROCCAT, Redragon, ASUS Armoury, AutoHotkey). Dos cadenas aportadas por el usuario aparecen en herramientas SS públicas y pasan a `secondary`.
- `tools\Import-ResearchSignatures.ps1`: incorpora una propuesta de indicadores con fuente aplicando reglas contra falsos positivos (descarta cadenas cortas y genéricas, dominios que ya no son del cliente y modid compartidos con mods legítimos) y escribe solo los archivos que cambian, con el formato de los escritos a mano.

### Cambiado

- **Revisión automática de una tecla.** `Start-AmonSS.ps1` ya no pide consentimiento: lo cubren los términos de la SS del servidor, y el reporte deja constancia en el alcance autorizado del usuario, el equipo, la fecha y si se ejecutó como administrador. Al abrirse muestra el banner; sin administrador ofrece reabrirse como tal (`[A]`, con el aviso UAC de Windows) o seguir con Enter o tras 10 s; ejecuta el escaneo completo, muestra el veredicto, exporta el reporte y termina en un menú de una tecla sin Enter: `H` abrir el reporte HTML, `D` detalle por módulo, `T` línea temporal, `R` repetir, `M` más opciones, `Q`/`Esc` salir. Enter no hace nada en ese menú, a propósito.
- "Más opciones" y "Ajustes" también funcionan con una sola tecla. En Ajustes, `G` y `P` alternan los glifos (`auto`, `full`, `safe`, `ascii`) y el periodo (3, 7, 14 o 30 días); los formatos de reporte ya no se cambian desde el menú (`reportFormats` en `settings.json`). La línea temporal muestra directamente el periodo de la revisión.
- `-Scan` ya no exige `-Consent`; `-OutputPath`, `-ConsentNote` y `-Modules` también valen en modo interactivo.
- Veredicto sin falsos positivos: los clientes sin firmas verificables pasan de `INCONCLUSIVE` a `NOT COVERED` y salen en una línea gris aparte; la tabla solo lista los clientes con algún indicio y los limpios se resumen en "Sin indicadores (N clientes)". Los hallazgos `INFO` no cuentan para el resultado global.
- Temp ya no se omite sin indicadores: siempre busca `JNativeHook*.dll` en el primer nivel de `%TEMP%`, donde la versión 2.1 de JNativeHook extrae `JNativeHook-<versión o SHA-1>.<arquitectura>.dll` (`GlobalInputHook`, `INCONCLUSIVE`; fuente: `DefaultLibraryLocator` de [kwhat/jnativehook](https://github.com/kwhat/jnativehook), rama 2.1). El resto de Temp, solo con indicadores.
- Orden del escaneo completo: Minecraft, Firmas, Procesos, Memoria, Prefetch, BAM, PCA, ShimCache, Recent, UserAssist, Eventos, Evasión, Temp, Papelera, USN Journal, firmas sobre evidencias y correlación.
- Una coincidencia solo de nombre (`KeywordName`) se sigue mostrando, pero ya no cambia el veredicto del cliente ni el resultado global: un archivo cualquiera que contenga `vape` o `wurst` no pone la revisión en `REVISAR A MANO`.
- El software de macros (categoría `macro`) solo produce hallazgos `INFO` y queda fuera del veredicto por cliente. El escáner de memoria no usa indicadores débiles.
- Exportar otra vez la misma revisión (`R` o `Más opciones > E`) ya no sobrescribe el reporte anterior: crea `<id>-2`, `<id>-3`...
- Al reabrirse como administrador, la copia elevada conserva `-Modules`, `-OutputPath`, `-ConsentNote`, `-Theme` y `-Glyphs`.
- BAM lee también la clave antigua `bam\UserSettings` cuando la de Windows 10 1809+ no existe. Los hallazgos de herramientas en ShimCache se registran como presencia, no como ejecución.

### Corregido

- Falso positivo encontrado durante la revisión en el equipo del autor: la palabra clave `gamesense` coincidía con SteelSeries GG (`SteelSeriesCVGameSense.exe`). Se quitó y quedó una prueba de regresión.

### Obsoleto

- `-Consent`: se acepta por compatibilidad y no hace nada. Sin `-Scan` ya no lanza el modo no interactivo.

### Eliminado

- La pantalla de consentimiento, el menú principal numerado (`01`-`12`, `00`) y la pantalla de alcance con confirmación previa al escaneo completo.
- El código de salida `2` (modo no interactivo sin `-Consent`).

### Seguridad

- La memoria de los procesos se lee en modo de solo lectura: no se escribe, no se suspende ningún proceso y no se guarda su contenido; del escáner de Java solo quedan qué firmas aparecen y en qué dirección, y del Explorador solo las rutas que siguen al marcador `PcaClient`.
- Amon SS solo se reinicia como administrador si el revisor pulsa `A`, y siempre a través del aviso UAC de Windows.

## [1.0.0] - 2026-10-20

Primera versión.

### Añadido

- Terminal morada con tres temas (Full Purple, Minimal Purple, Classic Terminal), detección de VT/Unicode, modos de glifos `full`/`safe`/`ascii`, banner AMON SS con degradado, menús, tablas, tarjetas de hallazgos y barra de progreso de dos líneas. En el menú principal, un Enter vacío no cierra la sesión.
- Motor de Minecraft: instancias de Minecraft Launcher, TLauncher, Badlion, Lunar Client (perfiles), Feather, Prism/PolyMC, CurseForge, Modrinth App, GDLauncher, rutas configuradas y `--gameDir` de procesos vivos (así se detecta MultiMC, que es portable, si el juego está abierto); logs `latest.log` y `.log.gz`; mods instalados frente a cargados; mods cargados que ya no están instalados; perfiles de versión con verificación del SHA-1 declarado por Mojang, `-javaagent` y clase principal. Un log ilegible se anota sin detener la instancia, una fecha imposible en el nombre de un log rotado se sustituye por la de modificación y los ids de mod se comparan de forma literal.
- Motor de firmas JSON con fuente citada por indicador: paquetes, entradas, entrypoints, MANIFEST, modid, configuración, logs, cadenas y firmas binarias (Aho-Corasick en C#), SHA-256, perfiles de versión y argumentos JVM; JAR anidados sujetos a la cancelación, al tiempo del módulo y al total descomprimido; confianza limitada para firmas no validadas. Cada escaneo completo empieza de cero, la pasada de evidencias solo omite los archivos escaneados por completo y la ruta extra del menú 03 se guarda como dato de la sesión. Solo las detecciones `DETECTED` se registran como indicadores para los demás módulos. El validador exige `category`, `indicators` y `strength` aunque el cargador tenga valores por defecto.
- Definiciones iniciales: Meteor, Wurst, LiquidBounce, BleachHack, ThunderHack, Lambda, KAMI Blue, SalHack, RusherHack, Baritone (uso dual), Aristois/EMC, Impact, MatHax, Coffee, Phobos, Future; Doomsday, Nova y Prestige con las cadenas aportadas (sin validar); Vape, Raven, Inertia, Sigma, Rise y Novoline sin indicadores verificables.
- Procesos (Win32_Process, línea de comandos con secretos ocultos, firma Authenticode, DLL sin firma cargadas en Java). Un argumento JVM de firma validado da `DETECTED` (confianza media); uno sin validar, `INCONCLUSIVE` (confianza baja).
- Prefetch SCCA v17/v23/v26/v30/v31 con descompresión MAM (XPRESS Huffman). La relevancia se decide antes de traducir rutas y el mapa de volúmenes solo consulta discos locales.
- Papelera `$I`/`$R` (v1 y v2) con RECYCLE BIN ACTIVITY.
- USN Journal de solo lectura con reconstrucción de rutas y de envíos a la papelera. Filtra por las carpetas de las instancias (referencia NTFS), por JAR, `$I`/`$R`, borrados o renombrados de `.pf`, `.exe`, `.bat`, `.cmd`, `.ps1` y `.vbs`, palabras clave e indicadores; al alcanzar `maxUsnResults` conserva los registros más recientes.
- Recent (.lnk), UserAssist (ROT13) y eventos 4688/1102/104, Defender 1116/1117 y claves Run.
- Barrido de Temp solo con indicadores concretos.
- Motor de correlación (DETECTED / CORRELATED / INCONCLUSIVE / NOT DETECTED) y línea temporal unificada. Los nombres genéricos (`javaw.exe`, `latest.log`, `client.jar`, logs, JAR de versión...) solo se relacionan por SHA-256 y el tipo de fuente sale del módulo de origen. Sin fin explícito, la ventana temporal avanza hasta "ahora" al empezar cada módulo y al correlacionar.
- Reportes TXT, JSON y HTML con manifiesto SHA-256 y verificación de integridad.
- Instalación de una línea con versión fijada y verificación SHA-256; actualizaciones verificadas a petición (el repositorio se valida antes de guardarse y una etiqueta que no es número de versión no se ofrece); firma opcional de la release (`Sign-Release.ps1` acepta una carpeta o un archivo).
- Integridad del paquete: `tools\Build-Release.ps1` genera `Integrity.psd1` con el SHA-256 de todos los archivos, después de firmar los scripts, y lo firma; al arrancar se compara el paquete entero y uno alterado no llega a analizar nada; en ejecución se verifican además los `.cs`, las firmas y `config\settings.json` en cada lectura; una release sin manifiesto no arranca. `-VerifyPackage` comprueba la instalación completa. El ZIP usa `/` como separador.
- Códigos de salida: `-VerifyManifest` y `-VerifyPackage` terminan con `0` si todo está íntegro y `1` si no; el modo no interactivo sin `-Consent` termina con `2`. `-Scan` admite también `Temp`.
- `config\settings.json` solo contiene ajustes que usa el código (`schemaVersion` todavía no se comprueba).
- `tools\Invoke-AmonAdminCheck.ps1`: resumen de Prefetch, USN Journal y eventos sobre el sistema real (requiere administrador; solo lectura, no exporta nada).
- Batería Pester (unitarias con fixtures sintéticos, integración de solo lectura y pruebas de administrador) y CI en GitHub Actions para Windows PowerShell 5.1 y PowerShell 7.

### Seguridad

- Las rutas sacadas de artefactos (destinos de `.lnk`, rutas de evidencia, `gameDir` de `launcher_profiles.json`, `--gameDir` de procesos) solo se usan si son rutas absolutas de unidades locales: sin tráfico SMB/WebDAV ni autenticación NTLM.
- Privacidad: un comprimido o un log no es relevante solo por su extensión (`interestingExtensions` y Recent no los incluyen), y un Prefetch borrado de un programa no relacionado se cuenta sin mostrar su nombre.
- Las cajas de la terminal solo conservan secuencias de color SGR y sanean títulos y datos; el reporte TXT elimina caracteres de control y saltos de línea incrustados.
