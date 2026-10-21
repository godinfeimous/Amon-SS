# Seguridad

## Versiones con soporte

| Versión | Soporte |
| ------- | ------- |
| 1.1.x   | Sí      |
| 1.0.x   | No      |

## Informar de una vulnerabilidad

Usa **GitHub Security Advisories** del repositorio ("Report a vulnerability") para informar en privado. No abras issues públicos con detalles explotables. Incluye versión, PowerShell usado, pasos para reproducir e impacto. Se responderá en un plazo razonable y se publicará una versión corregida con su SHA-256.

## Principios de diseño

- **Solo lectura.** Ningún módulo escribe, mueve, restaura ni elimina artefactos del equipo analizado. Las únicas escrituras son los ajustes del propio Amon SS (`%LOCALAPPDATA%\AmonSS\settings.json`) y los reportes, que la revisión automática exporta al terminar (y el operador puede volver a exportar).
- **Sin red.** No hay telemetría, webhooks ni envío de archivos. La única conexión posible es la comprobación de actualizaciones, y solo cuando el operador la pide en Ajustes.
- **Sin tocar rutas de red.** Las rutas que salen de artefactos (destinos de `.lnk`, `-javaagent`, JAR citados en Prefetch o Recent, `gameDir` de `launcher_profiles.json`, `--gameDir` de procesos Java...) solo se usan si son rutas absolutas de una unidad local, fija o extraíble (`Test-AmonLocalPath`). Una ruta `\\servidor\recurso` o de una unidad de red no se comprueba ni se escanea, así que no genera tráfico SMB/WebDAV ni autenticación NTLM.
- **Sin secretos.** No se leen archivos de cuentas de launchers. Los tokens de sesión (`--accessToken`, JWT, propiedades `-D…password/token…`) se ocultan antes de mostrarse o exportarse.
- **Privacidad.** Prefetch, BAM, PCA, ShimCache, Recent, UserAssist, papelera y USN muestran solo artefactos relacionados con la revisión; el resto se cuenta. BAM incluye las entradas de todas las cuentas del equipo y se filtra con el mismo criterio. Los nombres originales de documentos personales enviados a la papelera se ocultan, y un Prefetch borrado de un programa no relacionado se cuenta sin mostrar su nombre. Un comprimido o un log no es relevante solo por su extensión.
- **Memoria de procesos: solo lectura y solo coincidencias.** El escáner de memoria abre los `java.exe`/`javaw.exe` en ejecución con `PROCESS_QUERY_INFORMATION | PROCESS_VM_READ` (o `PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ` si no se concede el primero) y lee con `ReadProcessMemory` las regiones comprometidas y legibles. No escribe, no suspende el proceso, no vuelca la memoria a disco y no guarda nada de su contenido: solo qué firmas aparecen y en qué dirección. PCA lee del mismo modo la memoria privada del `explorer.exe` del usuario actual y solo conserva el texto que sigue al marcador `,MonitorProcess,` (las rutas de las trazas `PcaClient`). El inspector de procesos no lee memoria: solo la lista de módulos cargados (rutas de DLL).
- **Elevación solo a petición.** Si Amon SS no se ejecuta como administrador, ofrece reabrirse como tal; solo lo hace si el revisor pulsa `A`, siempre a través del aviso UAC de Windows, y `-NoElevate` desactiva la oferta. Rechazar el aviso no detiene la revisión.
- **Sin pantalla de consentimiento, con constancia.** El consentimiento se rige por los términos de la SS del servidor. Amon SS no lo pregunta, pero cada reporte registra en su alcance autorizado quién ejecutó la revisión, en qué equipo, cuándo y si fue como administrador.
- **Sin evasión.** No se desactivan antivirus, auditorías ni políticas; no hay técnicas de ocultación ni persistencia. El módulo de evasión solo consulta el estado de servicios y registros de eventos.
- **Datos no confiables.** Los nombres de archivo y líneas de log se limpian de caracteres de control antes de pintarse (evita inyección de secuencias ANSI en la terminal del revisor). Además, las cajas de la terminal solo dejan pasar secuencias de color SGR (nada de borrado de pantalla, movimiento del cursor, OSC ni BEL) y sanean su título. El reporte TXT elimina los caracteres de control y los saltos de línea incrustados en los datos, de modo que un artefacto no puede falsificar líneas del reporte, y el HTML escapa todos los valores.

## Integridad de la distribución

- El comando de instalación fija una versión concreta y **rechaza el ZIP si su SHA-256 no coincide** con el valor publicado; solo entonces lo extrae, quita la marca de Internet a esos archivos y ejecuta `Start-AmonSS.ps1`.
- `-ExecutionPolicy RemoteSigned` se aplica **solo al proceso** lanzado por ese comando; no cambia ninguna política persistente. Si una directiva de grupo impone la política, PowerShell la respeta y el comando no podrá ejecutar scripts: usa entonces una release firmada (`tools\Sign-Release.ps1`) o pide al administrador una ejecución autorizada. La copia que Amon SS abre como administrador usa el mismo `-ExecutionPolicy RemoteSigned` de proceso.
- Cada release incluye `Integrity.psd1` en la raíz del paquete, con el SHA-256 de **todos** sus archivos. `tools\Build-Release.ps1` lo genera después de firmar los scripts (si se firma la release) y después firma también `Integrity.psd1`.
- En ejecución, Amon SS lee una sola vez los bytes de cada archivo protegido y verifica esos mismos bytes antes de usarlos (`Read-AmonVerifiedText`/`Read-AmonVerifiedBytes`): los `.cs` antes de compilarlos, cada `signatures\*.json` y `config\settings.json`. Una firma añadida o borrada también impide cargar el conjunto de firmas (`Assert-AmonPackageFolder` y la propia verificación). Si algo no coincide, la operación que necesita ese archivo falla con "Integridad del paquete comprometida: ..." y nunca usa el contenido alterado: dentro de un módulo, el fallo queda aislado y registrado en el reporte; fuera de un módulo (la configuración al arrancar, o la carga de firmas al abrir un módulo desde el menú), Amon SS termina con ese error.
- Una release sin `Integrity.psd1` no arranca ("Paquete incompleto: falta Integrity.psd1. ..."). Una copia de desarrollo del repositorio no tiene manifiesto y no comprueba nada.
- `Start-AmonSS.ps1 -VerifyPackage` compara cada archivo de la instalación con `Integrity.psd1` (incluidos los scripts, `themes.json` y la documentación); en una release, la misma comparación se hace al arrancar y un paquete alterado no llega a analizar nada y termina con código `0` si todo está íntegro o `1` si no.
- Amon SS no comprueba por sí mismo la firma Authenticode de `Integrity.psd1`. Sin firma, el manifiesto detecta cambios posteriores a la extracción, pero quien pueda escribir en la carpeta también podría regenerarlo: en entornos exigentes usa una release firmada y verifica las firmas con `Get-AuthenticodeSignature` (ver [docs/INSTALL.md](docs/INSTALL.md#c-scripts-firmados-entornos-allsigned)).
- Los reportes se acompañan de un manifiesto `.sha256`; anota el hash fuera del equipo analizado (p. ej. en el ticket) para poder comprobar después que no se alteró.

## Modelo de amenazas y límites

Amon SS se ejecuta en el equipo de la persona revisada. Alguien con control total de ese equipo (administrador, rootkit, driver, PowerShell o .NET modificados) puede ocultar o falsear lo que la herramienta ve, también la memoria de los procesos. Los resultados son evidencias a valorar por una persona, no una prueba irrefutable, y nunca deben usarse para sanciones automáticas. Consulta [docs/LIMITATIONS.md](docs/LIMITATIONS.md).
