# Comandos y opciones

Todo se ejecuta con `Start-AmonSS.ps1`. Sin parámetros se abre el modo interactivo; con `-Scan` o `-Consent` se ejecuta el modo no interactivo; con `-VerifyManifest` solo se verifica un reporte, y con `-VerifyPackage` solo se verifica la instalación.

## Modo interactivo

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
```

En una release, antes de leer la configuración, Amon SS comprueba que exista `Integrity.psd1` (si no, termina con código `1`); después, la configuración, las firmas y el código C# se verifican frente a ese manifiesto al cargarse (ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)). Secuencia de arranque:

1. Banner con el estado, la versión, el sistema, el tema, el modo (`LOCAL FORENSIC`) y el privilegio (`ADMINISTRADOR` o `USUARIO ESTÁNDAR`).
2. Caja **CONSENTIMIENTO**: explica que todo es de solo lectura, qué se analizará y que no se emiten sanciones. Pregunta "¿El propietario del equipo autoriza esta revisión?" con respuesta por defecto **no** (`[s/N]`). Si no se confirma, Amon SS termina sin analizar nada.
3. Referencia opcional (ticket, nick del jugador). Se guarda en el alcance autorizado del reporte.
4. Se crea la revisión, con un identificador `AMON-AAAAMMDD-HHMMSS-XXXXXX` y el periodo de análisis (`defaultDays`, 7 por defecto).
5. Menú principal. Después de cada opción se muestra un pie con la versión y el identificador de la revisión.

Las confirmaciones aceptan `s`, `si`, `sí`, `y` o `yes`; Enter usa el valor por defecto que se indica entre corchetes. El número de opción puede escribirse con o sin cero inicial (`1` equivale a `01`). En el menú principal, un Enter vacío vuelve a mostrar el menú: para cerrar la sesión hay que escribir `0` o `00`.

## Menú principal

| Opción | Nombre | Qué hace |
| --- | --- | --- |
| `01` | FULL FORENSIC SCAN | Muestra el alcance (módulos activables, ubicaciones que se inspeccionarán, periodo y tiempo máximo por módulo), pide confirmación, ejecuta los módulos en orden, la pasada de firmas sobre evidencias y la correlación. Después ofrece exportar el reporte (por defecto sí) y ver el detalle de cada módulo (por defecto no). Sin administrador, la pantalla de alcance avisa junto a cada módulo que lo necesita: Prefetch y USN Journal "requiere administrador (se informará SIN ACCESO)" y Eventos "sin administrador: solo System, Defender y claves Run (PARCIAL)". |
| `02` | MINECRAFT ANALYSIS | Ejecuta Minecraft Analysis y muestra instancias, mods instalados y cargados, perfiles de versión y sesiones. |
| `03` | CHEAT SIGNATURE SCANNER | Pide una ruta adicional opcional (archivo o carpeta, que debe existir) y ejecuta el escáner de firmas. La ruta queda registrada en el alcance autorizado y se guarda como dato en la sesión (`ExtraScanPaths`): los escaneos de firmas posteriores de esa misma sesión, incluido el del escaneo completo, también la incluyen. |
| `04` | PROCESS INSPECTOR | Procesos Java, launchers y coincidencias. |
| `05` | PREFETCH ANALYZER | Prefetch (sin administrador informa `SIN ACCESO`). |
| `06` | RECYCLE BIN FORENSICS | Si hay privilegios de administrador y el USN Journal aún no se analizó en la sesión, lo ejecuta primero para poder cruzarlo; después analiza la papelera. |
| `07` | NTFS / USN JOURNAL | USN Journal (sin administrador informa `SIN ACCESO`). |
| `08` | RECENT & USERASSIST | Ejecuta Recent Files y después UserAssist. |
| `09` | WINDOWS EVENT ANALYSIS | Eventos 4688, 1102, 104, Defender y claves Run. |
| `10` | FORENSIC TIMELINE | Línea temporal de lo analizado en la sesión (ver abajo). |
| `11` | EVIDENCE REPORTS | Submenú de reportes. |
| `12` | SETTINGS | Submenú de ajustes. |
| `00` | EXIT | Cierra la sesión. |

### Prerrequisitos de los módulos sueltos

Al lanzar un módulo desde el menú, Amon SS carga antes el conjunto de firmas si todavía no está en la sesión (es instantáneo y solo aporta las palabras clave de los clientes; no escanea ningún JAR). Además, ejecuta Minecraft Analysis si no se ejecutó ya en la sesión cuando el módulo saca partido de las rutas de las instancias:

| Módulo | Ejecuta antes |
| --- | --- |
| Signatures, RecycleBin, USNJournal | Minecraft |
| Minecraft, Processes, Prefetch, Recent, UserAssist, Events | Nada |

El escaneo de JAR con firmas solo se hace al pedirlo (`03`) o en el escaneo completo. Tras cada módulo se recalcula la correlación y se muestra la vista del módulo. Ctrl+C cancela de forma cooperativa y conserva los resultados parciales.

### Línea temporal (10)

Si la sesión todavía no tiene eventos, ofrece lanzar el escaneo completo. Si los tiene, pregunta el intervalo:

- Enter: el periodo de la revisión.
- Un número de días (`3`): los últimos N días.
- Un rango `AAAA-MM-DD AAAA-MM-DD`: ese intervalo. Los datos fuera de la ventana de análisis original pueden no haberse recopilado.

Muestra un resumen por día (eventos y eventos ligados a indicadores) y la tabla de eventos con fecha, hora, zona, tipo, fuente, confianza y ruta.

### Submenú EVIDENCE REPORTS (11)

| Opción | Acción |
| --- | --- |
| `1` | EXPORTAR REPORTE DE LA SESIÓN en los formatos de `reportFormats` y en la carpeta `reportDirectory`. Muestra la ruta y el SHA-256 de cada archivo y la ruta del manifiesto. |
| `2` | VERIFICAR INTEGRIDAD: pide la ruta de un manifiesto `.sha256` de un reporte y muestra cada archivo como `ÍNTEGRO` o `ALTERADO O AUSENTE`. |
| `0` | VOLVER |

### Submenú SETTINGS (12)

Los cambios se guardan en `%LOCALAPPDATA%\AmonSS\settings.json`, nunca en `config\settings.json`.

| Opción | Acción |
| --- | --- |
| `1` | Tema FULL PURPLE (degradado, bordes dobles, animación). |
| `2` | Tema MINIMAL PURPLE (bordes simples, sin animación). |
| `3` | Tema CLASSIC TERMINAL (16 colores, máxima compatibilidad). |
| `4` | GLIFOS: `auto`, `full`, `safe` o `ascii`. |
| `5` | PERIODO POR DEFECTO: de 1 a 365 días; se aplica a la próxima revisión. |
| `6` | CARPETA DE REPORTES. |
| `7` | FORMATOS DE REPORTE: lista separada por comas de `txt`, `json` y `html`. |
| `8` | ANIMACIONES: activa o desactiva. |
| `9` | RUTA EXTRA DE INSTANCIA: directorio de juego de un launcher portable (MultiMC, ATLauncher...). Tiene que existir. |
| `10` | BUSCAR ACTUALIZACIONES: valida el repositorio (`propietario/repositorio`) antes de guardarlo, consulta GitHub e instala una versión nueva solo si su etiqueta es un número de versión y el operador aporta su SHA-256 (ver [INSTALL.md](INSTALL.md#actualizar)). |
| `0` | VOLVER |

## Modo no interactivo

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Consent [opciones]
```

| Parámetro | Valores | Descripción |
| --- | --- | --- |
| `-Scan` | `Full`, `Minecraft`, `Signatures`, `Processes`, `Prefetch`, `Recent`, `UserAssist`, `Events`, `Temp`, `RecycleBin`, `USNJournal` | `Full` ejecuta los módulos activos en `modules` (o los de `-Modules`). Con un módulo concreto se ejecutan **Minecraft y ese módulo**, sin la pasada de firmas salvo que el módulo sea `Signatures`. `-Scan Temp` ejecuta **Minecraft, Signatures y Temp**: el barrido de Temp solo busca los indicadores concretos que registra el escáner de firmas (si no hay ninguna detección `DETECTED`, queda `OMITIDO`). |
| `-Modules` | `Minecraft`, `Signatures`, `Processes`, `Prefetch`, `Recent`, `UserAssist`, `Events`, `Temp`, `RecycleBin`, `USNJournal` | Solo con `-Scan Full` (o sin `-Scan`). Limita los módulos; se ejecutan siempre en el orden de investigación, no en el que se escriben. |
| `-Consent` | interruptor | Confirma que el propietario del equipo dio su consentimiento explícito. **Obligatorio** en modo no interactivo. Pasarlo sin `-Scan` equivale a `-Scan Full`. |
| `-ConsentNote` | texto | Se guarda en el reporte como "Referencia del revisor". |
| `-Days` | 0 a 365 | Ventana de análisis en días. `0` (por defecto) usa `defaultDays`. |
| `-Report` | `txt`, `json`, `html` | Formatos a exportar al terminar. **Si no se indica, no se exporta ningún reporte.** |
| `-OutputPath` | carpeta | Carpeta de reportes (por defecto, `reportDirectory`). |
| `-Theme` | `FullPurple`, `MinimalPurple`, `ClassicTerminal` | Tema para esta ejecución (no se guarda). También vale en modo interactivo. |
| `-Glyphs` | `Auto`, `Full`, `Safe`, `Ascii` | Juego de glifos para esta ejecución (no se guarda). |
| `-NoAnimation` | interruptor | Desactiva las animaciones. |
| `-VerifyManifest` | ruta `.sha256` | Verifica un reporte y termina con código `0` si está íntegro o `1` si algún archivo falta o fue alterado. Tiene prioridad sobre el resto de opciones, salvo `-VerifyPackage`. |
| `-VerifyPackage` | interruptor | Compara cada archivo de esta instalación con `Integrity.psd1` y termina. Solo muestra los archivos con problemas (`ALTERADO`, `AUSENTE` o `NO INCLUIDO`) y una línea de resumen, en texto plano. Código `0` si el paquete está íntegro, `1` si hay problemas o si la copia no tiene `Integrity.psd1` (copia de desarrollo). Se evalúa antes que cualquier otra opción y antes de leer la configuración. |

Las listas (`-Modules`, `-Report`) pueden escribirse desde CMD como `json,html`, `"json html"` o `json;html`. Los valores se validan sin distinguir mayúsculas; un valor desconocido detiene el script con un error que enumera los valores permitidos.

En modo no interactivo se muestra el banner, el progreso de cada módulo, el veredicto por cliente, un resumen (hallazgos `CORRELATED`, `DETECTED` e `INCONCLUSIVE`, eventos de la línea temporal y artefactos revisados) y, si se pidió, la caja del reporte con los SHA-256. El alcance autorizado del reporte registra el consentimiento por `-Consent` (fecha, equipo y usuario), la referencia y los módulos autorizados.

### Ejemplos (CMD)

Escaneo completo con reporte JSON y HTML:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Consent -ConsentNote "Ticket 4512 - Steve" -Report json,html
```

Solo algunos módulos, ventana de 3 días, reportes en otra carpeta:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Modules Minecraft,Signatures,Processes -Days 3 -Consent -Report txt -OutputPath "D:\Revisiones\4512"
```

Un módulo concreto (se ejecuta junto a Minecraft):

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Signatures -Consent -Report json
```

Salida apta para registros o terminales sin Unicode:

```bat
set NO_COLOR=1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Consent -Glyphs Ascii -NoAnimation -Report txt
```

Verificar un reporte:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -VerifyManifest "%LOCALAPPDATA%\AmonSS\reports\AMON-20261021-153000-1A2B3C.sha256"
```

Verificar la instalación frente a su `Integrity.psd1`:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\1.0.0\Start-AmonSS.ps1" -VerifyPackage
```

## Códigos de salida

| Código | Situación |
| --- | --- |
| `0` | Ejecución terminada: sesión interactiva cerrada, revisión no interactiva completada (haya o no hallazgos) o consentimiento rechazado en modo interactivo. También un `-VerifyManifest` con todos los archivos íntegros y un `-VerifyPackage` sin problemas. |
| `1` | `-VerifyManifest` con algún archivo ausente o alterado (o un manifiesto inexistente); `-VerifyPackage` con algún problema o sin `Integrity.psd1`; una release sin `Integrity.psd1`, o cuyo `config\settings.json` no coincide con él (las firmas o los `.cs` alterados hacen fallar los módulos que los usan, ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)); o un error no controlado, por ejemplo un valor no admitido en `-Scan`, en `-Report` o en `-Modules`. |
| `2` | Modo no interactivo sin `-Consent`: no se analiza nada y el motivo se escribe en la salida de error. |

Otras herramientas del repositorio: `tests\Invoke-AmonTests.ps1` devuelve `1` si alguna prueba falla, `tools\Repair-Encoding.ps1 -Check` devuelve `1` si hay scripts sin UTF-8 con BOM, y `tools\Invoke-AmonAdminCheck.ps1` devuelve `1` si no se ejecuta como administrador (ver [INSTALL.md](INSTALL.md#ejecutar-como-administrador)).

## Variables de entorno

Usadas por la interfaz (`modules\UI.psm1`):

| Variable | Efecto |
| --- | --- |
| `NO_COLOR` | Con cualquier valor no vacío, desactiva los colores ([convención NO_COLOR](https://no-color.org/)). Tiene prioridad sobre el modo de color del tema. |
| `AMON_GLYPHS` | `Full`, `Safe` o `Ascii`. Se usa cuando el modo de glifos es automático (sin `-Glyphs` y con `glyphs: "auto"`) y tiene prioridad sobre la preferencia del tema y la detección de terminal. |
| `WT_SESSION` | Si existe (Windows Terminal), el modo automático usa glifos `Full`. |
| `TERM_PROGRAM` | Con el valor `vscode`, glifos `Full`. |
| `ConEmuANSI` | Con el valor `ON`, glifos `Full`. |
| `TERM` | Si empieza por `xterm`, glifos `Full`. |

Sin ninguna de esas señales, el modo automático usa `Safe` (subconjunto WGL4 que suelen tener Consolas y Lucida Console). Además:

- Si la salida está redirigida (archivo o tubería), no hay colores ni animaciones.
- Si la consola admite secuencias VT, se usa color de 24 bits; si no, 16 colores mediante `Write-Host`. El tema Classic Terminal siempre usa 16 colores.
- Salvo en modo `Ascii` o con la salida redirigida, la codificación de salida de la consola pasa a UTF-8 y se restaura al salir. Los temas Full Purple y Minimal Purple ponen fondo negro al limpiar la pantalla y también lo restauran.

Variables del sistema que determinan **qué** se analiza:

| Variable | Uso |
| --- | --- |
| `APPDATA`, `USERPROFILE`, `LOCALAPPDATA` | Búsqueda de instancias de Minecraft y de la carpeta `Recent`; `LOCALAPPDATA` también para ajustes, reportes y versiones (si falta, se usa la carpeta temporal). |
| `TEMP` | Carpeta del barrido de Temp. |
| `SystemRoot` | Carpeta de Prefetch. |
| `SystemDrive` | Unidad cuyo USN Journal se lee siempre. |

## Archivos y carpetas

| Ruta | Contenido |
| --- | --- |
| `Integrity.psd1` | Solo en el paquete de release: SHA-256 de cada archivo del paquete (ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)). |
| `config\settings.json` | Ajustes predeterminados del paquete. No se modifica nunca; en una release se verifica frente a `Integrity.psd1` al cargarse. |
| `config\themes.json` | Definición de los temas. |
| `%LOCALAPPDATA%\AmonSS\settings.json` | Ajustes del usuario. Se combinan sobre los predeterminados de forma recursiva; las listas se reemplazan completas. Si el archivo está dañado, se ignora. |
| `%LOCALAPPDATA%\AmonSS\reports\` | Reportes (`<id>.txt`, `<id>.json`, `<id>.html`) y manifiesto `<id>.sha256`. |
| `%LOCALAPPDATA%\AmonSS\versions\` | Versiones instaladas por el comando de una línea o por Settings > Buscar actualizaciones. |

## Claves de `config\settings.json`

| Clave | Predeterminado | Significado |
| --- | --- | --- |
| `schemaVersion` | `1` | Versión del formato. El código actual no la comprueba. |
| `theme` | `FullPurple` | Tema: `FullPurple`, `MinimalPurple` o `ClassicTerminal`. |
| `glyphs` | `auto` | Glifos: `auto`, `full`, `safe` o `ascii`. |
| `animations` | `true` | Animaciones del banner y de los contadores. |
| `defaultDays` | `7` | Periodo de análisis por defecto, en días. |
| `reportDirectory` | `%LOCALAPPDATA%\AmonSS\reports` | Carpeta de reportes (se expanden las `%VARIABLES%`). |
| `reportFormats` | `["txt","json","html"]` | Formatos de la exportación interactiva. En modo no interactivo mandan `-Report`. |
| `moduleTimeoutSeconds` | `180` | Tiempo máximo por módulo; al alcanzarlo, el módulo queda `PARCIAL`. |
| `limits.maxJarSizeMB` | `64` | Los JAR mayores no se hashean ni se abren como ZIP en Minecraft, y en el escáner de firmas solo se revisan sus bytes en bruto. |
| `limits.maxEntrySizeMB` | `16` | Tamaño máximo de una entrada ZIP (o de un JAR anidado) que se descomprime y escanea. |
| `limits.maxDecompressedPerJarMB` | `256` | Bytes descomprimidos como máximo por JAR, incluidos los anidados. |
| `limits.maxEntriesPerJar` | `60000` | Entradas como máximo que se listan y escanean por JAR. |
| `limits.maxNestedJarDepth` | `2` | Profundidad máxima de JAR dentro de JAR. |
| `limits.maxRawScanMB` | `128` | Bytes en bruto que se escanean de un JAR o ZIP (como máximo, también `maxJarSizeMB`). |
| `limits.maxExecutableScanMB` | `64` | Bytes en bruto que se escanean de un archivo que no es ZIP (EXE, DLL) y tamaño máximo para hashear en el barrido de Temp. |
| `limits.maxFilesPerDirectory` | `5000` | Archivos como máximo enumerados en cada carpeta `mods` y en cada ruta extra de escaneo. |
| `limits.maxLogFiles` | `60` | Logs como máximo por instancia (los más recientes). |
| `limits.maxLogSizeMB` | `64` | Datos leídos como máximo de cada log. |
| `limits.maxUsnResults` | `20000` | Registros relevantes del USN Journal como máximo por unidad. Al alcanzarlo se conservan los más recientes. |
| `limits.maxTableRows` | `40` | Filas visibles en las tablas de la terminal (los reportes contienen todo). |
| `limits.maxTempFiles` | `4000` | Archivos como máximo enumerados en `%TEMP%`. |
| `minecraft.extraInstancePaths` | `[]` | Directorios de juego adicionales (launchers portables). |
| `minecraft.standardGameDirectories` | lista | Nombres de carpetas habituales de un directorio de juego. Las demás se registran como carpetas no estándar de la instancia (aparecen en el JSON del reporte). |
| `scan.extraScanPaths` | `[]` | Archivos o carpetas que el escáner de firmas revisa siempre (en carpetas: `*.jar`, `*.exe`, `*.dll` y `*.zip` hasta 2 niveles). |
| `scan.scanVersionJarsWhenHashUnverified` | `true` | Escanear con firmas los JAR de `versions\` cuyo SHA-1 no se pudo verificar. |
| `keywords` | lista | Palabras clave base para decidir qué artefactos son relevantes (subcadena sin distinguir mayúsculas). En ejecución se añaden las palabras clave de los clientes, los nombres de los archivos con una detección `DETECTED` de firmas y los `--gameDir` de los procesos Java. |
| `interestingExtensions` | `[".jar", ".exe", ".dll", ".bat", ".cmd", ".ps1", ".vbs", ".pf"]` | Extensiones que hacen relevante por sí solas un elemento de la papelera y el nombre original de un envío a la papelera que registra el USN Journal. Los comprimidos (`.zip`, `.rar`, `.7z`) y los logs no están en la lista por privacidad: solo aparecen si su ruta contiene una palabra clave o un indicador (en la papelera, también si estaban en una carpeta de Minecraft). |
| `launcherProcessNames` | lista | Nombres de proceso que se tratan como Java o launcher (procesos, Prefetch, eventos 4688). |
| `privacy.showUnrelatedRecycleEntries` | `false` | Con `true`, la papelera muestra también los elementos no relacionados, con su ruta original. |
| `updates.repository` | `""` | Repositorio `propietario/nombre` para buscar actualizaciones. Settings comprueba el formato antes de guardarlo. |
| `modules.<Módulo>` | `true` | Selección por defecto del escaneo completo (`Minecraft`, `Signatures`, `Processes`, `Prefetch`, `Recent`, `UserAssist`, `Events`, `Temp`, `RecycleBin`, `USNJournal`). |

Ejemplo de `%LOCALAPPDATA%\AmonSS\settings.json` con solo los cambios del usuario:

```json
{
  "theme": "MinimalPurple",
  "defaultDays": 14,
  "minecraft": { "extraInstancePaths": ["D:\\Juegos\\MultiMC\\instances\\PvP\\.minecraft"] },
  "modules": { "Temp": false }
}
```
