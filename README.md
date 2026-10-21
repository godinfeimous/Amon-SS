# Amon SS - Advanced Minecraft Forensic Suite

Herramienta forense de **solo lectura**, escrita en PowerShell, para revisiones SS (ScreenShare) **consentidas** de Minecraft Java Edition en Windows 10 y 11. Revisa instancias y mods, busca firmas de clientes modificados y reúne artefactos de Windows (procesos, Prefetch, papelera, USN Journal, Recent, UserAssist y eventos). Después correlaciona todo en una línea temporal y genera un reporte verificable con SHA-256.

La conclusión siempre queda en manos de una persona: Amon SS describe lo que encontró, de dónde sale cada dato y con qué confianza. No emite sanciones.

## Qué es

- Un script interactivo (`Start-AmonSS.ps1`) con menú de terminal y un modo no interactivo para automatizar revisiones.
- Un conjunto de módulos PowerShell (`modules\*.psm1`) con dos piezas de C# que se compilan en memoria: el motor de búsqueda Aho-Corasick y el lector del USN Journal.
- Un motor de firmas basado en archivos JSON (`signatures\*.json`). Cada indicador cita su fuente, y las firmas sin validar tienen la confianza limitada.
- Un motor de correlación que solo relaciona evidencias que comparten una clave concreta (cliente, ruta, nombre de archivo o SHA-256).

## Qué no es

- **No sanciona.** No emite veredictos automáticos: el resultado dice "conclusión para revisión humana".
- **No lee memoria.** No vuelca ni inspecciona la memoria de ningún proceso. Del proceso de Java solo consulta la lista de DLL cargadas (sus rutas) y su firma Authenticode.
- **No modifica el sistema.** No restaura, mueve ni borra archivos, no finaliza procesos y no cambia registros, auditorías ni políticas. Solo escribe sus propios ajustes y los reportes que el operador exporta.
- **No envía datos.** No tiene telemetría ni webhooks. Solo se conecta a internet al instalarse con el comando de una línea y al buscar actualizaciones, y esto último solo si el operador lo pide en Settings.
- **No es un antitrampas en tiempo real.** Un cliente que solo vive en memoria o que se inyecta sin dejar archivos puede no dejar rastro en lo que se analiza (ver [limitaciones](docs/LIMITATIONS.md)).
- **No funciona sin consentimiento.** En modo interactivo la primera pantalla pide confirmar que el propietario del equipo autoriza la revisión (la respuesta por defecto es "no"). En modo no interactivo hay que pasar `-Consent` de forma explícita.

## Identidad visual

La interfaz usa una paleta morada con tres temas (`FullPurple`, `MinimalPurple` y `ClassicTerminal`), un banner con degradado y tres juegos de glifos (`Full`, `Safe` y `Ascii`), que se eligen según la terminal. Los ejemplos siguientes se generaron con el propio módulo `UI.psm1`, sin color y con 100 columnas de ancho:

```
powershell -NoProfile -Command "Import-Module 'modules\UI.psm1'; Initialize-AmonUI -Theme FullPurple -GlyphMode Full -ColorMode None -Width 100 -NoAnimation; Format-AmonBanner -Version '1.0.0' -BuildDate '2026-10-20' -System 'WINDOWS 11 PRO  BUILD 26200' -Privilege 'ADMINISTRADOR'"
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
║ ◆ STATUS    : READY                            ◆ VERSION   : v1.0.0  2026-10-20                 ║
║ ◆ SYSTEM    : WINDOWS 11 PRO  BUILD 26200      ◆ THEME     : FULL PURPLE                        ║
║ ◆ MODE      : LOCAL FORENSIC                   ◆ PRIVILEGE : ADMINISTRADOR                      ║
╚═════════════════════════════════════════════════════════════════════════════════════════════════╝
```

Menú principal (`Format-AmonMenu` con los elementos de `Get-AmonMainMenuItems`):

```text
╔═════════════════════════════════════════ ◆ MAIN MENU ◆ ═════════════════════════════════════════╗
║                                                                                                 ║
║  [01] ◆ FULL FORENSIC SCAN        Todos los módulos en orden, correlación y reporte             ║
║  [02] ◆ MINECRAFT ANALYSIS        Instancias, loaders, mods instalados y cargados               ║
║  [03] ◆ CHEAT SIGNATURE SCANNER   Firmas de clientes en JAR, configuración y logs               ║
║  [04] ◆ PROCESS INSPECTOR         Java y launchers en ejecución                                 ║
║  [05] ◆ PREFETCH ANALYZER         Ejecuciones registradas (requiere administrador)              ║
║  [06] ◆ RECYCLE BIN FORENSICS     Metadatos $I/$R y actividad de 7 días                         ║
║  [07] ◆ NTFS / USN JOURNAL        Creación, borrado y renombrado (administrador)                ║
║  [08] ◆ RECENT & USERASSIST       Accesos recientes y programas iniciados                       ║
║  [09] ◆ WINDOWS EVENT ANALYSIS    4688, 1102, 104, Defender e inicio automático                 ║
║  [10] ◆ FORENSIC TIMELINE         Línea temporal unificada de la sesión                         ║
║  [11] ◆ EVIDENCE REPORTS          Exportar TXT/JSON/HTML y verificar integridad                 ║
║  [12] ◆ SETTINGS                  Tema, glifos, periodo, reportes y actualizaciones             ║
║                                                                                                 ║
║  [00] ◇ EXIT                                                                                    ║
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

Cada release lleva `Integrity.psd1` con el SHA-256 de todos sus archivos. Amon SS comprueba con él el código C#, las firmas y la configuración al cargarlos, y `-VerifyPackage` comprueba la instalación completa:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\<versión>\Start-AmonSS.ps1" -VerifyPackage
```

Desde una copia local ya verificada:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
```

Modo no interactivo (exige `-Consent`):

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Consent -ConsentNote "Ticket 123" -Report json,html
```

Todas las opciones están en [docs/COMMANDS.md](docs/COMMANDS.md).

## Módulos

| Módulo | Administrador | Resumen |
| --- | --- | --- |
| Minecraft Analysis | No | Instancias, loaders, mods instalados frente a cargados, perfiles de versión |
| Cheat Signature Scanner | No | Firmas JSON sobre JAR, configuraciones, perfiles y logs |
| Process Inspector | No (sí para ver las DLL de un Java elevado) | Java y launchers en ejecución |
| Prefetch Analyzer | Sí | Ejecuciones registradas por Windows |
| Recent Files | No | Accesos directos recientes del Explorador |
| UserAssist | No | Programas iniciados desde el Explorador |
| Windows Event Analysis | Parcial (el registro de Seguridad sí lo requiere) | 4688, 1102, 104, Defender y claves Run |
| Temp Indicator Sweep | No | `%TEMP%`, solo con indicadores concretos |
| Recycle Bin Forensics | No | `$I`/`$R` de la papelera del usuario actual |
| NTFS / USN Journal | Sí | Creaciones, borrados y renombrados relevantes |

**Minecraft Analysis.** Localiza instancias de Minecraft Launcher, TLauncher, Badlion, Lunar Client (cada perfil), Feather, Prism Launcher, PolyMC, CurseForge, Modrinth App y GDLauncher. También usa las rutas que configures y el `--gameDir` de los procesos Java vivos (solo rutas locales); así se detectan launchers portables como MultiMC cuando el juego está abierto. Lee `latest.log` y los logs rotados (`.log.gz`) del periodo, distingue los mods **instalados** (JAR en `mods`) de los **cargados** (los cita un log), avisa de los mods que se cargaron y ya no están, y comprueba los perfiles de `versions\`: clase principal, `-javaagent` y SHA-1 del JAR frente al valor que declara el JSON de Mojang.

**Cheat Signature Scanner.** Escanea los JAR de las instancias (con JAR anidados), los JAR de versión cuyo SHA-1 no se pudo verificar y las rutas extra. Busca paquetes, entradas, entrypoints, atributos del MANIFEST, ids de mod, cadenas y firmas binarias (en los bytes en bruto y en el contenido descomprimido de cada entrada) y SHA-256. También revisa carpetas de configuración, perfiles de versión, argumentos JVM y logs. Ver [docs/SIGNATURES.md](docs/SIGNATURES.md).

**Process Inspector.** Lee `Win32_Process` y muestra solo Java, los launchers conocidos y los procesos que coinciden con palabras clave o indicadores. De cada Java extrae la clase principal, `-jar`, `-javaagent`, `-Dfabric.addMods`, el classpath fuera de librerías, la versión, `--gameDir` y el usuario, siempre con los tokens de sesión ocultos. Comprueba la firma Authenticode y señala las DLL sin firma cargadas desde carpetas de usuario.

**Prefetch Analyzer.** Interpreta los Prefetch SCCA v17, v23, v26, v30 y v31, incluidos los comprimidos MAM (XPRESS Huffman) de Windows 10 y 11. Extrae el contador y las hasta 8 últimas ejecuciones, los archivos referenciados y los JAR que cargó Java fuera de las librerías. Solo muestra los Prefetch relacionados con la revisión; del resto da el recuento.

**Recent Files y UserAssist.** Interpreta los `.lnk` de `Recent` con un parser propio de MS-SHLLINK y las entradas ROT13 de UserAssist (contador, foco y última ejecución). Muestra solo lo relacionado con Minecraft, los JAR y ejecutables, o los indicadores encontrados. Los destinos de red de los accesos directos no se tocan.

**Windows Event Analysis.** Revisa el evento 4688 (creación de procesos) filtrado a Java, launchers e indicadores, e indica si la auditoría está activa y si incluye la línea de comandos. También el 1102 (borrado del registro de Seguridad), el 104 (borrado de otros registros), Defender 1116/1117 relacionados con la revisión y las claves Run/RunOnce.

**Temp Indicator Sweep.** Solo entra en `%TEMP%` si el escáner de firmas ya registró un nombre de archivo y un SHA-256 concretos (una detección `DETECTED`). Sin indicadores no toca la carpeta.

**Recycle Bin Forensics.** Interpreta los `$I` v1 y v2 (tamaño, fecha de eliminación y ruta original) y su `$R`. La vista RECYCLE BIN ACTIVITY resume eliminaciones, metadatos incoherentes, contenido ausente y cambios del contenedor, sin restaurar nada y sin atribuir intenciones.

**NTFS / USN Journal.** Lee el journal con `FSCTL_READ_USN_JOURNAL` (solo lectura) y filtra en C# por JAR, `$I`/`$R`, borrados o renombrados de `.pf`, ejecutables y scripts, palabras clave, indicadores y carpetas de las instancias. Reconstruye los envíos a la papelera aunque después se vaciara. Al alcanzar el máximo de registros conserva los más recientes, y los Prefetch borrados de programas no relacionados solo se cuentan.

**Detection & Correlation Engine, línea temporal y reportes.** Agrupa los hallazgos por cliente, calcula el estado de cada uno y crea una línea temporal donde cada fila procede de un artefacto concreto. Exporta TXT, JSON y HTML con un manifiesto SHA-256. En el escaneo completo, una segunda pasada de firmas revisa los archivos que citan otros módulos (JAR de Prefetch, Recent, `$R` de la papelera, agentes Java...).

El detalle de cada módulo está en [docs/MODULES.md](docs/MODULES.md).

## Estados de resultado

Definidos en `modules\Correlation.psm1`:

| Estado | Significado |
| --- | --- |
| `DETECTED` | Indicador presente. |
| `CORRELATED` | Dos o más fuentes **independientes** contienen información compatible. |
| `INCONCLUSIVE` | Información insuficiente (firmas débiles o no validadas, solo nombres, o clientes sin firmas verificables). |
| `NOT DETECTED` | No se encontraron indicadores dentro del alcance analizado. |

Los hallazgos también pueden tener el estado `INFO` (dato de contexto sin valor acusatorio, por ejemplo el agente Java propio de Lunar Client). Reglas que conviene recordar:

- Solo se relacionan hallazgos que comparten el mismo cliente, la misma ruta, el mismo nombre de archivo o el mismo SHA-256. **La proximidad temporal sola nunca crea una relación.** Los nombres que comparten todas las instalaciones (`javaw.exe`, `latest.log`, `client.jar`, JAR de versión como `1.20.1.jar`...) no relacionan nada por nombre ni por ruta: con ellos solo vale el SHA-256.
- Las fuentes se cuentan por módulo: el USN Journal de varias unidades es una sola fuente, y la sesión de Minecraft de un log cuenta como el propio log.
- Un cliente sin firmas verificables (Vape, Raven, Inertia, Sigma, Rise, Novoline) queda como `INCONCLUSIVE`, nunca como `NOT DETECTED`: el escaneo de archivos no puede descartarlo.
- Las firmas no validadas nunca superan la confianza media, y una correlación basada en ellas también se limita a media.
- `NOT DETECTED` describe el alcance analizado; no demuestra que el cliente no se usara.

## Privacidad y seguridad

- Solo lectura: los archivos se abren en modo de lectura compartida y el volumen se abre con acceso de lectura para consultar el USN Journal.
- Prefetch, Recent, UserAssist, papelera y USN muestran únicamente los artefactos relacionados con la revisión; el resto se cuenta. Los nombres originales de documentos personales enviados a la papelera se ocultan, y un Prefetch borrado de un programa no relacionado se cuenta sin mostrar su nombre. Un comprimido o un log no es relevante solo por su extensión. `%TEMP%` solo se revisa con indicadores concretos.
- Las rutas de red que aparecen en artefactos (accesos directos, `-javaagent`, Prefetch, Recent, `gameDir` de perfiles, `--gameDir` de procesos) no se comprueban ni se escanean: solo se usan rutas absolutas de unidades locales, para no generar tráfico SMB/WebDAV ni autenticación NTLM.
- No se leen archivos de cuentas de los launchers. En las líneas de comandos se ocultan `--accessToken`, `--session`, `--password`, propiedades `-D...token/password...` y los JWT antes de mostrarlas o exportarlas.
- Los datos que vienen de artefactos (rutas, nombres, líneas de log) se limpian de caracteres de control antes de pintarse, así que un nombre de archivo con secuencias ANSI no puede alterar la terminal; además, las cajas de la terminal solo dejan pasar secuencias de color. El reporte TXT elimina los caracteres de control y los saltos de línea incrustados (no se pueden falsificar líneas) y el HTML escapa todos los valores.
- En una release, el código C#, las firmas y la configuración se verifican con `Integrity.psd1` antes de usarse.
- Nunca se ejecuta código de los archivos analizados: los JAR se leen como datos.
- Los reportes contienen datos identificativos del equipo (nombre del equipo, usuario de Windows y SID) y el nombre de usuario de Minecraft que aparece en los logs. Guárdalos con el mismo cuidado que cualquier evidencia.

Política de seguridad y modelo de amenazas: [SECURITY.md](SECURITY.md).

## Reportes e integridad

- Formatos: `txt`, `json` y `html` (HTML autocontenido, sin recursos externos). Nombre: `<id de revisión>.<formato>`, por ejemplo `AMON-20261021-153000-1A2B3C.json`.
- Carpeta por defecto: `%LOCALAPPDATA%\AmonSS\reports` (configurable en Settings o con `-OutputPath`).
- Cada exportación escribe un manifiesto `<id>.sha256` en formato `sha256sum` (`<hash> *<archivo>`) y muestra el SHA-256 de cada archivo en pantalla para que el revisor lo anote fuera del equipo analizado (por ejemplo, en el ticket).
- Verificación: menú `11 > 2`, `Start-AmonSS.ps1 -VerifyManifest <ruta .sha256>` (código de salida `0` si el reporte está íntegro y `1` si algún archivo falta o fue alterado) o `sha256sum -c <id>.sha256` en la carpeta del reporte.
- Fechas en ISO 8601 UTC y en hora local con su desplazamiento.

## Pruebas

La batería Pester tiene tres etiquetas: `Unit` (fixtures sintéticos), `Integration` (solo lectura contra el Windows real) y `Admin` (requiere elevación). Estado verificado el 2026-10-21 en el equipo del autor (Windows 11 Pro build 26200, sesión **sin elevar**):

- 199 pruebas descubiertas; 198 superadas y 0 fallos tanto en Windows PowerShell 5.1.26100 como en PowerShell 7.4.6, con Pester 5.7.1. La única que no se ejecutó es la prueba `Admin` de Prefetch real.
- Escaneo completo no interactivo en unos 32 s (PS 5.1) sobre 6 instancias (vanilla y 5 perfiles de Lunar): 171 JAR de las instancias y 3 archivos citados por otros módulos escaneados con firmas, sin falsos positivos, y 12 perfiles de versión verificados con el SHA-1 de Mojang. El tiempo con PS 7 (41 s) es de una ejecución anterior a la revisión de código.
- **Prefetch, USN Journal y el registro de Seguridad no se ejecutaron sobre un sistema real** porque la sesión no estaba elevada: solo los cubren pruebas sintéticas y falta verificarlos como administrador. Para esa verificación existe `tools\Invoke-AmonAdminCheck.ps1`, que resume los tres módulos sobre el sistema real sin exportar nada.

Cómo ejecutar las pruebas y qué cubre cada una: [docs/TESTING.md](docs/TESTING.md).

## Estructura del proyecto

```text
Amon-SS/
├── Start-AmonSS.ps1              Punto de entrada (menú interactivo y modo no interactivo)
├── config/
│   ├── settings.json             Ajustes predeterminados (el usuario los sobrescribe en %LOCALAPPDATA%)
│   └── themes.json               Temas FullPurple, MinimalPurple y ClassicTerminal
├── modules/
│   ├── Core.psm1                 Contrato de datos, ajustes, contexto, lectura segura, hashes
│   ├── UI.psm1                   Motor de interfaz (banner, menús, tablas, tarjetas, progreso)
│   ├── Views.psm1                Vistas de cada módulo
│   ├── Jar.psm1                  Inspección estática de JAR/ZIP y metadatos de mods
│   ├── Minecraft.psm1            Instancias, logs, mods y perfiles de versión
│   ├── Signatures.psm1           Motor de firmas JSON
│   ├── Processes.psm1            Inspector de procesos
│   ├── Prefetch.psm1             Parser de Prefetch (SCCA/MAM)
│   ├── Recent.psm1               Parser de .lnk
│   ├── UserAssist.psm1           UserAssist (ROT13)
│   ├── Events.psm1               Eventos de Windows y claves Run
│   ├── TempSweep.psm1            Barrido de %TEMP% con indicadores
│   ├── RecycleBin.psm1           Papelera ($I/$R)
│   ├── USNJournal.psm1           USN Journal
│   ├── Correlation.psm1          Motor de correlación y veredicto por cliente
│   ├── Timeline.psm1             Línea temporal unificada
│   ├── Reports.psm1              Reportes TXT/JSON/HTML y manifiesto SHA-256
│   ├── Update.psm1               Actualizaciones verificadas a petición
│   ├── Orchestrator.psm1         Catálogo de módulos y orden del escaneo completo
│   └── Native/
│       ├── AmonNative.cs         Aho-Corasick, MAM, USN, volúmenes, auditoría
│       └── AmonZip.cs            Escaneo del contenido de entradas ZIP
├── signatures/                   Una definición JSON por cliente + schema.json
├── tests/                        Pruebas Pester, Invoke-AmonTests.ps1 y Helpers/
├── tools/
│   ├── Build-Release.ps1         Construye el paquete con Integrity.psd1, el ZIP, SHA256SUMS.txt e INSTALL-CMD.txt
│   ├── Sign-Release.ps1          Firma Authenticode de una carpeta de release o de un archivo
│   ├── Invoke-AmonAdminCheck.ps1 Comprobación de Prefetch, USN y eventos como administrador
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
- [Comandos y opciones](docs/COMMANDS.md): menú, parámetros, códigos de salida, variables de entorno y ajustes.
- [Módulos](docs/MODULES.md): qué lee cada módulo, qué extrae y qué hallazgos produce.
- [Firmas](docs/SIGNATURES.md): formato, reglas de confianza y cómo añadir un cliente.
- [Limitaciones](docs/LIMITATIONS.md): límites forenses de cada fuente.
- [Arquitectura](docs/ARCHITECTURE.md): mapa de módulos, contrato de datos y rendimiento.
- [Pruebas](docs/TESTING.md): cómo ejecutarlas, fixtures sintéticos, estado verificado y CI.

## Licencia

MIT. Ver [LICENSE](LICENSE).

## Uso responsable

Amon SS está pensado para revisiones en las que el propietario del equipo da su consentimiento explícito e informado, por ejemplo en servidores de Minecraft con una política de ScreenShare conocida por los jugadores. No lo uses en equipos ajenos sin autorización: hacerlo puede ser ilegal en tu país.

Un hallazgo es un indicio que hay que revisar, no una prueba de culpabilidad. Las firmas pueden dar falsos positivos, los artefactos de Windows pueden faltar por motivos legítimos y la ausencia de evidencia no demuestra que algo no ocurriera. Toda decisión sobre un jugador debe tomarla una persona que haya revisado las evidencias y sus [limitaciones](docs/LIMITATIONS.md). Los autores no se responsabilizan del uso que se haga de la herramienta ni de las decisiones basadas en sus resultados.
