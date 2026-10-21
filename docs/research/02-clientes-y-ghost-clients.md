# Amon SS — Investigación 02: clientes de trampas, ghost clients, autoclickers, macros y bypasses

- **Fecha:** 2026-10-21. Las fuentes se consultaron ese día. Las URL de GitHub y Codeberg apuntan a un commit concreto cuando fue posible; si no, a `HEAD`/`main` con fecha de acceso 2026-10-21.
- **Alcance:** Minecraft Java, 2023-2026. Herramienta de **solo lectura** para SS consentidas.
- **Método:** solo se leyó código fuente, documentación y listas públicas de cadenas. No se descargó ni ejecutó ningún JAR, EXE ni DLL de clientes. No se decodificaron ni visitaron cadenas Base64 ni dominios sacados de las listas de firmas, salvo las webs oficiales de los propios clientes.
- **Archivo de datos:** `02-indicadores-propuestos.json` (mismo directorio). Tiene 158 indicadores: 43 de fuente primaria (42 validados) y 115 secundarios. Ninguno es `user-provided`. Además de los campos pedidos, incluye `group`, `match`, `encodings`, `scopes` y `relativeTo` donde el tipo los necesita, con el mismo significado que en `schema.json`.

## 1. Resumen

1. **Raven** e **Inertia** pasan a tener indicadores de **fuente primaria**:
   - **Raven bS:** su autor publica el código en Codeberg (`strangerrrrs/raven-bS`), ya que los repositorios de GitHub están bloqueados por DMCA.
   - **Inertia Client:** se construye sobre **ICB** (Inertia Client Base), que el propio desarrollador publica en GitHub. Su *issue tracker* oficial contiene logs reales del cliente.
2. **Vape** no tiene código público, pero su **documentación oficial** (docs.vape.gg) explica el método de carga:
   - Es un **inyector `.exe` con nombre aleatorio** distinto en cada descarga (por ejemplo `k4xw2tfl.exe`), normalmente en Descargas.
   - No hay instalación: Vape solo modifica el juego en tiempo de ejecución.
   - **Vape Lite** usa una **GUI externa** y su web lo anuncia como cliente "para evitar screenshares".

   El escaneo de archivos de Amon **no puede descartar Vape**. Solo hay indicadores secundarios: el firmante `Manthe Industries, LLC`, cadenas YARA de spokwn y hashes de cracks.
3. **Sigma 5, Rise 6 y Novoline** tienen **código filtrado o desofuscado** en GitHub. Con él se proponen paquetes y carpetas (`sigma5/`, `jello/jello.lic`, `com/alan/clients/`, `Rise/…`, `cc/novoline/`, `Novoline`), siempre como `secondary` y sin validar.
4. Clientes nuevos:
   - **Con fuente primaria:** Slinky (`%USERPROFILE%\.slinky\bin`), Breeze (`%APPDATA%\breeze\1.8.9\scripts`), FDPClient y GameSense.
   - **Solo secundaria:** Argon (se disfraza de ImmediatelyFast) y Tenacity.
5. **Clientes inyectables o externos que no dejan nada en `mods`:** Vape, Vape Lite, Slinky, Entropy, Breeze, Prestige y Doomsday.
   - Doomsday deja elegir el nombre del loader y **aleatoriza su tamaño**, según su web oficial.
   - En todos ellos la detección depende de artefactos de ejecución (Prefetch, BAM, PCA, USN) y no de firmas de archivo.
6. **Corroboraciones de firmas que hoy son `user-provided`:**
   - `prestige.entry-raw` aparece en el escáner de zeezy (y contiene `zprestige`).
   - `nova.b64.url` aparece en MeowModAnalyzer.

   Ambas pueden pasar a `secondary`.
7. **Herramientas SS públicas:** se revisaron 30 y 22 tienen código legible. Comprueban sobre todo:
   - Memoria de javaw, DPS, PcaSvc, explorer y csrss.
   - Prefetch, BAM, el USN Journal y el estado de servicios.
   - El hash del mod contra la API de Modrinth y `Zone.Identifier` (`HostUrl`).
8. **Autoclickers:**
   - Speed AutoClicker guarda su configuración en `%APPDATA%\SpeedAutoClickerV3` (fuente oficial).
   - OP Auto Clicker y Speed AutoClicker se llaman los dos `AutoClicker.exe`, así que el nombre no sirve como firma.
   - **JNativeHook** extrae su DLL en `%TEMP%` solo en las versiones 1.x-2.1. La 2.2 la extrae **junto al JAR**.
9. **Macros:** las rutas de G HUB e iCUE vienen de documentación oficial; las demás, de una herramienta SS pública. Su presencia solo indica software instalado. Las macros guardadas en la **memoria interna del ratón** no dejan rastro en el disco.
10. **Bypasses:** se documentan artefactos y detección de once técnicas. Hay dos dudas abiertas:
    - El evento "Application 3079 = USN Journal borrado" que usan algunas herramientas **no se pudo confirmar** con una fuente oficial.
    - Algunos dominios de listas públicas ya no pertenecen al cliente: `whiteout.gg` es un juego de tablero y `novoline.lol` un overlay de estadísticas.

### Indicadores con fuente por cliente

| Cliente (`clientId`) | Categoría | Indicadores | Primarios (validados) | Secundarios |
| --- | --- | --- | --- | --- |
| Vape (v4 / Lite) (`vape`) | cheat-client | 11 | 0 (0) | 11 |
| Raven (B+, bS, XD y forks) (`raven`) | cheat-client | 18 | 12 (12) | 6 |
| Inertia Client (`inertia`) | cheat-client | 13 | 8 (7) | 5 |
| Sigma (Sigma 5 / Jello) (`sigma`) | cheat-client | 5 | 0 (0) | 5 |
| Rise (Rise 6) (`rise`) | cheat-client | 6 | 0 (0) | 6 |
| Novoline (`novoline`) | cheat-client | 2 | 0 (0) | 2 |
| Slinky (`slinky`) | cheat-client | 7 | 2 (2) | 5 |
| Breeze (`breeze`) | cheat-client | 5 | 3 (3) | 2 |
| Argon (`argon`) | cheat-client | 4 | 0 (0) | 4 |
| Tenacity (`tenacity`) | cheat-client | 3 | 0 (0) | 3 |
| FDPClient (`fdpclient`) | cheat-client | 7 | 6 (6) | 1 |
| GameSense (1.12.2) (`gamesense`) | cheat-client | 6 | 6 (6) | 0 |
| Drip (Lite / X) (`drip`) | cheat-client | 5 | 0 (0) | 5 |
| Entropy (`entropy`) | cheat-client | 1 | 0 (0) | 1 |
| Whiteout (`whiteout`) | cheat-client | 1 | 0 (0) | 1 |
| Koid (`koid`) | cheat-client | 1 | 0 (0) | 1 |
| Dream Client (`dream`) | cheat-client | 2 | 0 (0) | 2 |
| Krypton (`krypton`) | cheat-client | 2 | 0 (0) | 2 |
| Catlean (`catlean`) | cheat-client | 2 | 0 (0) | 2 |
| Dqrkis Client (`dqrkis`) | cheat-client | 11 | 0 (0) | 11 |
| Asteria (`asteria`) | cheat-client | 1 | 0 (0) | 1 |
| Xenon (`xenon`) | cheat-client | 1 | 0 (0) | 1 |
| Gypsy (`gypsy`) | cheat-client | 1 | 0 (0) | 1 |
| Virgin (`virgin`) | cheat-client | 1 | 0 (0) | 1 |
| Prestige Client (`prestige`) | cheat-client | 3 | 0 (0) | 3 |
| Doomsday Client (`doomsday`) | cheat-client | 15 | 0 (0) | 15 |
| Nova Client (`nova-client`) | cheat-client | 1 | 0 (0) | 1 |
| Impact (`impact`) | cheat-client | 1 | 0 (0) | 1 |
| Aristois (vía EMC Framework) (`aristois`) | cheat-client | 1 | 0 (0) | 1 |
| Future Client (`future`) | cheat-client | 1 | 0 (0) | 1 |
| ThunderHack Recode (`thunderhack`) | cheat-client | 1 | 0 (0) | 1 |
| JNativeHook (librería de hooks globales) (`jnativehook`) | dual-use | 2 | 2 (2) | 0 |
| Speed AutoClicker (`speed-autoclicker`) | autoclicker | 1 | 1 (1) | 0 |
| OP Auto Clicker (`op-autoclicker`) | autoclicker | 1 | 0 (0) | 1 |
| AutoHotkey (`autohotkey`) | dual-use | 2 | 1 (1) | 1 |
| Autoclickers externos (varios) (`generic-autoclicker`) | autoclicker | 3 | 0 (0) | 3 |
| Logitech G HUB (`logitech-ghub`) | macro | 2 | 1 (1) | 1 |
| Logitech Gaming Software (`logitech-lgs`) | macro | 1 | 0 (0) | 1 |
| Razer Synapse 3 (`razer-synapse`) | macro | 2 | 0 (0) | 2 |
| SteelSeries Engine 3 (`steelseries`) | macro | 1 | 0 (0) | 1 |
| ROCCAT Swarm (`roccat-swarm`) | macro | 1 | 0 (0) | 1 |
| Redragon Gaming Mouse (`redragon`) | macro | 1 | 0 (0) | 1 |
| ASUS ROG Armoury (`asus-armoury`) | macro | 1 | 0 (0) | 1 |
| Corsair iCUE (`corsair-icue`) | macro | 1 | 1 (1) | 0 |
| **Total** | | **158** | **43 (42)** | **115** |

## 2. Cómo leer este informe

| Procedencia | Significado aquí |
| --- | --- |
| `primary-source` | Código fuente o documentación oficial del propio cliente o programa (incluye el repositorio público del autor). `validated: true` si el valor se leyó en código o documentación activos. |
| `secondary` | Código filtrado, desofuscado o reconstruido, *issue trackers* con logs de usuarios y herramientas SS de terceros. Siempre `validated: false`. |

**Límites del motor actual que condicionan las propuestas:**

- `config`/`path` solo admiten rutas relativas a `gameDir` o `userHome`, sin comodines. Por eso:
  - `%APPDATA%` se expresa como `AppData/Roaming/…` relativo a `userHome`.
  - Las rutas de `C:\Program Files` y `C:\ProgramData` solo figuran en el texto.
- No hay tipo para nombres de archivo con patrón (`JNativeHook*.dll`, inyectores con nombre aleatorio) ni para el firmante Authenticode. El firmante se propone como `string` en ámbito `raw`, porque el certificado va embebido en el PE.
- Las cadenas de memoria (javaw, DPS, explorer) que usan las herramientas SS no son firmas de archivo. Solo se proponen como `string` cuando es razonable que estén también en el JAR, EXE o DLL.
- Un indicador `weak` no validado **no suma** en Amon. Los débiles se incluyen para documentar y como apoyo de correlación, no para detectar.

## 3. Panorama de clientes (2023-2026)

| Cliente | Tipo | Versiones / loaders | Cómo se carga | En Amon hoy | Propuesto aquí |
| --- | --- | --- | --- | --- | --- |
| Meteor, Wurst, LiquidBounce, ThunderHack, BleachHack, Lambda, KAMI Blue, SalHack, RusherHack | Blatant, código abierto (RusherHack: API pública) | Fabric / Forge | Mod en `mods` (RusherHack: loader con `-Drusherhack.enablePlugins`) | Sí, fuente primaria | ThunderHack: 1 cadena secundaria |
| Impact, Aristois, Future, Coffee, Phobos, MatHax | Blatant, cerrado o archivado | Varios | Versión propia en `versions/` (Impact) o mod | Sí, en parte secundario | Impact, Aristois y Future: 1 cada uno |
| **Vape v4 / Lite** | Ghost | v4: 1.7.10-26.2 Vanilla/Forge/Fabric/NeoForge; Lite: 1.7.10-1.14.4 | Inyector `.exe` con nombre aleatorio; Lite con GUI externa | 0 | 11 secundarios |
| **Raven B+ / bS / B4 / XD** | Ghost/blatant, 1.8.9 Forge | Forge 1.8.9 | Mod en `mods` que se hace pasar por KeystrokesMod | 0 | 12 primarios (bS) + 6 secundarios |
| **Inertia** | Blatant / utilidades | 1.12.2 Forge, 1.13.2, 1.14.4-1.16.5 Fabric; ICB 1.21.4 | Mod Fabric/Forge, instalador `.jar` | 0 | 8 primarios (7 validados) + 5 secundarios |
| **Sigma 5 / Jello** | Blatant | 1.16.4 con ViaVersion (Sigma 5); Jello 1.8 | Cliente completo (versión propia) | 0 | 5 secundarios |
| **Rise 6** | Blatant | 1.8.9 (MCP) con ViaMCP | Cliente completo | 0 | 6 secundarios |
| **Novoline** | Blatant | 1.8.9 (MCP) | Cliente completo | 0 | 2 secundarios |
| Doomsday | Ghost | 1.8-26.1.2, Vanilla/Forge/Fabric/Feather/Lunar/LabyMod | Loader `.jar` con nombre y tamaño aleatorios | 26 user-provided | 15 secundarios |
| Prestige | Ghost | Fabric 1.21-26.1.2 | Inyectable (Windows 10/11) | 3 user-provided | 3 secundarios |
| Nova | Ghost | — | — | 5 user-provided | 1 secundario (corroboración) |
| Slinky | Ghost | 1.7.10 / 1.8.9, Vanilla/Forge/Lunar/Badlion | Loader `.exe` inyector | — | 2 primarios + 5 secundarios |
| Breeze | Ghost/híbrido | 1.8.9 | Inyección "one-click" | — | 3 primarios + 2 secundarios |
| Entropy | Ghost | 1.7.10/1.8.9, Vanilla/Forge/LabyMod/Badlion/Lunar | Inyectable (web oficial) | — | 1 débil |
| Drip (Lite/X) | Ghost | — | Inyectable (web tras Cloudflare) | — | 5 secundarios |
| Argon | Ghost (crystal PvP) | Fabric 1.21 | Mod Fabric disfrazado de ImmediatelyFast | — | 4 secundarios |
| Krypton, Catlean, Dqrkis, Asteria, Xenon, Gypsy, Virgin | Ghost Fabric (crystal/mace PvP) | 1.21.x | Mods o inyectables de pago | — | Solo cadenas secundarias |
| Tenacity | Blatant | 1.8.9 | Cliente completo | — | 3 secundarios |
| FDPClient | Blatant (fork de LiquidBounce) | Forge 1.8.9 | Mod | — | 6 primarios + 1 secundario |
| GameSense | Anarquía | Forge 1.12.2 | Mod | — | 6 primarios |
| Koid, Itami, Whiteout, Dream | Ghost antiguos (2019-2021) | 1.7/1.8 | Inyectables | — | Koid 1, Whiteout 1, Dream 2, Itami 0 |
| Moon | Ghost | — | — | — | 0: `MoonDLL.pdb` aparece en zeezy sin etiqueta y no se atribuye |

## 4. Fichas de los clientes sin indicadores en Amon

### 4.1 Vape (v4 / Lite)

**Carga (fuente primaria, docs.vape.gg):**

- Se descarga desde la web un ejecutable con **nombre aleatorio que cambia en cada descarga**, por ejemplo `k4xw2tfl.exe` ([launch-issues](https://docs.vape.gg/troubleshooting/launch-issues)).
- Se ejecuta con Minecraft abierto. El inyector se cierra solo al terminar ([install](https://docs.vape.gg/intro/install)).
- Vape no tiene instalación: es un cliente de inyección que solo modifica el juego en tiempo de ejecución ([what-is-vape](https://docs.vape.gg/intro/what-is-vape)).
- Versiones soportadas: v4 cubre de 1.7.10 a 26.2 (Vanilla, Forge, Fabric y NeoForge según la versión); Lite cubre de 1.7.10 a 1.14.4 ([supported-versions](https://docs.vape.gg/guides/general/supported-versions)).
- La web archivada de Vape Lite lo presenta como cliente para evitar screenshares, con GUI externa y visuales que no salen en grabaciones ([features-lite, archivo 2026-10-01](https://web.archive.org/web/20261001083839/https://www.vape.gg/features-lite)).
- La empresa es Manthe Industries, LLC (pie de la web y de la documentación).

**Consecuencias para Amon:**

- No hay JAR en `mods`.
- El nombre del `.exe` no sirve para detectar.
- Lo útil es lo siguiente:
  - Evidencia de ejecución de un `.exe` de 8 caracteres aleatorios en `Downloads`, en BAM, Prefetch o PCA, justo antes de lanzar el juego.
  - El firmante del ejecutable, si se conserva.
  - Las cadenas YARA del inyector.

**Vape (v4 / Lite)** (`vape`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `Manthe Industries, LLC` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/BAM/BAM.cpp) | (codificación ascii; ámbito raw) spokwn BAM-parser (línea 145) marca el firmante 'manthe industries, llc' como 'Cheat Signature'; el gist de Azran (idk.md) lo asocia a Vape Lite. La web y la documentación oficiales confirman el nombre de la empresa ('Copyright 2015-2026 Manthe Industries, LLC', https://docs.vape.gg/). Se espera en el certificado Authenticode del ejecutable; las mayúsculas exactas del certificado no están verificadas (Amon distingue mayúsculas). |
| string | `[!] Failed to find Vape jar` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) Regla YARA 'Specifics A' ($e), insensible a mayúsculas, ascii y wide. |
| string | `Vape Launcher` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) Regla YARA 'Specifics A' ($f). La página de soporte oficial habla de 'the vape launcher' (https://docs.vape.gg/troubleshooting/launch-issues). |
| string | `vape.gg` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) Dominio oficial; también en OmniSS jvm.rs y Onyx. Corto y presente en cachés de navegador: solo apoyo. |
| string | `(JLcn/gov/vape/util/jvmti/ClassLoadHook;)I` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (codificación ascii; ámbito raw/entries) Lista kRedDetections (línea 248) sin etiqueta de cliente; atribución a Vape por el nombre del paquete. Firma JNI típica del modulo inyectado. |
| string | `Vape4DLL.dll` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Sypherox/Devyl/HEAD/scanner/DPS_Strings.txt) | (codificación ascii/utf16le; ámbito raw) Línea 875 'Vape4DLL.dll:::2025/09/09:17:11:33' de una lista de cadenas DPS (memoria del servicio DPS). Que aparezca dentro del inyector no está comprobado. |
| sha256 | `30023ad5e824d2f17c3724b488b66d1afbf4bdf191fc453f61fe4b0ec4a91eb5` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo crack) TuxTool: 'Vape Crack (Fake)'. Solo identifica esa compilación; los cracks falsos suelen ser malware. |
| sha256 | `68a675b0d31fe9fe538ed7580f22416bd824518ad17b9d5a69e35b8bc57102c8` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo crack) TuxTool: 'Vape V3.25 Crack'. |
| string | `com/sun/jna/z/Main` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo legacy; ámbito raw/entries) AstroSS 'Vape Cracked #2'; también andreaonorato/Minecraft-Cheat-Scanner lo etiqueta 'Vape 2.06'. Versión antigua (v2/v3). |
| string | `com/sun/jna/z/a/e/a/a/a/f` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo legacy; ámbito raw/entries) AstroSS 'Vape Cracked #1'. Versión antigua. |
| string | `erouax/instavape` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo legacy; ámbito raw/entries) AstroSS 'Wax Vape Mod'; el gist de Azran lo etiqueta 'Instant Vape Mod'. Versión antigua. |

**Falsos positivos y notas:**

- `vape.gg` aparece en cachés del navegador y en foros.
- Los hashes de cracks solo identifican esas compilaciones, y los "cracks" suelen ser malware.
- Las cadenas `legacy` son de Vape v2/v3 (2016-2018).

### 4.2 Raven (B+, bS, B4, XD y forks)

**Carga:** mod de Forge 1.8.9 en `mods`.

- Usa el `mcmod.info` del KeystrokesMod legítimo (modid `keystrokes`, nombre `KeystrokesMod`) para disimular.
- Los repositorios de GitHub de Raven b+, B3, bS y XD están bloqueados por DMCA (HTTP 451). En el [aviso de 2025-07-15](https://raw.githubusercontent.com/github/dmca/master/2025/07/2025-07-15-raven-b4.md), el titular de **Raven B4** (de pago y cerrado) afirma que b+ y bS derivan del código de Raven B3.
- **Fuente primaria usada:** el autor de Raven bS mantiene el código en [codeberg.org/strangerrrrs/raven-bS](https://codeberg.org/strangerrrrs/raven-bS) (commit `44d82ec`). Su README remite a las *releases* de ese repositorio, y Codeberg le atribuye 17 forks. Hay derivados como `raven-bC`, `raven-bento`, `raven-autoclicker` y `raven-bS-injectable`.

**Raven (B+, bS, XD y forks)** (`raven`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `keystrokesmod/module/` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/Raven.java) | (grupo bS) Raven bS (repositorio del autor en Codeberg, commit 44d82ec). 'package keystrokesmod;' e 'import keystrokesmod.module.Module'. El aviso DMCA de GitHub (2025-07-15) afirma que Raven b+ y bS derivan del código de Raven B3: el paquete es común a la familia y a sus forks. |
| package | `keystrokesmod/script/` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/script/ScriptManager.java) | (grupo bS) API de scripting de Raven bS. |
| entrypoint | `keystrokesmod.Raven` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/Raven.java) | (grupo bS) Clase @Mod principal (keystrokesmod/Raven.class). |
| entry | `mixins.raven.json` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/build.gradle.kts) | (grupo bS) mixinConfig("mixins.raven.json") y recurso src/main/resources/mixins.raven.json. |
| entry | `mixins.raven.refmap.json` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/build.gradle.kts) | (grupo bS) defaultRefmapName.set("mixins.raven.refmap.json"). |
| manifest | `MixinConfigs: mixins.raven.json` | strong | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/build.gradle.kts) | (grupo bS) Atributo del MANIFEST definido en tasks.withType(Jar). |
| modid | `keystrokes` | weak | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/resources/mcmod.info) | (grupo bS) Raven copia el mcmod.info del KeystrokesMod legitimo (modid 'keystrokes', name 'KeystrokesMod'): por si solo no distingue Raven de ese mod. |
| config | `keystrokes/profiles` | medium | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/utility/profile/ProfileManager.java) | (relativo a gameDir; grupo bS) new File(mc.mcDataDir + File.separator + "keystrokes", "profiles") (línea 66). |
| config | `keystrokes/scripts` | medium | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/script/ScriptManager.java) | (relativo a gameDir; grupo bS) new File(mc.mcDataDir + File.separator + "keystrokes", "scripts") (línea 44). |
| path | `keystrokes/players.json` | medium | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/utility/PlayerRelationsManager.java) | (relativo a gameDir; grupo bS) Lista de amigos/enemigos (líneas 69-73). |
| path | `AppData/Local/Temp/cmF2ZW5fc2NyaXB0cw` | medium | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/java/keystrokesmod/utility/Utils.java) | (relativo a userHome; grupo bS) getCompilerDirectory(): System.getProperty("java.io.tmpdir") + "cmF2ZW5fc2NyaXB0cw" en Windows (línea 404). Solo existe si se compilaron scripts y si %TEMP% es la ruta por defecto. |
| entry | `assets/keystrokesmod/textures/capes/rvn_white.png` | medium | primaria | sí | [fuente](https://codeberg.org/strangerrrrs/raven-bS/raw/commit/44d82ec09b83d03f7c8af47cf97823f40bb33745/src/main/resources/assets/keystrokesmod/textures/capes/rvn_white.png) | (grupo bS) Recurso de capa de Raven bS (hay variantes rvn_aqua, rvn_green, rvn_purple, rvn_red, rvn_yellow). |
| sha256 | `320ec3ef32f50693fea5d821491fb60c18cf94524c7be99ac60b535a3c13bcfe` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo b+) TuxTool: 'Raven B+ v.1.0.16'. |
| sha256 | `03f069fa7fcd395492088329ceda11bacc666612979882704982c97073034163` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo b+) TuxTool: 'Raven B+ Experimental'. |
| sha256 | `59c1f741f198c68cb70f94630fa36739f6106c7a06eb2a04514feb2c84ef6ad6` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo b+) TuxTool: 'Raven B+ Beta'. |
| sha256 | `99781fa9716552e2abad20304f39d673fa530c941928b104e17df8d94ae31673` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | (grupo b+) TuxTool: 'Old Raven B+'. |
| string | `keystr0kes` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo legacy; ámbito raw/entries) AstroSS 'Raven Mod Client' (cadena de memoria de javaw; versión antigua). |
| string | `ravenbplus` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (ámbito raw/entries) OmniSS 'Raven Ghost' (memoria). Fuente de fiabilidad baja; solo apoyo. |

**Falsos positivos y notas:**

- El modid `keystrokes` también es el del KeystrokesMod legítimo. Por eso se propone como `weak`.
- El paquete `keystrokesmod/` (desde la raíz) no coincide con el KeystrokesMod original, que usa `pw/cinque/keystrokesmod/` según AstroSS.
- Existen forks como "Novoline-bS" (Raven bS con estética de Novoline): darán positivo como Raven, no como Novoline.
- Raven B4 es cerrado y no se verificó si conserva estos valores.

### 4.3 Inertia Client

**Carga:** mod de Fabric (1.14.4-1.16.5) o Forge 1.12.2, más una edición para 1.13.2. Se instala con `Inertia Client Installer.jar` o con descargas manuales del tipo `Inertia Client 3.1.3 - 1.16.5.zip`, según la [copia de su web](https://github.com/eralp232/InertiaClient-Web), que es secundaria. La web dice que es de código cerrado. La versión actual se apoya en **ICB**, publicado por el propio desarrollador en [THEREALWWEFAN231/inertia-client-base](https://github.com/THEREALWWEFAN231/inertia-client-base) (commit `a51e09b`, Fabric 1.21.4).

**Inertia Client** (`inertia`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `com/inertiaclient/base/` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/resources/fabric.mod.json) | (grupo icb) ICB (Inertia Client Base), repositorio público del propio desarrollador (THEREALWWEFAN231/IKnowImEZ). Su README dice que Inertia Client se construye sobre ICB; ICB por si solo no trae modulos: la atribución a Inertia Client es inferida (en el archivo de firmas encaja mejor como 'framework'). |
| entrypoint | `com.inertiaclient.base.FabricMod` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/resources/fabric.mod.json) | (grupo icb) Entrypoint 'client' de ICB. |
| modid | `icb` | weak | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/resources/fabric.mod.json) | (grupo icb) Id de tres letras: poco distintivo. |
| entry | `icb.mixins.json` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/resources/fabric.mod.json) | (grupo icb) |
| entry | `icb.accesswidener` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/resources/fabric.mod.json) | (grupo icb) |
| config | `icb/Configs` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/java/com/inertiaclient/base/utils/FileManager.java) | (relativo a gameDir; grupo icb) mainDirectory = gameDirectory.resolve("icb"); getGameFolder("Configs") (líneas 62 y 73). |
| log | `saved ICB settings json` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/java/com/inertiaclient/base/utils/FileManager.java) | (grupo icb) InertiaBase.LOGGER.info("saved ICB settings json") (línea 53); logger 'icb'. |
| config | `Inertia` | medium | primaria | no | [fuente](https://raw.githubusercontent.com/THEREALWWEFAN231/inertia-client-base/a51e09bc766e6063a757857bee060aee84ae1d73/inertia-client-base/src/main/java/com/inertiaclient/base/utils/FileManager.java) | (relativo a gameDir; grupo client) Solo en un comentario del código oficial (línea 61): new File(gameDirectory + File.separator + "Inertia", InertiaClient.MINECRAFT_VERSION). Indica la carpeta de Inertia Client, pero no es código activo: sin validar. Nombre corto que puede coincidir con otros mods. |
| entry | `mixins.inertia.json` | medium | secundaria | no | [fuente](https://github.com/THEREALWWEFAN231/Inertia-Issues/issues/822) | (grupo client) Log publicado en el issue tracker oficial: 'Mixin apply failed mixins.inertia.json:MmJq' (Inertia 1.16.3). |
| entry | `assets/minecraft/textures/inertia/logos/squareredicon.png` | medium | secundaria | no | [fuente](https://github.com/THEREALWWEFAN231/Inertia-Issues/issues/1330) | (grupo client) Campo 'icon' del fabric.mod.json de Inertia Client 3.1.3 citado en el issue. |
| log | `This isent good, please report this on the github` | medium | secundaria | no | [fuente](https://github.com/THEREALWWEFAN231/Inertia-Issues/issues/956) | (grupo client) Mensaje (con la errata 'isent') que Inertia 3.1 imprime por STDOUT y queda en latest.log. |
| modid | `inertia` | weak | secundaria | no | [fuente](https://github.com/THEREALWWEFAN231/Inertia-Issues/issues/822) | (grupo client) Logs de Fabric: 'inertia@1.16.3'. Falso positivo probable: el mod de cámara 'Inertia!' de Modrinth pública inertia-1.0.0.jar (su id real no se verificó). |
| package | `inertia/` | medium | secundaria | no | [fuente](https://github.com/THEREALWWEFAN231/Inertia-Issues/issues/956) | (grupo client) Clases ofuscadas en las trazas: 'at inertia.ZGbt.pAcb' dentro de 'Inertia Client 3.1.3 - 1.16.4.jar'. Comprobar que el mod 'Inertia!' no usa ese paquete. |

**Falsos positivos y notas:**

- El mod de cámara "Inertia!" de Modrinth (`inertia-1.0.0.jar`, Fabric 1.20.1) puede compartir el modid `inertia`. "Inertia Anti Cheat" (de servidor) tampoco tiene relación.
- Los repositorios `Minecraft-Inertia/*` y otros "Inertia Client" de GitHub son señuelos (posible malware), no fuentes.
- ICB es una base pública: un mod de terceros hecho con ICB coincidiría con el grupo `icb`. En `signatures/` encajaría como `framework` (ver `aristois.json`).

### 4.4 Sigma (Sigma 5 / Jello)

**Carga:** cliente completo para 1.16.4 con ViaVersion. La [reconstrucción SigmaRemap](https://github.com/xquj/SigmaRemap) parte de un Sigma 5.0 desofuscado por terceros: las clases están renombradas, así que no hay paquete propio verificable. La edición Jello para 1.8 aparece con el paquete `com/mentalfrostbyte/jello/` en dos repositorios no oficiales. La web oficial no respondió.

**Sigma (Sigma 5 / Jello)** (`sigma`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `com/mentalfrostbyte/jello/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/neilhuang007/sigma_buildable/d666dc29c2053e207bc94dfa230649b19d5b3918/src/main/java/com/mentalfrostbyte/jello/main/Jello.java) | (grupo jello-1.8) Paquete de Jello para 1.8 en dos repositorios no oficiales (neilhuang007/sigma_buildable y EnderDrago0/SigmaJello). No se comprobó que el JAR de Sigma 5 lo conserve: el Sigma 5.0 desofuscado (SigmaRemap) usa clases renombradas. |
| config | `sigma5` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/xquj/SigmaRemap/8bb0f8ae4433831978865c9aef37f674c3c32e10/src/deobf/remapped/SigmaMainClass.java) | (relativo a gameDir; grupo sigma5) private final File sigmaFolder = new File("sigma5") (Sigma 5.0.0b15, línea 20). Ruta relativa al directorio de trabajo (normalmente gameDir). |
| path | `sigma5/config.json` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/xquj/SigmaRemap/8bb0f8ae4433831978865c9aef37f674c3c32e10/src/deobf/remapped/SigmaMainClass.java) | (relativo a gameDir; grupo sigma5) Líneas 71, 162 y 173. |
| config | `sigma5/profiles` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/xquj/SigmaRemap/8bb0f8ae4433831978865c9aef37f674c3c32e10/src/deobf/remapped/ConfigManager.java) | (relativo a gameDir; grupo sigma5) Archivos <nombre>.profile (líneas 60-116). |
| path | `jello/jello.lic` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/xquj/SigmaRemap/8bb0f8ae4433831978865c9aef37f674c3c32e10/src/deobf/remapped/AccountManager.java) | (relativo a gameDir; grupo sigma5) Licencia guardada por Sigma 5 (líneas 182, 300 y 326). |

**Notas:** las rutas de Sigma 5 son relativas al directorio de trabajo del proceso. Con el launcher oficial ese directorio es el `gameDir`.

### 4.5 Rise (Rise 6)

**Carga:** cliente completo (MCP 1.8.9 + ViaMCP). Según su web, Rise cubre de 1.8 a 1.19.4. Ojo: `riseclient.com` enlaza hoy a revendedores y a "vantage.rip", y podría no ser la web original.

**Fuente:** código filtrado de Rise 6.2.4 ([CykXd/RiseClient](https://github.com/CykXd/RiseClient), commit `c590a42`). Muchos otros repositorios "Rise Client" de GitHub son señuelos con ejecutables: no son fuente.

**Rise (Rise 6)** (`rise`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `com/alan/clients/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/Client.java) | Código filtrado de Rise 6.2.4 ('package com.alan.clients;'). Un comentario del propio código dice que en la versión ofuscada algunas clases siguen en com.alan.clients. Coincide con las listas de Onyx y MeowModAnalyzer. |
| package | `hackclient/` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/Client.java) | Paquete de la versión ofuscada según Client.java (líneas 151 y 196: dirExist("hackclient.")). Nombre genérico: otros clientes podrían usarlo. |
| config | `Rise/configs` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/util/file/config/ConfigManager.java) | (relativo a gameDir) FileManager.DIRECTORY = new File(mc.mcDataDir, "Rise") + "configs" (latest.json). |
| path | `Rise/alts/alts.json` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/util/file/alt/AltManager.java) | (relativo a gameDir) |
| config | `Rise/insults` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/util/file/insult/InsultManager.java) | (relativo a gameDir) |
| config | `Rise/scripts` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/CykXd/RiseClient/c590a4228929d1fe0294db87b96e0e8d72836db0/script/ScriptManager.java) | (relativo a gameDir) Scripts .js. |

**Notas:**

- La versión ofuscada mueve el código a `hackclient.`, pero según un comentario del código algunas clases siguen en `com.alan.clients`.
- La carpeta `Rise` del `gameDir` es el indicador más estable.

### 4.6 Novoline

**Carga:** cliente completo para 1.8.9. **Fuente:** remapeo comunitario del JAR ([RandomForks/novoline](https://github.com/RandomForks/novoline), commit `0b0fe7b`), coherente con [oooooomygod/novoline-opensource](https://github.com/oooooomygod/novoline-opensource).

**Novoline** (`novoline`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `cc/novoline/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/RandomForks/novoline/0b0fe7b1007aa83fc0fa9768d229ff8741814d22/src/cc/novoline/Novoline.java) | Código filtrado/remapeado (RandomForks/novoline y oooooomygod/novoline-opensource). Coincide con Onyx y MeowModAnalyzer. Ojo: hay forks de Raven bS llamados 'Novoline-bS' que no usan este paquete. |
| config | `Novoline` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/RandomForks/novoline/0b0fe7b1007aa83fc0fa9768d229ff8741814d22/src/cc/novoline/Novoline.java) | (relativo a gameDir) dataFolder = Paths.get(mc.mcDataDir...).resolve("Novoline") (líneas 59 y 135). |

**Falsos positivos:** `novoline.lol`, que listan OmniSS y Leo-Galli, aloja hoy "Myah", un overlay de estadísticas (comprobado el 2026-10-21). No debe usarse como indicador.

## 5. Otros clientes

### 5.1 Ghost clients con fuente oficial: Slinky y Breeze

**Slinky:**

- Loader `.exe` que inyecta en 1.7.10 y 1.8.9 (Vanilla, Forge, Lunar y Badlion), según la [web oficial](https://slinky.gg/).
- Su documentación pide excluir del antivirus el loader y la carpeta `%USERPROFILE%\.slinky\bin`.
- En Linux usa el loader `slinky-loader` y la carpeta de datos `~/.slinky`.

**Slinky** (`slinky`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| path | `.slinky/bin` | medium | primaria | sí | [fuente](https://docs.slinky.gg/basics/get-started/) | (relativo a userHome) La documentación oficial pide excluir del antivirus 'The %USERPROFILE%\.slinky\bin folder'. |
| config | `.slinky` | medium | primaria | sí | [fuente](https://docs.slinky.gg/basics/linux/) | (relativo a userHome) Guía oficial de Linux: 'exempt the Slinky data directory ... --filesystem=~/.slinky'. |
| string | `slinkyhook.dll` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) YARA 'Specifics A' ($c); también zeezy MemoryScanner.cpp línea 266. |
| string | `slinky_library.dll` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) YARA 'Specifics A' ($d). |
| string | `slinkyhooks.class` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (ámbito raw/entries) Línea 267. |
| string | `slinkware` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/BAM/BAM.cpp) | (codificación ascii; ámbito raw) Firmante marcado como 'Cheat Signature' (línea 145) sin etiqueta de cliente; atribución a Slinky inferida por el nombre. |
| string | `slinky.gg` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) Dominio oficial; solo apoyo. |

**Breeze:**

- Cliente "inyectable híbrido" para 1.8.9, con configuraciones en la nube ([web](https://breeze.rip/)).
- Su documentación de scripting sitúa los scripts en la carpeta `breeze/1.8.9/scripts` de `%APPDATA%`. La introducción la llama `breeze/1.8.9/scripting`.

**Breeze** (`breeze`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `AppData/Roaming/breeze/1.8.9` | medium | primaria | sí | [fuente](https://scripting.breeze.rip/getting_started.md) | (relativo a userHome) Documentación oficial: carpeta en %APPDATA% ('the same folder where .minecraft is') con la ruta 'breeze/1.8.9/scripts'. |
| path | `AppData/Roaming/breeze/1.8.9/scripts` | medium | primaria | sí | [fuente](https://scripting.breeze.rip/getting_started.md) | (relativo a userHome) La introducción (https://scripting.breeze.rip/) la llama 'breeze/1.8.9/scripting': conviene comprobar ambas. |
| path | `AppData/Roaming/breeze/1.8.9/scripting` | medium | primaria | sí | [fuente](https://scripting.breeze.rip/) | (relativo a userHome) Variante del nombre de carpeta citada en la introducción oficial. |
| string | `Breeze.InjectScreen` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/PathsParser/HEAD/rules.cpp) | (codificación ascii/utf16le; ámbito raw) YARA de PathsParser ($ah). |
| string | `breeze.dll` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/PathsParser/HEAD/rules.cpp) | (codificación ascii/utf16le; ámbito raw) YARA de PathsParser ($af). |

### 5.2 Mods con código disponible: Argon, Tenacity, FDPClient y GameSense

**Argon:**

- El JAR descompilado ([06gw/argon-b1.1-decompiled](https://github.com/06gw/argon-b1.1-decompiled)) declara en `fabric.mod.json` el id `immediatelyfast` y los datos de contacto de RaphiMC: es un **mod troyanizado o disfrazado**.
- zeezy describe el mismo patrón en otras familias: copias de `net/raphimc/immediatelyfast` o de `net/blay09/mods/balm` con módulos de combate inyectados.
- Detección recomendada: comprobar que el hash del mod coincide con el publicado en Modrinth, como hacen HabibiModAnalyzer y MeowModAnalyzer.

**Argon** (`argon`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `dev/lvstrng/argon/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/06gw/argon-b1.1-decompiled/36d90a6e85de0e4a923cc7df00f9e223d7302989/client.mixins.json) | JAR descompilado (06gw/argon-b1.1-decompiled): 'package': 'dev.lvstrng.argon.mixin'. zeezy lo usa como ejemplo de firma ('dev/lvstrng/argon/'). |
| entrypoint | `dev.lvstrng.argon.Main` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/06gw/argon-b1.1-decompiled/36d90a6e85de0e4a923cc7df00f9e223d7302989/fabric.mod.json) | Se disfraza de ImmediatelyFast: el fabric.mod.json declara id 'immediatelyfast' y autor RK_01. No usar ese modid (es el de un mod legitimo). |
| entry | `argon-refmap.json` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/06gw/argon-b1.1-decompiled/36d90a6e85de0e4a923cc7df00f9e223d7302989/argon-refmap.json) | Entrada en la raiz del JAR. |
| entry | `LICENSE_argon` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/06gw/argon-b1.1-decompiled/36d90a6e85de0e4a923cc7df00f9e223d7302989/LICENSE_argon) | Entrada en la raiz del JAR. |

**Tenacity** (`tenacity`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `dev/tenacity/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/lo1am0n/TenacityRC/0a1d6e5997c300d3630de35922e3de7420e114e4/dev/tenacity/Tenacity.java) | (grupo 5.x) Base Tenacity 5.1 (fork TenacityRC). |
| package | `dev/client/tenacity/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Xicopannt/Tenacity-Client-4.0-Eclipse-Ready/ca92020f6daefa241c1b2c515d87d1f82168ce65/dev/client/tenacity/Tenacity.java) | (grupo 4.0) Tenacity 4.0 (copia 'Eclipse Ready'). |
| config | `Tenacity` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/lo1am0n/TenacityRC/0a1d6e5997c300d3630de35922e3de7420e114e4/dev/tenacity/Tenacity.java) | (relativo a gameDir) DIRECTORY = new File(mc.mcDataDir, "Tenacity") (igual en 4.0). |

**FDPClient** (`fdpclient`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| modid | `fdpclient` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/src/main/resources/mcmod.info) | Repositorio oficial SkidderMC/FDPClient (commit 07d0307). Fork de LiquidBounce legacy: comparte net/ccbluex/liquidbounce/. |
| entry | `fdpclient.forge.mixins.json` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/src/main/resources/fdpclient.forge.mixins.json) |  |
| entry | `fdpclient.mixins.refmap.json` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/src/main/resources/fdpclient.forge.mixins.json) | Campo 'refmap'. |
| manifest | `MixinConfigs: fdpclient.forge.mixins.json` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/build.gradle) | manifest.attributes (línea 336). |
| config | `FDPCLIENT` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/src/main/java/net/ccbluex/liquidbounce/file/FileManager.kt) | (relativo a gameDir) val dir = File(mc.mcDataDir, "FDPCLIENT"). |
| log | `Starting preload tasks of FDPCLIENT` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/SkidderMC/FDPClient/07d03078b3fe12ac7278c678f56d0e7f607fbec2/src/main/java/net/ccbluex/liquidbounce/FDPClient.kt) | LOGGER.info("Starting preload tasks of $CLIENT_NAME") con CLIENT_NAME = "FDPCLIENT". |
| sha256 | `0c495411826534916323ace825e0e734ac6e5ddc643276c834db7de54f2ab091` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/Briiqn/TuxTool/main/check/modcheats.sh) | TuxTool: 'Skidp (FDP Client)'. |

**GameSense:** es un cliente de anarquía para 1.12.2 de código abierto. Si "Gamesense/Moon" en la petición se refería a otro producto ghost, no se encontró fuente.

**GameSense (1.12.2)** (`gamesense`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `com/gamesense/` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/src/main/java/com/gamesense/client/GameSense.java) | Repositorio oficial IUDevman/gamesense-client (anarquía 1.12.2). No confundir con otros productos llamados 'GameSense'. |
| modid | `gamesense` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/src/main/resources/mcmod.info) |  |
| entry | `mixins.gamesense.json` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/build.gradle) | 'MixinConfigs': 'mixins.gamesense.json'. |
| manifest | `FMLCorePlugin: com.gamesense.mixin.GameSenseMixinLoader` | strong | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/build.gradle) |  |
| config | `GameSense/Modules` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/src/main/java/com/gamesense/api/config/SaveConfig.java) | (relativo a gameDir) fileName = "GameSense/" + moduleName = "Modules/" (relativo al directorio de trabajo). |
| log | `Starting up GameSense v\d+\.\d+\.\d+!` | medium | primaria | sí | [fuente](https://raw.githubusercontent.com/IUDevman/gamesense-client/62061a43fea311f42c64ea2b1dbbb56599c32295/src/main/java/com/gamesense/client/GameSense.java) | (regex) LOGGER.info("Starting up " + MODNAME + " " + MODVER + "!") con MODVER = "v2.3.0". |

### 5.3 Ghost clients con solo cadenas de terceros

Son Drip, Entropy, Whiteout, Koid, Dream, Krypton, Catlean, Dqrkis, Asteria, Xenon, Gypsy y Virgin. Sus webs oficiales no publican rutas ni nombres de archivo, o no responden. Las listas públicas de herramientas SS aportan cadenas, casi siempre de **memoria** o de **dominio**.

**Drip (Lite / X)** (`drip`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `drip.gg` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (codificación ascii/utf16le; ámbito raw) OmniSS 'Drip Lite' (memoria). Solo apoyo. |
| string | `driplite` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (ámbito raw/entries) OmniSS 'Drip Lite'. |
| string | `;9<C7D=CHCAL>@?DQI;MDSQRNQIMKEJ8` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo cracked-legacy; ámbito raw/entries) AstroSS 'Drip Cracked #1' (cadena de javaw; versión crackeada antigua). |
| string | `0,$037ADCBDIJICA` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo cracked-legacy; ámbito raw/entries) AstroSS 'Drip Cracked #3'. |
| string | `neverlack.in` | weak | secundaria | no | [fuente](https://gist.githubusercontent.com/synthedev2/bfd1d6af8d4456f803e2c6822cd382df/raw/LSASS.md) | (grupo legacy; codificación ascii/utf16le; ámbito raw) Gist de Azran (2018), lista de LSASS: 'Drip Client'. Antiguo. |

**Entropy** (`entropy`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `entropy.club` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (codificación ascii/utf16le; ámbito raw) Dominio oficial (https://entropy.club/ dice 'Hidden from all public screenshare solutions'). Solo apoyo. |

**Whiteout** (`whiteout`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `whiteout.gg` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (codificación ascii/utf16le; ámbito raw) OmniSS 'Whiteout'. Falso positivo: el dominio aloja hoy un juego de tablero (comprobado el 2026-10-21). |

**Koid** (`koid`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `www.koid.es` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (codificación ascii/utf16le; ámbito raw) Lista de cache DNS (línea 809). Dominio caído el 2026-10-21. |

**Dream Client** (`dream`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `dream-injector` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) YARA 'Specifics A' ($w); atribución a Dream por el nombre. |
| string | `dreamclient.net` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (codificación ascii/utf16le; ámbito raw) OmniSS 'Dream Client'. Dominio sin respuesta el 2026-10-21. |

**Krypton** (`krypton`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `dev/krypton` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx ('Known client') y MeowModAnalyzer (suspiciousPatterns) coinciden. Muchos repositorios 'Krypton Client' de GitHub distribuyen malware (p. ej. uno con payload.exe). |
| string | `skid/krypton` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx y MeowModAnalyzer. |

**Catlean** (`catlean`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `assets/catlean/` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | zeezy busca 'assets/catlean' (línea 261); como entrada ZIP equivale a la carpeta de recursos. |
| string | `catleanclient` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx 'Known client'. |

**Dqrkis Client** (`dqrkis`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `CwskKkUfHQYB` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `HgsCDQ49KkUfHQYB` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `DhsnbQ0LDg0MDA` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `OhYHBQcOHw` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `EgQKDiUqRR8WChk` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `KjoFWRcEAx0M` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `Hx0GAVkcChwdDA` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `HSw7RQQIAQQ` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `BR0sFBcOGg4a` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `Oh0yWR0MCA` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/YarpLetapStan/PowershellScripts/refs/heads/main/YarpsModAnalyzer6.0.ps1) | (ámbito entries) YarpsModAnalyzer 6.0, $dqrkisStrings (línea ~1293) -> 'Reason: Dqrkis Client Strings'. No se decodificó (política del proyecto). |
| string | `dqrkis.xyz` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/MeowTonynoh/MeowModAnalyzer/main/MeowModAnalyzer.ps1) | (codificación ascii/utf16le; ámbito raw/entries) MeowModAnalyzer $cheatStrings; Yarp lo usa como HostUrl de Zone.Identifier. |

**Asteria** (`asteria`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `asteriaclient` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx 'Known client' (subcadena de memoria). Solo apoyo. |

**Xenon** (`xenon`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `xenonclient` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx 'Known client' (subcadena de memoria). Solo apoyo. |

**Gypsy** (`gypsy`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `gypsyclient` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx 'Known client' (subcadena de memoria). Solo apoyo. |

**Virgin** (`virgin`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `virginclient` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/v1shal-tools/onyx-strings-analyzer/HEAD/Onyx_Strings.ps1) | (ámbito raw/entries) Onyx 'Known client' (subcadena de memoria). Solo apoyo. |

**Itami:** solo aparece en una lista de cadenas DPS (memoria del servicio DPS) de [Devyl](https://raw.githubusercontent.com/Sypherox/Devyl/HEAD/scanner/DPS_Strings.txt), por ejemplo `Itami Client:::2020/07/21:00:58:02`. No hay indicador de archivo.

**Nombres de proceso o Prefetch** que usa zeezy ([ExternalToolScanner.cpp](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/ExternalToolScanner.cpp)), útiles como `keywords` pero no como firmas:

- `VAPE INJECTOR.EXE`, `VAPEINJECTOR.EXE`
- `PRESTIGEINJECTOR.EXE`
- `VIRGIN INJECTOR.EXE`, `VIRGININJECTOR.EXE`
- `198MACROS.EXE`

### 5.4 Corroboraciones para clientes ya incluidos

**Prestige Client** (`prestige`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `dev/zprestige/prestige/` | strong | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | Derivado de la cadena de zeezy 'dev/zprestige/prestige/api/mixin/MixinLightmapTextureManager.classPK' (línea 263), que es un nombre de entrada ZIP. Corrobora prestige.entry-raw (hoy user-provided). |
| string | `dev/zprestige/prestige/api/mixin/MixinLightmapTextureManager.classPK` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (ámbito raw) Mismo valor que el indicador user-provided 'prestige.entry-raw': puede pasar a 'secondary'. |
| string | `prestigeclient.vip` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/ohsogalacy-del/OmniSS/HEAD/src/jvm.rs) | (codificación ascii/utf16le; ámbito raw) Dominio oficial (Fabric 1.21-26.1.2, inyectable, según https://prestigeclient.vip/). |

**Doomsday Client** (`doomsday`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| hex | `6161370E160609949E0029033EA7000A2C1D03548403011D1008A1FFF6033EA7000A2B1D03548403011D07A1FFF710FEAC150599001A2A160C14005C6588B800` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | DoomsdayFinder.ps1, $knownMaliciousBytePatterns pattern1 (bytes de clases descomprimidas; Amon busca hex en raw y entries). La herramienta solo lo aplica a JAR de 200 KB-15 MB. |
| hex | `0C1504851D85160A6161370E160609949E0029033EA7000A2C1D03548403011D1008A1FFF6033EA7000A2B1D03548403011D07A1FFF710FEAC150599001A2A16` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | DoomsdayFinder.ps1, $knownMaliciousBytePatterns pattern2 (bytes de clases descomprimidas; Amon busca hex en raw y entries). La herramienta solo lo aplica a JAR de 200 KB-15 MB. |
| hex | `5910071088544C2A2BB8004D3B033DA7000A2B1C03548402011C1008A1FFF61A9E000C1A110800A2000503AC04AC00000000000A0005004E000101FA000001D3` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | DoomsdayFinder.ps1, $knownMaliciousBytePatterns pattern3 (bytes de clases descomprimidas; Amon busca hex en raw y entries). La herramienta solo lo aplica a JAR de 200 KB-15 MB. |
| string | `net/java/f` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/g` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/h` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/i` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/k` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/l` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/m` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/r` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/s` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/t` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `net/java/y` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/praiselily/lilith-ps/HEAD/DoomsdayFinder.ps1) | (ámbito entries) $suspiciousClassNames (busca la referencia dentro de los bytes de clases). Corto: solo apoyo. JInput usa net/java/games/, que no coincide con estos valores salvo 'net/java/g' (prefijo de 'net/java/games'): no usar 'net/java/g' sin más contexto. |
| string | `doomsdayclient.com` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (codificación ascii/utf16le; ámbito raw) Dominio oficial; zeezy (cache DNS) y PJCheatScanner. |

**Nova Client** (`nova-client`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `aHR0cDovL2FwaS5ub3ZhY2xpZW50LmxvbC93ZWJob29rLnR4dA==` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/MeowTonynoh/MeowModAnalyzer/main/MeowModAnalyzer.ps1) | (ámbito entries) Está en $cheatStrings de MeowModAnalyzer (línea 362, sin etiqueta). Mismo valor que nova.b64.url (user-provided): corroboración independiente. No decodificar ni visitar (política del proyecto). |

**Impact** (`impact`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `net/impactclient/` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | AstroSS 'Impact Client' ('net/impactclient'). |

**Aristois (vía EMC Framework)** (`aristois`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `net/aristois/opencode/` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | AstroSS 'Aristois Client'. |

**Future Client** (`future`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `future/api` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (ámbito entries) AstroSS 'Future Client'. Corto y genérico. |

**ThunderHack Recode** (`thunderhack`, cheat-client)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `thunderhack/module` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/zeezyexe/zeezy-cheat-scanner/HEAD/src/scanner/MemoryScanner.cpp) | (ámbito raw/entries) Línea 260, sin etiqueta. Distinto del paquete actual thunder/hack/: puede ser otra versión o fork. |

**Sugerencias:**

- Cambiar `prestige.entry-raw` de `user-provided` a `secondary` citando zeezy (línea 263). `zprestige` solo aparece dentro de esa misma cadena, así que su corroboración es indirecta.
- Cambiar `nova.b64.url` a `secondary` citando MeowModAnalyzer (línea 362).
- Ninguna de las 26 cadenas de Doomsday ni las demás de Nova aparecen en las herramientas revisadas.

## 6. Herramientas SS públicas: qué comprueban

| Herramienta | Código | Qué comprueba | Valor para Amon | Notas |
| --- | --- | --- | --- | --- |
| Echo (echo.ac) | Cerrado, de pago | Escaneo automatizado; driver `echo_driver.sys` | Ninguno extraíble | Pika Network la cita junto a Ocean como herramienta de SS ([Pika](https://support.pika-network.net/articles/screenshare-info)) |
| Ocean (anticheat.ac) | Cerrado | "cheats, macros, injectors" según su ficha de Discord | Ninguno | — |
| Avenge, Paladin, Hydra, Baldr, detect.ac | No localizado | — | — | "Avenge Clicker v3" solo aparece como etiqueta DPS en Devyl |
| [spokwn BAM-parser / prefetch-parser / PathsParser](https://github.com/spokwn/BAM-parser) | Abierto, C++ con YARA | BAM, Prefetch, rutas de memoria y firmantes Authenticode | Firmantes "cheat" y reglas YARA (Vape, Slinky, Breeze, Dream, clickers) | La fuente secundaria más concreta para inyectables |
| [zeezy-cheat-scanner](https://github.com/zeezyexe/zeezy-cheat-scanner) | Abierto, C++ | Memoria de javaw, caché DNS, Prefetch y procesos externos | Cadenas de Prestige, Slinky, Catlean, Argon y Vape; patrón de mods troyanizados | Listas sin etiqueta de cliente |
| [Onyx strings analyzer](https://github.com/v1shal-tools/onyx-strings-analyzer) | Abierto, PowerShell, solo lectura | Cadenas de javaw (ASCII y UTF-16) y argumentos JVM (`-javaagent:`, `-Xbootclasspath`, `-agentpath:`, `-agentlib:jdwp`) | Paquetes `cc/novoline`, `com/alan/clients`, `net/ccbluex`, Krypton | Lista de `-javaagent` permitidos: `jmxremote`, `yjp`, `jrebel`, `newrelic`, `jacoco`, `theseus` |
| [MeowModAnalyzer](https://github.com/MeowTonynoh/MeowModAnalyzer) | Abierto, PowerShell | Hash SHA-1 en Modrinth/Megabase, `Zone.Identifier`, JAR anidados ("hollow shell"), cadenas, ofuscadores | Nombres de ofuscadores (Skidfuscator, Radon, Caesium, Bozar, Branchlock, Binscure, Zelix, Stringer, JNIC) | Corrobora Nova |
| [YarpsModAnalyzer 6.0](https://github.com/YarpLetapStan/PowershellScripts) | Abierto, PowerShell | Lo mismo que Meow, más `HostUrl` → cliente y argumentos JVM `-Dfabric.addMods=` | Cadenas de Dqrkis; falsos positivos conocidos (Simple Voice Chat, Marlow's Crystal Optimizer v2.0.0, ViaFabricPlus) | — |
| [HabibiModAnalyzer](https://github.com/HadronCollision/PowershellScripts) | Abierto | Hash en Modrinth/Megabase y cadenas de módulos | Método de verificación contra Modrinth | Cadenas genéricas propensas a falsos positivos |
| [AstroSS](https://github.com/Jammy108/AstroSS) | Abierto, Python | Cadenas de javaw (coincidencia exacta), DPS, PcaSvc/explorer, `%TEMP%\JNativeHook*.dll`, papelera | Unas 500 cadenas antiguas con etiqueta (Vape v2/v3, Drip cracked, Impact, Aristois, Future…) | Casi todo de 2016-2020 |
| [lilith-ps](https://github.com/praiselily/lilith-ps) | Abierto, PowerShell | `JAVA*.EXE-*.pf` → JAR cargados; detector de Doomsday; estado de servicios; registro y eventos | Patrones hex de Doomsday | `IHateScreensharing.ps1` **modifica el sistema**: no copiar su comportamiento |
| [tempusernamedduck/screenshare-tool](https://github.com/tempusernamedduck/screenshare-tool) | Abierto, C/C++ | BAM, Prefetch (System Informer / Process Hacker), USN, reinicio de servicios, archivos y memoria de macros, mods modificados tras arrancar el juego | Rutas de macros de 15 marcas | — |
| [TuxTool](https://github.com/Briiqn/TuxTool) | Abierto, Linux | SHA-256 de `mods`, mapas de memoria, `javaagent`, mods borrados en uso | Hashes de Raven B+, Vape crack y FDP | `/tmp/libJNativeHook*.so` |
| [OmniSS](https://github.com/ohsogalacy-del/OmniSS) | Abierto, Rust | Memoria y ventanas *stream-proof* (afinidad de captura) | Dominios y cadenas de ghost clients | Fiabilidad baja: marca código de Fabric Loader y `oshi` |
| [Lafferrr ScreensharingGuide / SSTools](https://github.com/Lafferrr/ScreensharingGuide) | Guía abierta | Flujo completo de SS (expresiones DPS/CSRSS, USN, ADS, USB, suspensión de hilos, macros en dwm) | Métodos de detección de bypass (sección 8) | Recomienda ejecutar scripts remotos con `iex` y desactivar el antivirus: Amon no debe hacerlo |
| [Recaf](https://github.com/Col-E/Recaf) | Abierto (MIT) | Editor y decompilador de bytecode | Inspección manual de JAR sospechosos fuera de Amon | No es un escáner |
| Root, MeowClientFucker, Javaw-scanner, Atlas, Multiorb | Cerrados o inaccesibles | Según sus descripciones: memoria, DNS, "Hollow Detect", USN | Ninguno verificable | — |

**Expresiones regulares de la guía de Lafferrr** (DPS y CSRSS, para extensiones cambiadas y rutas ejecutadas):

```text
^!![A-Z]((?!Exe).)*$
^\\device\\harddiskvolume((?!Exe|dll).)*$
^\\device\\harddiskvolume[0-99]\\((?!exe).)*$
^\\device\\mup\\localhost\\*
^[A-Z]:\\.+\.(exe)$
^[A-Z]:\\.+\.(dll)$
^[a-z]:.+\.((?!exe|pyd|manifest|dll|config|\\|cpl|microsoft-|shell).)*$
```

**Lecciones aplicables a Amon (sin implementar):**

1. Leer `Zone.Identifier` (`HostUrl`) de los JAR de `mods`. Yarp asocia `doomsdayclient.com`, `prestigeclient.vip`, `198macros.com` y `dqrkis.xyz` a sus clientes.
2. Comparar el SHA-1 de cada mod con una lista local de hashes de Modrinth, sin red durante la SS, para detectar mods troyanizados como Argon.
3. Marcar `-javaagent:` desconocidos fuera de la lista permitida de Onyx; el tipo `jvmArg` ya existe.
4. Detectar JAR con muy pocas clases que cargan otro JAR anidado ("hollow shell" de Meow, "Hollow Detect" de Atlas).

## 7. Autoclickers y macros

### 7.1 Autoclickers

| Programa | Ejecutable | Configuración en disco | Fuente (clase) | Notas |
| --- | --- | --- | --- | --- |
| OP Auto Clicker | `AutoClicker.exe` (SourceForge `orphamielautoclicker`) | No documentada (la web solo dice que guarda los ajustes) | [opautoclicker.com](https://www.opautoclicker.com/) (oficial); hash en [Chocolatey](https://community.chocolatey.org/packages/autoclicker) (secundaria) | SHA-256 de la 3.0 en el JSON. Nombre compartido con Speed AutoClicker |
| GS Auto Clicker | `GSAutoClicker.exe` | No documentada | [goldensoft.org](https://www.goldensoft.org/) (oficial, v3.1.4); [freefixer](http://www.freefixer.com/library/file/GSAutoClicker.exe-153703/) (secundaria): `C:\Program Files (x86)\GSAutoClicker3\`, firmado por "Yang Cai" | La ruta en Program Files no se puede expresar con `path` |
| Speed AutoClicker | `AutoClicker.exe` (zip) | `%APPDATA%\SpeedAutoClickerV3` | [FAQ oficial](https://www.speedautoclicker.net/faq) | En el JSON (validado) |
| Free Auto Clicker | Instalador `autoclicker_setup.msi` | No documentada | [mediafreeware.com](http://www.mediafreeware.com/free-auto-clicker.html) (oficial) | Nombre genérico usado por varios programas |
| Auto Clicker (Polar) | Portable | No documentada | [MajorGeeks](https://www.majorgeeks.com/files/details/auto_clicker.html) (secundaria) | — |
| MurGee Auto Clicker | Instalador `setup.exe` | No documentada | [murgee.com](https://www.murgee.com/auto-clicker/) (oficial) | — |
| AutoHotkey (uso doble) | `AutoHotkey64.exe`, `AutoHotkey32.exe`, `AutoHotkeyUX.exe` (v2); `AutoHotkeyU64.exe` (v1) | `%ProgramFiles%\AutoHotkey` o `%LocalAppData%\Programs\AutoHotkey`; `HKCU\Software\AutoHotkey` | [Docs v2](https://www.autohotkey.com/docs/v2/Program.htm) (oficial) | Un `.exe` compilado guarda el script en el recurso `>AUTOHOTKEY SCRIPT<` ([NVISO](https://blog.nviso.eu/2023/07/20/the-soc-toolbox-analyzing-autohotkey-compiled-executables/)). zeezy marca `AUTOHOTKEY*.EXE` en Prefetch solo como aviso |
| Toad | `Toad.exe` | No documentada | [itch.io](https://steve987321.itch.io/autoclicker), [GitHub](https://github.com/Steve987321/toadclicker) (oficial) | Hecho para Minecraft |
| Clickers en Java | JAR con JNativeHook y `java.awt.Robot` | DLL nativa (ver 7.2) | [Kapcode/click](https://raw.githubusercontent.com/Kapcode/click/master/Click.java) (ejemplo) | `org.jnativehook.*` |

**Cadenas DPS de autoclickers** en AstroSS y Devyl. Son memoria del servicio DPS, no archivos. Las herramientas las asocian a un ejecutable concreto aunque se renombre; no se verificó de qué campo del PE sale la fecha:

- `.exe!2019/03/14:20:01:24` → OP AutoClicker (3.0)
- `.exe!2016/05/30:16:33:32` → GS AutoClicker
- `.exe!2019/07/05:07:17:50` → Speed AutoClicker (AstroSS); Devyl da otras fechas para Speed AutoClicker
- `.exe!2018/11/09:01:13:38` → GhostBytes
- `.exe!2018/10/21:19:34:21` → Ecstasy

### 7.2 JNativeHook: dónde deja la DLL

Fuente primaria: código oficial de `kwhat/jnativehook`.

| Versión | Paquete | Dónde extrae la DLL | Nombre resultante en Windows | Se borra |
| --- | --- | --- | --- | --- |
| 1.1 | `org/jnativehook/` | `File.createTempFile(...)` en `%TEMP%` ([código](https://raw.githubusercontent.com/kwhat/jnativehook/1.1/src/java/org/jnativehook/GlobalScreen.java)) | `JNativeHook_<dígitos>.dll` (deducido; hay una muestra real `JNativeHook_6120256879266977110.dll` en `AppData\Local\Temp` según [freefixer](https://www.freefixer.com/library/file/JNativeHook_6120256879266977110.dll-175359/)) | Sí, con `deleteOnExit` (si la JVM sale con normalidad) |
| 2.0 / 2.1 | `org/jnativehook/` | `java.io.tmpdir` ([código 2.1](https://raw.githubusercontent.com/kwhat/jnativehook/2.1/src/java/org/jnativehook/DefaultLibraryLocator.java)) | `JNativeHook-<versión>.<arch>.dll` o `JNativeHook-<SHA1 en mayúsculas>.<arch>.dll` (deducido) | No |
| 2.2.x | `com/github/kwhat/jnativehook/` | **Carpeta del JAR**, salvo `-Djnativehook.lib.path` ([código 2.2](https://raw.githubusercontent.com/kwhat/jnativehook/2.2/src/main/java/com/github/kwhat/jnativehook/DefaultLibraryLocator.java)) | `JNativeHook-<versión>.x86_64.dll` o `JNativeHook.x86_64.dll` (deducido) | No |

Propiedades del sistema relacionadas: `jnativehook.lib.name`, `jnativehook.lib.path` (2.2) y `jnativehook.lib.locator`. Si aparecen en la línea de comandos de Java, sirven como `jvmArg`.

JNativeHook (LGPL) también lo usan grabadores de macros y overlays legítimos. Su presencia prueba que se ejecutó una aplicación Java con hook global, no un clicker.

### 7.3 Software de macros: dónde guarda la configuración

| Software | Ruta | Clase | En el JSON |
| --- | --- | --- | --- |
| Logitech G HUB | `%LOCALAPPDATA%\LGHUB\settings.db` | Oficial ([soporte Logitech](https://support.logi.com/hc/en-us/articles/360048161973-Logitech-G-logo-loops-when-attempting-to-run-G-HUB)) | Sí |
| Logitech Gaming Software | `%LOCALAPPDATA%\Logitech\Logitech Gaming Software\profiles` | Foro ([Steam](https://steamcommunity.com/discussions/forum/12/1743346190285531465)) | Sí |
| Razer Synapse 3 | `%LOCALAPPDATA%\Razer\Synapse3\Log\Razer Synapse 3.log` (herramienta SS); macros en `C:\ProgramData\Razer\Razer Central\Accounts\RZR_<id>\Emily3\Macros` ([Razer Insider](https://insider.razer.com/general-discussion-6/synapse-3-path-to-macro-32937), foro) | Secundaria / foro | Solo el log |
| SteelSeries Engine 3 / GG | `%APPDATA%\steelseries-engine-3-client\Session Storage\000003.log`; `%ProgramData%\SteelSeries\SteelSeries Engine 3` ([foro](https://techenclave.com/threads/steelseries-engine-woes-after-update.199721)) | Secundaria / foro | Solo la carpeta en `%APPDATA%` |
| Corsair iCUE | `%APPDATA%\Corsair\CUE Backup` | Oficial ([notas de iCUE 5.21](https://www.corsair.com/ww/zh/explorer/patch-notes/icue/icue-521107/)) | Sí |
| Glorious Core | `C:\ProgramData\Glorious Core\userdata\<usuario>\data\MacroDB.db` | Secundaria | No (fuera de `userHome`) |
| Bloody 7 (A4Tech) | `C:\Program Files (x86)\Bloody7\Bloody7\UserLog\Mouse\TLcir_9EFF3FF4\language\Settings\EnvironmentVar.ini`; macros `.amc` (X7) y `.mgn` (Bloody 7) según una [tienda de macros](https://monecle.com/buy/47652) | Secundaria | No |
| ROCCAT Swarm | `%APPDATA%\ROCCAT\SWARM\macro\macro_list.dat`, `custom_macro_list.dat`; perfiles `.rkp` | Secundaria | Sí |
| Redragon | `%APPDATA%\REDRAGON\GamingMouse\macro.ini`, `config.ini` | Secundaria | Sí |
| ASUS ROG Armoury | `Documents\ASUS\ROG\ROG Armoury\common\macro` (`.GMAC`) | Secundaria | Sí |
| Otras (AYAX, KROM KOLT, SPC Gear, Xenon200, FANTECH VX7, MotoSpeed, M711, Alienware) | Rutas en `Program Files`, `ProgramData` o `Documents` | Secundaria | No |

Salvo que se indique otra fuente, la clase "secundaria" corresponde a [tempusernamedduck macros.c](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c).

**Cómo lo detectan las comunidades SS:**

- **Contenido de archivos** (tempusernamedduck):
  - `"durationMs":` en `settings.db` de G HUB.
  - `MacroClient:Delete` (macro borrada) y `turbo: true` en el log de Razer.
- **Memoria de procesos** (misma herramienta):
  - `lghub_agent.exe` con la expresión `durationms.+\"isDown\"`.
  - `Razer Synapse 3.exe` con `SetKeysPerSecond`.
  - `RazerCentralService.exe` con `Datasync: Status: COMPLETE Action: NONE Macros/`.
  - `SteelSeriesGGClient.exe` con `delay.+is_deleted`.
- **Guía de Lafferrr:**
  - Cadenas de macros en `dwm.exe` (por ejemplo `198Macros`).
  - MacroScanner: busca archivos `.ahk`/`.py` con palabras de autoclick.
- **YARA genérica de spokwn** para PE: `clicker`, `autoclick`, `clicking`, `String Cleaner`, `double_click`, `Jitter Click`, `Butterfly Click`. Es demasiado genérica para Amon.
- **Límite:** muchos ratones guardan perfiles y macros en su **memoria interna**. No encontrar archivos no descarta macros.

### 7.4 Indicadores propuestos de autoclickers, librerías y macros

Para casi todo el software de macros la fuerza es `weak`: su presencia solo prueba que el programa está instalado o se usó, no que haya una macro activa en Minecraft. Antes de añadirlos conviene decidir si Amon debe tratarlos como hallazgos informativos.

**JNativeHook (librería de hooks globales)** (`jnativehook`, dual-use)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| package | `com/github/kwhat/jnativehook/` | weak | primaria | sí | [fuente](https://raw.githubusercontent.com/kwhat/jnativehook/2.2/src/main/java/com/github/kwhat/jnativehook/DefaultLibraryLocator.java) | Código oficial 2.2.x. La usan autoclickers en Java y también programas legitimos: su presencia en un JAR de mods es sospechosa, no prueba nada. |
| package | `org/jnativehook/` | weak | primaria | sí | [fuente](https://raw.githubusercontent.com/kwhat/jnativehook/2.1/src/java/org/jnativehook/DefaultLibraryLocator.java) | Paquete de las versiones 1.x-2.1. 2.0/2.1 extraen la DLL a java.io.tmpdir como 'JNativeHook-<versión>.<arch>.dll' sin borrarla; 1.1 usa createTempFile('JNativeHook_') con deleteOnExit; 2.2 la extrae junto al JAR. |

**Speed AutoClicker** (`speed-autoclicker`, autoclicker)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `AppData/Roaming/SpeedAutoClickerV3` | medium | primaria | sí | [fuente](https://www.speedautoclicker.net/faq) | (relativo a userHome) FAQ oficial: escribir '%appdata%' y buscar la carpeta 'SpeedAutoClickerV3' para reiniciarlo. Prueba instalación o uso pasado, no uso durante la partida. |

**OP Auto Clicker** (`op-autoclicker`, autoclicker)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| sha256 | `3406f9805dac7d055c2d0eb3f0c0dcd9caa18b180db46378c408a203438cb57b` | strong | secundaria | no | [fuente](https://community.chocolatey.org/packages/autoclicker) | Checksum sha256 de AutoClicker.exe en el paquete Chocolatey 3.0.0.20230225 (descarga oficial de SourceForge). Solo esa compilación. El nombre AutoClicker.exe lo comparte Speed AutoClicker: no usar el nombre como firma. |

**AutoHotkey** (`autohotkey`, dual-use)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `>AUTOHOTKEY SCRIPT<` | medium | secundaria | no | [fuente](https://blog.nviso.eu/2023/07/20/the-soc-toolbox-analyzing-autohotkey-compiled-executables/) | (codificación utf16le/ascii; ámbito raw) Nombre del recurso RCDATA que guarda el script en un .exe compilado con AutoHotkey (un 'clicker.exe' compilado lo tendria). Los nombres de recurso PE se guardan en UTF-16LE. Herramienta de uso doble. |
| path | `AppData/Local/Programs/AutoHotkey` | weak | primaria | sí | [fuente](https://www.autohotkey.com/docs/v2/Program.htm) | (relativo a userHome) Directorio por defecto de una instalación 'current user' de v2 (la de 'all users' va a Program Files, fuera de userHome). |

**Autoclickers externos (varios)** (`generic-autoclicker`, autoclicker)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| string | `Sapphire LITE Clicker` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) YARA 'Specifics A' ($p). |
| string | `The clicker code was done by Nightbot. I skidded it :)` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/spokwn/BAM-parser/HEAD/yara/yara.cpp) | (codificación ascii/utf16le; ámbito raw) YARA 'Specifics A' ($l). |
| string | `me/tojatta/clicker` | medium | secundaria | no | [fuente](https://raw.githubusercontent.com/Jammy108/AstroSS/HEAD/Astro/config.py) | (grupo legacy; ámbito raw/entries) AstroSS 'Tojatta Clicker #1' (clicker Java antiguo). |

**Logitech G HUB** (`logitech-ghub`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| path | `AppData/Local/LGHUB/settings.db` | weak | primaria | sí | [fuente](https://support.logi.com/hc/en-us/articles/360048161973-Logitech-G-logo-loops-when-attempting-to-run-G-HUB) | (relativo a userHome) Soporte oficial de Logitech: los ajustes de G HUB están en C:\Users\[USERNAME]\AppData\Local\LGHUB\settings.db. Solo prueba que G HUB está instalado; las macros hay que revisarlas a mano. |
| string | `"durationMs":` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (codificación ascii/utf16le; ámbito raw) tempusernamedduck/screenshare-tool busca esta cadena en settings.db como rastro de macro. En Amon solo sirve si settings.db se añade a scan.extraScanPaths. |

**Logitech Gaming Software** (`logitech-lgs`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `AppData/Local/Logitech/Logitech Gaming Software/profiles` | weak | secundaria | no | [fuente](https://steamcommunity.com/discussions/forum/12/1743346190285531465) | (relativo a userHome) Foro de Steam (2018) citando el foro de Logitech. |

**Razer Synapse 3** (`razer-synapse`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| path | `AppData/Local/Razer/Synapse3/Log/Razer Synapse 3.log` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (relativo a userHome) La herramienta busca 'MacroClient:Delete' (macro borrada) y 'turbo: true' en este log. |
| string | `MacroClient:Delete` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (codificación ascii/utf16le; ámbito raw) Contenido del log de Synapse 3; solo útil si el log entra en extraScanPaths. |

**SteelSeries Engine 3** (`steelseries`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `AppData/Roaming/steelseries-engine-3-client` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (relativo a userHome) La herramienta revisa 'Session Storage\000003.log' dentro de esta carpeta. |

**ROCCAT Swarm** (`roccat-swarm`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| path | `AppData/Roaming/ROCCAT/SWARM/macro/macro_list.dat` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (relativo a userHome) También custom_macro_list.dat. |

**Redragon Gaming Mouse** (`redragon`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| path | `AppData/Roaming/REDRAGON/GamingMouse/macro.ini` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (relativo a userHome) |

**ASUS ROG Armoury** (`asus-armoury`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `Documents/ASUS/ROG/ROG Armoury/common/macro` | weak | secundaria | no | [fuente](https://raw.githubusercontent.com/tempusernamedduck/screenshare-tool/HEAD/Screenshare%20Tool/checks/macros/macros.c) | (relativo a userHome) Archivos .GMAC. Documents puede estar redirigido a OneDrive. |

**Corsair iCUE** (`corsair-icue`, macro)

| Tipo | Valor exacto | Fuerza | Procedencia | Validado | Fuente | Nota |
| --- | --- | --- | --- | --- | --- | --- |
| config | `AppData/Roaming/Corsair/CUE Backup` | weak | primaria | sí | [fuente](https://www.corsair.com/ww/zh/explorer/patch-notes/icue/icue-521107/) | (relativo a userHome) Notas oficiales de iCUE 5.21: copias de seguridad en esa carpeta. Solo prueba que iCUE está instalado. |

## 8. Bypasses de SS: artefactos y detección

Fuentes de Windows:

- [Microsoft 1102](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-1102), [Microsoft 4616](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4616) y [EnablePrefetcher](https://learn.microsoft.com/en-us/previous-versions/windows/embedded/bb499146(v=winembedded.5)).
- [Sygnia: PCA en Windows 11 22H2](https://www.sygnia.co/blog/new-windows-11-pca-artifact/), [winreg-kb: BAM](https://winreg-kb.readthedocs.io/en/latest/sources/system-keys/Background-activity-moderator.html), [SANS ISC: Prefetch](https://isc.sans.edu/diary/Forensic+Value+of+Prefetch/29168) y [Magnet: Amcache/Shimcache](https://www.magnetforensics.com/blog/shimcache-vs-amcache-key-windows-forensic-artifacts/).
- [Elastic: borrado del USN con fsutil](https://www.elastic.co/docs/reference/security/prebuilt-rules/rules/windows/defense_evasion_delete_volume_usn_journal_with_fsutil) y [Sigma: Eventlog Cleared (104)](https://detection.fyi/sigmahq/sigma/windows/builtin/system/microsoft_windows_eventlog/win_system_eventlog_cleared/).

Fuentes de Minecraft: [guía de Lafferrr](https://raw.githubusercontent.com/Lafferrr/ScreensharingGuide/HEAD/windowsHackChecking.html) y [Pika Network](https://support.pika-network.net/articles/screenshare-info).

| Técnica | Artefactos que deja | Cómo se detecta | Fuente |
| --- | --- | --- | --- |
| Renombrar el JAR o cambiar la extensión (`.jar` → `.png`/`.txt`) | Prefetch de `JAVAW.EXE` (lista los archivos que cargó), PCA, cadenas de csrss/DPS con rutas de extensión no estándar | Firmas por contenido (Amon ya lo hace); expresiones de "extensión modificada" en csrss/DPS; analizar `JAVA*.EXE-*.pf` | Lafferrr; lilith `DoomsdayFinder.ps1` |
| Loader con nombre o tamaño aleatorio (Vape, Doomsday) | El mismo `.exe`/`.jar` en `Downloads`; BAM/Prefetch/PCA con nombre aleatorio | Ejecución de un binario desconocido justo antes del juego; los hashes no sirven | docs.vape.gg; doomsdayclient.com |
| Ejecutar desde USB, FAT32/exFAT o unidad externa | `HKLM\SYSTEM\CurrentControlSet\Enum\USBSTOR`, `MountPoints2` del usuario, BAM con ruta `\Device\HarddiskVolumeN` de otro volumen | USBDeview o registro. FAT32/exFAT no tienen journal: la guía de Lafferrr lo trata como baneo directo | Lafferrr; Magnet (USB) |
| Borrar archivos (CCleaner, sdelete, papelera) | USN `FILE_DELETE`; fecha de modificación de `$Recycle.Bin`; Prefetch y BAM de la herramienta de borrado; SHA-1 en Amcache | USN alrededor del inicio de la SS; papelera modificada después de lanzar el juego | Lafferrr; Magnet |
| Manipular Prefetch | `EnablePrefetcher` ≠ 3 en `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters`; SysMain desactivado; `.pf` de solo lectura (USN `BASIC_INFO_CHANGE`); `.pf` de JAVAW borrado o renombrado tras el inicio de sesión | Leer el valor de registro, atributos de `.pf` y eventos USN | Microsoft; Lafferrr; lilith `Services.ps1` |
| Desactivar o suspender servicios (SysMain, PcaSvc, DPS, EventLog, BAM, DcomLaunch, DusmSvc, CDPUserSvc) | Eventos 7040 (cambio de tipo de inicio) y 7036 (parada); valor `Start` en `HKLM\SYSTEM\CurrentControlSet\Services\<svc>`; servicio reiniciado tras el inicio de sesión; hilos suspendidos con el servicio "Running" | Comprobar estado e inicio de cada servicio y sus hilos (System Informer). Pika lo castiga como intento de bypass | Pika; Lafferrr; Splunk/LogRhythm (7040) |
| Borrar el USN Journal (`fsutil usn deletejournal`) | Journal recién creado o muy corto; Prefetch, BAM y PCA de `fsutil.exe` | Evidencia de ejecución de `fsutil` con `usn` y `deletejournal` | Elastic. lilith usa "Application 3079" como "USN Journal cleared", **sin confirmación oficial** |
| Borrar registros de eventos | 1102 (Security, Microsoft-Windows-Eventlog) y 104 (System) | Buscar 1102 y 104 en la ventana de la sesión | Microsoft; Sigma |
| Cambiar la hora del sistema | 4616 con `PreviousTime`/`NewTime`. Lo normal es `LOCAL SERVICE` con `svchost.exe` | Cualquier 4616 de otro usuario o proceso | Microsoft |
| String cleaners y limpieza de memoria | Prefetch de `SYSTEMINFORMER.EXE`/`PROCESSHACKER.EXE`; patrón residual `) (0x` en volcados; binarios con cadenas `String Cleaner`; `LSquad.dll` (AstroSS); "Phantom String Cleaner" (Devyl, DPS) | Prefetch de herramientas de memoria cerca de la SS; YARA genérica | tempusernamedduck; Lafferrr; spokwn |
| Inyección y argumentos JVM | `-javaagent:`, `-Xbootclasspath/p:`/`/a:`, `-agentpath:`, `-agentlib:jdwp`, `-Dfabric.addMods=`, `-Dfabric.loadMods=`, `-Dfml.coreMods.load=`; mods cargados desde `%TEMP%` o `Downloads` | `jvmArg` en perfiles y procesos (Amon); lista permitida de Onyx | Onyx; Yarp; Lafferrr |
| Autodestrucción (self-destruct) y "hollow" | Cadenas `Self-Destructed successfully.` (AstroSS) y `Destructed Succesfully` (zeezy); JAR casi vacío que cargaba otro | USN (borrados), Prefetch de JAVAW, detección de JAR "hueco" | AstroSS; zeezy; Meow |
| Alternate Data Streams | USN `STREAM_CHANGE` en un archivo inocuo | `dir /r`, AlternateStreamView | Lafferrr |
| Mods legítimos troyanizados (Argon, copias de `balm` o `immediatelyfast`) | `fabric.mod.json` de un mod real con paquetes extra | Comparar el hash con Modrinth; paquetes inyectados | zeezy; Habibi; Meow |
| Ventanas *stream-proof* (Vape Lite, overlays externos) | Ventanas con afinidad de captura excluida | Enumerar ventanas y su afinidad (OmniSS) | OmniSS; web de Vape Lite |

**Artefactos de ejecución de Windows** (detalle en `01-artefactos-windows.md` si ya existe):

- **PCA (Windows 11 22H2+):** `C:\Windows\appcompat\pca\PcaAppLaunchDic.txt` (ANSI, `ruta|hora UTC`), `PcaGeneralDb0.txt` y `PcaGeneralDb1.txt` (UTF-16LE). Solo registra lanzamientos desde la GUI, no `java -jar` desde consola.
- **BAM:** `HKLM\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings\<SID>`. El valor es un FILETIME en los primeros 8 bytes y confirma ejecución por usuario.
- **Prefetch:** hasta 8 marcas de tiempo y 1024 archivos.
- **Amcache:** prueba existencia y SHA-1, no ejecución, en Windows 10+.

## 9. Fuentes principales

**Oficiales:**

- [docs.vape.gg](https://docs.vape.gg/)
- [Raven bS en Codeberg](https://codeberg.org/strangerrrrs/raven-bS)
- [inertia-client-base](https://github.com/THEREALWWEFAN231/inertia-client-base) e [Inertia-Issues](https://github.com/THEREALWWEFAN231/Inertia-Issues)
- [docs.slinky.gg](https://docs.slinky.gg/basics/get-started/)
- [scripting.breeze.rip](https://scripting.breeze.rip/getting_started.md)
- [FDPClient](https://github.com/SkidderMC/FDPClient), [GameSense](https://github.com/IUDevman/gamesense-client) y [JNativeHook](https://github.com/kwhat/jnativehook)
- [Speed AutoClicker FAQ](https://www.speedautoclicker.net/faq) y [AutoHotkey docs](https://www.autohotkey.com/docs/v2/Program.htm)
- [Logitech](https://support.logi.com/hc/en-us/articles/360048161973-Logitech-G-logo-loops-when-attempting-to-run-G-HUB) y [Corsair](https://www.corsair.com/ww/zh/explorer/patch-notes/icue/icue-521107/)
- Webs de [Doomsday](https://doomsdayclient.com/), [Prestige](https://prestigeclient.vip/), [Entropy](https://entropy.club/) y [Slinky](https://slinky.gg/)

**Código filtrado o reconstruido:**

- [SigmaRemap](https://github.com/xquj/SigmaRemap) y [sigma_buildable](https://github.com/neilhuang007/sigma_buildable)
- [RiseClient 6.2.4](https://github.com/CykXd/RiseClient)
- [RandomForks/novoline](https://github.com/RandomForks/novoline)
- [argon-b1.1-decompiled](https://github.com/06gw/argon-b1.1-decompiled)
- [TenacityRC](https://github.com/lo1am0n/TenacityRC) y [Tenacity 4.0](https://github.com/Xicopannt/Tenacity-Client-4.0-Eclipse-Ready)

**Herramientas SS:** las de la tabla de la sección 6, más el [gist de Azran](https://gist.github.com/synthedev2/bfd1d6af8d4456f803e2c6822cd382df) y [andreaonorato/Minecraft-Cheat-Scanner](https://github.com/andreaonorato/Minecraft-Cheat-Scanner).

**Forense de Windows:** las enlazadas en la sección 8.
