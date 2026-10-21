# Amon SS - Advanced Minecraft Forensic Suite

Herramienta forense de **solo lectura**, escrita en PowerShell, para revisiones SS (ScreenShare) de Minecraft Java Edition en Windows 10 y 11. Revisa instancias y mods, busca firmas de clientes modificados en los archivos y en la memoria del juego en ejecución, y reúne artefactos de Windows (procesos, Prefetch, BAM, PCA, ShimCache, papelera, USN Journal, Recent, UserAssist, eventos y señales de evasión). Después correlaciona todo en una línea temporal y genera un reporte verificable con SHA-256.

La conclusión siempre queda en manos de una persona: Amon SS describe lo que encontró, de dónde sale cada dato y con qué confianza. No emite sanciones.

## Qué es

- Un script (`Start-AmonSS.ps1`) que al abrirse hace la revisión completa solo (escaneo, veredicto y reporte) y termina en un menú de una tecla, y un modo no interactivo para automatizar revisiones.
- Un conjunto de módulos PowerShell (`modules\*.psm1`) con código C# que se compila en memoria (`Native\AmonNative.cs` y `Native\AmonZip.cs`): el motor de búsqueda Aho-Corasick, el lector del USN Journal y el lector de memoria de procesos.
- Un motor de firmas basado en archivos JSON (`signatures\*.json`). Cada indicador cita su fuente, y las firmas sin validar tienen la confianza limitada.
- Un motor de correlación que solo relaciona evidencias que comparten una clave concreta (cliente, ruta, nombre de archivo o SHA-256).

## Qué no es

- **No sanciona.** No emite veredictos automáticos: el resultado global (`INDICADORES ENCONTRADOS`, `REVISAR A MANO` o `SIN INDICADORES`) es un resumen "para revisión humana".
- **No modifica el sistema.** No restaura, mueve ni borra archivos, no finaliza ni suspende procesos y no cambia registros, servicios, auditorías ni políticas. Solo escribe sus propios ajustes y los reportes.
- **No vuelca memoria.** El escáner de memoria lee la de los procesos de Java en ejecución, pero solo busca las firmas y no guarda nada de su contenido; del `explorer.exe` del usuario solo extrae las rutas de las trazas `PcaClient` (ver [Privacidad y seguridad](#privacidad-y-seguridad)).
- **No envía datos.** No tiene telemetría ni webhooks. Solo se conecta a internet al instalarse con el comando de una línea y al buscar actualizaciones, y esto último solo si el operador lo pide en Ajustes.
- **No es un antitrampas en tiempo real.** La memoria solo se revisa en el momento de la revisión y con las firmas conocidas; un cliente sin firmas verificables, ofuscado o ya descargado puede no dejar rastro en lo que se analiza (ver [limitaciones](docs/LIMITATIONS.md)).
- **No pide consentimiento en pantalla.** El consentimiento lo cubren los términos de la SS del servidor. El reporte deja constancia en su alcance autorizado del usuario de Windows, el equipo, la fecha y si la revisión se ejecutó como administrador.

## Identidad visual

La interfaz usa una paleta morada con tres temas (`FullPurple`, `MinimalPurple` y `ClassicTerminal`), un banner con degradado y tres juegos de glifos (`Full`, `Safe` y `Ascii`), que se eligen según la terminal. Los ejemplos siguientes se generaron con el propio módulo `UI.psm1`, sin color y con 100 columnas de ancho:

```
powershell -NoProfile -Command "Import-Module 'modules\UI.psm1'; Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 100 -NoAnimation; Format-AmonBanner -Version '1.1.0' -BuildDate '2026-10-21' -System 'WINDOWS 11 PRO  BUILD 26200' -Privilege 'ADMINISTRADOR'"
```

Banner:

```text
╔═════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                                                                                 ║
║                    █████╗ ███╗   ███╗ ██████╗ ███╗   ██╗    ███████╗███████╗                    ║
║                   ██╔══██╗████╗ ████║██╔═══██╗████╗  ██║    ██╔════╝██╔════╝                    ║
║                   ███████║██╔████╔██║██║   ██║██╔██╗ ██║    ███████╗███████╗                    ║
║                   ██╔══██║██║╚██╔╝██║██║   ██║██║╚██╗██║    ╚════██║╚════██║                    ║
║                   ██║  ██║██║ ╚═╝ ██║╚██████╔╝██║ ╚████║    ███████║███████║                    ║
║                   ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═══╝    ╚══════╝╚══════╝                    ║
║                                                                                                 ║
║                             ✦  ADVANCED MINECRAFT FORENSIC SUITE  ✦                             ║
║                                                                                                 ║
╠═════════════════════════════════════════════════════════════════════════════════════════════════╣
║ ◆ STATUS    : READY                            ◆ VERSION   : v1.1.0  2026-10-21                 ║
║ ◆ SYSTEM    : WINDOWS 11 PRO  BUILD 26200      ◆ THEME     : FULL PURPLE                        ║
║ ◆ MODE      : LOCAL FORENSIC                   ◆ PRIVILEGE : ADMINISTRADOR                      ║
╚═════════════════════════════════════════════════════════════════════════════════════════════════╝
```

Menú final de la revisión automática (`Format-AmonMenu` con los elementos de `Invoke-AmonFinalMenu`, en `Start-AmonSS.ps1`). Cada opción es una sola tecla, sin Enter:

```text
╔════════════════════════════════════ ◆ REVISIÓN TERMINADA ◆ ═════════════════════════════════════╗
║                                                                                                 ║
║  [H] ◆ ABRIR EL REPORTE   versión HTML en el navegador                                          ║
║  [D] ◆ DETALLE            resultados de cada módulo                                             ║
║  [T] ◆ LÍNEA TEMPORAL     últimos 7 días                                                        ║
║  [R] ◆ REPETIR            volver a escanear todo                                                ║
║  [M] ◆ MÁS OPCIONES       módulos sueltos, verificación y ajustes                               ║
║                                                                                                 ║
║  [Q] ◇ SALIR                                                                                    ║
║                                                                                                 ║
╚═════════════════════════════════════════════════════════════════════════════════════════════════╝
```

Tarjeta de hallazgo (`Format-AmonFinding`). **Ejemplo ficticio**: el cliente, la ruta, el hash y la firma son inventados y no existen en `signatures\`. La fecha se muestra en hora local con su desplazamiento UTC.

```text
┌── ● DETECTED  EJEMPLO FICTICIO (Cliente de prueba) ────────────────────────── CONFIANZA MEDIA ──┐
│ Cliente      Cliente de prueba                                                                  │
│ Indicador    ejemplo/ficticio/ (paquete Java) +1                                                │
│ Ruta         C:\Users\Ejemplo\AppData\Roaming\.minecraft\mods\ejemplo-ficticio-1.0.jar          │
│ SHA-256      0000000000000000000000000000000000000000000000000000000000000000                   │
│ Fecha        2026-10-19 11:42:07 UTC-07:00                                                      │
│ Fuente       Signatures: firma de ejemplo (no existe en signatures/)                            │
│ Motivo       2 indicador(es) coincidente(s): 0 validado(s) con fuente pública y 2 sin validar.  │
│              Datos inventados para la documentación.                                            │
│ Evidencias   ▸ paquete Java 'ejemplo/ficticio/' en entrada ejemplo/ficticio/Main.class. Fuente: │
│                ejemplo (user-provided, sin validar).                                            │
│ Posibles FP  Ejemplo ilustrativo: no corresponde a ningún archivo real.                         │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘
```

## Inicio rápido

Abre **CMD** (Símbolo del sistema), preferiblemente como administrador y con la misma cuenta de Windows que usa el jugador, y pega el comando de instalación de la versión publicada. Esta es su plantilla. El script de release (`tools\Build-Release.ps1`) sustituye `VERSION`, `HASH` y `OWNER`, y el comando definitivo se publica en cada release (`INSTALL-CMD.txt` y en las notas de la versión):

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "$v='VERSION';$h='HASH';$u='https://github.com/OWNER/Amon-SS/releases/download/v'+$v+'/Amon-SS-'+$v+'.zip';$d=Join-Path $env:LOCALAPPDATA ('AmonSS\versions\'+$v);$z=$d+'.zip';[Net.ServicePointManager]::SecurityProtocol='Tls12';New-Item -ItemType Directory -Force -Path (Split-Path $z) | Out-Null;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $z;if((Get-FileHash -LiteralPath $z -Algorithm SHA256).Hash -ne $h){Remove-Item -LiteralPath $z;throw 'SHA-256 no coincide: descarga rechazada'};Expand-Archive -LiteralPath $z -DestinationPath $d -Force;Get-ChildItem -LiteralPath $d -Recurse -File | Unblock-File;& (Join-Path $d 'Start-AmonSS.ps1')"
```

El comando descarga una versión fija, **rechaza el ZIP si su SHA-256 no coincide**, lo extrae en `%LOCALAPPDATA%\AmonSS\versions\<versión>`, quita la marca de internet de esos archivos y abre Amon SS. `-ExecutionPolicy RemoteSigned` solo se aplica a ese proceso y no cambia ninguna política persistente. Mientras el repositorio de GitHub sea privado, el comando no puede descargar de forma anónima. Los detalles, la instalación manual verificada y el uso con scripts firmados (`AllSigned`) están en [docs/INSTALL.md](docs/INSTALL.md).

Al abrirse, Amon SS trabaja solo:

1. Muestra el banner. Si no se ejecuta como administrador, ofrece reabrirse como tal: `A` lo hace (con el aviso UAC de Windows) y Enter, o esperar 10 s, sigue sin administrador.
2. Ejecuta el escaneo completo, muestra el veredicto y exporta el reporte (TXT, JSON y HTML por defecto) con su manifiesto SHA-256.
3. Termina en el menú de una tecla: `H` abre el reporte HTML, `D` muestra el detalle de cada módulo, `T` la línea temporal, `R` repite el escaneo, `M` abre más opciones y `Q` o `Esc` salen. Enter no hace nada en ese menú, a propósito.

Cada release lleva `Integrity.psd1` con el SHA-256 de todos sus archivos. Amon SS comprueba con él el código C#, las firmas y la configuración al cargarlos, y `-VerifyPackage` comprueba la instalación completa:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\<versión>\Start-AmonSS.ps1" -VerifyPackage
```

Desde una copia local ya verificada:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
```

Modo no interactivo:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -ConsentNote "Ticket 123" -Report json,html
```

Todas las opciones están en [docs/COMMANDS.md](docs/COMMANDS.md).

## Módulos

En el orden en que los ejecuta el escaneo completo:

| Módulo | Administrador | Resumen |
| --- | --- | --- |
| Minecraft Analysis | No | Instancias, loaders, mods instalados frente a cargados, perfiles de versión |
| Cheat Signature Scanner | No | Firmas JSON sobre JAR, configuraciones, perfiles y logs |
| Process Inspector | No (sí para ver las DLL de un Java elevado) | Java y launchers en ejecución, agentes cargados en caliente, JNativeHook y herramientas por nombre |
| Java Memory Scanner | No (sí si el juego se ejecuta como administrador) | Firmas en la memoria de Java en ejecución |
| Prefetch Analyzer | Sí | Ejecuciones registradas, herramientas por nombre y programas lanzados desde unidades externas |
| BAM | Sí | Última ejecución de cada programa según Windows |
| PCA & MUICache | No | Programas abiertos desde la interfaz gráfica (con hora en Windows 11 22H2 o posterior) |
| ShimCache | No | Ejecutables que el sistema vio antes del último arranque |
| Recent Files | No | Accesos directos recientes del Explorador |
| UserAssist | No | Programas iniciados desde el Explorador |
| Windows Event Analysis | Parcial (el registro de Seguridad sí lo requiere) | 4688, 1102, 104, 7045, Ntfs 501, Defender, caídas de Java y claves Run |
| Bypass & Tamper Check | No | Servicios forenses detenidos o reiniciados y cambios de la hora del sistema |
| Temp Indicator Sweep | No | DLL de JNativeHook y, con indicadores concretos, copias en `%TEMP%` |
| Recycle Bin Forensics | No | `$I`/`$R` de la papelera del usuario actual |
| NTFS / USN Journal | Sí | Creaciones, borrados y renombrados relevantes |

**Minecraft Analysis.** Localiza instancias de Minecraft Launcher, TLauncher, Badlion, Lunar Client (cada perfil), Feather, Prism Launcher, PolyMC, CurseForge, Modrinth App y GDLauncher. También usa las rutas que configures y el `--gameDir` de los procesos Java vivos (solo rutas locales); así se detectan launchers portables como MultiMC cuando el juego está abierto. Lee `latest.log` y los logs rotados (`.log.gz`) del periodo, distingue los mods **instalados** (JAR en `mods`) de los **cargados** (los cita un log), avisa de los mods que se cargaron y ya no están, y comprueba los perfiles de `versions\`: clase principal, `-javaagent` y SHA-1 del JAR frente al valor que declara el JSON de Mojang.

**Cheat Signature Scanner.** Escanea los JAR de las instancias (con JAR anidados), los JAR de versión cuyo SHA-1 no se pudo verificar y las rutas extra. Busca paquetes, entradas, entrypoints, atributos del MANIFEST, ids de mod, cadenas y firmas binarias (en los bytes en bruto y en el contenido descomprimido de cada entrada) y SHA-256. También revisa carpetas de configuración, perfiles de versión, argumentos JVM y logs. Ver [docs/SIGNATURES.md](docs/SIGNATURES.md).

**Process Inspector.** Lee `Win32_Process` y muestra solo Java, los launchers conocidos y los procesos que coinciden con palabras clave, indicadores o nombres de herramientas conocidas (firmas `filename`). De cada Java extrae la clase principal, `-jar`, `-javaagent`, `-Dfabric.addMods`, el classpath fuera de librerías, la versión, `--gameDir` y el usuario, siempre con los tokens de sesión ocultos. Comprueba la firma Authenticode, señala las DLL sin firma cargadas desde carpetas de usuario, un agente Java cargado con el juego ya en marcha (`instrument.dll` sin `-javaagent` en la línea de comandos) y la librería JNativeHook (gancho global de teclado y ratón que usan muchos autoclickers en Java).

**Java Memory Scanner.** Busca en la memoria de los `java.exe`/`javaw.exe` en ejecución los paquetes y clases de las firmas (en forma interna con `/` y en forma Java con `.`) y sus cadenas largas, en ASCII y UTF-16LE. Es la prueba más directa de que un cliente está cargado ahora mismo, también si se inyectó sin dejar un JAR en disco. Solo lectura, con un límite de 3 GB y 60 s por proceso. Si no hay Minecraft abierto, el módulo queda `OMITIDO` y avisa de que hay que abrirlo antes de la revisión.

**Prefetch Analyzer.** Interpreta los Prefetch SCCA v17, v23, v26, v30 y v31, incluidos los comprimidos MAM (XPRESS Huffman) de Windows 10 y 11. Extrae el contador y las hasta 8 últimas ejecuciones, los archivos referenciados y los JAR que cargó Java fuera de las librerías. Reconoce herramientas por su nombre de ejecutable y señala los programas ejecutados en el periodo desde una unidad extraíble o desde un volumen que ya no está conectado. Solo muestra los Prefetch relacionados con la revisión; del resto da el recuento.

**BAM, PCA & MUICache y ShimCache.** Tres registros de Windows sobre programas ejecutados: BAM guarda la última ejecución de cada programa (requiere administrador); PCA, los programas abiertos desde la interfaz gráfica (con hora en `PcaAppLaunchDic.txt` de Windows 11 22H2 o posterior, y también en la memoria del Explorador, la clave `Compatibility Assistant\Store` y `MuiCache`); y ShimCache, los ejecutables que el sistema vio antes del último arranque (no prueba que se ejecutaran). Los tres solo muestran los ejecutables relevantes y cuentan el resto. BAM y PCA añaden un aviso `INFO` "para revisar" con los ejecutables del periodo lanzados desde Descargas, Escritorio, Documentos, Temp u otra unidad que no tienen firma válida o ya no existen.

**Recent Files y UserAssist.** Interpreta los `.lnk` de `Recent` con un parser propio de MS-SHLLINK y las entradas ROT13 de UserAssist (contador, foco y última ejecución). Muestra solo lo relacionado con Minecraft, los JAR y ejecutables, o los indicadores encontrados. Los destinos de red de los accesos directos no se tocan.

**Windows Event Analysis.** Revisa el evento 4688 (creación de procesos) filtrado a Java, launchers e indicadores, e indica si la auditoría está activa y si incluye la línea de comandos. También el 1102 (borrado del registro de Seguridad), el 104 (borrado de otros registros), el 7045 (servicio o driver instalado desde una carpeta de usuario), el 501 de Ntfs/Operational (USN Journal eliminado), Defender 1116/1117 relacionados con la revisión, 5007 (exclusiones) y 5001 (protección en tiempo real desactivada), el 1000 de Application Error cuando Java o un launcher se cierra por una DLL ajena, y las claves Run/RunOnce.

**Bypass & Tamper Check.** Comprueba si los servicios que generan rastros forenses (SysMain, PcaSvc, DPS, EventLog y el controlador `bam`) están detenidos, deshabilitados o se reiniciaron mucho después del arranque, los cambios de su tipo de inicio y sus caídas, y los cambios de la hora del sistema de 2 minutos o más con el programa que los hizo. Nada de esto prueba trampas: indica que los rastros de Windows pueden estar incompletos.

**Temp Indicator Sweep.** Busca siempre, solo por nombre, la DLL que JNativeHook extrae en el primer nivel de `%TEMP%`. El resto de la carpeta solo se revisa si el escáner de firmas ya registró un nombre de archivo y un SHA-256 concretos (una detección `DETECTED`).

**Recycle Bin Forensics.** Interpreta los `$I` v1 y v2 (tamaño, fecha de eliminación y ruta original) y su `$R`. La vista RECYCLE BIN ACTIVITY resume eliminaciones, metadatos incoherentes, contenido ausente y cambios del contenedor, sin restaurar nada y sin atribuir intenciones.

**NTFS / USN Journal.** Lee el journal con `FSCTL_READ_USN_JOURNAL` (solo lectura) y filtra en C# por JAR, `$I`/`$R`, borrados o renombrados de `.pf`, ejecutables y scripts, palabras clave, indicadores y carpetas de las instancias. Reconstruye los envíos a la papelera aunque después se vaciara. Al alcanzar el máximo de registros conserva los más recientes, y los Prefetch borrados de programas no relacionados solo se cuentan.

**Detection & Correlation Engine, línea temporal y reportes.** Agrupa los hallazgos por cliente, calcula el estado de cada uno y el resultado global, y crea una línea temporal donde cada fila procede de un artefacto concreto. Exporta TXT, JSON y HTML con un manifiesto SHA-256. En el escaneo completo, una segunda pasada de firmas revisa los archivos que citan otros módulos (JAR de Prefetch, ejecutables de BAM, PCA y ShimCache, Recent, `$R` de la papelera, agentes Java, DLL de caídas de Java...).

El detalle de cada módulo está en [docs/MODULES.md](docs/MODULES.md).

## Estados de resultado

Definidos en `modules\Correlation.psm1`:

| Estado | Significado |
| --- | --- |
| `DETECTED` | Indicador presente. |
| `CORRELATED` | Dos o más fuentes **independientes** contienen información compatible. |
| `INCONCLUSIVE` | Información insuficiente (firmas débiles o no validadas). Una coincidencia solo de nombre se muestra como `INCONCLUSIVE` pero no cambia ni el veredicto del cliente ni el resultado global. |
| `NOT DETECTED` | No se encontraron indicadores dentro del alcance analizado. |
| `NOT COVERED` | Solo en el veredicto por cliente: el cliente no tiene firmas verificables y no se puede comprobar por archivo. |

Los hallazgos también pueden tener el estado `INFO` (dato de contexto sin valor acusatorio, por ejemplo el agente Java propio de Lunar Client o un ejecutable "para revisar"). La vista del veredicto y los reportes solo listan en la tabla los clientes con algún indicio; los clientes sin indicadores se resumen en una línea ("Sin indicadores (N clientes)") y los `NOT COVERED`, en otra línea gris aparte.

Además, la revisión tiene un **resultado global** de una palabra (`Correlation.Outcome`, que también aparece en los reportes TXT, JSON y HTML):

| Resultado | Cuándo |
| --- | --- |
| `INDICADORES ENCONTRADOS` | Algún cliente `CORRELATED` o `DETECTED` (salvo las herramientas de uso dual, como Baritone), o algún hallazgo `DETECTED` sin cliente (por ejemplo, un USN Journal eliminado o un cambio de hora). |
| `REVISAR A MANO` | Ningún caso anterior, pero sí algún hallazgo `INCONCLUSIVE` que no sea una simple coincidencia de nombre. |
| `SIN INDICADORES` | Ninguno de los anteriores. Los hallazgos `INFO` no cuentan. |

Reglas que conviene recordar:

- Solo se relacionan hallazgos que comparten el mismo cliente, la misma ruta, el mismo nombre de archivo o el mismo SHA-256. **La proximidad temporal sola nunca crea una relación.** Los nombres que comparten todas las instalaciones (`javaw.exe`, `latest.log`, `client.jar`, JAR de versión como `1.20.1.jar`...) no relacionan nada por nombre ni por ruta: con ellos solo vale el SHA-256.
- Las fuentes se cuentan por módulo: el USN Journal de varias unidades es una sola fuente, y la sesión de Minecraft de un log cuenta como el propio log.
- Un cliente sin firmas verificables quedaría como `NOT COVERED`, nunca como `NOT DETECTED` ni como sospechoso. Desde la 1.1.0 todos los clientes de las firmas tienen al menos un indicador con fuente (Vape, Raven, Inertia, Sigma, Rise y Novoline incluidos).
- Un nombre de archivo que contiene la palabra clave de un cliente (por ejemplo `wurst-rezepte.exe`) se muestra, pero no cuenta como indicio: no cambia el veredicto ni el resultado global.
- El software de macros (G HUB, iCUE, Synapse, AutoHotkey...) solo produce hallazgos `INFO`: tenerlo instalado es normal; sirve para revisar las macros a mano.
- Las firmas no validadas nunca superan la confianza media, y una correlación basada en ellas también se limita a media.
- `NOT DETECTED` y `SIN INDICADORES` describen el alcance analizado; no demuestran que el cliente no se usara.

## Privacidad y seguridad

- Solo lectura: los archivos se abren en modo de lectura compartida, el volumen se abre con acceso de lectura para consultar el USN Journal y los procesos se abren solo con permisos de consulta y lectura de memoria.
- Prefetch, BAM, PCA, ShimCache, Recent, UserAssist, papelera y USN muestran únicamente los artefactos relacionados con la revisión; el resto se cuenta. Los nombres originales de documentos personales enviados a la papelera se ocultan, y un Prefetch borrado de un programa no relacionado se cuenta sin mostrar su nombre. Un comprimido o un log no es relevante solo por su extensión. En `%TEMP%` solo se busca por nombre la DLL de JNativeHook; el resto, solo con indicadores concretos.
- Memoria: del escáner de Java solo quedan qué firmas aparecen y en qué dirección; de la memoria del `explorer.exe` del usuario solo se extraen las rutas que siguen al marcador de las trazas `PcaClient`. Nada se vuelca a disco.
- Las rutas de red que aparecen en artefactos (accesos directos, `-javaagent`, Prefetch, Recent, `gameDir` de perfiles, `--gameDir` de procesos) no se comprueban ni se escanean: solo se usan rutas absolutas de unidades locales, para no generar tráfico SMB/WebDAV ni autenticación NTLM.
- No se leen archivos de cuentas de los launchers. En las líneas de comandos se ocultan `--accessToken`, `--session`, `--password`, propiedades `-D...token/password...` y los JWT antes de mostrarlas o exportarlas.
- Los datos que vienen de artefactos (rutas, nombres, líneas de log) se limpian de caracteres de control antes de pintarse, así que un nombre de archivo con secuencias ANSI no puede alterar la terminal; además, las cajas de la terminal solo dejan pasar secuencias de color. El reporte TXT elimina los caracteres de control y los saltos de línea incrustados (no se pueden falsificar líneas) y el HTML escapa todos los valores.
- En una release, el código C#, las firmas y la configuración se verifican con `Integrity.psd1` antes de usarse.
- Nunca se ejecuta código de los archivos analizados: los JAR se leen como datos.
- Los reportes contienen datos identificativos del equipo (nombre del equipo, usuario de Windows y SID) y el nombre de usuario de Minecraft que aparece en los logs. Guárdalos con el mismo cuidado que cualquier evidencia.

Política de seguridad y modelo de amenazas: [SECURITY.md](SECURITY.md).

## Reportes e integridad

- Formatos: `txt`, `json` y `html` (HTML autocontenido, sin recursos externos). Nombre: `<id de revisión>.<formato>`, por ejemplo `AMON-20261021-153000-1A2B3C.json`.
- La revisión automática exporta el reporte al terminar, en los formatos de `reportFormats` (los tres por defecto); en modo no interactivo se exporta con `-Report`. Volver a exportar en la misma sesión (`Más opciones > E` o `R`) nunca sobrescribe un reporte ya exportado (su SHA-256 puede estar anotado): crea `<id>-2`, `<id>-3`...
- Carpeta por defecto: `%LOCALAPPDATA%\AmonSS\reports` (configurable en Ajustes o con `-OutputPath`, en los dos modos).
- Cada exportación escribe un manifiesto `<id>.sha256` en formato `sha256sum` (`<hash> *<archivo>`) y muestra el SHA-256 de cada archivo en pantalla para que el revisor lo anote fuera del equipo analizado (por ejemplo, en el ticket).
- Verificación: `Más opciones > V`, `Start-AmonSS.ps1 -VerifyManifest <ruta .sha256>` (código de salida `0` si el reporte está íntegro y `1` si algún archivo falta o fue alterado) o `sha256sum -c <id>.sha256` en la carpeta del reporte.
- Fechas en ISO 8601 UTC y en hora local con su desplazamiento.

## Pruebas

La batería Pester tiene tres etiquetas: `Unit` (fixtures sintéticos), `Integration` (solo lectura contra el Windows real, incluidos procesos de prueba propios para el escaneo de memoria) y `Admin` (requiere elevación). Estado verificado el 2026-10-21 en el equipo del autor (Windows 11 Pro build 26200, sesión **sin elevar**):

- 239 pruebas descubiertas; 238 superadas y 0 fallos tanto en Windows PowerShell 5.1.26100 como en PowerShell 7.4.6, con Pester 5.7.1. La única que no se ejecutó es la prueba `Admin` de Prefetch real.
- Escaneo completo real sin administrador, con Windows PowerShell 5.1 y las 285 firmas de la 1.1.0, en unos 40 s. Resultado **SIN INDICADORES**: 46 clientes sin indicadores, ninguno `NOT COVERED`, y un único `INFO` por el driver de la herramienta de SS Ocean.
- **Prefetch, BAM, USN Journal y el registro de Seguridad necesitan administrador**: en ese escaneo quedaron sin acceso o parciales, y sus pruebas Pester usan datos sintéticos. Para comprobarlos con datos reales existe `tools\Invoke-AmonAdminCheck.ps1`, que resume Prefetch, BAM, USN Journal y eventos sobre el sistema real sin exportar nada.

Cómo ejecutar las pruebas y qué cubre cada una: [docs/TESTING.md](docs/TESTING.md).

## Estructura del proyecto

```text
Amon-SS/
├── Start-AmonSS.ps1              Punto de entrada (revisión automática y modo no interactivo)
├── config/
│   ├── settings.json             Ajustes predeterminados (el usuario los sobrescribe en %LOCALAPPDATA%)
│   └── themes.json               Temas FullPurple, MinimalPurple y ClassicTerminal
├── modules/
│   ├── Core.psm1                 Contrato de datos, ajustes, contexto, lectura segura, hashes
│   ├── UI.psm1                   Motor de interfaz (banner, menús, tablas, tarjetas, progreso, teclas)
│   ├── Views.psm1                Vistas de cada módulo
│   ├── Jar.psm1                  Inspección estática de JAR/ZIP y metadatos de mods
│   ├── Minecraft.psm1            Instancias, logs, mods y perfiles de versión
│   ├── Signatures.psm1           Motor de firmas JSON
│   ├── Processes.psm1            Inspector de procesos
│   ├── Memory.psm1               Escáner de memoria de Java
│   ├── Prefetch.psm1             Parser de Prefetch (SCCA/MAM)
│   ├── ExecutionArtifacts.psm1   BAM, PCA y MUICache, ShimCache
│   ├── Recent.psm1               Parser de .lnk
│   ├── UserAssist.psm1           UserAssist (ROT13)
│   ├── Events.psm1               Eventos de Windows y claves Run
│   ├── Tamper.psm1               Servicios forenses y cambios de hora
│   ├── TempSweep.psm1            Barrido de %TEMP% (JNativeHook e indicadores)
│   ├── RecycleBin.psm1           Papelera ($I/$R)
│   ├── USNJournal.psm1           USN Journal
│   ├── Correlation.psm1          Motor de correlación, veredicto por cliente y resultado global
│   ├── Timeline.psm1             Línea temporal unificada
│   ├── Reports.psm1              Reportes TXT/JSON/HTML y manifiesto SHA-256
│   ├── Update.psm1               Actualizaciones verificadas a petición
│   ├── Orchestrator.psm1         Catálogo de módulos y orden del escaneo completo
│   └── Native/
│       ├── AmonNative.cs         Aho-Corasick, MAM, USN, volúmenes, auditoría, memoria de procesos
│       └── AmonZip.cs            Escaneo del contenido de entradas ZIP
├── signatures/                   Una definición JSON por cliente o herramienta + schema.json
├── tests/                        Pruebas Pester, Invoke-AmonTests.ps1 y Helpers/
├── tools/
│   ├── Build-Release.ps1         Construye el paquete con Integrity.psd1, el ZIP, SHA256SUMS.txt e INSTALL-CMD.txt
│   ├── Sign-Release.ps1          Firma Authenticode de una carpeta de release o de un archivo
│   ├── Invoke-AmonAdminCheck.ps1 Comprobación de Prefetch, BAM, USN y eventos como administrador
│   └── Repair-Encoding.ps1       Comprueba o corrige UTF-8 con BOM
├── install/one-liner.template.txt
├── docs/                         Documentación
├── .github/workflows/            CI (ci.yml) y publicación de releases (release.yml)
├── PSScriptAnalyzerSettings.psd1
├── CHANGELOG.md
├── SECURITY.md
└── LICENSE
```

## Documentación

- [Instalación](docs/INSTALL.md): comando de una línea, instalación manual verificada y scripts firmados.
- [Comandos y opciones](docs/COMMANDS.md): revisión automática, menús de una tecla, parámetros, códigos de salida, variables de entorno y ajustes.
- [Módulos](docs/MODULES.md): qué lee cada módulo, qué extrae y qué hallazgos produce.
- [Firmas](docs/SIGNATURES.md): formato, tipos, categorías, reglas de confianza y cómo añadir un cliente o una herramienta.
- [Limitaciones](docs/LIMITATIONS.md): límites forenses de cada fuente.
- [Arquitectura](docs/ARCHITECTURE.md): mapa de módulos, contrato de datos y rendimiento.
- [Pruebas](docs/TESTING.md): cómo ejecutarlas, fixtures sintéticos, estado verificado y CI.

## Licencia

MIT. Ver [LICENSE](LICENSE).

## Uso responsable

Amon SS está pensado para revisiones SS en servidores de Minecraft cuyos términos, conocidos y aceptados por los jugadores, incluyen la revisión del equipo. Amon SS no pide el consentimiento en pantalla: es responsabilidad del servidor y del revisor que esos términos existan y se cumplan. No lo uses en equipos ajenos sin autorización: hacerlo puede ser ilegal en tu país.

Un hallazgo es un indicio que hay que revisar, no una prueba de culpabilidad. Las firmas pueden dar falsos positivos, los artefactos de Windows pueden faltar por motivos legítimos y la ausencia de evidencia no demuestra que algo no ocurriera. Toda decisión sobre un jugador debe tomarla una persona que haya revisado las evidencias y sus [limitaciones](docs/LIMITATIONS.md). Los autores no se responsabilizan del uso que se haga de la herramienta ni de las decisiones basadas en sus resultados.
