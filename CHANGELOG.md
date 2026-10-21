# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/); versionado [SemVer](https://semver.org/lang/es/).

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
