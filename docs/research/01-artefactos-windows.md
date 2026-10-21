# Amon SS: artefactos de Windows 10/11 para SS de Minecraft (investigación)

Fecha: 2026-10-21. Alcance: artefactos que demuestran **ejecución** o **borrado** de programas y que se pueden leer en **solo lectura** desde PowerShell 5.1/7 + C# (`Add-Type`), sin herramientas externas, sin cargar colmenas y sin instantáneas de volumen.

## Convenciones de fiabilidad

| Marca | Significado |
|---|---|
| **[Fuente]** | Lo dice una fuente primaria o reconocida (Microsoft Learn, libyal, Zimmerman, Velociraptor, investigadores DFIR). URL en cada sección. |
| **[Empírico 26200]** | Lo comprobé en solo lectura en este PC (Windows 11 Pro 10.0.26200, sesión **sin** administrador). Es una sola máquina: sirve para validar, no para generalizar. |
| **[No verificado]** | Viene de guías de la comunidad de SS o es una deducción mía. Hay que probarlo en una VM antes de basar un hallazgo en ello. |

## 0. Lo que ya hay en el repositorio (para no duplicar)

Al revisar `A:\01_Proyectos\Minecraft\Amon-SS\modules` vi que ya existen:
- `ExecutionArtifacts.psm1`: **ShimCache** (recorre las entradas `10ts` hasta el final del buffer, bien hecho) y **BAM**.
- `Tamper.psm1`: estado de SysMain/PcaSvc/DPS/EventLog/bam, eventos **7040/7031/7034** y **Kernel-General 1**.
- `Prefetch.psm1` ya lee `EnablePrefetcher`, y `Recent.psm1` dice explícitamente que no interpreta las Jump Lists.

Por eso las secciones 1, 2 y 7 sirven sobre todo como **validación y mejoras** de esos módulos. Lo nuevo de verdad está en las secciones 3 a 6 y 8.

---

## 1. BAM / DAM (Background Activity Moderator)

**Qué prueba:** la última ejecución de un ejecutable por un usuario (SID). Es de los mejores artefactos de ejecución con hora.

**Rutas [Fuente: winreg-kb, Velociraptor]:**
- `HKLM\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings\<SID>` (Windows 10 1809 y posteriores; también Windows 11).
- `HKLM\SYSTEM\CurrentControlSet\Services\bam\UserSettings\<SID>` (Windows 10 1709/1803).
- DAM: la clave equivalente `...\Services\dam\...`. [Empírico 26200] la clave `dam` existe pero no tiene subclave `UserSettings`, y `bam\UserSettings` (la variante antigua) no existe.

**Formato del valor [Fuente: winreg-kb; Suhanov]:**
- Nombre del valor: ruta NT del ejecutable, `\Device\HarddiskVolumeN\...\programa.exe`. Las apps empaquetadas (UWP) usan el nombre de la familia del paquete.
- Datos: `REG_BINARY` de 24 bytes.

| Offset | Tamaño | Contenido |
|---|---|---|
| 0x00 | 8 | FILETIME UTC (little-endian) de la última ejecución |
| 0x08 | 8 | Desconocido (ceros) |
| 0x10 | 4 | Estado de moderación (0, 1 o 2). Suhanov: si no es 0, la purga por antigüedad no borra la entrada |
| 0x14 | 4 | Desconocido (winreg-kb: siempre 2) |

- Conversión: `[DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($d,0))`.
- Cada SID también tiene valores que no son rutas (normalmente `Version` y `SequenceNumber`, de tipo DWORD). Hay que **filtrar por tipo `REG_BINARY`**, como hace Velociraptor. [No verificado] los nombres exactos de esos valores en 26200: no pude leer la clave sin administrador.
- Para traducir `\Device\HarddiskVolumeN` a letra de unidad: `QueryDosDevice` para cada letra (A-Z) y comparar prefijos. Es de solo lectura.

**Permisos [Empírico 26200]:** sin administrador, `bam\State` y la propia subclave del SID devuelven *Acceso denegado*. **Hace falta administrador**, y la lectura es un `OpenSubKey(..., writable:$false)` normal.

**Comportamiento que importa en SS [Fuente: Maxim Suhanov, "BAM internals"]:**
- La FILETIME se actualiza al **crear** el proceso y al **terminar**, así que se parece a "última ejecución o cierre".
- **Vida por defecto: 7 días** (`UserSettingsLifetimeMs`, por defecto 0x240C8400 ms = 604 800 s). Las entradas más antiguas se purgan, sobre todo durante el arranque.
- **Se borran las entradas cuyo ejecutable ya no existe.** Un cheat borrado puede desaparecer de BAM después de reiniciar. La ausencia en BAM no prueba nada.
- **No se crean entradas para ejecutables en unidades extraíbles ni en recursos de red** (el driver devuelve `STATUS_NOT_SUPPORTED`). Un cheat ejecutado desde USB **no deja BAM**.
- Hay una anomalía sin explicar: las aplicaciones de consola lanzadas desde una sesión de línea de comandos pueden no crear entrada.

**Falsos positivos y límites:** BAM no guarda hash ni argumentos. Se puede borrar con privilegios. Que la última escritura de la clave del SID sea reciente es normal, porque BAM se actualiza constantemente.

**Mejoras para el módulo actual:** documentar en `Limitations` lo de USB y red, la purga a los 7 días y el borrado de entradas de ejecutables que ya no existen. Cruzar con Prefetch, que **sí** registra ejecuciones desde USB.

Fuentes: https://winreg-kb.readthedocs.io/en/latest/sources/system-keys/Background-activity-moderator.html · https://dfir.ru/2020/04/08/bam-internals/ · https://docs.velociraptor.app/artifact_references/pages/windows.forensics.bam

---

## 2. ShimCache / AppCompatCache (Windows 10/11)

**Qué prueba:** que el sistema **vio** el archivo (por ejecución, o al mostrarlo en el Explorador) y su fecha de **última modificación** ($STANDARD_INFORMATION). **No** prueba la ejecución ni da la hora de ejecución [Fuente: winreg-kb, Magnet, Cyber Triage].

**Ruta:** `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\AppCompatCache`, valor `AppCompatCache` (`REG_BINARY`). [Empírico 26200] **se lee sin administrador** (299 180 bytes, 1024 entradas).

**Cabecera [Fuente: winreg-kb; AppCompatCacheParser]:**
- Offset 0, 4 bytes: tamaño de cabecera y también offset de la primera entrada. Vale **0x30** (Windows 10 anterior a Creators Update) o **0x34** (Creators Update y posteriores, también Windows 11).
- Número de entradas: winreg-kb y Zimmerman lo sitúan en 0x24 (cabecera 0x30) o en **0x28** (cabecera 0x34).
- **[Empírico 26200] en 0x28 hay 0x34 (52), y también en 0x2C, pero hay 1024 entradas.** En este build ese campo **no** es el número de entradas. Hay que recorrer las firmas `10ts` hasta el final, que es lo que ya hace `ConvertFrom-AmonShimCache`.

**Entrada (tamaño variable) [Fuente: winreg-kb, AppCompatCacheParser]:**

| Offset relativo | Tamaño | Campo |
|---|---|---|
| 0 | 4 | Firma ASCII `10ts` |
| 4 | 4 | Desconocido. [Empírico] parece un hash |
| 8 | 4 | Tamaño de la entrada sin estos 12 primeros bytes. La siguiente entrada empieza en `inicio + 12 + tamaño` |
| 12 | 2 | Longitud de la ruta en bytes |
| 14 | n | Ruta en UTF-16LE, sin terminador |
| 14+n | 8 | FILETIME de última modificación del archivo |
| 22+n | 4 | Tamaño de los datos |
| 26+n | m | Datos (formato no documentado) |

**Particularidades de Windows 10/11:**
- **Orden:** la posición 0 es la entrada más reciente [Fuente: Velociraptor, Cyber Triage].
- **Solo se escribe en el registro al apagar o reiniciar.** Lo que pasó desde el último arranque no está en el registro [Fuente: Magnet, Cyber Triage]. Un reinicio forzado (corte de luz) puede perder la caché de esa sesión.
- **Máximo de 1024 entradas** [Fuente: Cyber Triage. Empírico: exactamente 1024].
- **Apps empaquetadas [Empírico 26200]:** 105 de 1024 entradas tienen una "ruta" con campos separados por tabulador (`00000009<TAB>…<TAB>8664<TAB>Microsoft.WindowsTerminal<TAB>8wekyb3d8bbwe`) y FILETIME 0. Se descartan, como ya hace el módulo.
- **Bandera de ejecución:** no hay acuerdo y **no es fiable**.
  - Cyber Triage y versiones antiguas de AppCompatCacheParser: si los **últimos 4 bytes de los datos valen 1**, es "probable" que se ejecutara.
  - El código actual de AppCompatCacheParser (`Windows10.cs`) trata los datos como registros TLV alineados a 4 bytes (etiqueta u32, tamaño u32, valor) y marca ejecutado si aparece la **etiqueta 0x100**. Las etiquetas 0x800 y 0x2000 contendrían el tipo de máquina PE (0x8664 / 0x14C).
  - [Empírico 26200] las dos heurísticas dan resultados distintos con los mismos datos (199 frente a 318 de 1024). En todas las entradas los datos empiezan por el DWORD 0x200.
  - **Recomendación:** no mostrar "ejecutado". Como mucho, un indicio de baja confianza.

**Falsos positivos:** entran archivos que solo se vieron en el Explorador (miniaturas, propiedades). La fecha es de modificación del archivo, no de ejecución, y se puede falsificar (timestomping).

Fuentes: https://github.com/libyal/winreg-kb/blob/main/docs/sources/system-keys/Application-compatibility-cache.md · https://github.com/EricZimmerman/AppCompatCacheParser (archivo `AppCompatCache/Windows10.cs`) · https://docs.velociraptor.app/artifact_references/pages/windows.registry.appcompatcache · https://www.cybertriage.com/blog/shimcache-and-amcache-forensic-analysis-2026/ · https://www.magnetforensics.com/blog/shimcache-vs-amcache-key-windows-forensic-artifacts/

---

## 3. Amcache.hve

**Qué prueba:** existencia y metadatos de ejecutables: ruta, tamaño, **SHA-1 de los primeros 30 MB**, editor, versión y fecha de enlace del PE. Ayuda a probar que un archivo **existió** aunque ya se haya borrado. **No** es prueba definitiva de ejecución: Cyber Triage aconseja tratarlo como evidencia de existencia, y Velociraptor pide corroborarlo.

**Ruta:** `C:\Windows\appcompat\Programs\Amcache.hve` (formato REGF), más `Amcache.hve.LOG1`/`.LOG2` (registros de transacciones).

**Estructura útil (Windows 10/11) [Fuente: AmcacheParser `AmcacheNew.cs`, Velociraptor]:**
- `Root\InventoryApplicationFile\<subclave>` con valores de texto: `LowerCaseLongPath`, `FileId` (= `0000` + SHA-1), `Size`, `Name`, `Publisher`, `ProductName`, `ProductVersion`, `Version`, `BinaryType`, `LinkDate` (texto con formato de fecha, interpretado como UTC), `IsOsComponent`, `IsPeFile`, `ProgramId`, `LongPathHash`, `Usn`, `OriginalFileName`.
- También `Root\InventoryApplication`, `InventoryApplicationShortcut`, `InventoryDriverBinary` (útil para drivers vulnerables) e `InventoryDevicePnp`.
- La última escritura (LastWrite) de cada subclave se usa como "Timestamp" en las herramientas, pero no hay una semántica oficial. No la presentes como hora de ejecución.

**¿Se puede leer en solo lectura sin herramientas externas?**
- `RegLoadKey` / `RegLoadAppKey`: **no**. Microsoft documenta que `RegLoadAppKey` **crea un archivo vacío si no existe** y carga la colmena en el registro. Además, Project Zero (MS16-124) mostró que el modo de solo lectura de `NtLoadKeyEx` podía perder la bandera y abrir la colmena en escritura, creando archivos de log. Lo descarto, igual que las instantáneas de volumen.
- **Viable: leer los bytes y parsear REGF en C#.**
  - [Empírico 26200] `[IO.File]::Open(ruta,'Open','Read','ReadWrite,Delete')` abrió `Amcache.hve` y leyó la cabecera `regf` (secuencias iguales, versión 1.5).
  - En ese momento la colmena **no figuraba en `HKLM\SYSTEM\CurrentControlSet\Control\hivelist`**. Windows la carga **bajo demanda** (tareas de *Application Experience*), y fuera de esos momentos el archivo no está bloqueado.
  - Si está cargada, la apertura fallará con *sharing violation*. Entonces hay que informar "no disponible" o usar el plan B.
- **Permisos:** la ACL normal da lectura de datos solo a Administradores/SYSTEM (Usuarios solo tiene `ExecuteFile/ReadPermissions`). En este PC había además un ACE explícito para el usuario, que no es estándar. **Asume que hace falta administrador.**
- **Plan B (más caro):** leer el volumen en bruto (`\\.\C:` con `GENERIC_READ`, como el accesor NTFS de Velociraptor), localizar el archivo en la MFT y extraer sus *runs*. Es de solo lectura, pero supone un parser NTFS completo.
- **Datos pendientes:** si la cabecera tiene secuencias distintas (colmena "sucia"), o los `.LOG1/.LOG2` contienen transacciones nuevas, la colmena principal puede estar desfasada. Aplicar los logs en memoria es complejo. Como mínimo, avisar de "posiblemente incompleta".
- Referencia del formato REGF (hbin, nk, vk, listas lf/lh/ri/li, big data `db`): documentación de libregf (Joachim Metz).

**Win10 frente a Win11:** el esquema `Inventory*` es el mismo. El formato ha cambiado muchas veces desde 2013 (`Root\File` y `Root\Programs` son antiguos).

Fuentes: https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regloadappkeyw · https://www.exploit-db.com/exploits/40608/ · https://github.com/EricZimmerman/AmcacheParser · https://docs.velociraptor.app/artifact_references/pages/windows.forensics.amcache · https://cyber.gouv.fr/sites/default/files/2019/01/anssi-coriin_2019-analysis_amcache.pdf · https://github.com/libyal/libregf/blob/main/documentation/Windows%20NT%20Registry%20File%20(REGF)%20format.asciidoc · https://www.cybertriage.com/blog/shimcache-and-amcache-forensic-analysis-2026/

---

## 4. Memoria de procesos (técnica de las SS)

### 4.1 APIs, privilegios y alcance

- **Proceso del servicio:** `QueryServiceStatusEx(SC_STATUS_PROCESS_INFO)` o `Win32_Service.ProcessId` para DPS/PcaSvc. Desde Windows 10 1703, en equipos de escritorio con más de 3,5 GB de RAM, cada servicio corre en su **propio** svchost; con menos RAM siguen agrupados [Fuente: Microsoft Learn].
- **Apertura:** `OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid)`. `PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ` también sirve para `VirtualQueryEx`/`ReadProcessMemory`.
- **Recorrido:** bucle de `VirtualQueryEx` filtrando `State == MEM_COMMIT`, `Type == MEM_PRIVATE`, `Protect & PAGE_READWRITE` y sin `PAGE_GUARD`. Luego `ReadProcessMemory` por región y búsqueda de marcadores ASCII y UTF-16.
- **SeDebugPrivilege:** hace falta para los svchost de servicios, que corren como LocalService o SYSTEM. Habilitarlo (`AdjustTokenPrivileges`) solo toca el token del propio Amon SS, no la configuración del sistema. Con él, `OpenProcess` concede el acceso aunque el descriptor de seguridad no lo dé [Fuente: Microsoft Learn OpenProcess].
- **csrss.exe: no viable.** Microsoft documenta que `OpenProcess` falla con `ERROR_ACCESS_DENIED` para System y para los procesos CSRSS aunque se tenga SeDebugPrivilege. Las guías de SS usan el **driver de kernel de System Informer** para leerlo. Fuera de alcance para una herramienta de solo lectura sin drivers.
- **lsass.exe: nunca.** Contiene credenciales, puede ser PPL (RunAsPPL), y los antivirus tratan cualquier lectura de su memoria como robo de credenciales.
- **Riesgo con antivirus/EDR:** leer la memoria de otros procesos (sobre todo svchost de servicios) puede disparar heurísticas. Hay que documentarlo para el staff.
- **Privacidad:** la memoria de explorer y de los servicios contiene rutas, nombres de documentos y a veces URLs. Reglas mínimas:
  1. buscar solo marcadores concretos;
  2. no volcar ni guardar regiones crudas;
  3. mostrar solo rutas ejecutables relevantes (indicadores, sin firma, borradas) y contar el resto, como hace ya `ExecutionArtifacts`;
  4. avisar al jugador antes de leer memoria.

### 4.2 explorer.exe: trazas PcaClient (verificado)

- **[Empírico 26200]**: en la memoria privada de lectura/escritura de `explorer.exe` hay líneas **ANSI**, separadas por CRLF, con este formato:
  ```
  TRACE,0000,0000,PcaClient,MonitorProcess,<ruta completa del .exe>,Time,<n>
  ```
  Leerlas **no requiere administrador** (mismo usuario, misma integridad). También aparecieron líneas que terminan en `,SFC protected`.
- `pcasvc-executed` (spokwn, C++) usa exactamente los marcadores `TRACE,` y `,MonitorProcess,`, y la ruta llega hasta la siguiente coma [Fuente: código en GitHub].
- **Qué aporta:** lista de programas lanzados recientemente por el usuario, a menudo los últimos. Persiste mientras viva el proceso explorer.
- **Límites:** **no hay marca de tiempo.** El significado de `Time,<n>` es desconocido [No verificado]. Se pierde si se reinicia explorer, y la guía Red Lotus lo considera fácil de eludir. Las rutas con comas se cortan.
- La guía Red Lotus también busca `file:///` en explorer (archivos abiertos desde el shell), pero produce mucho ruido y no prueba ejecución.

### 4.3 PcaSvc (svchost `-s PcaSvc`)

- Requiere administrador y SeDebugPrivilege.
- `pcasvc-executed` busca en **toda la memoria comprometida** el patrón ASCII `:\` y reconstruye rutas tipo `C:\...\x.ext` (caracteres imprimibles de 0x21 a 0x7A; un espacio corta la ruta) [Fuente: código]. **No obtiene marca de tiempo** de la memoria.
- La guía Red Lotus recomienda buscar `jar` sin punto en PcaSvc para cazar `java -jar` con la extensión cambiada.
- **Mejor alternativa:** en Windows 11 22H2+, el propio PcaSvc vuelca su información en `C:\Windows\appcompat\pca\*.txt` con fecha (sección 5). Es más fiable y no toca memoria.

### 4.4 DPS (svchost `-k LocalServiceNoNetwork -p -s DPS`)

- Requiere administrador y SeDebugPrivilege (el servicio corre como LocalService).
- **Formato `!!nombre.exe!AAAA/MM/DD:HH:MM:SS`: [No verificado en fuente primaria].**
  - Lo único publicado es la guía Red Lotus. Usa las regex `^([a-zA-Z]:\\.+)\\?$` (rutas completas) y `^!![A-Z]((?!Exe).)*$` (entradas que empiezan por `!!` y **no** terminan en `.exe`, para ejecutables renombrados). Eso confirma el prefijo `!!`.
  - La misma guía dice que junto a la ruta suele haber la **fecha de compilación del PE** (TimeDateStamp de la cabecera), **no la hora de ejecución**.
  - Si se implementa, esa fecha solo sirve para identificar el binario, comparándola con el PE de un cheat conocido.
- No pude comprobarlo empíricamente: hace falta administrador.
- **Plan de validación en VM:** ejecutar un .exe conocido, leer la memoria de DPS con el bucle del 4.1, buscar `!!` en ASCII y UTF-16, y comparar la fecha con el `TimeDateStamp` del PE.
- **Fragilidad:** las cadenas desaparecen al reiniciar el servicio (también al reiniciar el equipo). Por eso la sección 7.1 propone vigilar la hora de inicio del proceso del servicio. El proyecto Devyl tiene su escáner de firmas DPS "temporalmente desactivado".

Fuentes: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocess · https://learn.microsoft.com/en-us/windows/application-management/svchost-service-refactoring · https://github.com/spokwn/pcasvc-executed (`Process_Utils.cpp`, `Process_Scan/PcaSvc.cpp`) · https://itzicehere.gitbook.io/redlotusguide/screensharing-general-knowledge/seventh-section-manual-ss-techniques/specific-processes-to-analyze-and-search-patterns/4-svchostexe.md · https://itzicehere.gitbook.io/redlotusguide/screensharing-general-knowledge/seventh-section-manual-ss-techniques/specific-processes-to-analyze-and-search-patterns/1-explorerexe.md · https://itzicehere.gitbook.io/redlotusguide/screensharing-general-knowledge/seventh-section-manual-ss-techniques/specific-processes-to-analyze-and-search-patterns/2-csrssexe.md · https://github.com/Sypherox/Devyl

---

## 5. Program Compatibility Assistant (PCA)

### 5.1 Archivos de texto de Windows 11 22H2+ (prioridad alta)

Carpeta `C:\Windows\appcompat\pca\`. **[Empírico 26200]** los dos archivos con datos **se leen sin administrador**, con `FileShare.ReadWrite`.

**`PcaAppLaunchDic.txt`** [Fuente: Rathbun/Gonzalez en aboutdfir; Sygnia]
- Codificación **ANSI (CP-1252)**, líneas CRLF.
- Formato de cada línea: `ruta completa|AAAA-MM-DD HH:MM:SS.fff`, por ejemplo `C:\Program Files\Everything\Everything.exe|2022-12-28 16:06:24.212`.
- La hora es la **última ejecución, en UTC** (Sygnia). [Empírico] sin BOM, y empieza directamente por `C:\...|2026-05-17...`.
- Análisis: separar por el **último** `|`, y convertir con `[DateTime]::ParseExact(s,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture,'AssumeUniversal,AdjustToUniversal')`.
- **Solo registra lanzamientos desde interfaz gráfica** (Explorador, RDP, página de descargas del navegador, 7-Zip GUI). **No** registra cmd, PowerShell, tareas programadas ni PsExec [Fuente: Sygnia].
- Una ruta con caracteres no ANSI corta la línea en el primer carácter no ANSI, y Sygnia observó que después **dejan de registrarse ejecuciones nuevas**. Hay que detectar líneas sin `|` y marcarlas como "registro truncado".
- Solo existe en Windows 11 22H2 o posterior (no estaba en 21H2). En Windows 10 no existe.

**`PcaGeneralDb0.txt` / `PcaGeneralDb1.txt`** [Fuente: aboutdfir; Sygnia]
- Codificación **UTF-16LE** (admite sustitutos sueltos) sin BOM, líneas CRLF. [Empírico: empieza por `2026-05-17 02:46:52.205|3|%progr...`].
- 8 campos separados por `|`, en este orden según aboutdfir: **hora** | **tipo de registro** | **ruta** (normalizada) | **descripción** | **fabricante** | **versión** | **ProgramId** (el mismo de Amcache) | **mensaje** (por ejemplo `Abnormal process exit with code 0x80`).
- Tipos según Sygnia: 0 = fallo del instalador; 1 = driver bloqueado (`BlockReasonCet/Hvci/Other`); 2 = **salida anormal del proceso** (código de salida distinto de 0); 3 = "PCA Resolve is Called"; 4 = desconocido.
- **Rutas normalizadas:** en minúsculas, sin letra de unidad, con variables (`%programfiles%`, `%USERNAME%`) y con el nombre de carpeta bajo `Users` sustituido por x.
- La zona horaria de estos archivos no está documentada. [No verificado] probablemente UTC, como el diccionario.
- **Rotación:** se escribe en el principal hasta unos 2 MB y luego se alterna con el otro, así que hay entre 2 y 4 MB de historia. [Empírico] Db0 de 673 KB y Db1 vacío.
- Para SS: el tipo 2 con la ruta de un cheat, o `javaw.exe` saliendo con código anormal, es un buen indicio adicional.

### 5.2 Registro `Compatibility Assistant\Store` (Windows 10 y 11)

- Ruta: `HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store`. No requiere administrador, porque es la colmena del usuario.
- Cada valor tiene como nombre la ruta completa de un ejecutable lanzado (en contexto PCA) y como datos un `REG_BINARY`.
- **Formato no documentado públicamente.** [Empírico 26200] 381 valores, con tamaños de 60, 108, 132, 148 y 172 bytes. Todos empiezan por la firma ASCII `SACP` y un DWORD 1.
  - En el offset 0x2C hay una FILETIME, pero era **la misma en los 381 valores** (2026-05-16, que coincide con la creación de la carpeta PCA). **No es una hora por entrada.**
- **Uso:** prueba de que un ejecutable se lanzó alguna vez desde la sesión del usuario. La única fecha es la LastWrite de la clave (última entrada nueva).
- La subclave `...\Compatibility Assistant\Persisted` también existe [Empírico: 5 valores].

### 5.3 Eventos PCA (habilitados por defecto, [Empírico 26200])

- `Microsoft-Windows-Application-Experience/Program-Compatibility-Assistant`, **id 17**: datos `ExePath` y `ResolverName` (por ejemplo `DetectorShim_KernelDriver`, `WrpKeyMitigation`). Da ruta y hora del evento.
- `Microsoft-Windows-Application-Experience/Program-Telemetry`, **id 500/505**: `ProcessId`, `StartTime` (UTC), `ExePath`, `FixID`, `FixName`. Indica que se aplicó una corrección de compatibilidad al proceso, así que da **hora de inicio del proceso**, pero solo para apps que reciben un shim.

Fuentes: https://aboutdfir.com/new-windows-11-pro-22h2-evidence-of-execution-artifact/ · https://www.sygnia.co/blog/new-windows-11-pca-artifact/ · https://docs.velociraptor.app/exchange/artifacts/pages/windows.system.appcompatpca

---

## 6. Otros artefactos de usuario

### 6.1 MUICache (fácil y útil)

- Ruta: `HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache` (está en `UsrClass.dat`, accesible por HKCU **sin administrador**).
- Nombres de valor con la forma `<ruta>.FriendlyAppName` y `<ruta>.ApplicationCompany`. Los datos son `FileDescription` y `CompanyName` del PE.
- Prueba la ejecución de programas **con interfaz gráfica** por parte de ese usuario, e incluye la ruta completa.
- **No tiene marca de tiempo** por valor. Microsoft no documenta cuándo se crea la entrada [Fuente: Cyber Triage, Magnet].
- Útil porque sobrevive al borrado del ejecutable y muestra la descripción del PE aunque el archivo se haya renombrado.

### 6.2 ShellBags (resumen)

- `HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU` y `Bags` (UsrClass.dat), y `HKCU\Software\Microsoft\Windows\Shell\BagMRU` (NTUSER.DAT).
- Árbol de subclaves numeradas. Cada valor es un *shell item* binario (formato libfwsi) con el tipo, el nombre 8.3, el nombre largo y a veces fechas.
- Prueban la **navegación por carpetas** en el Explorador, incluidas carpetas borradas y unidades extraíbles. No prueban acceso a archivos ni ejecución.
- **Esfuerzo alto** (parsear shell items) y valor medio-bajo para SS. Lo recomiendo solo como futuro "carpetas USB visitadas".

### 6.3 Jump Lists (AutomaticDestinations), viable con esfuerzo medio

- Ubicación: `%APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations\<AppID>.automaticDestinations-ms`. El AppID es un CRC64 de la ruta del ejecutable.
- **Formato OLE Compound File** ([MS-CFB], documentado por Microsoft) con un flujo `DestList` y flujos de nombre hexadecimal, cada uno con un **LNK** completo ([MS-SHLLINK]).
- `DestList` [Fuente: libyal dtformats]:
  - Cabecera de 32 bytes: versión (1 = Windows 7, 3/4 = Windows 10+), número de entradas, número de fijadas, último número de entrada…
  - Entrada v1: identificadores droid, nombre NetBIOS (16 B) en 0x48, número de entrada en 0x58, **FILETIME de última modificación en 0x64**, estado de fijado en 0x6C, longitud de la ruta en 0x70 (en caracteres) y ruta UTF-16 en 0x72.
  - Entrada v3+: igual hasta 0x6F; luego 0x70 desconocido, **0x74 posible contador de accesos**, 0x78 vacío, **0x80 longitud de la ruta**, 0x82 ruta, y 4 bytes de relleno.
  - El número de entrada en hexadecimal es el nombre del flujo LNK (así lo usa JLECmd de Zimmerman). [No verificado] para v4.
- **Viabilidad:** sí. Un lector CFB mínimo (sectores de 512 B, FAT, DIFAT, directorio, mini-stream) cabe en unas 300-400 líneas de C#. Normalmente se abre con `FileShare.ReadWrite`.
- **Valor para SS:** archivos abiertos con cada app (por ejemplo `.jar` o configuraciones abiertos con un programa concreto) con fecha. Complementa Recent, que ya se lee.

### 6.4 SRUM: no viable en solo lectura simple

- `C:\Windows\System32\sru\SRUDB.dat` es una base de datos **ESE**. Se escribe **cada hora y al apagar**; lo reciente queda temporalmente en el registro [Fuente: Magnet, TROOPERS19].
- La tabla *Application Resource Usage* `{D10CA2FE-6FCF-4F6D-848E-B2E99266FA89}` da la ruta de la app, el SID y uso de CPU/E/S por intervalo: prueba que algo corrió en una franja de una hora.
- **Bloqueada en un sistema vivo.** Para leerla haría falta extraerla en bruto (NTFS) y además abrirla con ESE (`esent.dll`, que exige una ruta en disco y puede necesitar recuperación, lo que modifica la copia) o con un parser ESE propio, que es muy costoso.
- **Conclusión:** fuera del alcance de "solo lectura simple". No lo implementaría.

Fuentes: https://www.cybertriage.com/blog/muicache-2026-guide/ · https://www.magnetforensics.com/blog/forensic-analysis-of-muicache-files-in-windows/ · https://www.magnetforensics.com/blog/forensic-analysis-of-windows-shellbags/ · https://github.com/libyal/dtformats/blob/main/documentation/Jump%20lists%20format.asciidoc · https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/ · https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-shllink/ · https://www.magnetforensics.com/blog/srum-forensic-analysis-of-windows-system-resource-utilization-monitor/ · https://troopers.de/downloads/troopers19/TROOPERS19_AD_Beyond_Windows_Forensics.pdf

---

## 7. Manipulación típica antes de una SS y cómo detectarla

Enfoque: **indicadores observables** que Amon SS puede leer. Ninguno prueba trampas por sí solo; cada uno lleva una lista de falsos positivos.

### 7.1 Servicios detenidos, deshabilitados, reiniciados o "congelados"

- **Estado y tipo de inicio:** `Win32_Service` (`State`, `StartMode`) para SysMain, PcaSvc, DPS, EventLog y DiagTrack. `bam` es un **driver** (`Services\bam\Start`, 1 = System); `Start = 4` significa deshabilitado. Se lee sin administrador.
- **Evento 7040** (System, Service Control Manager): cambio de tipo de inicio. Datos `param1..3` y **`param4` = nombre de la clave del servicio** [Empírico]. Para caídas, **7034/7031**. Ya está en Tamper.
- **7036 ("el servicio entró en estado X"): no contar con él.** [Empírico 26200] la plantilla existe, pero **no hay ni un 7036** en el registro System, que abarca desde el 31-07-2026. Se cree que dejó de emitirse por defecto en versiones recientes, pero no encontré confirmación oficial. **Cómo saber cuándo se detuvo un servicio sin 7036:**
  1. **Hora de inicio del proceso host** (`Win32_Process.CreationDate` del PID del servicio) comparada con el arranque (`Win32_OperatingSystem.LastBootUpTime` o Kernel-General 12). Un svchost de DPS, PcaSvc o SysMain que arrancó mucho después del arranque indica que el servicio se reinició, y eso **borra sus cadenas en memoria**. Falsos positivos: actualizaciones, caídas (cruzar con 7031/7034) y servicios de inicio por demanda.
  2. Para EventLog, un **6005** (servicio de registro de eventos iniciado) sin un Kernel-General 12 (arranque) cercano indica que se reinició el servicio. El **1100** de Security (el servicio de registro se apagó) también ayuda.
- **Hilos suspendidos o eliminados** [Fuente: guía Red Lotus; Phant0m]: hay técnicas que congelan o matan solo los hilos del servicio (por ejemplo los de `wevtsvc.dll` en el svchost de EventLog) para que siga "Running" pero no registre nada.
  - Detección de solo lectura: `[Diagnostics.Process]::GetProcessById(pid).Threads`, marcando `ThreadState -eq 'Wait' -and WaitReason -eq 'Suspended'` (valor 5; solo es válido cuando el estado es `Wait`) [Fuente: .NET ThreadWaitReason].
  - Señal de apoyo: que el registro System o Security no tenga eventos recientes en un sistema activo.

### 7.2 Cambio de la hora del sistema

- **Security 4616**: se registra **siempre**, independientemente de la directiva de auditoría. Incluye `PreviousTime`, `NewTime` (UTC), `ProcessName` y el SID. Microsoft recomienda alertar si el sujeto no es LOCAL SERVICE o el proceso no es svchost (W32Time). Requiere administrador para leer Security.
- **System, Kernel-General 1** [Empírico, campos en 26200]: `NewTime`, `OldTime`, `TimeDeltaInMs`, `Reason` (con texto, por ejemplo "An application or system component changed the time"), `ProcessName` (ruta NT), `ProcessID`, `CmosTime`, `TimeZoneBias`. No requiere administrador. Filtrar por `ProcessName` distinto de svchost o por un `TimeDeltaInMs` grande.
- Contexto: Kernel-General **22** (cambio de diferencia horaria) y **24** (actualización de la zona horaria).

### 7.3 Borrado del USN Journal

- **`Microsoft-Windows-Ntfs/Operational` id 501** (habilitado por defecto [Empírico]). La plantilla del sistema dice: "Un proceso ha eliminado un diario USN en un volumen", con `ProcessName`, `VolumeName`, **`JournalId`** y `CurrentUsn`.
  - **Atención [Empírico 26200]:** hay 375 eventos 501, todos de `SearchIndexer` con el **mismo** JournalId y `CurrentUsn=0`, sin que el diario cambiara. Parece emitirse también en llamadas que no borran nada [No verificado: causa exacta].
  - **Regla útil:** 501 con `ProcessName` distinto de SearchIndexer, sobre todo `fsutil`, o un JournalId distinto del actual.
- **`FSCTL_QUERY_USN_JOURNAL`** (ya se usa en el módulo USN):
  - `UsnJournalID` cambia cada vez que se crea un diario nuevo [Fuente: Microsoft Learn].
  - [Empírico] el JournalId del volumen C: se decodifica como FILETIME plausible (2025-04-10). Si `UsnJournalID` interpretado como FILETIME es **posterior al último arranque** o muy reciente, el diario se recreó hace poco [No verificado como garantía; Microsoft no lo documenta].
  - Si el primer registro legible del diario es muy reciente con un `MaximumSize` grande, también es sospechoso.
- **Corroboración:** un `FSUTIL.EXE-*.pf` en Prefetch con hora cercana (si Prefetch está activo), y 4688 con la línea de comandos si está auditado.

### 7.4 Limpieza de Prefetch

- `EnablePrefetcher` (0 = desactivado) y SysMain detenido o deshabilitado; Amon ya lo hace.
- Registros USN con motivo `FILE_DELETE` sobre `C:\Windows\Prefetch\*.pf`.
- Incoherencias: un `javaw.exe`, `explorer.exe` o el launcher en ejecución **sin** su `.pf`; muy pocos `.pf` en un sistema con mucho tiempo encendido; la LastWrite de la carpeta muy reciente.

### 7.5 Timestomping

- **Señal barata:** USN con motivo `BASIC_INFO_CHANGE` (0x00008000) sobre el archivo sospechoso, sin una modificación de contenido asociada [Fuente: inversecos].
- **Señal fuerte pero cara:** $STANDARD_INFORMATION anterior a $FILE_NAME (requiere leer la MFT en bruto).
- **Señal débil:** nanosegundos a cero. inversecos demuestra que hay herramientas que fijan nanosegundos arbitrarios.
- **Falso positivo clásico:** al copiar un archivo, la fecha de creación es posterior a la de modificación. Eso es normal y no indica timestomping.

### 7.6 Process Hacker / System Informer usados antes de la SS

- **Presencia:** Prefetch (`SYSTEMINFORMER.EXE`, `PROCESSHACKER.EXE`), BAM, PCA, la clave del driver `HKLM\SYSTEM\CurrentControlSet\Services\KSystemInformer` y el **evento 7045** (servicio o driver instalado).
- **Cuidado:** el staff lo usa en la propia SS. Solo es relevante si la ejecución es **anterior** a la hora de inicio de la revisión.
- Que se borraran cadenas de memoria no se puede demostrar después del hecho. Lo que sí se ve es el reinicio de servicios (7.1) y la herramienta (este punto).

### 7.7 Máquinas virtuales y entorno

- `Win32_ComputerSystem.Manufacturer` y `.Model` (SMBIOS tipo 1) con cadenas de hipervisores conocidos (VMware, VirtualBox, QEMU, "Virtual Machine").
- **`HypervisorPresent = True` no basta:** también es verdadero en equipos físicos con Hyper-V, VBS o integridad de memoria, o WSL2. Puede generar muchos falsos positivos.

### 7.8 Ejecución desde USB

- BAM **no registra** ejecutables en unidades extraíbles (Suhanov), pero Prefetch sí guarda el volumen. Hay que cruzar las rutas de Prefetch que estén fuera de C:.
- **Registro:** `HKLM\SYSTEM\CurrentControlSet\Enum\USBSTOR` y `Enum\USB` (sin administrador). Las fechas de primera instalación, última llegada y última retirada son propiedades de `{83da6326-97a6-4088-9453-a1923f573b29}` (0x65 FirstInstall, 0x64 Install, 0x66 LastArrival, 0x67 LastRemoval) [Fuente: Elcomsoft].
  - Para no depender de permisos de la subclave `Properties`, usar la API `SetupDiGetDevicePropertyW` con `DEVPKEY_Device_FirstInstallDate`, `DEVPKEY_Device_LastArrivalDate` y `DEVPKEY_Device_LastRemovalDate` [No verificado: comportamiento de permisos en 26200].
- **Eventos (habilitados por defecto [Empírico]):**
  - `Microsoft-Windows-Kernel-PnP/Configuration`: según las plantillas de Windows, **400 = dispositivo configurado**, **410 = iniciado**, **420 = borrado** y **430 = requiere más instalación**. Algunas fuentes secundarias dicen "410 migrado" o "430 instalado"; me quedo con las plantillas del sistema. Incluyen `DeviceInstanceId` (`USBSTOR\...\<serie>`).
  - `Microsoft-Windows-Partition/Diagnostic` **1006**: fabricante, modelo y número de serie, más copia del VBR (`Vbr0`). El número de serie del volumen está en el VBR (NTFS 0x48, FAT32 0x43, exFAT 0x64) [Fuente: Jason Hale vía Elcomsoft/NCST].
  - `Storage-ClassPnP/Operational` 507.
  - `DriverFrameworks-UserMode/Operational` está **deshabilitado** por defecto [Empírico].

### 7.9 Papelera vaciada

La LastWrite de `C:\$Recycle.Bin\<SID>` y los registros USN `FILE_DELETE` de nombres `$R*`/`$I*` dentro de esa carpeta. Complementa el módulo RecycleBin actual.

Fuentes: https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4616 · https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-usn_journal_data_v0 · https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.threadwaitreason · https://github.com/hlldz/Phant0m · https://itzicehere.gitbook.io/redlotusguide/screensharing-general-knowledge/eighth-section-common-bypass-techniques-in-screensharing/artifact-and-system-manipulation/service-thread-suspension.md · https://www.elastic.co/guide/en/security/current/delete-volume-usn-journal-with-fsutil.html · https://inversecos.com/2022/04/defence-evasion-technique-timestomping.html · https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem · https://blog.elcomsoft.com/2026/02/usb-device-forensics-on-windows-10-and-11/ · https://blog.ncst.com/usb-forensics-recover-more-volume-serial-numbers-with-the-windows-10-partition-diagnostic-event-log1678811064 · https://learn.microsoft.com/en-us/previous-versions/windows/embedded/ff794503(v=winembedded.1001)

---

## 8. Eventos adicionales sin auditoría especial

Todos estaban **habilitados y con eventos** en este PC con Windows 11 26200, salvo los indicados. "Admin" significa que hace falta administrador para leerlos.

| Registro / proveedor | Id | Qué aporta para SS | Notas |
|---|---|---|---|
| System / Service Control Manager | **7045** | Servicio o **driver** instalado: nombre, ruta del binario, tipo, cuenta. Detecta drivers vulnerables o de herramientas (por ejemplo KSystemInformer) | 339 eventos aquí; filtrar por ventana de tiempo |
| System / Application Popup | **26** | Ventanas de error (DLL que falta, fallos de inyección): `Caption`, `Message` | Verificado |
| System / EventLog | 6005, 6006, 6008, 6013 | Inicio y parada del servicio de registro, apagado inesperado y tiempo encendido | Base para 7.1 |
| System / Kernel-General | 12, 13 | Hora de arranque y de apagado del sistema operativo | Línea de tiempo |
| Application / Application Error | **1000** | Caída de `javaw.exe` o del launcher con el **módulo culpable**. Una DLL desconocida en una caída de javaw es muy relevante | 42 aquí |
| Application / Application Hang | 1002 | Bloqueos | |
| Application / Windows Error Reporting | 1001 | Informe WER | **0 aquí**: según Microsoft no siempre se registra |
| Archivos `Report.wer` | – | En `C:\ProgramData\Microsoft\Windows\WER\*\*\` y `%LOCALAPPDATA%\Microsoft\Windows\WER\`. UTF-16 con pares clave=valor; `EventTime` es FILETIME; `AppPath`; `TargetAppId` `W:…!0000<SHA1>` (hash como en Amcache) | Sirve para cheats que se cayeron y ya se borraron |
| Microsoft-Windows-Shell-Core/Operational | **9707/9708** | Comando ejecutado desde Run/RunOnce al iniciar sesión (`Command`) | Verificado, con línea de comandos |
| …/Program-Compatibility-Assistant | 17 | `ExePath` y `ResolverName` | Sección 5.3 |
| …/Program-Telemetry | 500/505 | `ExePath` y `StartTime` del proceso (con shim) | Sección 5.3 |
| Microsoft-Windows-Ntfs/Operational | **501** | Borrado de USN (ver 7.3) | Ignorar SearchIndexer |
| Microsoft-Windows-Windows Defender/Operational | **5007** | Cambio de configuración: buscar `NewValue` con `\Exclusions\` (exclusiones añadidas). **5001**: protección en tiempo real desactivada | El módulo actual solo lee 1116/1117 |
| Windows PowerShell | 400, 403, 600 | Inicio y fin del motor con `HostApplication` (línea de comandos del host) | Verificado |
| Microsoft-Windows-PowerShell/Operational | **4104** (nivel Warning) | PowerShell registra **automáticamente** bloques de script "sospechosos" aunque el Script Block Logging esté apagado | Útil contra limpiadores en PowerShell |
| Microsoft-Windows-Kernel-PnP/Configuration y Partition/Diagnostic | 400/410/420/430 y 1006 | Cronología USB (7.8) | |
| Security | 4616, 1100 | Hora (7.2), parada de EventLog | Admin |
| Microsoft-Windows-TaskScheduler/Operational | – | **Deshabilitado** por defecto aquí | No contar con él |
| Microsoft-Windows-Kernel-Process/Analytic | – | Deshabilitado (registro analítico) | No |
| MPLog de Defender | – | `C:\ProgramData\Microsoft\Windows Defender\Support\MPLog-*.log`, texto plano con historial de procesos y archivos analizados por Defender | Admin; el formato cambia entre versiones [Fuente: CrowdStrike] |

Fuentes: https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-application-service-crashing-behavior · https://isc.sans.edu/diary/22536 · https://docs.velociraptor.app/exchange/artifacts/pages/windows.system.windowserrorreporting · https://www.hexacorn.com/blog/?p=5918 · https://detection.fyi/sigmahq/sigma/windows/builtin/windefend/win_defender_config_change_exclusion_added/ · https://docs.velociraptor.app/artifact_references/pages/windows.eventlogs.powershellscriptblock · https://trustedsec.com/blog/building-a-detection-foundation-part-3-powershell-and-script-logging · https://www.crowdstrike.com/en-us/blog/how-to-use-microsoft-protection-logging-for-forensic-investigations/

---

## 9. Prioridad de implementación

Criterio: valor probatorio (ejecución o borrado, con hora), riesgo de falsos positivos, esfuerzo, y si requiere administrador.

| # | Artefacto | Valor | Riesgo FP | Esfuerzo | Admin | Comentario |
|---|---|---|---|---|---|---|
| 1 | **PCA Win11: `PcaAppLaunchDic.txt` + `PcaGeneralDb0/1.txt`** | Alto (ruta + **última ejecución UTC**; salidas anormales) | Bajo | Bajo | No | El mejor valor por esfuerzo. Solo Windows 11 22H2+ y lanzamientos desde la interfaz gráfica; detectar líneas truncadas |
| 2 | **Eventos nuevos baratos**: 7045, Ntfs 501 (sin SearchIndexer), Defender 5007/5001, Application Error 1000 (javaw/launcher), Shell-Core 9707, Program-Telemetry 500/505, PCA 17, Application Popup 26, PowerShell 4104 Warning y 400/600 | Medio-alto | Bajo-medio | Bajo | No (Security sí) | Reutiliza la infraestructura de `Events.psm1` |
| 3 | **Tamper+**: hora de inicio del host de cada servicio frente al arranque; hilos suspendidos; 6005 sin arranque; `bam\Start`; JournalId como FILETIME | Alto contra la manipulación | Medio | Bajo | No (algunas partes sí) | Compensa la ausencia de 7036 |
| 4 | **Trazas PcaClient en explorer** (`TRACE,…,PcaClient,MonitorProcess,<ruta>`) | Medio (ejecuciones recientes, sin hora) | Bajo | Bajo | No | Verificado en 26200. Filtrar y no volcar la memoria (privacidad) |
| 5 | **MUICache** | Medio (ejecución con interfaz gráfica, sin hora) | Bajo | Muy bajo | No | Sobrevive al borrado del archivo |
| 6 | **Compatibility Assistant\Store** | Bajo-medio (existencia de lanzamiento) | Bajo | Muy bajo | No | Formato `SACP` no documentado; usar solo los nombres de valor |
| 7 | **USB**: USBSTOR/Enum USB + Kernel-PnP 400/410 + Partition 1006 | Medio (dispositivo conectado y cuándo) | Bajo | Medio | No | Cruzar con Prefetch fuera de C: (BAM no ve los USB) |
| 8 | **Amcache** (parser REGF propio, solo lectura) | Medio-alto (SHA-1, existencia de borrados) | Medio (no prueba ejecución) | Alto | Sí | Puede estar bloqueado si Windows lo tiene cargado; avisar si la colmena está sucia |
| 9 | **Memoria de DPS/PcaSvc** | Medio | Medio | Medio | Sí + SeDebug | Formato DPS sin verificar; riesgo de alertas de antivirus; validar en VM primero |
| 10 | **Jump Lists** (CFB + DestList + LNK) | Medio | Bajo | Medio-alto | No | Complementa Recent |
| 11 | ShellBags | Bajo-medio | Bajo | Alto | No | Solo si se quieren carpetas de USB visitadas |
| – | SRUM | – | – | Muy alto | Sí | **No viable** en solo lectura simple (ESE bloqueado) |
| – | Memoria de csrss | – | – | – | – | **No viable**: `OpenProcess` lo deniega por diseño; hace falta un driver |
| – | Memoria de lsass | – | – | – | – | **Nunca** (credenciales) |

**Mejoras en módulos existentes (coste mínimo):**
- **BAM:** añadir a las limitaciones que no registra unidades extraíbles ni de red, la purga a los 7 días y el borrado de entradas de ejecutables que ya no existen; filtrar por `REG_BINARY`.
- **ShimCache:** no confiar en el contador de 0x28 (en Windows 11 26200 no lo es); no mostrar "ejecutado".
- **Tamper:** no depender de 7036; añadir hora de inicio del proceso del servicio e hilos suspendidos.
- **Events:** añadir Defender 5007/5001 y Security 4616.
