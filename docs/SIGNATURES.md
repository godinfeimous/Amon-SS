# Motor de firmas

El motor de firmas (`modules\Signatures.psm1`) carga todas las definiciones de `signatures\*.json` (salvo `schema.json`), las valida y construye índices de búsqueda. En una release, cada archivo se verifica antes frente a `Integrity.psd1`: una firma alterada, añadida o borrada impide cargar el conjunto (ver [INSTALL.md](INSTALL.md#integridad-del-paquete-integritypsd1)). Los índices son un autómata Aho-Corasick en C# para cadenas y firmas binarias, y tablas hash para paquetes, entradas, clases, ids de mod, SHA-256 y atributos del MANIFEST. Nunca ejecuta código de los archivos analizados: los JAR se leen como datos.

## Regla principal: no inventar firmas

- Cada indicador tiene que citar su **fuente** (`source`): la URL exacta del código o la documentación oficial, o el texto "Proporcionada por el usuario; pendiente de validar con muestras autorizadas".
- Si no hay ningún indicador verificable para un cliente, se publica su definición **sin indicadores** (`"indicators": []`). El cliente aparece entonces como `INCONCLUSIVE` ("no se puede confirmar ni descartar con archivos") en lugar de `NOT DETECTED`. Así están hoy Vape, Raven, Inertia, Sigma, Rise y Novoline.
- No se copian firmas de foros, listas de terceros ni otras herramientas de SS que no se puedan verificar.
- Las cadenas que aporta un usuario se añaden como `provenance: "user-provided"` y `validated: false` hasta comprobarlas con muestras autorizadas (ver [Cadenas aportadas por el usuario](#cadenas-aportadas-por-el-usuario)).

## Formato de archivo

Un archivo puede contener una definición (un objeto) o varias (`{"clients": [ ... ]}`, como `other-clients.json`). `schema.json` es un JSON Schema draft-07 de referencia para editores; la validación que aplica el programa es `Test-AmonSignatureSet` (ver [Validar](#validar)).

### Campos del cliente

| Campo | Obligatorio | Descripción |
| --- | --- | --- |
| `schemaVersion` | Sí | Siempre `1`. |
| `id` | Sí | Único entre todos los archivos. Minúsculas, números y guiones (`^[a-z0-9][a-z0-9\-]*$`). Es la clave de correlación. |
| `name` | Sí | Nombre que se muestra. |
| `category` | Sí | `cheat-client`, `dual-use` (herramientas que muchos servidores permiten, como Baritone) o `framework` (código compartido: la atribución al cliente es inferida). Si falta, el cargador asume `cheat-client` para seguir escaneando, pero la validación lo marca como error. |
| `indicators` | Sí | Lista de indicadores (puede estar vacía). Si falta, el cargador usa una lista vacía y la validación lo marca como error. |
| `description`, `notes` | No | Contexto: qué se investigó, qué ramas se verificaron y en qué fecha. |
| `openSource` | No | `true` si el código es público. |
| `loaders` | No | Loaders o métodos de carga conocidos. |
| `references` | No | Páginas de referencia (no se usan para detectar). |
| `keywords` | No | Palabras distintivas para filtrar artefactos de otros módulos (ver [Palabras clave](#palabras-clave-frente-a-firmas)). |
| `falsePositives` | No | Falsos positivos conocidos. Se copian en cada hallazgo del cliente. |

### Campos del indicador

| Campo | Obligatorio | Descripción |
| --- | --- | --- |
| `id` | Sí | Único dentro del cliente. |
| `type` | Sí | Uno de los [tipos de indicador](#tipos-de-indicador). |
| `value` | Sí | Valor no vacío. |
| `strength` | Sí | `strong`, `medium` o `weak`. Si falta, el cargador asume `weak` y la validación lo marca como error. |
| `provenance` | Sí | `primary-source`, `secondary`, `user-provided` o `sample-verified`. |
| `validated` | Sí | Booleano JSON (`true`/`false`, sin comillas). |
| `source` | Sí | Fuente concreta. |
| `note` | No | Aclaraciones (qué representa el valor, por qué tiene esa fuerza). |
| `group` | No | Variante del cliente (por ejemplo `legacy` o `current`). Aparece en la justificación como "Variante". |
| `match` | No | `literal` (por defecto) o `regex`. Solo tiene efecto en `log`; `versionId` siempre es una expresión regular. |
| `encodings` | No | Para `string`: `ascii`, `utf8` y/o `utf16le`. Por defecto `["ascii"]`. |
| `scopes` | No | Para `string`: `raw` y/o `entries`. Por defecto `["raw", "entries"]`. |
| `relativeTo` | No | Para `config` y `path`: `gameDir` (por defecto) o `userHome`. |

## Tipos de indicador

| Tipo | Dónde se busca | Cómo coincide |
| --- | --- | --- |
| `package` | Nombres de entrada de cada JAR/ZIP (y anidados) | Prefijo exacto de carpeta, distingue mayúsculas, terminado en `/` (`net/wurstclient/`). Se comprueban los prefijos de hasta 5 niveles. |
| `entry` | Nombres de entrada | Ruta completa o solo nombre de archivo, sin distinguir mayúsculas (`wurst.mixins.json`). |
| `entrypoint` | Metadatos y nombres de entrada | Clase con puntos (`net.wurstclient.WurstInitializer`): coincide si `fabric.mod.json` la declara como entrypoint o si existe la entrada `net/wurstclient/WurstInitializer.class`. |
| `manifest` | `META-INF/MANIFEST.MF` | `Clave: Valor`; compara el valor completo del atributo, sin espacios sobrantes y sin distinguir mayúsculas. |
| `modid` | Metadatos del JAR y logs | Sin distinguir mayúsculas. En el JAR: ids de `fabric.mod.json`, `quilt.mod.json`, `mods.toml`/`neoforge.mods.toml` (solo tablas `[[mods]]`), `mcmod.info` y el nombre de `litemod.json`. En los logs: lista de mods cargados, mods anidados o ids de recursos cargados. |
| `config` / `path` | Sistema de archivos | Ruta relativa a `gameDir` (cada instancia) o `userHome` (`%USERPROFILE%`). Existe o no existe. Si un segmento contiene `<...>`, la ruta se corta antes de él. |
| `log` | Texto de `latest.log` y logs rotados del periodo | Literal (distingue mayúsculas) o expresión regular si `match` es `regex`. |
| `string` | Bytes de archivos | Secuencia literal de bytes en la codificación indicada, según los ámbitos (ver abajo). |
| `hex` | Bytes de archivos | Bytes en hexadecimal (se ignoran los espacios). Siempre se busca en ambos ámbitos. |
| `sha256` | Archivos escaneados | SHA-256 exacto del archivo (se hashean archivos de hasta 1 GB). |
| `versionId` | Ids de los perfiles de `versions\` | Expresión regular sobre el id (`^.+-Impact_.+$`). |
| `jvmArg` | Argumentos JVM | Subcadena sin distinguir mayúsculas en `arguments.jvm` de los perfiles de versión y en la línea de comandos de los procesos Java en ejecución. |

Qué archivos se escanean (Cheat Signature Scanner): los JAR de las carpetas `mods` de cada instancia, los JAR de `versions\` cuyo SHA-1 no se pudo verificar (`scan.scanVersionJarsWhenHashUnverified`), las rutas de `scan.extraScanPaths` y las rutas adicionales indicadas en la opción 03 durante la sesión (se guardan como dato en `ExtraScanPaths` y entran en todos los escaneos posteriores de la sesión). En el escaneo completo, una segunda pasada (`SignaturesEvidence`) revisa los `.jar`, `.exe`, `.dll` y `.zip` que todavía existen y que citan otros módulos: JAR referenciados en Prefetch, accesos de Recent, entradas de UserAssist, agentes Java y DLL de procesos, contenido `$R` de la papelera, JAR de versión modificados, coincidencias de Temp y ejecutables de claves Run. Solo se aceptan rutas absolutas de unidades locales: las rutas de red que citen los artefactos no se escanean.

Cada escaneo completo de firmas empieza de cero (también descarta el resultado de una pasada de evidencias anterior), así que repetir un escaneo o retomar uno interrumpido vuelve a revisar todos los archivos. La pasada de evidencias solo omite los archivos que ya se escanearon **por completo** en la sesión; un escaneo cortado por límites, tiempo o cancelación no cuenta como completo.

## Ámbitos y codificaciones

- `raw`: bytes del archivo tal como está en el disco. En un JAR esto incluye los nombres de entrada y el contenido de las entradas almacenadas sin compresión, pero no el de las comprimidas. También se aplica a los bytes de cada JAR anidado. Límites: `maxRawScanMB` (y `maxJarSizeMB`) para JAR/ZIP, `maxExecutableScanMB` para el resto.
- `entries`: contenido **descomprimido** de cada entrada de un JAR/ZIP, incluidos los anidados hasta `maxNestedJarDepth`. Se saltan los recursos multimedia (`.png`, `.ogg`, `.jpg`, `.wav`, `.ttf`, `.nbt`...) y las entradas mayores que `maxEntrySizeMB`. Límites totales: `maxDecompressedPerJarMB` y `maxEntriesPerJar`, que también cuentan los JAR anidados; entre un anidado y el siguiente se comprueban además la cancelación y el tiempo del módulo.
- Un metadato dañado (por ejemplo, deflate inválido en `fabric.mod.json`) se anota en el error del JAR y se trata como vacío: no impide escanear el resto del archivo.
- Una cadena que solo existe dentro de un `.class` comprimido únicamente se encuentra con el ámbito `entries`. Una cadena que incluye bytes de la estructura ZIP (como el `PK` final de `prestige.entry-raw`) solo se encuentra con `raw`.
- `encodings`: `ascii` y `utf8` buscan los bytes UTF-8 del valor (para texto ASCII son idénticos); `utf16le` busca la versión UTF-16LE, la habitual en cadenas de ejecutables de Windows. Cada codificación es un patrón distinto del autómata, y la evidencia indica cuál coincidió.
- Se registra solo la **primera** aparición de cada indicador por archivo, con su desplazamiento.

## Fuerza, procedencia y validación

| `provenance` | Significado | `validated` |
| --- | --- | --- |
| `primary-source` | Código fuente o documentación oficial del propio cliente, citado con URL | `true` si se comprobó en esa fuente |
| `secondary` | Copia no oficial, fork, framework relacionado o texto de terceros | `false` |
| `user-provided` | Aportado por un usuario, sin muestras verificadas | **Siempre `false`** (`Test-AmonSignatureSet` rechaza `true`) |
| `sample-verified` | Comprobado con muestras autorizadas del cliente | `true` |

La fuerza (`strength`) indica lo específico que es el valor: `strong` para algo que solo tiene ese cliente (un paquete propio, un archivo de mixins con su nombre), `medium` para algo distintivo pero que podría reutilizarse (una carpeta de configuración, una cadena de 13 o más caracteres), y `weak` para algo genérico o corto (5 a 7 caracteres, un nombre común).

## Cómo se calcula la confianza

### Archivos (`Get-AmonSignatureDetections`)

Las coincidencias de un archivo se agrupan por cliente. Después de [eliminar subcadenas](#eliminación-de-subcadenas):

| Condición | Confianza | Estado |
| --- | --- | --- |
| Al menos 1 indicador **validado** `strong`, o 2 o más validados `medium` | `High` | `DETECTED` |
| 1 validado `medium`, o 2 o más validados `weak`, o 2 o más **no validados** `strong`/`medium` | `Medium` | `DETECTED` |
| Cualquier otro caso (por ejemplo, 1 solo indicador no validado, o indicadores no validados `weak`) | `Low` | `INCONCLUSIVE` |

Consecuencias:

- Las firmas no validadas **nunca** dan confianza alta y necesitan al menos dos coincidencias independientes de fuerza media o fuerte. Los indicadores no validados `weak` no suman.
- Severidad: `Low` para `dual-use` o cuando el estado es `INCONCLUSIVE`; `High` si la confianza es alta y la categoría es `cheat-client`; `Medium` en el resto.
- La justificación indica cuántos indicadores son validados y cuántos no, los tres principales y, si ninguno está validado, avisa de que la confianza se limita a media y de que una coincidencia no demuestra ejecución. En `framework` añade que la atribución es inferida, y en `dual-use`, que muchos servidores la permiten.
- Si un archivo no tiene ninguna coincidencia pero su nombre contiene una palabra clave de un cliente, se crea un hallazgo `KeywordName` (`INCONCLUSIVE`, confianza baja).

### Logs, configuración y perfiles (`New-AmonClientFinding`)

Para los hallazgos `ClientLog`, `ClientConfig` y `ClientVersionProfile` **solo cuentan los indicadores validados**:

| Condición | Confianza |
| --- | --- |
| 1 validado `strong`, o 2 o más validados `medium` | `High` (en `ClientConfig` se rebaja a `Medium`) |
| 1 validado `medium` | `Medium` |
| Otro caso (solo `weak` o solo no validados) | `Low` (estado `INCONCLUSIVE`) |

- Una carpeta de configuración prueba uso pasado, no que el cliente siga instalado; por eso `ClientConfig` nunca pasa de confianza media.
- `ClientLog` se marca como evidencia de carga o ejecución, y la correlación lo tiene en cuenta.
- Cada indicador `config`/`path` que existe genera su propio hallazgo con las fechas de creación y modificación.

### Procesos

Si la línea de comandos de un Java en ejecución contiene un `jvmArg`, se crea un hallazgo `ClientProcess` (severidad `Medium`, evidencia de ejecución): `DETECTED` con confianza `Medium` si el indicador está validado, o `INCONCLUSIVE` con confianza `Low` si no lo está. Hoy el único `jvmArg` incluido es el de RusherHack, que está validado.

### Indicadores para los demás módulos

Solo las detecciones `DETECTED` de un archivo registran su nombre y su SHA-256 como indicadores de la revisión (`Add-AmonIndicator`), que Prefetch, Recent, UserAssist, eventos, Temp y el USN Journal usan para decidir qué es relevante. Una detección `INCONCLUSIVE` no se registra: haría que esos módulos emitieran hallazgos por una simple coincidencia de nombre.

### Correlación

La correlación (`modules\Correlation.psm1`) parte de estos hallazgos. Un cliente pasa a `CORRELATED` cuando hay al menos un hallazgo `DETECTED` y dos tipos de fuente independientes (por ejemplo, archivo con firma y log de Minecraft). El tipo de fuente sale del módulo de origen. Los nombres genéricos (`javaw.exe`, `latest.log`, `client.jar`, JAR de versión como `1.20.1.jar`...) no relacionan nada por nombre ni por ruta: con ellos solo vale el SHA-256 (lista completa en [LIMITATIONS.md](LIMITATIONS.md#principios-generales)). La confianza de la correlación es alta solo si la del indicador ancla lo es; si se apoya en firmas no validadas o débiles, se limita a media.

## Eliminación de subcadenas

Si dentro del mismo cliente coinciden dos indicadores `string`/`hex` y el valor de uno está contenido en el del otro, solo cuenta el más largo. Así, `zprestige` no suma dos veces si también coincide `dev/zprestige/prestige/api/mixin/MixinLightmapTextureManager.classPK`, y `U2VsZiBEZXN0cnVjdA` (sin relleno) no suma con `U2VsZiBEZXN0cnVjdA==`. Una prueba Pester lo comprueba.

## Palabras clave frente a firmas

| | Palabras clave (`keywords`) | Firmas (`indicators`) |
| --- | --- | --- |
| Qué son | Subcadenas de nombres (`wurst`, `doomsday`) | Indicadores con tipo, fuerza y fuente |
| Para qué sirven | Decidir qué artefactos de Prefetch, Recent, UserAssist, papelera, USN, eventos y procesos son relevantes para la revisión | Identificar un cliente |
| Qué producen | Como mucho, hallazgos `KeywordName` (`INCONCLUSIVE`, confianza baja) | `DETECTED` o `INCONCLUSIVE` según las reglas anteriores |
| En la correlación | Se excluyen como ancla y como fuente | Son las anclas |

Un nombre de archivo no prueba nada por sí solo: un `wurst.jar` sin firmas queda como `KeywordName`, y un cliente renombrado con nombre aleatorio sigue detectándose por su contenido. Elige palabras clave distintivas (`novaclient` en lugar de `nova`) para no llenar la revisión de ruido.

## Añadir un cliente nuevo

1. **Investiga y anota fuentes.** Busca el repositorio o la documentación oficial. Para cada indicador, guarda la URL exacta, preferiblemente a un commit o una rama concretos (`raw.githubusercontent.com/<org>/<repo>/<rama>/...`). Si solo encuentras copias no oficiales, usa `secondary`. Si no encuentras nada verificable, publica la definición sin indicadores.
2. **Elige indicadores robustos.** De mejor a peor: paquete propio (`package`), `modid`, entrypoint, archivos de mixins o access wideners (`entry`), atributos del MANIFEST, carpetas de configuración, mensajes de log y, por último, cadenas y bytes. Un SHA-256 solo identifica una compilación concreta.
3. **Crea `signatures\<id>.json`** en UTF-8 en el repositorio, no en una copia de release: en una release, un archivo de firmas añadido o modificado no coincide con `Integrity.psd1` y el conjunto de firmas no se carga. Para distribuirlo, construye una release nueva. Usa la plantilla siguiente.
4. **Escapa las barras invertidas.** En JSON, `\\` es una barra invertida literal y `\"` unas comillas. `"Z;\\<Rr"` representa `Z;\<Rr`. Un `\t` sin escapar se convertiría en un tabulador y la firma dejaría de coincidir. En las expresiones regulares de `log` y `versionId`, `\\d` es el `\d` de la regex.
5. **Valida** (siguiente sección) y añade pruebas Pester si el cliente tiene particularidades (cadenas con símbolos, variantes).
6. **Revisa los falsos positivos.** Escanea mods legítimos populares y anota en `falsePositives` lo que pueda confundirse.

Plantilla completa. **Todos los valores son ficticios** y no corresponden a ningún cliente real. Este JSON pasa `Test-AmonSignatureSet` sin errores:

```json
{
  "schemaVersion": 1,
  "id": "cliente-ejemplo",
  "name": "Cliente Ejemplo",
  "category": "cheat-client",
  "description": "PLANTILLA FICTICIA: todos los valores son inventados. Sustitúyelos por datos reales con su fuente.",
  "openSource": true,
  "loaders": ["fabric"],
  "references": ["https://github.com/organizacion-ejemplo/cliente-ejemplo"],
  "keywords": ["clienteejemplo"],
  "falsePositives": [
    "Otros mods del mismo autor comparten el prefijo com/ejemplo/: basarse en com/ejemplo/cliente/ o en el id."
  ],
  "notes": "Rama verificada: 1.21.x en el commit indicado en cada fuente.",
  "indicators": [
    { "id": "ejemplo.package", "type": "package", "value": "com/ejemplo/cliente/", "strength": "strong", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/java/com/ejemplo/cliente/Cliente.java" },
    { "id": "ejemplo.modid", "type": "modid", "value": "cliente-ejemplo", "strength": "strong", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/resources/fabric.mod.json" },
    { "id": "ejemplo.entrypoint", "type": "entrypoint", "value": "com.ejemplo.cliente.Cliente", "strength": "strong", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/resources/fabric.mod.json" },
    { "id": "ejemplo.mixins", "type": "entry", "value": "cliente-ejemplo.mixins.json", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/resources/fabric.mod.json" },
    { "id": "ejemplo.installer", "type": "manifest", "value": "Main-Class: com.ejemplo.cliente.Instalador", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/build.gradle" },
    { "id": "ejemplo.config", "type": "config", "value": "cliente-ejemplo", "relativeTo": "gameDir", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/java/com/ejemplo/cliente/Config.java", "note": "Carpeta que crea el cliente dentro del directorio de juego." },
    { "id": "ejemplo.log.start", "type": "log", "value": "Iniciando Cliente Ejemplo v\\d+\\.\\d+", "match": "regex", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/src/main/java/com/ejemplo/cliente/Cliente.java" },
    { "id": "ejemplo.version-id", "type": "versionId", "value": "^.+-ClienteEjemplo_.+$", "match": "regex", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/instalador/<commit>/src/main/java/Instalador.java" },
    { "id": "ejemplo.jvm", "type": "jvmArg", "value": "-Dclienteejemplo.plugins=true", "strength": "medium", "provenance": "primary-source", "validated": true, "source": "https://raw.githubusercontent.com/organizacion-ejemplo/cliente-ejemplo/<commit>/README.md" },
    { "id": "ejemplo.str.1", "type": "string", "value": "Ej3mpl0\\Cadena", "strength": "medium", "provenance": "user-provided", "validated": false, "source": "Proporcionada por el usuario; pendiente de validar con muestras autorizadas", "note": "En el JSON, \\\\ representa una sola barra invertida literal.", "encodings": ["ascii", "utf16le"], "scopes": ["raw", "entries"] },
    { "id": "ejemplo.hex.1", "type": "hex", "value": "45 4A 45 4D 50 4C 4F 21", "strength": "weak", "provenance": "user-provided", "validated": false, "source": "Proporcionada por el usuario; pendiente de validar con muestras autorizadas" },
    { "id": "ejemplo.sha256", "type": "sha256", "value": "0000000000000000000000000000000000000000000000000000000000000000", "strength": "strong", "provenance": "user-provided", "validated": false, "source": "Proporcionada por el usuario; pendiente de validar con muestras autorizadas", "note": "Valor de relleno: un hash solo identifica una compilación concreta." }
  ]
}
```

## Validar

`Test-AmonSignatureSet` devuelve la lista de errores (vacía si todo es correcto). Comprueba: JSON válido; `id` de cliente con formato correcto y no duplicado; `name`; `schemaVersion` igual a `1`; que el cliente declare `category` e `indicators` y cada indicador `strength` (aunque el cargador use valores por defecto para seguir escaneando); categoría válida; `id` de indicador presente y único dentro del cliente; tipo permitido; valor no vacío; fuerza y procedencia válidas; `validated` booleano; `source` presente; que ningún `user-provided` esté marcado como validado; hexadecimal con pares completos; SHA-256 de 64 caracteres hexadecimales; `relativeTo`, `scopes` y `encodings` válidos; y expresiones regulares que compilan.

```powershell
Import-Module .\modules\Core.psm1, .\modules\Jar.psm1, .\modules\Signatures.psm1 -DisableNameChecking
$set = Get-AmonSignatureSet -Path .\signatures
Test-AmonSignatureSet -Set $set     # sin salida = todo válido
```

Además:

- `tests\Signatures.Tests.ps1` comprueba que todas las definiciones son válidas, que el validador detecta los campos obligatorios ausentes aunque tengan valor por defecto, que los ids son únicos, que cada indicador tiene fuente, que ningún `user-provided` está validado, que Vape, Raven, Inertia, Sigma, Rise y Novoline no tienen indicadores y que las cadenas de Doomsday, Nova y Prestige se conservan **exactamente** (incluidas las barras invertidas y los símbolos, y los 26 indicadores `string` de Doomsday). Si cambias esas cadenas, las pruebas fallan a propósito.
- `tools\Build-Release.ps1` se niega a construir una release si `Test-AmonSignatureSet` devuelve errores.
- Para probar una firma contra un archivo concreto:

  ```powershell
  (Invoke-AmonFileSignatureScan -Path .\muestra.jar -Set $set).Detections | Format-List ClientName, Status, Confidence, Justification
  ```

## Cadenas aportadas por el usuario

1. Añádelas con `"provenance": "user-provided"`, `"validated": false` y `"source": "Proporcionada por el usuario; pendiente de validar con muestras autorizadas"`. Indica en `group` la variante si se conoce.
2. Asigna una fuerza prudente: `weak` para cadenas de 5 a 7 caracteres, que pueden aparecer por azar en archivos grandes, y `medium` para cadenas largas y distintivas.
3. Mientras sigan sin validar, el motor limita la confianza a media y exige al menos dos coincidencias independientes de fuerza media; una sola coincidencia queda como `INCONCLUSIVE`.
4. Para validarlas, consigue **muestras autorizadas** del cliente (obtenidas legalmente y con permiso para analizarlas), comprueba que cada cadena aparece en ellas y que no aparece en mods legítimos habituales, y cambia el indicador a `"provenance": "sample-verified"`, `"validated": true`, con una `source` que describa la verificación (versión de la muestra, fecha y SHA-256 de la muestra). No uses `validated: true` con `user-provided`: la validación lo rechaza.
5. No visites URL ni dominios contenidos en las cadenas aportadas (por ejemplo, URL codificadas en Base64): la política del proyecto lo prohíbe.

## Clientes incluidos

Recuento a fecha del 2026-10-21: 25 clientes y 148 indicadores (93 validados con fuente primaria, 21 secundarios y 34 aportados por el usuario).

| Archivo | Cliente | Categoría | Indicadores | Procedencia |
| --- | --- | --- | --- | --- |
| `baritone.json` | Baritone | `dual-use` | 5 | Fuente primaria, validados |
| `bleachhack.json` | BleachHack | `cheat-client` | 7 | Fuente primaria, validados |
| `kamiblue.json` | KAMI Blue | `cheat-client` | 9 | Fuente primaria, validados |
| `lambda.json` | Lambda | `cheat-client` | 11 | Fuente primaria, validados |
| `liquidbounce.json` | LiquidBounce | `cheat-client` | 15 | Fuente primaria, validados |
| `meteor.json` | Meteor Client | `cheat-client` | 15 | Fuente primaria, validados |
| `rusherhack.json` | RusherHack | `cheat-client` | 6 | Fuente primaria (API pública de plugins), validados |
| `salhack.json` | SalHack | `cheat-client` | 8 | Fuente primaria, validados |
| `thunderhack.json` | ThunderHack Recode | `cheat-client` | 7 | Fuente primaria, validados |
| `wurst.json` | Wurst Client (Wurst7) | `cheat-client` | 8 | Fuente primaria, validados |
| `impact.json` | Impact | `cheat-client` | 3 | 2 de fuente primaria (instalador oficial), validados; 1 secundario (`clientapi/`) |
| `aristois.json` | Aristois (vía EMC Framework) | `framework` | 6 | Solo secundarios: indicadores del EMC Framework; relación con Aristois inferida |
| `mathax.json` | MatHax (Legacy) | `cheat-client` | 5 | Solo secundarios (copia no oficial) |
| `coffee.json` | Coffee Client | `cheat-client` | 4 | Solo secundarios (el repositorio oficial ya no existe) |
| `phobos.json` | Phobos | `cheat-client` | 4 | Solo secundarios (fork archivado no oficial) |
| `future.json` | Future Client | `cheat-client` | 1 | Solo secundario y débil (`Future/auth_key` en el perfil del usuario) |
| `doomsday.json` | Doomsday Client | `cheat-client` | 26 | Cadenas aportadas por el usuario, **sin validar** (grupos `legacy` y `current`) |
| `nova.json` | Nova Client | `cheat-client` | 5 | Cadenas aportadas por el usuario, **sin validar** |
| `prestige.json` | Prestige Client | `cheat-client` | 3 | Cadenas aportadas por el usuario, **sin validar** |
| `other-clients.json` | Vape (v4 / Lite) | `cheat-client` | 0 | Sin indicadores verificables |
| `other-clients.json` | Raven (B+, BS, XD y forks) | `cheat-client` | 0 | Sin indicadores verificables |
| `other-clients.json` | Inertia Client | `cheat-client` | 0 | Sin indicadores verificables |
| `other-clients.json` | Sigma (Sigma 5 / Jello) | `cheat-client` | 0 | Sin indicadores verificables |
| `other-clients.json` | Rise (Rise 6) | `cheat-client` | 0 | Sin indicadores verificables |
| `other-clients.json` | Novoline | `cheat-client` | 0 | Sin indicadores verificables |

Ningún indicador tiene todavía la procedencia `sample-verified`. Las notas de cada archivo explican qué se investigó; por ejemplo, la web de Doomsday indica que su loader puede descargarse con nombre y tamaño aleatorios, y Prestige se describe como inyectable, así que puede no dejar nada en la carpeta `mods`.
