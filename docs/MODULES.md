# Módulos

Referencia funcional de cada módulo: qué artefactos lee, qué campos extrae, qué muestra, qué hallazgos puede producir (categoría, estado, severidad y confianza), cómo filtra por privacidad y si necesita administrador. Los estados se explican en el [README](../README.md#estados-de-resultado) y las reglas de las firmas en [SIGNATURES.md](SIGNATURES.md).

Notas comunes:

- Todos los módulos son de solo lectura, registran lo que revisaron en `Scope` y lo que no pudieron revisar en `Limitations`, y aparecen en el reporte con su estado (`COMPLETADO`, `PARCIAL`, `SIN ACCESO`, `OMITIDO`, `ERROR` o `CANCELADO`), su duración, los artefactos revisados y los hallazgos.
- "Relevante" significa relacionado con Minecraft, con un launcher, con una palabra clave de la revisión o con un indicador concreto ya encontrado por otro módulo (solo el escáner de firmas registra indicadores, y solo con detecciones `DETECTED`). Lo que no es relevante se cuenta pero no se muestra.
- Las rutas sacadas de artefactos solo se usan si son rutas absolutas de una unidad local, fija o extraíble (`Test-AmonLocalPath`): los recursos de red no se comprueban ni se escanean (ver [LIMITATIONS.md](LIMITATIONS.md#principios-generales)).
- El fin de la ventana de análisis avanza hasta "ahora" al empezar cada módulo y al correlacionar: lo que ocurre durante la revisión entra en el análisis.
- Las tablas de la terminal muestran como máximo `maxTableRows` filas (40); el reporte contiene todo.

## 02 Minecraft Analysis

**Administrador:** no.

**Lee:**

| Launcher | Ubicación |
| --- | --- |
| Minecraft Launcher | `%APPDATA%\.minecraft` y los perfiles de `launcher_profiles.json` con `gameDir` propio (solo si es una ruta local que existe) |
| TLauncher | `%APPDATA%\.minecraft` (si existe `TlauncherProfiles.json`) |
| Badlion Client | `%APPDATA%\.minecraft` con logs en `logs\blclient\minecraft` |
| Lunar Client | `%USERPROFILE%\.lunarclient\profiles\<perfil>` (con carpeta `mods` o `logs`) |
| Feather Client | `%APPDATA%\.feather` (carpetas `mods`, `user-mods` y `logs` hasta 3 niveles) |
| Prism Launcher / PolyMC | `%APPDATA%\PrismLauncher\instances` y `%APPDATA%\PolyMC\instances` (nombre de `instance.cfg`, loader y versión de `mmc-pack.json`) |
| CurseForge | `%USERPROFILE%\curseforge\minecraft\Instances` (`minecraftinstance.json`) |
| Modrinth App | `%APPDATA%\ModrinthApp\profiles` y `%APPDATA%\com.modrinth.theseus\profiles` |
| GDLauncher | `%APPDATA%\gdlauncher_next\instances` y `%APPDATA%\gdlauncher_carbon\data\instances\<id>\instance` |
| Rutas configuradas | `minecraft.extraInstancePaths` (MultiMC, ATLauncher y otros portables) |
| Procesos vivos | `--gameDir` de `java.exe`/`javaw.exe` (consulta CIM), solo si es una ruta local que existe |

MultiMC es portable y no tiene ubicación fija: solo se detecta si el juego está en ejecución (por el `--gameDir` del proceso Java) o si su carpeta se añade en `extraInstancePaths`. Repetir el análisis en la misma sesión sustituye las instancias anteriores en lugar de acumularlas.

En cada instancia lee `latest.log` y los logs rotados `AAAA-MM-DD-N.log[.gz]` modificados dentro del periodo (hasta `maxLogFiles`); los JAR de `mods` (`*.jar`, `*.disabled`, `*.litemod`); los nombres de `config`; y `versions\<id>\<id>.json` con su JAR. Un log que no se puede interpretar se anota como advertencia y no detiene el resto de la instancia.

**Extrae:**

- De los logs: versión de Minecraft, loader y versión (Fabric, Quilt, Forge, NeoForge, Forge antiguo, OptiFine), lista de mods cargados y anidados, archivos de mod de Forge, usuario (`Setting user:`), marca del cliente (Lunar, Badlion, Feather), ids de recursos cargados, JAR citados, y el inicio y el fin de la sesión con la fuente de la fecha. Si el nombre de un log rotado tiene una fecha imposible, se ignora y se usa la fecha de modificación.
- De cada JAR de mod (con `Jar.psm1`, sin ejecutarlo): SHA-256, fechas, loader, ids de mod, nombre, versión, si se declara agente Java, si tiene metadatos, si es un ZIP válido y archivos de `config` que empiezan por su id. El id sale del JAR y no es confiable, así que se compara de forma literal (un `*` o un `?` no actúan como comodines). Un metadato dañado se anota en el error del JAR y no impide leer el resto.
- Estado de carga: `Sí` si un log lo menciona (lista de mods, JAR citado o recursos), `No`, `No (desactivado)` o `Sin logs`, con la evidencia de carga y la última fecha de carga.
- De cada perfil de versión: id, `inheritsFrom`, tipo, clase principal (y si es una conocida de vanilla, Fabric, Quilt, Forge, NeoForge o LaunchWrapper), loader, argumentos JVM, agentes `-javaagent`, número de librerías y estado del SHA-1 (`Verified`, `Mismatch`, `NotDeclared`, `NoJar`, `Unreadable`).
- Carpetas no estándar del directorio de juego (las que no están en `standardGameDirectories`).

**Muestra:** tablas INSTANCIAS, MODS INSTALADOS / CARGADOS, PERFILES DE VERSIÓN y SESIONES REGISTRADAS EN LOGS (inicio, loader, versión, usuario, cliente y número de mods).

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `RemovedMod` | `DETECTED` | Low / Medium | Un log del periodo muestra un mod cargado (o un archivo de mod de Forge) que ningún JAR instalado declara. No cuenta los ids de plataforma (`minecraft`, `fabricloader`, `forge`, `java`...). |
| `VersionJarModified` | `DETECTED` | Medium / Medium | El SHA-1 del JAR de versión no coincide con el que declara el JSON de Mojang. |
| `VersionJavaAgent` | `INCONCLUSIVE` | Medium / Medium | El perfil de versión incluye `-javaagent`. El agente se añade a las rutas de evidencia si es una ruta local absoluta. |
| `VersionMainClass` | `INCONCLUSIVE` | Low / Low | Clase principal no reconocida. |
| `JavaAgentJar` | `INCONCLUSIVE` | Low / Low | Un JAR de `mods` declara `Premain-Class`, `Agent-Class` o `Launcher-Agent-Class`. |
| `InvalidJar` | `INCONCLUSIVE` | Low / Low | Un `.jar` que no es un ZIP legible. |

**Eventos de la línea temporal:** JAR de mod creado o copiado, JAR de mod modificado, perfil de versión modificado y sesión de Minecraft (inicio).

**Privacidad:** no lee archivos de cuentas (`launcher_accounts*.json` ni archivos de credenciales). Sí muestra el nombre de usuario de Minecraft que aparece en los logs, porque identifica la cuenta revisada.

## 03 Cheat Signature Scanner

**Administrador:** no.

**Lee:** los JAR de `mods` de cada instancia; los JAR de `versions\` cuyo SHA-1 no está verificado (si `scan.scanVersionJarsWhenHashUnverified` es `true`); `scan.extraScanPaths` y las rutas adicionales de la opción 03 (en carpetas: `*.jar`, `*.exe`, `*.dll` y `*.zip` hasta 2 niveles); las rutas de configuración que indican las firmas (en cada `gameDir` y en `%USERPROFILE%`); los perfiles de versión; y los logs ya interpretados por Minecraft. Si no se ejecutó Minecraft en la sesión, el menú lo lanza antes. Las rutas de la opción 03 se guardan como dato en la sesión (`ExtraScanPaths`) y se incluyen en todos los escaneos posteriores de esa sesión.

Cada escaneo vuelve a revisar todos los archivos: los escaneos repetidos o interrumpidos no se saltan nada.

**Extrae:** de cada archivo, el SHA-256, el tamaño, las fechas, las coincidencias con su ubicación (entrada, desplazamiento, codificación) y las estadísticas del escaneo (entradas revisadas, bytes descomprimidos, JAR anidados, entradas omitidas por tamaño, truncado).

**Muestra:** un resumen (archivos escaneados, con detección, no concluyentes, clientes e indicadores cargados, clientes sin firmas verificables) y las tarjetas de hallazgos. En el reporte, la sección ARCHIVOS ANALIZADOS lista cada archivo con su resultado (`Detección`, `No concluyente` o `Sin coincidencias`), su SHA-256 y su ruta.

**Hallazgos:**

| Categoría | Estado | Cuándo |
| --- | --- | --- |
| `CheatSignature` | `DETECTED` o `INCONCLUSIVE` según la confianza | Un archivo coincide con indicadores de un cliente. Incluye cada coincidencia como evidencia con su fuente y si está validada. |
| `ClientLog` | `DETECTED` o `INCONCLUSIVE` | Un log contiene el id de mod del cliente (en la lista de mods cargados, como mod anidado o entre los recursos) o un mensaje `log`. Es evidencia de carga o ejecución. |
| `ClientConfig` | `DETECTED` (como mucho confianza media) o `INCONCLUSIVE` | Existe una carpeta o archivo de configuración del cliente. Prueba uso pasado. |
| `ClientVersionProfile` | `DETECTED` o `INCONCLUSIVE` | Un perfil de versión coincide con un `versionId` o contiene un `jvmArg`. |
| `KeywordName` | `INCONCLUSIVE` (Low / Low) | El nombre del archivo contiene una palabra clave de un cliente, pero ninguna firma coincide con el contenido. |

**Eventos:** archivo con firma de cliente (última modificación), cliente detectado en log y configuración de cliente creada o modificada.

**Efectos en otros módulos:** cada archivo con una detección `DETECTED` se registra como indicador (nombre y SHA-256); las `INCONCLUSIVE` no, para que los demás módulos no emitan hallazgos por una simple coincidencia de nombre. Las palabras clave de todos los clientes se añaden a las de la revisión.

**Pasada sobre evidencias** (solo en el escaneo completo): `Signature Scan (evidencias)` escanea los `.jar`, `.exe`, `.dll` y `.zip` que todavía existen y que citaron otros módulos (solo rutas locales), con las mismas reglas. Omite únicamente los archivos que ya se escanearon por completo en la sesión.

## 04 Process Inspector

**Administrador:** no. Para listar las DLL de un Java que se ejecuta como administrador, Amon SS también debe ejecutarse elevado.

**Lee:** `Win32_Process` (nombre, PID, PID del padre, ruta, línea de comandos y hora de inicio), la firma Authenticode de los ejecutables y la lista de módulos cargados (rutas de DLL) de cada proceso Java.

**Selecciona como relevantes:** los procesos de `launcherProcessNames` (Java y launchers), los que tienen una palabra clave en el nombre o la ruta, y los que citan un indicador en su línea de comandos.

**Extrae de cada Java:** ejecutable, clase principal o `-jar`, agentes `-javaagent`, mods de `-Dfabric.addMods`, classpath (y los JAR que no son librerías, versiones ni runtimes), `-Xbootclasspath`, `--gameDir`, `--version`, `--username` y `--assetIndex`. La línea de comandos se tokeniza con las reglas de `CommandLineToArgvW`.

**Muestra:** la tabla PROCESOS RELEVANTES (proceso, PID, padre, tipo, firma o firmante, inicio y ruta) y una caja por cada Java con sus detalles, el usuario y la línea de comandos con los secretos ocultos.

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `ClientProcess` | `DETECTED` (indicador validado) o `INCONCLUSIVE` (sin validar) | Medium / Medium (validado) o Low (sin validar) | La línea de comandos contiene un `jvmArg` de las firmas. Evidencia de ejecución. |
| `JavaAgentProcess` | `INCONCLUSIVE` (o `INFO` si es el agente de Lunar Client) | Medium (o Info) / Medium | El proceso Java usa `-javaagent`. El JAR del agente se escanea en la pasada de evidencias. |
| `UnsignedModule` | `INCONCLUSIVE` | Low / Low | DLL sin firma válida cargada desde una carpeta de usuario, `ProgramData` o temporal. Excluye Windows, el propio Java, las nativas conocidas (LWJGL, GLFW, OpenAL, JNA, OBS, Steam, RivaTuner, Discord, Simple Voice Chat) y las carpetas de Lunar. |
| `UnsignedJava` | `INFO` | Info / Medium | El ejecutable de Java no tiene firma válida (suele ser un runtime empaquetado por un launcher). |
| `KeywordName` | `INCONCLUSIVE` | Low / Low | Nombre o ruta del proceso con una palabra clave de un cliente. |

**Eventos:** proceso iniciado (sigue en ejecución), si empezó dentro del periodo. Los agentes, los JAR de la línea de comandos y las DLL señaladas se añaden a las rutas de evidencia si son rutas locales absolutas.

**Privacidad:** solo se muestran los procesos relevantes; del resto solo se da el recuento. Se ocultan `--accessToken`, `--session`, `--clientId`, `--xuid`, `--password`, `--token`, `--refreshToken`, `--userProperties`, las propiedades `-D` con `token`, `password`, `passwd`, `secret`, `session` o `auth`, y los JWT. Nunca se finalizan procesos ni se lee su memoria.

## 05 Prefetch Analyzer

**Administrador:** sí. Sin elevación devuelve `SIN ACCESO`.

**Lee:** `C:\Windows\Prefetch\*.pf` (SCCA v17, v23, v26, v30 y v31; los comprimidos MAM se descomprimen con `RtlDecompressBufferEx`), el valor `EnablePrefetcher` del registro y el mapa de volúmenes para traducir `\VOLUME{...}` y `\DEVICE\HarddiskVolumeN` a letras de unidad. El mapa solo consulta los discos locales, fijos y extraíbles (`Win32_LogicalDisk` y `QueryDosDevice`): una unidad de red desconectada podría bloquear la consulta.

**Selecciona como relevantes:** los Prefetch de Java (`JAVA.EXE`, `JAVAW.EXE`), de launchers, de ejecutables con palabra clave y los que referencian un archivo señalado. La decisión se toma sobre los nombres en bruto, antes de traducir rutas: solo los Prefetch relevantes pagan la conversión de rutas y el análisis por archivo.

**Extrae:** ejecutable, hash del Prefetch, versión del formato, si estaba comprimido, contador de ejecuciones, hasta 8 últimas ejecuciones, ruta del ejecutable, JAR referenciados que no son librerías ni JAR de versión, coincidencias con indicadores, rutas con palabras clave y fechas del propio `.pf`.

**Muestra:** la tabla PREFETCH RELEVANTES (ejecutable, ejecuciones, última ejecución, número de JAR y ruta) y una caja "JAR CARGADOS POR ..." para cada ejecutable que cargó JAR (hasta 15).

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `ExecutionEvidence` | `DETECTED` | Medium / Medium | El Prefetch referencia un archivo con el mismo nombre que un indicador. |
| `JarOutsideMinecraft` | `INCONCLUSIVE` | Low / Medium | Java cargó un JAR desde Descargas, Escritorio, Documentos o Temp. |
| `KeywordName` | `INCONCLUSIVE` | Low / Low | Ejecutable con palabra clave que no es Java ni launcher. |

**Eventos:** cada ejecución registrada dentro del periodo (confianza alta). Los JAR referenciados se añaden a las rutas de evidencia (solo los que se tradujeron a una ruta local).

**Privacidad:** los Prefetch no relevantes no se muestran; se informa cuántos se omitieron.

## 06 Recycle Bin Forensics

**Administrador:** no.

**Lee:** `<unidad>:\$Recycle.Bin\<SID del usuario actual>` en cada unidad fija: los `$I` (metadatos) y los `$R` (contenido). Desde el menú, si hay privilegios de administrador y el USN Journal aún no se analizó, se ejecuta antes para poder cruzarlos.

**Extrae de cada `$I`:** versión (1 o 2), tamaño declarado, fecha de eliminación y ruta original. **De su `$R`:** presencia, si es carpeta y su tamaño real (en carpetas, hasta 5000 archivos).

**Relevante si:** el nombre original coincide con un indicador, la ruta original contiene una palabra clave, estaba en una carpeta de una instancia de Minecraft o su extensión está en `interestingExtensions` (`.jar`, `.exe`, `.dll`, `.bat`, `.cmd`, `.ps1`, `.vbs`, `.pf` por defecto). Un comprimido o un log no es relevante solo por su extensión.

**Muestra:** la caja RECYCLE BIN ACTIVITY con el recuento por categoría y las 25 operaciones más recientes, y la tabla ELEMENTOS RELEVANTES EN LA PAPELERA (nombre original, fecha de eliminación, `$R` presente o ausente, incidencias y ruta original).

Categorías de RECYCLE BIN ACTIVITY:

| Categoría | Significado |
| --- | --- |
| Eliminación registrada | Un `$I` con fecha de eliminación dentro del periodo. |
| Inconsistencia de metadatos | `$I` ilegible, tamaño declarado distinto del real, fecha nula, futura o distinta de la creación del `$I`, o `$R` sin `$I`. |
| Archivo asociado ausente | Existe el `$I` pero no su `$R`. |
| Actividad correlacionada | Cruce con el USN Journal (lo añade el motor de correlación, que rehace estas filas cada vez que correlaciona): envío confirmado por el journal, elemento enviado que ya no está en la papelera, eliminación definitiva o modificación del contenedor que coincide con purgas registradas. |
| Evidencia insuficiente | Sin carpeta o sin acceso, papelera vacía con contenedor modificado, contenedor modificado después de la última eliminación, o ninguna operación en el periodo. |

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `RelevantDeletion` | `DETECTED` | Medium si coincide con un indicador, una palabra clave o una carpeta de Minecraft; Low si solo por extensión / High | Elemento relevante enviado a la papelera dentro del periodo. |
| `OrphanRecycleData` | `INCONCLUSIVE` | Low / Medium | Contenido `$R` sin su `$I`. |

**Eventos:** archivo enviado a la papelera (confianza alta) y contenedor de la papelera modificado (confianza baja).

**Efectos:** los `$R` con extensión `.jar`, `.exe`, `.dll` o `.zip` se escanean con firmas en su sitio, sin restaurarlos.

**Privacidad:** los elementos no relevantes se cuentan por extensión y su ruta se sustituye por "(elemento no relacionado ..., ruta omitida por privacidad)", salvo que `privacy.showUnrelatedRecycleEntries` sea `true`. Nunca se restaura, mueve ni elimina nada, y nunca se afirma intención.

## 07 NTFS / USN Journal

**Administrador:** sí. Sin elevación devuelve `SIN ACCESO`.

**Lee:** el USN Journal (`$Extend\$UsnJrnl:$J`) de la unidad del sistema y de las unidades donde están las instancias (resolviendo junctions), con `FSCTL_QUERY_USN_JOURNAL` y `FSCTL_READ_USN_JOURNAL`, siempre en modo de lectura.

**Filtra en C#** los registros del periodo (más 10 minutos) que sean finales (con `CLOSE` o `RENAME_OLD_NAME`) y cumplan alguna de estas condiciones: estar directamente en una carpeta de una instancia (`gameDir`, `mods`, `logs`, `versions`, `config`); empezar por `$I` o `$R`; ser `.jar`; ser `.pf`, `.exe`, `.bat`, `.cmd`, `.ps1` o `.vbs` borrado o renombrado (en todo el volumen); o contener una palabra clave o un indicador de al menos 4 caracteres. Un renombrado también pasa si su nombre anterior cumplía alguna condición.

La carpeta Prefetch no se vigila entera (cada programa que se abre actualiza su `.pf`), y los borrados de comprimidos (`.zip`, `.rar`, `.7z`), logs (`.log`, `.gz`) y DLL fuera de las carpetas de las instancias no se registran por su extensión: exponen nombres personales o son ruido de Windows Update. Los logs de Minecraft entran por las carpetas de las instancias. El filtro por carpeta compara la referencia NTFS del directorio padre de cada registro con la de esas carpetas (`GetFileReference`).

Hasta `maxUsnResults` registros por unidad: al alcanzarlo se conservan los **más recientes** y se descartan los más antiguos.

**Extrae:** fecha, USN, nombre, ruta reconstruida con la ubicación **actual** del directorio padre (o solo el nombre si ya no existe) y su fiabilidad, operación (eliminación, renombrado anterior o nuevo, creación, modificación de datos, cambio de atributos o de seguridad), motivos, referencias de archivo, nombre y carpeta anteriores en los renombrados, y datos del journal (identificador, tamaño máximo, primer y último registro, total de registros).

**Muestra:** las tablas JOURNALS, ACTIVIDAD DE PAPELERA SEGÚN EL JOURNAL (envíos con nombre y carpeta originales, purgas y metadatos creados) y REGISTROS RELEVANTES.

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `IndicatorFileChange` | `DETECTED` | Medium / Medium (Low si solo se conoce el nombre) | Eliminación o renombrado de un archivo cuyo nombre coincide con un indicador. |
| `RecycleUsn` | `DETECTED` | Low / High | Envío a la papelera de un `.jar`, `.exe`, `.dll` o de un nombre con palabra clave, con su eliminación definitiva si consta. |
| `PrefetchDeleted` | `INCONCLUSIVE` | Low / Medium | Borrado de archivos `.pf`. Muestra los nombres de los relacionados con la revisión (palabra clave o indicador) y cuenta el resto como "N de programas no relacionados (nombres omitidos)". |
| `MinecraftLogDeleted` | `INCONCLUSIVE` | Low / Medium | Borrado de logs de Minecraft o de launchers. |
| `JournalRecent` | `INCONCLUSIVE` | Low / Low | El identificador del journal, leído como fecha, cae en el periodo y coincide con el registro más antiguo: el journal pudo crearse o recrearse hace poco. |

**Eventos:** cada registro relevante (`USN: <operación>`), con confianza media si la ruta está reconstruida y baja si solo se conoce el nombre.

**Privacidad:** los renombrados a `$R` revelan el nombre original de cualquier archivo enviado a la papelera; ese nombre solo se conserva si es relevante (extensión de `interestingExtensions`, indicador o palabra clave) y se informa cuántos se ocultaron. Los registros de `.pf` de programas no relacionados no se muestran en la tabla ni en la línea temporal: sus borrados solo se cuentan en `PrefetchDeleted`. El resto del journal solo se cuenta. Nunca se modifica, trunca ni elimina el journal.

## 08 Recent & UserAssist

### Recent Files

**Administrador:** no.

**Lee:** `%APPDATA%\Microsoft\Windows\Recent\*.lnk` con un parser propio de MS-SHLLINK.

**Extrae:** ruta de destino (local o de red), argumentos, fechas y tamaño del destino guardados en el `.lnk`, serie del volumen, si el destino existe todavía, y las fechas del propio `.lnk` (creación aproximada a la primera apertura, modificación a la última). La existencia del destino solo se comprueba en rutas locales: un destino de red no se toca y figura como inexistente.

**Relevante si:** el nombre coincide con un indicador, la ruta contiene una palabra clave, o la extensión es `.jar`, `.exe` o `.dll`. Un comprimido (`.zip`, `.rar`, `.7z`) no es relevante solo por su extensión.

**Muestra:** la tabla ACCESOS RECIENTES RELEVANTES (última y primera apertura, si existe, motivo y destino) y el recuento de accesos no relacionados.

**Hallazgos:** `ExecutionEvidence` (`DETECTED`, Medium / Medium) si el archivo abierto coincide con un indicador, y `KeywordName` (`INCONCLUSIVE`) si la ruta contiene una palabra clave de un cliente.

**Eventos:** primera y última apertura registradas dentro del periodo. Los `.jar`, `.exe`, `.dll` y `.zip` relevantes que todavía existen en una ruta local se añaden a las rutas de evidencia.

### UserAssist

**Administrador:** no.

**Lee:** `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist\{GUID}\Count` (categorías Ejecutables y Accesos directos, y otras por GUID).

**Extrae:** nombre decodificado de ROT13, ruta con las carpetas conocidas resueltas (`{GUID}` de Program Files, Descargas, Escritorio, AppData...), contador de ejecuciones, veces con foco, segundos con foco y última ejecución (datos de 72 bytes de Windows 7 o posterior; también el formato de XP).

**Relevante si:** coincide con un indicador, contiene una palabra clave o es un `.jar`.

**Muestra:** la tabla ENTRADAS RELEVANTES (última ejecución, ejecuciones, segundos con foco, tipo y programa) y el recuento de entradas no relacionadas.

**Hallazgos:** `ExecutionEvidence` (`DETECTED`, Medium / Medium) si coincide con un indicador, y `KeywordName` (`INCONCLUSIVE`) si contiene una palabra clave de un cliente.

**Eventos:** última ejecución registrada dentro del periodo. Los `.jar` y `.exe` que todavía existen se añaden a las rutas de evidencia (salvo los JAR dentro de `.minecraft`).

## 09 Windows Event Analysis

**Administrador:** parcial. Sin privilegios no se lee el registro de Seguridad y el módulo queda `PARCIAL`; System, Defender y las claves Run se leen por separado y cada fuente que falla se informa como advertencia. La pantalla de alcance del escaneo completo lo indica como "sin administrador: solo System, Defender y claves Run (PARCIAL)".

**Lee:**

| Fuente | Qué |
| --- | --- |
| Security 4688 | Creación de procesos del periodo (hasta 30000): proceso, línea de comandos, proceso padre y usuario. |
| Security 1102 | Los 50 borrados del registro de Seguridad más recientes, con la cuenta. |
| System 104 | Los 50 borrados de otros registros más recientes (proveedor `Microsoft-Windows-Eventlog`), con el canal y la cuenta. |
| Defender 1116/1117 | Detecciones del periodo (hasta 500): amenaza, ruta y acción. |
| Auditoría | Si la subcategoría "Creación del proceso" está habilitada (`AuditQuerySystemPolicy`) y si incluye la línea de comandos (`ProcessCreationIncludeCmdLine_Enabled`). |
| Claves Run | `Run` y `RunOnce` de HKCU y HKLM, y `Run` de `WOW6432Node`. |

**Muestra:** la caja AUDITORÍA (4688 habilitado, línea de comandos, acceso al registro de Seguridad, número de entradas Run) y la tabla EVENTOS Y ENTRADAS RELEVANTES.

**Hallazgos:**

| Categoría | Estado | Severidad / confianza | Cuándo |
| --- | --- | --- | --- |
| `ExecutionEvidence` | `DETECTED` | Medium / High | Un 4688 relacionado por nombre o línea de comandos con un indicador. Evidencia de ejecución. |
| `SecurityLogCleared` | `DETECTED` dentro del periodo, `INFO` fuera | Medium (Info) / High | Evento 1102. No tiene relación con la papelera de reciclaje. |
| `EventLogCleared` | `DETECTED` | Low / High | Evento 104 dentro del periodo. |
| `DefenderDetection` | `DETECTED` | Medium / High | Detección de Defender relacionada con la revisión (palabra clave, indicador o ruta `.jar`). |
| `AutorunRelated` | `INCONCLUSIVE` | Low / Low | Una entrada Run contiene un indicador o una palabra clave de un cliente. Los launchers que arrancan con Windows solo se listan. |
| `KeywordName` | `INCONCLUSIVE` | Low / Low | Un 4688 cuyo proceso contiene una palabra clave de un cliente. |

**Eventos:** proceso creado (4688), registro de Seguridad borrado (1102), registro de eventos borrado (104) y detección de Windows Defender.

**Privacidad:** de los 4688 solo se muestran los relacionados con Java, launchers, palabras clave o indicadores, y sus líneas de comandos pasan por la ocultación de secretos. Las entradas de inicio automático se listan todas en la vista, con su motivo de relevancia. No modifica el registro, la auditoría ni los registros de eventos.

## Temp Indicator Sweep (escaneo completo)

No tiene opción propia en el menú: se ejecuta dentro del escaneo completo (`Temp` en `modules` o en `-Modules`) o con `-Scan Temp`.

**Administrador:** no.

**Lee:** `%TEMP%`, hasta 3 niveles y `maxTempFiles` archivos, solo `*.jar`, `*.exe`, `*.dll` y `*.zip`, y **solo si** ya hay un nombre de archivo o un SHA-256 concreto registrado como indicador, es decir, si el escáner de firmas tuvo alguna detección `DETECTED`. Si no, devuelve `OMITIDO`. Por eso `-Scan Temp` ejecuta antes Minecraft y Signatures.

**Hallazgos:** `TempIndicator`: `DETECTED` (Medium / High) si coincide el SHA-256, o `INCONCLUSIVE` (Low / Low) si solo coincide el nombre; en ese caso el archivo se añade a la pasada de firmas.

**Eventos:** archivo relacionado en Temp creado o modificado.

## 10 Forensic Timeline

Reúne los eventos de todos los módulos de la sesión, filtra el intervalo, elimina duplicados (mismo segundo, tipo y ruta) y los ordena. Cada fila tiene fecha, hora local, desplazamiento UTC, tipo, fuente, módulo, ruta, indicador, confianza y descripción, y se resalta si el archivo coincide con un indicador o el evento lleva uno. No interpola ni inventa horas. Ver [COMMANDS.md](COMMANDS.md#línea-temporal-10).

## Detection & Correlation Engine

Se ejecuta al final del escaneo completo, después de cada módulo suelto y al exportar. No lee artefactos: trabaja con los hallazgos, los eventos y la tabla de mods.

- **Por cliente:** reúne los hallazgos del cliente y, para cada ancla con ruta, los hallazgos de otros módulos con la misma ruta, el mismo nombre de archivo o el mismo SHA-256, los eventos de otros módulos sobre el mismo nombre de archivo (ejecución, borrado, renombrado, presencia o carga) y los mods de la misma ruta que los logs marcan como cargados. Si hay al menos un ancla `DETECTED` y dos tipos de fuente distintos, crea un hallazgo `ClientCorrelation` (`CORRELATED`). Confianza alta solo si el ancla es de confianza alta; si no, media. Severidad baja para `dual-use`.
- **Nombres genéricos:** si el archivo del ancla tiene un nombre que comparten todas las instalaciones (`java.exe`, `javaw.exe`, `javaws.exe`, `jp2launcher.exe`, `latest.log`, `debug.log`, `client.jar`, `minecraft.jar`, `launcher_profiles.json`, `options.txt`, `minecraftlauncher.exe`, `minecraft.exe`, cualquier `.log` o `.log.gz`, o un JAR de versión como `1.20.1.jar`), no se relaciona nada por nombre ni por ruta: solo vale el mismo SHA-256.
- **Tipo de fuente:** sale del módulo que produjo el hallazgo o el evento, no del texto de su fuente. Así, el USN Journal de varias unidades es una sola fuente, y la "Sesión de Minecraft" de un log cuenta como el propio log (no como segunda fuente de un `ClientLog` de ese log).
- **Por archivo sin cliente:** si dos o más fuentes registran actividad sobre el mismo `.jar`, `.exe` o `.dll` (que no tenga un nombre genérico) y al menos una es `DETECTED`, crea `FileActivityCorrelation` (`CORRELATED`, Low / Medium), que describe actividad sin identificar software.
- **Papelera y USN Journal:** añade la "Actividad correlacionada" a RECYCLE BIN ACTIVITY. Las filas se rehacen en cada correlación, así que no se duplican aunque la correlación se repita.
- **Veredicto por cliente:** `CORRELATED`, `DETECTED`, `INCONCLUSIVE` o `NOT DETECTED`, con justificación y confianza, y una conclusión para revisión humana que nombra los clientes con evidencias, las herramientas de uso dual, los módulos sin acceso y los clientes sin firmas verificables.

## 11 Evidence Reports

Exporta el modelo de la sesión en TXT, JSON y HTML con el manifiesto `<id>.sha256`, y verifica manifiestos. Contenido del reporte: identificador, herramienta y versión, fechas, zona horaria, periodo, equipo, usuario de Windows, SID, privilegios y sistema operativo, alcance autorizado, módulos con estado y duración, módulos sin acceso, veredicto por cliente, hallazgos con evidencias y falsos positivos, archivos analizados con firmas, datos de Minecraft (instancias, sesiones, versiones y mods), RECYCLE BIN ACTIVITY, línea temporal, advertencias, limitaciones y conclusión. El TXT elimina de los datos los caracteres de control y los saltos de línea incrustados (un artefacto no puede falsificar líneas del reporte) y el HTML escapa todos los valores. Ver [README](../README.md#reportes-e-integridad).

## 12 Settings

Tema, glifos, periodo por defecto, carpeta y formatos de reporte, animaciones, rutas extra de instancia y búsqueda de actualizaciones verificadas (el repositorio se valida antes de guardarse y una etiqueta que no sea un número de versión no se ofrece para instalar). Ver [COMMANDS.md](COMMANDS.md#submenú-settings-12) e [INSTALL.md](INSTALL.md#actualizar).
