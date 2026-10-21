# Instalación

Amon SS es un conjunto de scripts de PowerShell: no tiene instalador, servicios ni dependencias externas. Hay tres formas de obtenerlo con garantías:

| Vía | Para quién | Verificación |
| --- | --- | --- |
| [A. Comando de una línea](#a-comando-de-una-línea-cmd) | Revisiones habituales | SHA-256 fijado dentro del comando |
| [B. Instalación manual verificada](#b-instalación-manual-verificada) | Repositorio privado, proxies, auditoría paso a paso | SHA-256 comparado a mano |
| [C. Scripts firmados](#c-scripts-firmados-entornos-allsigned) | Equipos con política `AllSigned` | SHA-256 del ZIP y firma Authenticode |

## Requisitos

- **Windows 10 u 11.** La herramienta usa APIs de Windows (ntdll, `DeviceIoControl` sobre NTFS, advapi32, kernel32 para leer la memoria de procesos, registro, registros de eventos) y no funciona en otros sistemas. Los registros de texto de PCA solo existen desde Windows 11 22H2.
- **Windows PowerShell 5.1** (incluido en Windows) **o PowerShell 7**. Las pruebas se ejecutaron en 5.1.26100 y 7.4.6 (ver [TESTING.md](TESTING.md)).
- **No necesita** Python, Node, el SDK de .NET ni módulos de la Galería de PowerShell. El código C# se compila en memoria con `Add-Type`, que viene con PowerShell. Pester 5 solo hace falta para ejecutar las pruebas.
- **Internet**, solo para descargar el paquete con el comando de una línea y, si el operador lo pide, para buscar actualizaciones.
- **Administrador**, recomendado para que Prefetch, BAM, el USN Journal y el registro de Seguridad entren en el análisis (ver [Ejecutar como administrador](#ejecutar-como-administrador)). Si no se abre así, Amon SS ofrece reabrirse como administrador al empezar.
- **Minecraft abierto**, recomendado para que el escáner de memoria pueda revisar el juego en ejecución.
- **Terminal.** Windows Terminal (o VS Code) muestra los glifos completos; la consola clásica (conhost) usa automáticamente el juego de glifos `Safe`.

## Dónde se instala y qué escribe

| Ruta | Contenido |
| --- | --- |
| `%LOCALAPPDATA%\AmonSS\versions\<versión>\` | Copia de la versión verificada (vías A y actualizaciones) |
| `%LOCALAPPDATA%\AmonSS\versions\<versión>.zip` | ZIP descargado por el comando de una línea |
| `%LOCALAPPDATA%\AmonSS\settings.json` | Ajustes que cambies en Ajustes (solo se crea al guardar algo) |
| `%LOCALAPPDATA%\AmonSS\reports\` | Reportes exportados (carpeta configurable) |

Amon SS no escribe en el registro, no crea servicios ni tareas programadas, no modifica el `PATH` y no cambia ninguna política de ejecución.

## A. Comando de una línea (CMD)

Cada release publica el comando definitivo en `INSTALL-CMD.txt` y en sus notas, con la versión, el SHA-256 y el propietario del repositorio ya rellenados por `tools\Build-Release.ps1`. Esta es la plantilla:

```bat
powershell -NoProfile -ExecutionPolicy RemoteSigned -Command "$v='VERSION';$h='HASH';$u='https://github.com/OWNER/Amon-SS/releases/download/v'+$v+'/Amon-SS-'+$v+'.zip';$d=Join-Path $env:LOCALAPPDATA ('AmonSS\versions\'+$v);$z=$d+'.zip';[Net.ServicePointManager]::SecurityProtocol='Tls12';New-Item -ItemType Directory -Force -Path (Split-Path $z) | Out-Null;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $z;if((Get-FileHash -LiteralPath $z -Algorithm SHA256).Hash -ne $h){Remove-Item -LiteralPath $z;throw 'SHA-256 no coincide: descarga rechazada'};Expand-Archive -LiteralPath $z -DestinationPath $d -Force;Get-ChildItem -LiteralPath $d -Recurse -File | Unblock-File;& (Join-Path $d 'Start-AmonSS.ps1')"
```

Uso:

1. Abre **CMD** (Símbolo del sistema). Para un análisis completo, ábrelo con "Ejecutar como administrador" usando la misma cuenta de Windows del jugador, y deja Minecraft abierto.
2. Pega el comando de la release y pulsa Enter.
3. Amon SS se abre y trabaja solo: si no es administrador, ofrece reabrirse como tal (`A`) o seguir (Enter o 10 s); después escanea, muestra el veredicto, exporta el reporte y termina en un menú de una tecla (ver [COMMANDS.md](COMMANDS.md#revisión-automática-modo-interactivo)).

> Pégalo en CMD, no en una consola de PowerShell. Si lo pegas en PowerShell, esta expande `$v`, `$h`, `$u`... dentro de las comillas dobles antes de pasar el texto al nuevo proceso y el comando se rompe. En Windows Terminal, abre una pestaña de "Símbolo del sistema".

### Qué hace cada paso

| Fragmento | Función |
| --- | --- |
| `powershell -NoProfile` | Inicia Windows PowerShell sin cargar los perfiles del usuario, para que ningún script de perfil altere la ejecución. |
| `-ExecutionPolicy RemoteSigned` | Fija la política solo para este proceso (ver abajo). |
| `$v='VERSION';$h='HASH'` | Versión fijada y SHA-256 esperado del ZIP. Nunca se descarga "la última" versión. |
| `$u=...` | URL del recurso `Amon-SS-<versión>.zip` de la release con etiqueta `v<versión>`. |
| `$d=...;$z=$d+'.zip'` | Carpeta de destino `%LOCALAPPDATA%\AmonSS\versions\<versión>` y ruta del ZIP junto a ella. |
| `[Net.ServicePointManager]::SecurityProtocol='Tls12'` | Obliga a usar TLS 1.2 en este proceso (Windows PowerShell 5.1 no siempre lo negocia por defecto). |
| `New-Item -ItemType Directory -Force ...` | Crea `%LOCALAPPDATA%\AmonSS\versions` si no existe. |
| `Invoke-WebRequest -UseBasicParsing ...` | Descarga el ZIP. |
| `if((Get-FileHash ...).Hash -ne $h){Remove-Item ...;throw ...}` | Calcula el SHA-256 del ZIP. Si no coincide, lo borra y se detiene **antes de extraer nada**. La comparación no distingue mayúsculas. |
| `Expand-Archive ... -Force` | Extrae el paquete verificado (si repites el comando con la misma versión, se sobrescriben sus archivos). |
| `Get-ChildItem ... \| Unblock-File` | Quita la marca de internet (`Zone.Identifier`), si la hay, solo a los archivos de ese paquete. |
| `& (Join-Path $d 'Start-AmonSS.ps1')` | Abre Amon SS en modo interactivo. |

### Por qué `-ExecutionPolicy RemoteSigned` y solo en el ámbito del proceso

- El parámetro `-ExecutionPolicy` de `powershell.exe` se aplica al ámbito **Process**: equivale a `Set-ExecutionPolicy -Scope Process` y desaparece al cerrarse ese proceso. **No escribe en el registro ni cambia las políticas `LocalMachine` o `CurrentUser`.**
- `RemoteSigned` es la política mínima que permite ejecutar los scripts locales del paquete y sigue rechazando los scripts sin firmar que conservan la marca de internet. A diferencia de `Bypass`, no desactiva las comprobaciones para todo el proceso.
- La cadena de confianza es explícita: versión fijada, SHA-256 fijado, ZIP verificado y solo entonces desbloqueo y ejecución.

### Si una directiva de grupo impone la política

Las políticas definidas por directiva de grupo (ámbitos `MachinePolicy` y `UserPolicy`) tienen prioridad sobre `-ExecutionPolicy`. PowerShell las respeta y el parámetro del comando no tiene efecto. Compruébalo con:

```powershell
Get-ExecutionPolicy -List
```

- Si la directiva impone `AllSigned`, usa una release firmada ([vía C](#c-scripts-firmados-entornos-allsigned)).
- Si impone `Restricted` u otra política que impida los scripts, pide al administrador del equipo una ejecución autorizada. No intentes saltarte la directiva.

### Mientras el repositorio sea privado

GitHub no sirve de forma anónima los recursos de las releases de un repositorio privado, así que `Invoke-WebRequest` falla (normalmente con un error 404) y no se extrae nada. Hasta que el repositorio sea público:

- alguien con acceso descarga el ZIP desde la web de GitHub o con GitHub CLI, por ejemplo `gh release download v<versión> --repo OWNER/Amon-SS --pattern "Amon-SS-*.zip"`, y sigue la [vía B](#b-instalación-manual-verificada);
- la opción "Buscar actualizaciones" de Ajustes tampoco funciona, porque consulta la API pública de GitHub sin autenticarse.

### Problemas frecuentes

| Mensaje o síntoma | Causa probable | Qué hacer |
| --- | --- | --- |
| `SHA-256 no coincide: descarga rechazada` | ZIP corrupto, sustituido o comando de otra versión | No ejecutes nada. Comprueba que el comando sale de la release oficial y vuelve a intentarlo. Si se repite, avisa a los mantenedores. |
| Error 404 al descargar | Repositorio privado, `OWNER` incorrecto o versión inexistente | Revisa la URL o usa la vía B. |
| Error de canal seguro (TLS) | Proxy o inspección TLS de la red | Descarga el ZIP con el navegador y usa la vía B. |
| "La ejecución de scripts está deshabilitada" | Política impuesta por directiva de grupo | Ver la sección anterior. |
| Error al compilar el código nativo | Entornos con PowerShell en modo de lenguaje restringido (Constrained Language Mode), donde `Add-Type` no está permitido | No se ha probado en esos entornos; la herramienta no funcionará sin `Add-Type`. |
| `Integridad del paquete comprometida: <ruta> no coincide con Integrity.psd1.` | Un `.cs`, una firma (`signatures\*.json`) o `config\settings.json` cambió después de publicarse | El paquete está alterado: bórralo y vuelve a instalar una versión verificada. |
| `Integridad del paquete comprometida: <ruta> no figura en Integrity.psd1.` o `... falta <ruta>.` | Se añadió o se borró un archivo de `signatures\` | Igual que el anterior. `-VerifyPackage` muestra todos los archivos con problemas. |
| `Paquete incompleto: falta Integrity.psd1. ...` | La carpeta de la release no tiene su manifiesto | Bórrala y vuelve a instalar una versión verificada. |

## B. Instalación manual verificada

1. En la página de la release, descarga `Amon-SS-<versión>.zip` y `SHA256SUMS.txt`. El mismo SHA-256 aparece en las notas de la versión.
2. Calcula el hash del ZIP:

   ```bat
   certutil -hashfile Amon-SS-1.1.0.zip SHA256
   ```

   o en PowerShell:

   ```powershell
   Get-FileHash .\Amon-SS-1.1.0.zip -Algorithm SHA256
   ```

3. Compáralo con el valor publicado (las mayúsculas no importan). Si no coincide, borra el ZIP y no continúes.
4. Extrae el ZIP en una carpeta propia, por ejemplo `%LOCALAPPDATA%\AmonSS\versions\1.1.0`:

   ```powershell
   Expand-Archive -LiteralPath .\Amon-SS-1.1.0.zip -DestinationPath "$env:LOCALAPPDATA\AmonSS\versions\1.1.0"
   ```

5. Quita la marca de internet de los archivos extraídos:

   ```powershell
   Get-ChildItem -LiteralPath "$env:LOCALAPPDATA\AmonSS\versions\1.1.0" -Recurse -File | Unblock-File
   ```

6. Ejecuta:

   ```bat
   powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\1.1.0\Start-AmonSS.ps1"
   ```

7. Opcional: comprueba la instalación completa frente a su manifiesto (no debe salir ningún archivo con problemas):

   ```bat
   powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%LOCALAPPDATA%\AmonSS\versions\1.1.0\Start-AmonSS.ps1" -VerifyPackage
   ```

El paquete de release contiene `Start-AmonSS.ps1`, `Integrity.psd1`, `config\`, `modules\`, `signatures\`, `docs\`, `README.md`, `LICENSE`, `CHANGELOG.md` y `SECURITY.md`. No incluye `tests\` ni `tools\`. Las entradas del ZIP usan `/` como separador de carpetas.

### Integridad del paquete (`Integrity.psd1`)

`Integrity.psd1` fija el SHA-256 de cada archivo del paquete. El `Core.psm1` de la release lleva la marca `$script:AmonReleaseBuild = $true`, que hace obligatorio el manifiesto:

- **Al arrancar**, si falta `Integrity.psd1`, Amon SS termina con "Paquete incompleto: falta Integrity.psd1. Borra esta copia y vuelve a instalar una versión verificada." (código `1`).
- **Al arrancar** también se compara todo el paquete con el manifiesto, antes de analizar nada. Si algún archivo está alterado o falta, o si hay un archivo añadido dentro de `modules\`, `config\` o `signatures\`, Amon SS termina con "Integridad del paquete comprometida: <archivos> ..." (código `1`) y no ejecuta ningún módulo. Un archivo añadido fuera de esas carpetas no se carga y no detiene el arranque (sí aparece con `-VerifyPackage`).
- **Durante la ejecución**, además, los archivos que cambian el comportamiento sin ser scripts se leen una sola vez y se verifican esos mismos bytes, los que después se usan: los `.cs` antes de compilarlos, cada `signatures\*.json` y `config\settings.json`. Así un cambio hecho después del arranque tampoco se usa. Una firma añadida ("... no figura en Integrity.psd1.") o borrada ("... falta <ruta>.") también se rechaza.
- **Con `-VerifyPackage`** se comparan todos los archivos, incluidos los scripts, `config\themes.json` y la documentación. Solo se listan los problemas, con uno de estos estados: `ALTERADO` (el hash no coincide), `AUSENTE` (falta un archivo del manifiesto) o `NO INCLUIDO` (archivo que no figura en el manifiesto). La última línea resume cuántos archivos se comprobaron y cuántos tienen problemas. Termina con código `0` si todo está íntegro y `1` si hay algún problema (o si la copia no tiene `Integrity.psd1`).

En una copia de desarrollo del repositorio no existe `Integrity.psd1` y no se comprueba nada. Los ajustes del usuario (`%LOCALAPPDATA%\AmonSS\settings.json`) y los reportes están fuera del paquete y no forman parte del manifiesto.

## C. Scripts firmados (entornos AllSigned)

Con la política `AllSigned`, PowerShell solo ejecuta scripts y módulos firmados por un editor de confianza. Amon SS incluye `tools\Sign-Release.ps1`, que firma con Authenticode todos los `.ps1`, `.psm1` y `.psd1` de una carpeta de release, o un único archivo, usando un certificado de firma de código de `Cert:\CurrentUser\My` identificado por su huella digital (hash SHA-256 y servidor de sellado de tiempo opcional).

### Construir una release firmada

La forma recomendada es firmar durante la construcción, para que el ZIP y su SHA-256 ya incluyan las firmas:

```powershell
.\tools\Build-Release.ps1 -Owner <usuario-de-GitHub> -SignThumbprint <huella> -TimestampServer http://timestamp.digicert.com
```

`Build-Release.ps1`, en este orden:

1. Comprueba la codificación de los scripts y la validez de las firmas JSON, y ejecuta las pruebas unitarias (salvo `-SkipTests`).
2. Copia los archivos distribuibles a `release\Amon-SS-<versión>\` y marca el `Core.psm1` de esa copia como release (`$script:AmonReleaseBuild = $true`), lo que hace obligatorio `Integrity.psd1`.
3. Si se indica `-SignThumbprint`, firma los scripts de la copia con `Sign-Release.ps1`.
4. Genera `Integrity.psd1` en la raíz de la copia con el SHA-256 de todos los archivos (`New-AmonIntegrityManifest`, de `Core.psm1`). Como se genera después de firmar, fija los bytes ya firmados.
5. Si se indica `-SignThumbprint`, firma también `Integrity.psd1`.
6. Crea el ZIP (con `/` como separador de carpetas), `SHA256SUMS.txt`, `INSTALL-CMD.txt` y `RELEASE-NOTES.md`.

También puedes firmar una carpeta o un archivo por separado:

```powershell
.\tools\Sign-Release.ps1 -Path .\release\Amon-SS-1.1.0 -Thumbprint <huella> -TimestampServer http://timestamp.digicert.com
```

Pero firmar una copia ya construida cambia los bytes de los scripts: `Integrity.psd1` deja de coincidir con ellos (`-VerifyPackage` los marcará `ALTERADO`), y el ZIP y su SHA-256 ya no corresponden a la copia firmada. Lo más sencillo es volver a construir la release con `-SignThumbprint` y publicar el nuevo hash.

Notas sobre el certificado:

- Tiene que estar en `Cert:\CurrentUser\My`, con clave privada y uso de firma de código (el script lo busca con `-CodeSigningCert` y falla si no lo encuentra).
- El sellado de tiempo (`-TimestampServer`) es opcional, pero mantiene válidas las firmas cuando el certificado caduca.
- `Sign-Release.ps1` falla si alguna firma no queda en estado `Valid`.

### Qué queda protegido

- Firmados con Authenticode: todos los `.ps1` y `.psm1`, e `Integrity.psd1`, que a su vez fija el SHA-256 de todos los archivos del paquete.
- **Sin firma Authenticode propia:** los `.cs`, los JSON de `config\` y `signatures\` y la documentación. Los protege `Integrity.psd1`: los `.cs`, las firmas y `config\settings.json` se comprueban en cada ejecución, y el resto con `-VerifyPackage`.
- Amon SS no comprueba por sí mismo la firma de `Integrity.psd1` al leerlo: verifícala con el comando del paso 2 de la sección siguiente, que incluye los `.psd1`.
- Los cambios de ajustes se guardan en `%LOCALAPPDATA%\AmonSS\settings.json`, fuera del paquete, así que no invalidan ninguna firma ni el manifiesto. Editar cualquier archivo del paquete sí: invalida su firma (si la tiene) y deja de coincidir con `Integrity.psd1`.

### Ejecutar en el equipo revisado

1. La cadena del certificado debe ser de confianza en ese equipo. Si el editor no está entre los editores de confianza, PowerShell pregunta en la primera ejecución si quieres confiar en él.
2. Verifica las firmas (no debe salir ninguna línea):

   ```powershell
   Get-ChildItem -Recurse -Include *.ps1, *.psm1, *.psd1 | Get-AuthenticodeSignature | Where-Object Status -ne 'Valid'
   ```

3. Comprueba el resto del paquete frente a `Integrity.psd1`:

   ```bat
   powershell -NoProfile -File .\Start-AmonSS.ps1 -VerifyPackage
   ```

4. Ejecuta sin `-ExecutionPolicy` (la política ya es `AllSigned`), desde una consola ya elevada y con `-NoElevate`:

   ```bat
   powershell -NoProfile -File .\Start-AmonSS.ps1 -NoElevate
   ```

   Si Amon SS se reabre como administrador con `A`, la copia nueva se lanza con `-ExecutionPolicy RemoteSigned` de proceso: si `AllSigned` viene de una directiva de grupo, sigue mandando; si solo está en `LocalMachine` o `CurrentUser`, ese proceso usa `RemoteSigned`. Abrir tú la consola elevada y pasar `-NoElevate` mantiene `AllSigned` en todo momento.

## Ejecutar como administrador

Sin elevación, Amon SS funciona, pero estos módulos informan `SIN ACCESO` o resultados parciales:

| Fuente | Sin administrador |
| --- | --- |
| Prefetch (`C:\Windows\Prefetch`) | `SIN ACCESO`: Windows solo permite leerlo a administradores. |
| BAM | `SIN ACCESO`: Windows solo permite leer su clave a administradores. |
| USN Journal | `SIN ACCESO`: leer el journal requiere administrador. |
| Registro de Seguridad (4688, 1102) | No se lee (salvo que la cuenta pertenezca a "Lectores del registro de eventos"); el módulo de eventos queda `PARCIAL`. |
| Política de auditoría | Puede no poder comprobarse si 4688 está habilitado. |
| DLL cargadas en Java y memoria de Java | Si el juego se ejecuta como administrador, Amon SS también debe hacerlo para listar sus módulos y leer su memoria. |

PCA, ShimCache, el módulo de evasión y los eventos 7045, 501, 5001/5007 y 1000 no necesitan administrador.

Abre CMD o Windows Terminal con "Ejecutar como administrador" **con la cuenta del jugador**. Si no lo haces, la revisión automática lo ofrece al empezar: `A` reabre Amon SS como administrador en una ventana nueva, con el aviso UAC de Windows (Enter o 10 s sin pulsar nada siguen sin administrador; `-NoElevate` desactiva la oferta). Amon SS analiza el perfil del usuario que lo ejecuta: `%APPDATA%` y `%USERPROFILE%` para encontrar instancias, `HKCU` para UserAssist, Store y MUICache, `Recent`, la papelera del SID actual y el `explorer.exe` de ese usuario. Si elevas con las credenciales de otra cuenta de administrador, se analizan los datos de esa otra cuenta, no los del jugador. Lo mismo pasa al pulsar `A` si la cuenta del jugador es estándar: el aviso UAC pide la contraseña de otra cuenta y la ventana nueva se ejecuta con ella.

En el repositorio (no en el paquete de release), `tools\Invoke-AmonAdminCheck.ps1` sirve para comprobar los módulos que necesitan administrador con los datos reales del equipo, sin hacer una revisión. Requiere una consola elevada (si no, termina con código `1`), ejecuta Minecraft para conocer las instancias y resume Prefetch (formatos, archivos interpretados y fallidos, comprimidos MAM), BAM (estado, valores, mostrados, para revisar y no relacionados, con las últimas ejecuciones), el USN Journal (registros leídos y relevantes, cobertura, operaciones, rutas reconstruidas) y los eventos (acceso al registro de Seguridad, auditoría 4688, artefactos por tipo). Es de solo lectura y no exporta nada. `-TimeoutSeconds` (120 por defecto) limita cada módulo.

## Actualizar

Las actualizaciones nunca son automáticas.

- **Desde Ajustes (`M` > `S` > `U` en el menú final).** Si no hay repositorio configurado (o el guardado no tiene un formato válido), lo pide (`propietario/Amon-SS`), comprueba que tenga la forma `propietario/repositorio` y solo entonces lo guarda en `updates.repository`. Consulta la última release en la API pública de GitHub; si su etiqueta no es un número de versión (por ejemplo `nightly`), lo indica y no ofrece instalarla. Si es más reciente que la instalada, pide el SHA-256 de confianza del ZIP (copiado de las notas de la versión o de este repositorio). Descarga `Amon-SS-<versión>.zip`, lo rechaza y lo borra si el hash no coincide, y lo extrae en `%LOCALAPPDATA%\AmonSS\versions\<versión>`, sin tocar la instalación actual y sin sobrescribir una carpeta que ya exista. Al terminar muestra el comando para abrir la nueva versión.
- **Con el comando de una línea** de la nueva release.

## Desinstalar

1. Cierra Amon SS.
2. Borra `%LOCALAPPDATA%\AmonSS\versions\` (o solo la versión que quieras quitar y su `.zip`).
3. Decide qué hacer con `%LOCALAPPDATA%\AmonSS\settings.json` y `%LOCALAPPDATA%\AmonSS\reports\`. Los reportes son evidencias: consérvalos o elimínalos según la política de tu equipo de revisión.

No quedan claves de registro, servicios ni tareas programadas que limpiar.
