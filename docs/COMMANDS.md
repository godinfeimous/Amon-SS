# Comandos y opciones

Todo se ejecuta con `Start-AmonSS.ps1`. Sin `-Scan` se abre la revisión automática (modo interactivo); con `-Scan` se ejecuta el modo no interactivo; con `-VerifyManifest` solo se verifica un reporte, y con `-VerifyPackage` solo se verifica la instalación.

## Revisión automática (modo interactivo)

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1
```

En una release, antes de leer la configuración, Amon SS comprueba que exista `Integrity.psd1` (si no, termina con código `1`); después, la configuración, las firmas y el código C# se verifican frente a ese manifiesto al cargarse (ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)). Después todo ocurre solo:

1. Banner con el estado, la versión, el sistema, el tema, el modo (`LOCAL FORENSIC`) y el privilegio (`ADMINISTRADOR` o `USUARIO ESTÁNDAR`).
2. Si no se ejecuta como administrador (y no se pasó `-NoElevate`), una línea avisa de que sin él no se leen Prefetch, el USN Journal ni el registro de Seguridad (BAM tampoco) y espera una tecla: `A` reabre Amon SS como administrador en una ventana nueva, con el aviso UAC de Windows; Enter, `Esc` o 10 s sin pulsar nada siguen sin administrador. Si el aviso se acepta, esta ventana termina y la revisión continúa en la nueva; si se rechaza, sigue aquí sin administrador. La ventana nueva recibe `-Elevated` y, si se pasaron, `-Days` y `-NoAnimation`; el resto de opciones (`-Modules`, `-OutputPath`, `-ConsentNote`, `-Theme`, `-Glyphs`) no se le transmite.
3. Se crea la revisión, con un identificador `AMON-AAAAMMDD-HHMMSS-XXXXXX` y el periodo de análisis (`-Days` o `defaultDays`, 7 por defecto). No se pide consentimiento: lo cubren los términos de la SS del servidor. El alcance autorizado del reporte registra "Revisión SS ejecutada por el usuario `<usuario>` en `<equipo>` el `<fecha>` (como administrador); el consentimiento se rige por los términos de la SS del servidor." (la mención al administrador solo aparece si lo es) y, si se pasó `-ConsentNote`, la "Referencia del revisor".
4. Escaneo completo con progreso: los módulos activos en `modules` (o los de `-Modules`), la pasada de firmas sobre evidencias y la correlación. Ctrl+C cancela de forma cooperativa y conserva los resultados parciales.
5. Veredicto (resultado global, tabla de clientes con algún indicio, línea "Sin indicadores", línea "Sin firmas" y conclusión) y un resumen con los hallazgos `CORRELATED`, `DETECTED` e `INCONCLUSIVE`, los eventos de la línea temporal y los artefactos revisados.
6. Reporte exportado sin preguntar en los formatos de `reportFormats` (TXT, JSON y HTML por defecto) y en `-OutputPath` o `reportDirectory`, con el SHA-256 de cada archivo y la ruta del manifiesto.
7. Menú final **REVISIÓN TERMINADA**.

### Teclas

Los menús se manejan con **una sola tecla, sin Enter**; las teclas que no figuran en el menú se ignoran. Con la entrada redirigida (pruebas o tuberías) cada tecla llega como una línea: se usa su primer carácter, una línea vacía equivale a Enter y el fin de la entrada elige la opción por defecto (seguir sin administrador en el aviso inicial, volver o salir en los menús). Las preguntas que piden una ruta (`X`, `V`, `C`, `I`) sí se responden con texto y Enter; un Enter vacío las cancela.

### Menú final

| Tecla | Acción |
| --- | --- |
| `H` | Abre el reporte HTML de la revisión con el programa predeterminado (un archivo local, sin red). Si la exportación no incluyó HTML, lo avisa; con la entrada redirigida solo muestra la ruta. |
| `D` | Detalle: la vista de cada módulo ejecutado en la sesión. |
| `T` | Línea temporal del periodo de la revisión: resumen por día (eventos y eventos ligados a indicadores) y tabla con fecha, hora, zona, tipo, fuente, confianza y ruta. |
| `R` | Repite el escaneo completo en la misma sesión y vuelve a exportar el reporte como `<id>-2`, `<id>-3`... (nunca sobrescribe uno ya exportado). |
| `M` | Más opciones (ver abajo). |
| `Q` o `Esc` | Sale. |

Enter no hace nada en este menú, a propósito: un Enter sin querer no puede cerrar la revisión.

### Más opciones (`M`)

| Tecla | Acción |
| --- | --- |
| `1` | Minecraft Analysis: instancias, mods instalados y cargados, perfiles de versión y sesiones. |
| `2` | Cheat Signature Scanner. |
| `3` | Process Inspector. |
| `J` | Java Memory Scanner (necesita Minecraft abierto). |
| `4` | Prefetch (sin administrador informa `SIN ACCESO`). |
| `5` | Papelera. Si hay privilegios de administrador y el USN Journal aún no se analizó en la sesión, lo ejecuta primero para poder cruzarlo. |
| `6` | USN Journal (sin administrador informa `SIN ACCESO`). |
| `7` | Recent Files y después UserAssist. |
| `8` | Windows Event Analysis. |
| `9` | BAM, PCA & MUICache y ShimCache, en ese orden (BAM sin administrador informa `SIN ACCESO`). |
| `B` | Bypass & Tamper Check (evasión). |
| `X` | Pide una ruta adicional (archivo o carpeta, que debe existir) y ejecuta el escáner de firmas. La ruta queda registrada en el alcance autorizado ("Ruta adicional revisada con firmas: ...") y se guarda como dato en la sesión (`ExtraScanPaths`): los escaneos de firmas posteriores de esa misma sesión, incluido el de `R`, también la incluyen. |
| `E` | Exporta de nuevo el reporte con los resultados actuales (mismos formatos y carpeta; se guarda como `<id>-2`, `<id>-3`... sin sobrescribir el anterior). |
| `V` | Pide la ruta de un manifiesto `.sha256` y muestra cada archivo como `ÍNTEGRO` o `ALTERADO O AUSENTE`. |
| `S` | Ajustes (ver abajo). |
| `Q` o `Esc` | Vuelve al menú final. |

Tras cada módulo suelto se recalcula la correlación de la sesión y se muestra la vista del módulo. El reporte ya exportado no cambia: usa `E` para exportarlo de nuevo.

#### Prerrequisitos de los módulos sueltos

Al lanzar un módulo suelto, Amon SS carga antes el conjunto de firmas si todavía no está en la sesión (es instantáneo y aporta las palabras clave de los clientes y los nombres de herramientas; no escanea ningún JAR). Además, ejecuta Minecraft Analysis si no se ejecutó ya en la sesión cuando el módulo saca partido de las rutas de las instancias:

| Módulo | Ejecuta antes |
| --- | --- |
| Signatures, RecycleBin, USNJournal | Minecraft |
| Minecraft, Processes, Memory, Prefetch, BAM, PCA, ShimCache, Recent, UserAssist, Events, Tamper | Nada |

### Ajustes (`S`)

Los cambios se guardan en `%LOCALAPPDATA%\AmonSS\settings.json`, nunca en `config\settings.json`, y se aplican a la sesión en curso.

| Tecla | Acción |
| --- | --- |
| `1` | Tema FULL PURPLE (degradado, bordes dobles, animación). |
| `2` | Tema MINIMAL PURPLE (bordes simples, sin animación). |
| `3` | Tema CLASSIC TERMINAL (16 colores, máxima compatibilidad). |
| `G` | GLIFOS: cada pulsación pasa al siguiente valor (`auto`, `full`, `safe`, `ascii`). |
| `P` | PERIODO: cada pulsación pasa al siguiente valor (3, 7, 14 o 30 días); se aplica a la próxima revisión. Otros valores, con `-Days` o en `settings.json`. |
| `A` | ANIMACIONES: activa o desactiva. |
| `C` | CARPETA DE REPORTES: pide la ruta. |
| `I` | RUTA EXTRA DE INSTANCIA: directorio de juego de un launcher portable (MultiMC, ATLauncher...). Tiene que existir. |
| `U` | BUSCAR ACTUALIZACIONES: valida el repositorio (`propietario/repositorio`) antes de guardarlo, consulta GitHub e instala una versión nueva solo si su etiqueta es un número de versión y el operador aporta su SHA-256 (ver [INSTALL.md](INSTALL.md#actualizar)). |
| `Q` o `Esc` | Vuelve. |

Los formatos de reporte ya no se cambian desde el menú: edita `reportFormats` en `%LOCALAPPDATA%\AmonSS\settings.json`.

## Modo no interactivo

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full [opciones]
```

| Parámetro | Valores | Descripción |
| --- | --- | --- |
| `-Scan` | `Full`, `Minecraft`, `Signatures`, `Processes`, `Memory`, `Prefetch`, `BAM`, `PCA`, `ShimCache`, `Recent`, `UserAssist`, `Events`, `Tamper`, `Temp`, `RecycleBin`, `USNJournal` | Activa el modo no interactivo. `Full` ejecuta los módulos activos en `modules` (o los de `-Modules`). Con un módulo concreto se ejecutan **Minecraft y ese módulo**, sin la pasada de firmas salvo que el módulo sea `Signatures`. `-Scan Temp` ejecuta **Minecraft, Signatures y Temp**, porque el escáner de firmas registra los indicadores concretos que busca Temp (la búsqueda de JNativeHook no los necesita). |
| `-Modules` | `Minecraft`, `Signatures`, `Processes`, `Memory`, `Prefetch`, `BAM`, `PCA`, `ShimCache`, `Recent`, `UserAssist`, `Events`, `Tamper`, `Temp`, `RecycleBin`, `USNJournal` | Limita los módulos del escaneo completo, también en la revisión automática. Se ejecutan siempre en el orden de investigación, no en el que se escriben. Con `-Scan` de un módulo concreto no se usa. |
| `-Consent` | interruptor | **Obsoleto.** Se acepta por compatibilidad y no hace nada; sin `-Scan` ya no activa el modo no interactivo. |
| `-ConsentNote` | texto | Se guarda en el reporte como "Referencia del revisor" (en los dos modos). |
| `-Days` | 0 a 365 | Ventana de análisis en días. `0` (por defecto) usa `defaultDays`. |
| `-Report` | `txt`, `json`, `html` | Formatos a exportar al terminar. **Si no se indica, no se exporta ningún reporte.** Solo en modo no interactivo: la revisión automática usa `reportFormats`. |
| `-OutputPath` | carpeta | Carpeta de reportes (por defecto, `reportDirectory`), en los dos modos. |
| `-Theme` | `FullPurple`, `MinimalPurple`, `ClassicTerminal` | Tema para esta ejecución (no se guarda). También vale en modo interactivo. |
| `-Glyphs` | `Auto`, `Full`, `Safe`, `Ascii` | Juego de glifos para esta ejecución (no se guarda). |
| `-NoAnimation` | interruptor | Desactiva las animaciones. |
| `-NoElevate` | interruptor | La revisión automática no ofrece reabrirse como administrador. |
| `-Elevated` | interruptor | Interno: lo pasa la copia reabierta como administrador para no volver a ofrecerlo. |
| `-VerifyManifest` | ruta `.sha256` | Verifica un reporte y termina con código `0` si está íntegro o `1` si algún archivo falta o fue alterado. Tiene prioridad sobre el resto de opciones, salvo `-VerifyPackage`. |
| `-VerifyPackage` | interruptor | Compara cada archivo de esta instalación con `Integrity.psd1` y termina. Solo muestra los archivos con problemas (`ALTERADO`, `AUSENTE` o `NO INCLUIDO`) y una línea de resumen, en texto plano. Código `0` si el paquete está íntegro, `1` si hay problemas o si la copia no tiene `Integrity.psd1` (copia de desarrollo). Se evalúa antes que cualquier otra opción y antes de leer la configuración. |

Las listas (`-Modules`, `-Report`) pueden escribirse desde CMD como `json,html`, `"json html"` o `json;html`. Los valores se validan sin distinguir mayúsculas; un valor desconocido detiene el script con un error que enumera los valores permitidos.

En modo no interactivo se muestra el banner, el progreso de cada módulo, el veredicto (con el resultado global), un resumen (hallazgos `CORRELATED`, `DETECTED` e `INCONCLUSIVE`, eventos de la línea temporal y artefactos revisados) y, si se pidió, la caja del reporte con los SHA-256. No se ofrece reabrir como administrador. El alcance autorizado del reporte registra la misma constancia de la revisión que el modo interactivo (usuario, equipo, fecha y si fue como administrador), la referencia y los módulos ejecutados.

### Ejemplos (CMD)

Escaneo completo con reporte JSON y HTML:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -ConsentNote "Ticket 4512 - Steve" -Report json,html
```

Solo algunos módulos, ventana de 3 días, reportes en otra carpeta:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Modules Minecraft,Signatures,Processes,Memory -Days 3 -Report txt -OutputPath "D:\Revisiones\4512"
```

Un módulo concreto (se ejecuta junto a Minecraft):

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Signatures -Report json
```

Revisión automática sin ofrecer la elevación y con los reportes en otra carpeta:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -NoElevate -OutputPath "D:\Revisiones\4512"
```

Salida apta para registros o terminales sin Unicode:

```bat
set NO_COLOR=1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -Scan Full -Glyphs Ascii -NoAnimation -Report txt
```

Verificar un reporte:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\Start-AmonSS.ps1 -VerifyManifest "%LOCALAPPDATA%\AmonSS\reports\AMON-20261021-153000-1A2B3C.sha256"
```

Verificar la instalación frente a su `Integrity.psd1`:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\1.1.0\Start-AmonSS.ps1" -VerifyPackage
```

## Códigos de salida

| Código | Situación |
| --- | --- |
| `0` | Ejecución terminada: revisión automática cerrada (también la ventana original cuando la revisión sigue en una ventana de administrador) o revisión no interactiva completada, haya o no hallazgos. También un `-VerifyManifest` con todos los archivos íntegros y un `-VerifyPackage` sin problemas. |
| `1` | `-VerifyManifest` con algún archivo ausente o alterado (o un manifiesto inexistente); `-VerifyPackage` con algún problema o sin `Integrity.psd1`; una release sin `Integrity.psd1`, o cuyo `config\settings.json` no coincide con él (las firmas o los `.cs` alterados hacen fallar los módulos que los usan, ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)); o un error no controlado, por ejemplo un valor no admitido en `-Scan`, en `-Report` o en `-Modules`. |

El código `2` de versiones anteriores (modo no interactivo sin `-Consent`) ya no existe.

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
| `TEMP` | Carpeta del barrido de Temp (DLL de JNativeHook y copias de indicadores). |
| `SystemRoot` | Carpeta de Prefetch y de PCA (`appcompat\pca`). |
| `SystemDrive` | Unidad cuyo USN Journal se lee siempre. También, con `SystemRoot`, `ProgramFiles`, `ProgramFiles(x86)`, `ProgramW6432` y `ProgramData`, decide si una ruta es una carpeta de usuario (BAM, PCA, evento 7045). |
| `USERNAME`, `COMPUTERNAME` | Constancia de la revisión en el alcance autorizado del reporte. |

## Archivos y carpetas

| Ruta | Contenido |
| --- | --- |
| `Integrity.psd1` | Solo en el paquete de release: SHA-256 de cada archivo del paquete (ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)). |
| `config\settings.json` | Ajustes predeterminados del paquete. No se modifica nunca; en una release se verifica frente a `Integrity.psd1` al cargarse. |
| `config\themes.json` | Definición de los temas. |
| `%LOCALAPPDATA%\AmonSS\settings.json` | Ajustes del usuario. Se combinan sobre los predeterminados de forma recursiva; las listas se reemplazan completas. Si el archivo está dañado, se ignora. |
| `%LOCALAPPDATA%\AmonSS\reports\` | Reportes (`<id>.txt`, `<id>.json`, `<id>.html`) y manifiesto `<id>.sha256`. |
| `%LOCALAPPDATA%\AmonSS\versions\` | Versiones instaladas por el comando de una línea o por Ajustes > Buscar actualizaciones. |

## Claves de `config\settings.json`

| Clave | Predeterminado | Significado |
| --- | --- | --- |
| `schemaVersion` | `1` | Versión del formato. El código actual no la comprueba. |
| `theme` | `FullPurple` | Tema: `FullPurple`, `MinimalPurple` o `ClassicTerminal`. |
| `glyphs` | `auto` | Glifos: `auto`, `full`, `safe` o `ascii`. |
| `animations` | `true` | Animaciones del banner y de los contadores. |
| `defaultDays` | `7` | Periodo de análisis por defecto, en días. Ajustes > `P` alterna entre 3, 7, 14 y 30. |
| `reportDirectory` | `%LOCALAPPDATA%\AmonSS\reports` | Carpeta de reportes (se expanden las `%VARIABLES%`). |
| `reportFormats` | `["txt","json","html"]` | Formatos del reporte que la revisión automática exporta al terminar (y con `E`). No se cambian desde el menú. En modo no interactivo mandan `-Report`. |
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
| `limits.maxTempFiles` | `4000` | Archivos como máximo enumerados en `%TEMP%` para buscar copias de indicadores. |
| `minecraft.extraInstancePaths` | `[]` | Directorios de juego adicionales (launchers portables). |
| `minecraft.standardGameDirectories` | lista | Nombres de carpetas habituales de un directorio de juego. Las demás se registran como carpetas no estándar de la instancia (aparecen en el JSON del reporte). |
| `scan.extraScanPaths` | `[]` | Archivos o carpetas que el escáner de firmas revisa siempre (en carpetas: `*.jar`, `*.exe`, `*.dll` y `*.zip` hasta 2 niveles). |
| `scan.scanVersionJarsWhenHashUnverified` | `true` | Escanear con firmas los JAR de `versions\` cuyo SHA-1 no se pudo verificar. |
| `keywords` | lista | Palabras clave base para decidir qué artefactos son relevantes (subcadena sin distinguir mayúsculas). En ejecución se añaden las palabras clave de los clientes, los nombres de los archivos con una detección `DETECTED` de firmas y los `--gameDir` de los procesos Java. |
| `interestingExtensions` | `[".jar", ".exe", ".dll", ".bat", ".cmd", ".ps1", ".vbs", ".pf"]` | Extensiones que hacen relevante por sí solas un elemento de la papelera y el nombre original de un envío a la papelera que registra el USN Journal. Los comprimidos (`.zip`, `.rar`, `.7z`) y los logs no están en la lista por privacidad: solo aparecen si su ruta contiene una palabra clave o un indicador (en la papelera, también si estaban en una carpeta de Minecraft). |
| `launcherProcessNames` | lista | Nombres de proceso que se tratan como Java o launcher (procesos, Prefetch, eventos 4688 y 1000). |
| `knownScreenshareTools` | Ocean | Herramientas de SS del propio staff: `{ "name": ..., "patterns": [...] }`, con subcadenas que se buscan sin distinguir mayúsculas en la ruta o en el nombre del servicio. Un servicio o driver instalado (evento 7045) que coincide se informa como `INFO` ("Driver de la herramienta de SS"), y sus ejecutables no se listan como "para revisar" en BAM ni en PCA. |
| `privacy.showUnrelatedRecycleEntries` | `false` | Con `true`, la papelera muestra también los elementos no relacionados, con su ruta original. |
| `updates.repository` | `""` | Repositorio `propietario/nombre` para buscar actualizaciones. Ajustes comprueba el formato antes de guardarlo. |
| `modules.<Módulo>` | `true` | Selección por defecto del escaneo completo (`Minecraft`, `Signatures`, `Processes`, `Memory`, `Prefetch`, `BAM`, `PCA`, `ShimCache`, `Recent`, `UserAssist`, `Events`, `Tamper`, `Temp`, `RecycleBin`, `USNJournal`). |

Ejemplo de `%LOCALAPPDATA%\AmonSS\settings.json` con solo los cambios del usuario:

```json
{
  "theme": "MinimalPurple",
  "defaultDays": 14,
  "reportFormats": ["json", "html"],
  "minecraft": { "extraInstancePaths": ["D:\\Juegos\\MultiMC\\instances\\PvP\\.minecraft"] },
  "modules": { "Temp": false }
}
```
