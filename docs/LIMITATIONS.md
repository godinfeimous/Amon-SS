# Limitaciones forenses

Amon SS describe lo que muestran los artefactos del equipo y nada más. Esta página reúne los límites de cada fuente para interpretar bien un resultado. Las limitaciones que se aplican a una revisión concreta aparecen en la sección **LIMITACIONES** de su reporte y en las notas `LÍMITE` de cada vista.

## Principios generales

- **La ausencia de evidencia no es evidencia de ausencia.** `NOT DETECTED` y el resultado global `SIN INDICADORES` significan que no se encontraron indicadores dentro del alcance analizado. Los artefactos pueden faltar por rotación, por configuración de Windows, por limpieza legítima o por limpieza intencionada.
- **El resultado global es un resumen, no un veredicto.** `INDICADORES ENCONTRADOS`, `REVISAR A MANO` y `SIN INDICADORES` se calculan con los estados de los hallazgos: los `INFO` no cuentan y una herramienta de uso dual (Baritone) no lo cambia por sí sola. Hay que leer los hallazgos y sus falsos positivos.
- **La memoria solo se ve en el momento de la revisión.** Java Memory Scanner revisa la memoria de los `java.exe`/`javaw.exe` abiertos y solo con las firmas conocidas. Un cliente que ya se descargó, un juego reiniciado, un cliente que cifra sus nombres y cadenas o uno sin firmas no deja nada que encontrar, y fuera de la memoria la detección se basa en archivos: un cliente inyectable puede no dejar nada en las carpetas analizadas. Varias definiciones lo advierten de forma expresa (por ejemplo, Prestige se describe como inyectable y Vape también).
- **Clientes renombrados u ofuscados.** Las firmas de contenido no dependen del nombre de archivo: un JAR renombrado sigue detectándose por su contenido. Pero un cliente que cambia sus paquetes, cifra sus cadenas o se recompila en cada descarga evita las firmas de paquete, cadena o hash. La web de Doomsday, por ejemplo, ofrece descargar su loader con nombre y tamaño aleatorios. Las firmas `filename` de herramientas, al contrario, dependen del nombre: un ejecutable renombrado no coincide.
- **Firmas sin validar.** Las cadenas de Doomsday, Nova y Prestige las aportó un usuario y no se han validado con muestras autorizadas (dos de ellas aparecen además en herramientas SS públicas y pasaron a `secondary`). Los 120 indicadores secundarios de la 1.1.0 salen de herramientas SS públicas o de código filtrado: tampoco están validados con muestras. Su confianza se limita a media, una sola coincidencia queda como `INCONCLUSIVE`, y aun así pueden aparecer por azar en archivos grandes (sobre todo las de 5 a 7 caracteres).
- **Clientes cerrados o inyectables.** Desde la 1.1.0, Vape, Raven, Inertia, Sigma, Rise y Novoline tienen indicadores con fuente, pero sobre todo secundarios (herramientas SS públicas, código filtrado, hashes de versiones concretas). Vape se distribuye como inyector con nombre aleatorio y sin instalación, así que su detección depende sobre todo de la memoria de Java y de cadenas de versiones conocidas: una versión nueva puede no coincidir. Un cliente sin indicadores aparecería como `NOT COVERED` ("no comprobable por archivo").
- **Sin administrador falta parte del análisis.** Prefetch, BAM y el USN Journal quedan `SIN ACCESO` y el registro de Seguridad no se lee. Amon SS ofrece reabrirse como administrador, pero solo lo hace si el revisor pulsa `A` y se acepta el aviso UAC; con `-NoElevate`, en modo no interactivo o si se rechaza el aviso, la revisión sigue sin esas fuentes y el reporte lo hace constar.
- **La correlación nunca usa solo el tiempo.** Dos hallazgos se relacionan únicamente si comparten cliente, ruta, nombre de archivo o SHA-256. Hay tres matices:
  - La relación por **nombre de archivo** puede unir archivos distintos que se llaman igual en carpetas diferentes. Compara las rutas y los hashes de la evidencia.
  - Los **nombres genéricos**, que comparten todas las instalaciones (`java.exe`, `javaw.exe`, `javaws.exe`, `jp2launcher.exe`, `latest.log`, `debug.log`, `client.jar`, `minecraft.jar`, `launcher_profiles.json`, `options.txt`, `minecraftlauncher.exe`, `minecraft.exe`, cualquier `.log` o `.log.gz` y los JAR de versión como `1.20.1.jar`), no relacionan nada ni por nombre ni por ruta: con ellos solo cuenta el SHA-256. Por eso un proceso `javaw.exe` no se une con cualquier Prefetch de `javaw.exe`.
  - En la papelera, una modificación del contenedor `$Recycle.Bin` se presenta como "actividad correlacionada" si el USN Journal registra purgas de la papelera en los 10 minutos anteriores o posteriores. Es una relación entre operaciones de la propia papelera (no comprueba que sean de la misma unidad), aparece como actividad y no como hallazgo, y su texto aclara que los artefactos no indican quién ni por qué.
- **Fechas manipulables.** Las fechas de NTFS, de los logs y del reloj del sistema pueden alterarse. Amon SS las toma tal cual; la papelera señala algunas incoherencias (fechas nulas, futuras o distintas de la creación del `$I`) y el módulo de evasión, los cambios de la hora del sistema de 2 minutos o más que registra Windows.
- **El equipo lo controla la persona revisada.** Alguien con control total del equipo (administrador, rootkit, driver, PowerShell o .NET modificados) puede ocultar o falsear lo que ve la herramienta, también la memoria de los procesos (ver [SECURITY.md](../SECURITY.md)).
- **Se analiza el perfil de quien ejecuta Amon SS.** Las instancias se buscan en `%APPDATA%` y `%USERPROFILE%`, UserAssist, Store y MUICache en `HKCU`, Recent en el perfil, la papelera del SID actual y solo el `explorer.exe` de ese usuario. BAM es la excepción: incluye las entradas de todas las cuentas. Si se eleva con otra cuenta de administrador, se analizan los datos de esa cuenta; también al reabrir con `A` desde una cuenta estándar, porque el aviso UAC pide entonces las credenciales de otra cuenta.
- **Ventana temporal.** Por defecto, 7 días. Las sesiones de log, las eliminaciones, los eventos, los registros del USN Journal y las filas de la línea temporal se limitan a esa ventana. El fin de la ventana avanza hasta "ahora" al empezar cada módulo y al correlacionar, así que lo que ocurre durante la revisión (el juego abierto a petición, un borrado mientras se habla) entra en el análisis; solo queda fijo si el contexto se crea con un fin explícito (`New-AmonContext -UntilUtc`), cosa que `Start-AmonSS.ps1` no hace. Ampliar el intervalo de la línea temporal después no recupera lo que no se recopiló.
- **Límites de tamaño y tiempo.** Cada módulo tiene un tiempo máximo (`moduleTimeoutSeconds`, 180 s) y el escaneo de archivos tiene límites de tamaño (`limits` en `settings.json`). Cuando se alcanzan, el resultado se marca como parcial y queda constancia en el reporte.
- **Rutas conocidas.** Solo se descubren instancias en las rutas de los launchers soportados, en `minecraft.extraInstancePaths` y en el `--gameDir` de los procesos Java vivos. Los launchers portables (MultiMC, ATLauncher...) u otras ubicaciones necesitan que se configure su ruta; MultiMC, por ejemplo, solo aparece si el juego está abierto (por su `--gameDir`) o si se añade en `extraInstancePaths`.
- **Rutas de red.** Las rutas que salen de artefactos solo se usan si son rutas absolutas de una unidad local, fija o extraíble (`Test-AmonLocalPath`): destinos de `.lnk`, rutas de evidencia para la pasada de firmas (`-javaagent`, JAR citados en Prefetch o Recent, DLL de procesos...), `gameDir` de `launcher_profiles.json` y `--gameDir` de procesos. Una ruta `\\servidor\recurso`, de una unidad de red o relativa no se comprueba, no se escanea y no se usa como instancia, para no generar tráfico SMB/WebDAV ni autenticación NTLM. Un cliente que los artefactos sitúan en un recurso de red queda, por tanto, fuera de la pasada de firmas. Las rutas que configura el propio operador (`minecraft.extraInstancePaths`, `scan.extraScanPaths` o la ruta de `Más opciones > X`) no pasan por este filtro.

## Por módulo

### Minecraft Analysis

- "Lunar Client no imprime la lista estándar de mods de Fabric: la evidencia de carga se basa en JAR citados y recursos del log, y puede ser incompleta."
- "Log truncado por tamaño: ...": un log mayor que `maxLogSizeMB` solo se interpreta en parte.
- "No se pudo interpretar ...": un log que no se puede leer o interpretar se anota como advertencia y se salta; el resto de la instancia se analiza igual.
- Solo se leen `latest.log` y los logs rotados modificados dentro del periodo, hasta `maxLogFiles` por instancia. Un log borrado no se puede leer; el USN Journal puede registrar su eliminación.
- La fecha de una sesión sale del nombre del log rotado (o de la fecha de modificación en `latest.log`) más la hora que registra el log. Si el nombre tiene una fecha imposible (por ejemplo `2026-99-99-1.log`), se ignora y se usa la fecha de modificación. Si el log no tiene horas, se usan las fechas del sistema de archivos. El reporte indica qué fuente se usó en cada sesión.
- La versión de Minecraft de Lunar y vanilla se deduce del JAR del juego citado en las trazas y se marca como "deducida del JAR del juego".
- "Cargado" significa que el log menciona el mod (lista de mods, JAR citado o recursos), no que estuviera activo toda la sesión. "Sin logs" significa que no hay logs para comparar.
- Un mod que se cargó y ya no está instalado pudo actualizarse con otro id, moverse a otra instancia o desinstalarse de forma legítima.
- La estructura de Feather Client no está documentada: se buscan carpetas `mods`, `user-mods` y `logs` hasta 3 niveles.
- Los JAR mayores que `maxJarSizeMB` no se hashean ni se inspeccionan como mods.

### Cheat Signature Scanner

- "Los clientes inyectables o cargados desde memoria pueden no dejar archivos en las carpetas analizadas; el escaneo de memoria está fuera del alcance de esta herramienta." Este aviso del escáner de archivos se refiere a su propio alcance: la memoria de Java en ejecución la revisa Java Memory Scanner (ver más abajo).
- "Sin firmas verificables (el escaneo no puede descartarlos): Vape (v4 / Lite), Raven (B+, BS, XD y forks), Inertia Client, Sigma (Sigma 5 / Jello), Rise (Rise 6), Novoline."
- "Escaneo parcial por límites de tamaño o tiempo: ...": se alcanzó algún límite (`maxJarSizeMB`, `maxRawScanMB`, `maxEntrySizeMB`, `maxDecompressedPerJarMB`, `maxEntriesPerJar`) o el tiempo del módulo. En un archivo mayor que `maxJarSizeMB` solo se revisan los bytes en bruto.
- Las entradas multimedia (`.png`, `.ogg`, `.ttf`...) no se escanean, y los JAR anidados solo se abren hasta `maxNestedJarDepth` niveles. Los anidados cuentan para el total descomprimido (`maxDecompressedPerJarMB`) y para el número de entradas, y entre uno y otro se comprueban la cancelación y el tiempo del módulo.
- Un metadato dañado (por ejemplo, un `fabric.mod.json` con deflate inválido) se anota en el error del JAR y se trata como vacío: el resto del JAR se escanea igual, pero los ids de mod o entrypoints que solo estuvieran en ese metadato no se ven.
- Un archivo cuyo escaneo se cortó (por límites, tiempo o cancelación) no cuenta como escaneado por completo: la pasada de evidencias no lo da por revisado y lo vuelve a escanear si otro módulo lo cita. Cada escaneo de firmas completo empieza de cero.
- Una carpeta de configuración prueba uso pasado, no que el cliente siga instalado.
- Un indicador de fuente secundaria puede describir una versión distinta de la que tiene el jugador, y un indicador de un framework compartido (Aristois/EMC) prueba el framework, no el cliente.
- Las palabras clave en nombres de archivo son solo heurística (`KeywordName`).

### Process Inspector

- "No hay procesos Java en ejecución: solo se pueden analizar artefactos de ejecuciones pasadas."
- Es una foto del momento: lo que se cerró antes del análisis no aparece.
- Este módulo solo lista las rutas de las DLL cargadas en Java; no inspecciona su memoria (eso lo hace Java Memory Scanner). Si el juego se ejecuta como administrador y Amon SS no, no se pueden listar sus módulos.
- La lista de nativas legítimas (LWJGL, OBS, Steam, Discord, Simple Voice Chat...) es por nombre y por tanto evadible: solo reduce el ruido de un indicador heurístico.
- Un runtime de Java sin firma suele ser uno empaquetado por un launcher; por eso se informa como `INFO`.
- `RuntimeAgent` solo indica que hay un agente Java que no se declaró al arrancar: perfiladores y herramientas de monitorización (VisualVM, JProfiler) y algunos launchers o mods también cargan agentes en caliente.
- `GlobalInputHook` reconoce JNativeHook por el nombre de su DLL cargada en un proceso Java. Otros ganchos de teclado y ratón (otras librerías o programas nativos) no se detectan así.
- Una herramienta solo se reconoce por nombre (`ToolExecution`) si su proceso conserva el nombre de la firma.

### Java Memory Scanner

- "No había ningún proceso de Java en ejecución: abre Minecraft antes de la revisión para poder escanear su memoria." El módulo queda `OMITIDO`.
- "La memoria solo muestra lo cargado ahora: si el juego se reinició o el cliente se descargó, ya no aparece."
- "`<proceso>` PID `<n>`: memoria escaneada parcialmente (N MB) por límite de tiempo" (o "de tamaño"): se leen como máximo 3 GB y 60 s por proceso, o menos si se agota antes el tiempo del módulo.
- Solo se escanean los procesos llamados `java.exe` o `javaw.exe`; una JVM con otro nombre de ejecutable no se revisa. Si el juego se ejecuta como administrador y Amon SS no, Windows no deja abrir su memoria y el proceso aparece como advertencia ("No se pudo abrir el proceso para lectura").
- Solo se buscan los paquetes de 8 o más caracteres, las clases de entrada y las cadenas de 10 o más caracteres de las firmas. Un cliente que cambia sus nombres de paquete o cifra sus cadenas no coincide, y uno sin firmas (`NOT COVERED`) tampoco se puede buscar en memoria.
- Cada región de memoria se busca por separado: una cadena partida entre dos regiones no se encuentra.
- Las mismas reglas de confianza que en los archivos: una sola coincidencia no validada queda como `INCONCLUSIVE`. Un mod legítimo que incluya el mismo paquete daría la misma coincidencia.

### Prefetch Analyzer

- Requiere administrador; sin él, el módulo informa `SIN ACCESO`.
- "Prefetch guarda como máximo 8 ejecuciones por programa y Windows elimina los más antiguos al superar el límite; su ausencia no prueba que algo no se ejecutara."
- "Prefetch está desactivado en este equipo (EnablePrefetcher = 0): no se generan nuevos registros de ejecución." En muchas instalaciones de Windows Server está desactivado.
- "N Prefetch de programas no relacionados con la revisión se omitieron por privacidad."
- Prefetch prueba que un ejecutable se ejecutó y qué archivos cargó, no qué hacía. Las coincidencias con indicadores son por nombre de archivo.
- Las rutas `\VOLUME{...}` y `\DEVICE\HarddiskVolumeN` solo se traducen a letra de unidad para los discos locales (fijos y extraíbles) conectados; las de otros volúmenes quedan sin traducir y, al no ser rutas locales absolutas, no pasan a la pasada de firmas.
- Los Prefetch con formato dañado o no soportado se cuentan como errores y no se interpretan.
- Las herramientas se reconocen por el nombre del ejecutable que guarda el Prefetch (truncado a 29 caracteres): un ejecutable renombrado no coincide.
- `DetachedVolumeExecution` solo se evalúa si la última ejecución cae en el periodo, y compara el número de serie del volumen que guarda el Prefetch con los volúmenes conectados ahora. Un disco externo legítimo, un instalador desde un pendrive o un volumen formateado de nuevo producen el mismo resultado.

### BAM

- Requiere administrador; sin él, el módulo informa `SIN ACCESO`.
- "BAM guarda solo la última ejecución de cada programa y Windows borra las entradas antiguas (unos 7 días)."
- BAM no registra las ejecuciones desde unidades extraíbles: para eso está `DetachedVolumeExecution` de Prefetch.
- "N ejecutable(s) de BAM sin relación con la revisión se contaron pero no se muestran (privacidad)."
- Los ejecutables "para revisar" solo se eligen por su carpeta y su firma: muchos programas portables, instaladores y juegos legítimos no están firmados, y uno que "ya no existe" pudo moverse o desinstalarse. Lo ejecutado desde AppData (salvo Temp) no se lista para revisar, porque ahí se actualizan solos muchos programas; solo aparece si su nombre es relevante.
- La firma y la existencia del archivo se comprueban en el momento de la revisión, no en el de la ejecución.

### PCA & MUICache

- `PcaAppLaunchDic.txt` solo existe desde Windows 11 22H2; sin él, Amon SS lo indica y revisa el resto de fuentes.
- "PCA solo registra programas abiertos desde la interfaz gráfica (no desde consola, tareas ni scripts)." Si PcaSvc está detenido o deshabilitado, no anota nada (el módulo de evasión lo señala).
- "PcaAppLaunchDic.txt tiene N línea(s) truncada(s): una ruta con caracteres no ANSI corta el registro y Windows puede dejar de anotar lanzamientos nuevos."
- Store y MUICache no tienen fecha por entrada: prueban que el programa se lanzó alguna vez desde la sesión del usuario. De `PcaGeneralDb`, Store y MUICache solo se usan los indicadores, las herramientas y las palabras clave de clientes.
- Las trazas `PcaClient` de la memoria del Explorador no tienen hora y solo cubren lo lanzado desde que se abrió el `explorer.exe` actual: reiniciar el Explorador o la sesión las borra. Se leen como máximo 2 GB, 45 s y 5000 rutas por proceso, y solo del Explorador del usuario actual.
- "N entrada(s) de PCA, Store y MUICache sin relación con la revisión se contaron pero no se muestran (privacidad)."
- Los ejecutables "para revisar" tienen los mismos límites que en BAM.

### ShimCache

- "ShimCache se guarda en el registro al apagar el equipo: lo ocurrido desde el último arranque no aparece. Indica que el sistema vio el archivo, no que se ejecutara."
- La fecha es la de la última modificación del archivo, no la de su ejecución; la posición en la caché solo indica el orden relativo.
- Solo se interpreta el formato de Windows 10/11 (entradas `10ts`); otro formato hace fallar el módulo con un aviso. Las entradas sin ruta (aplicaciones empaquetadas) se omiten.
- "N entrada(s) de ShimCache sin relación con la revisión se contaron pero no se muestran (privacidad)." No genera avisos "para revisar".

### Recent Files

- "Las Jump Lists (AutomaticDestinations/CustomDestinations) no se interpretan. Windows puede limitar o desactivar el historial de Recent por configuración."
- La creación del `.lnk` se aproxima a la primera apertura y su modificación a la última. Abrir un archivo no equivale a ejecutarlo: un JAR también puede abrirse con un compresor.
- Los accesos no relacionados se cuentan, pero no se muestran. Un comprimido (`.zip`, `.rar`, `.7z`) solo es relevante si coincide con un indicador o su ruta contiene una palabra clave.
- Un acceso directo a un recurso de red se muestra si es relevante, pero no se comprueba si su destino existe ni se escanea (sin tráfico de red): en la columna EXISTE figura como `no`.

### UserAssist

- "UserAssist solo registra programas iniciados desde el Explorador (no desde consola ni launchers) y puede desactivarse por configuración."
- Solo se interpreta el formato de Windows 7 o posterior (72 bytes) y el antiguo de XP; las entradas de control `UEME_CTL` se ignoran.

### Windows Event Analysis

- El registro de Seguridad (4688 y 1102) solo pueden leerlo administradores o el grupo "Lectores del registro de eventos"; sin acceso, el módulo queda `PARCIAL`.
- "La auditoría de creación de procesos (evento 4688) no está habilitada: la ausencia de eventos 4688 no es evidencia de nada." Windows no la activa por defecto.
- "Los eventos 4688 no incluyen la línea de comandos (directiva no habilitada)."
- "No se pudo comprobar si la auditoría de creación de procesos (4688) está habilitada."
- "El registro de Seguridad solo conserva eventos desde ... (tamaño máximo alcanzado o registro borrado)."
- "Se revisaron solo los 30000 eventos 4688 más recientes del periodo."
- De 1102 y 104 se leen los 50 más recientes; de Defender, 1116 y 1117 del periodo (hasta 500). Solo generan hallazgo las detecciones de Defender relacionadas con la revisión. De 7045, 5001/5007 y 1000 se leen como máximo 500 eventos del periodo, y de 501, 2000.
- Las claves de inicio automático revisadas son Run y RunOnce de HKCU y HKLM, y Run de WOW6432Node. No se revisan tareas programadas ni la carpeta Inicio; de los servicios, solo los instalados dentro del periodo (evento 7045).
- Del evento 7045 solo se muestran los servicios y drivers cuyo binario está en una carpeta de usuario u otra unidad, o cuyo nombre contiene un indicador o una palabra clave de un cliente. Las herramientas de SS (Ocean, Echo...) y algunos antitrampas instalan su propio driver: solo las de `knownScreenshareTools` se reconocen y se informan como `INFO`; el resto aparece como `DriverInstalled` y hay que compararlo con la que usó el staff. La pasada de firmas no escanea los `.sys`.
- El evento 501 de SearchIndexer se descarta porque lo registra a menudo sin borrar nada. Si el registro Ntfs/Operational está vacío o no existe, no hay nada que revisar.
- Del evento 5007 solo generan hallazgo las exclusiones de rutas, procesos o extensiones; otro antivirus instalado también desactiva Defender (5001).
- El evento 1000 solo se revisa para los procesos de `launcherProcessNames`, y "DLL ajena" se decide por la carpeta del módulo: las nativas de mods o superposiciones (Discord, OBS, RivaTuner) también pueden provocar cierres.

### Bypass & Tamper Check

- "Un servicio detenido o reiniciado, o un cambio de hora, no prueban trampas: indican que los rastros de Windows pueden estar incompletos." Muchos programas y guías de "optimización" desactivan SysMain o PcaSvc, y algunas ediciones o configuraciones corporativas también.
- El reinicio de un servicio se deduce de la hora de inicio del proceso que lo aloja, y solo si ese proceso no aloja otros servicios; Windows también reinicia servicios tras actualizaciones o fallos. El controlador `bam` no tiene proceso propio: de él solo se comprueba el estado.
- El evento 7036 (cambio de estado de un servicio) no se usa porque Windows 11 ya no lo registra (comprobado en la build 26200, sin confirmación oficial de Microsoft): sin él no se sabe cuándo se detuvo un servicio. Los eventos 7040, 7031 y 7034 solo se buscan dentro del periodo y desaparecen si se vació el registro System (eso lo señalan los eventos 104 y 1102).
- Solo se informan los cambios de hora de 2 minutos o más; una corrección manual de una hora mal puesta o una pila de la placa base agotada producen el mismo evento.

### Temp Indicator Sweep

- "No hay indicadores concretos de otros módulos: en Temp solo se buscó JNativeHook (privacidad)." Los indicadores (nombre de archivo y SHA-256) solo los registra el escáner de firmas, y solo con detecciones `DETECTED`.
- La DLL de JNativeHook solo se busca en el primer nivel de `%TEMP%` y con el nombre que usa la versión 2.1 (`JNativeHook*.dll`). Otras versiones, un `java.io.tmpdir` distinto o un limpiador de temporales la dejan fuera, y programas Java legítimos de atajos, accesibilidad o grabación también la usan.
- "Se revisaron solo los primeros N archivos de Temp." Solo se buscan `.jar`, `.exe`, `.dll` y `.zip` hasta 3 niveles, y solo se hashean los archivos de hasta `maxExecutableScanMB`.
- Una coincidencia solo por nombre puede ser otro archivo distinto: por eso queda como `INCONCLUSIVE`.

### Recycle Bin Forensics

- "Solo se analiza la papelera del usuario actual. Los archivos borrados con Mayús+Supr o desde la consola no pasan por la papelera: el USN Journal puede registrarlos."
- Un elemento es relevante si coincide con un indicador, su ruta contiene una palabra clave, estaba en una carpeta de Minecraft o su extensión está en `interestingExtensions`. Los comprimidos y los logs no están en esa lista, así que fuera de esos casos se cuentan sin mostrarse.
- "Sin carpeta de papelera: no hay datos que analizar."
- "N elemento(s) sin relación con la revisión se contaron pero no se muestran (privacidad)."
- Registrar una eliminación no demuestra intención ni contenido malicioso. La modificación del contenedor es compatible con vaciar la papelera, restaurar elementos o eliminarlos de forma permanente, y los artefactos no permiten saber cuál ocurrió ni quién lo hizo.
- El contenido `$R` se escanea con firmas en su sitio, sin restaurarlo; un `$R` que ya no existe no se puede escanear.

### NTFS / USN Journal

- Requiere administrador; sin él, el módulo informa `SIN ACCESO`.
- "El journal de X: solo cubre desde ...: los cambios anteriores dentro del periodo ya se sobrescribieron (el journal es circular) y no se pueden analizar."
- "Las rutas se reconstruyen con la ubicación actual del directorio padre: si el directorio se movió después, la ruta mostrada es la actual." Si el directorio padre ya no existe, solo se conoce el nombre del archivo (la tabla lo indica como "solo nombre").
- "Solo se muestran registros relevantes para la revisión; el resto del journal se cuenta pero no se expone."
- "N nombre(s) original(es) de elementos enviados a la papelera sin relación con la revisión se ocultaron (privacidad)."
- "X: se alcanzó el máximo de registros relevantes (N); se muestran los más recientes." (`maxUsnResults` por unidad). Los registros más antiguos del periodo se descartan.
- "X: la lectura se detuvo por límite de tiempo; el journal se leyó parcialmente."
- "El USN Journal no está activo en X."
- Solo se leen la unidad del sistema y las unidades donde están las instancias (resolviendo junctions).
- El filtro no registra todo: en las carpetas de las instancias (`gameDir`, `mods`, `logs`, `versions`, `config`) solo los archivos situados directamente en ellas, y en el resto del volumen solo JAR, `$I`/`$R`, borrados o renombrados de `.pf`, `.exe`, `.bat`, `.cmd`, `.ps1` y `.vbs`, y nombres con una palabra clave o un indicador de al menos 4 caracteres. Los borrados de comprimidos, logs y DLL fuera de esas carpetas no se registran salvo por palabra clave o indicador. La carpeta Prefetch no se vigila entera.
- Un `.pf` borrado de un programa no relacionado con la revisión solo se cuenta en el hallazgo `PrefetchDeleted` ("N de programas no relacionados (nombres omitidos)"): no se muestra su nombre ni aparece en la tabla ni en la línea temporal.
- Interpretar el identificador del journal como fecha de creación es aproximado. Formatear, chkdsk o las actualizaciones de Windows también recrean el journal.
- Borrar Prefetch o logs es una técnica antiforense conocida, pero Windows rota los Prefetch y los launchers rotan los logs por sí mismos: por eso esos hallazgos son `INCONCLUSIVE`.

### Correlación, línea temporal y reportes

- La correlación agrupa por cliente, ruta, nombre de archivo y SHA-256 (ver los matices de [Principios generales](#principios-generales)). Un cliente identificado solo por firmas no validadas o débiles se correlaciona como mucho con confianza media. Un cliente sin firmas verificables queda como `NOT COVERED`: no se puede comprobar, que no es lo mismo que no haberlo encontrado.
- Las fuentes independientes se cuentan por módulo de origen: los registros del USN Journal de varias unidades son una sola fuente, y la "Sesión de Minecraft" sacada de un log cuenta como ese mismo log, no como una segunda fuente.
- Solo las detecciones `DETECTED` de firmas se registran como indicadores para los demás módulos. Un archivo con una detección `INCONCLUSIVE` no se usa como indicador: su nombre y su hash no generan hallazgos de coincidencia en Prefetch, Recent, UserAssist, eventos, Temp o el USN Journal.
- La línea temporal solo contiene eventos con una fecha respaldada por un artefacto concreto; no se interpolan horas. En el TXT se escriben como máximo 2000 filas y en el HTML 3000; el JSON contiene todas.
- El reporte exporta los hallazgos, el veredicto por cliente, los archivos escaneados con firmas, los datos de Minecraft, la actividad de la papelera y la línea temporal. Las tablas detalladas de procesos, memoria, Prefetch, BAM, PCA, ShimCache, Recent, UserAssist, eventos, evasión y USN no se exportan como tales: llegan al reporte como hallazgos y como filas de la línea temporal.
- El manifiesto `.sha256` demuestra que el reporte no cambió **después** de exportarse, siempre que su hash se haya anotado fuera del equipo analizado. No garantiza que los artefactos originales fueran auténticos.
