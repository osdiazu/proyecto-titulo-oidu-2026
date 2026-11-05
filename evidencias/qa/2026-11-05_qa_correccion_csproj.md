# Informe QA - Corrección de comentarios XML en .csproj - 2026-11-05

Revisor: agente `qa` (revisión independiente). Tipo de validación: solo local, en la estación de trabajo. No se ejecutó ninguna acción en Azure ni contra la base de datos.

## 1. Alcance revisado

- Archivos modificados según el desarrollador:
  - `src/Cobranza.Api/Cobranza.Api.csproj`
  - `src/Cobranza.Functions/Cobranza.Functions.csproj`
- Referencia de comparación: commit `34ec0a0` (HEAD), rutas `Repositorio_Cobranza_Automatizada_S10-S15/src/...`. La carpeta `src/` no tiene seguimiento en git.
- Evidencias del desarrollador en `evidencias/desarrollo/`: `2026-11-05_dotnet_info.txt`, `2026-11-05_restore.txt`, `2026-11-05_build.txt`, `2026-11-05_test.txt`, `2026-11-05_registro_errores.md`.
- Resto del árbol copiado desde HEAD: `Cobranza.slnx`, `README.md`, `docs/consultas_kql_s1*.kql`, `infra/`, `pruebas/`, `scripts/`, `sql/`, `src/` (sin `bin/` ni `obj/`).

Método (todo de solo lectura, salvo la reejecución de restore/build/test, que solo regenera `obj/` y `bin/`):
1. `git show HEAD:<ruta>` hacia el scratchpad y `git diff --no-index` contra la copia de trabajo.
2. Conteo de CR/LF, BOM y caracteres no ASCII en las versiones de HEAD y de trabajo.
3. Análisis del XML con `python -I` (`xml.dom.minidom`) y búsqueda por expresión regular de `--` dentro de `<!-- ... -->`.
4. Comparación de `git hash-object --no-filters` de cada archivo de trabajo con el hash del blob en HEAD, para los 46 archivos del subárbol `Repositorio_Cobranza_Automatizada_S10-S15/`. Se usó este método porque `core.autocrlf=true` hace que `git archive` convierta a CRLF y genere falsas diferencias.
5. Fechas de modificación (`find -newer`, `ls --time-style=full-iso`).
6. Se volvieron a ejecutar `dotnet restore Cobranza.slnx`, `dotnet build Cobranza.slnx --no-restore` y `dotnet test Cobranza.slnx --no-build`, con las salidas en el scratchpad (no se sobrescribieron las evidencias del desarrollador).
7. Revisión de `obj/project.assets.json` (cadena de dependencias) y de `Microsoft.Azure.Functions.Worker.Sdk.targets` 2.0.0, línea 78.

## 2. Resultados de las verificaciones pedidas

| # | Verificación | Resultado | Evidencia |
| --- | --- | --- | --- |
| V1.a | Una sola línea cambiada en cada `.csproj` | CUMPLE | `git diff --no-index --stat`: `1 insertion(+), 1 deletion(-)` en ambos archivos. Solo cambió la línea 5, dentro del comentario de cabecera, con el texto declarado. |
| V1.b | No queda `--` dentro de ningún comentario XML | CUMPLE | La búsqueda por expresión regular da 0 comentarios con `--` en Api, Functions y Comun. |
| V1.c | XML bien formado | CUMPLE | `minidom.parse` correcto en los 3 `.csproj`. Como control, la versión de HEAD de Api falla con `ExpatError: not well-formed (invalid token): line 5, column 65`, lo que confirma el defecto original. |
| V1.d | Codificación y finales de línea iguales a HEAD | CUMPLE | HEAD y trabajo: ASCII, sin BOM (primeros bytes `3C 50 72`), CR=0. LF=24 (Api) y LF=41 (Functions) en ambas versiones. |
| V2 | No se modificaron otros archivos fuera de `evidencias/` | CUMPLE | De los 46 archivos de HEAD, solo los 2 `.csproj` tienen un hash distinto. No hay archivos de trabajo que no estén en HEAD (salvo `bin/`, `obj/` y `evidencias/`). Los archivos versionados en la raíz (`CLAUDE.md`, `.claude/`, `docs/`) no tienen cambios en git. Fechas: los `.csproj` son de 18:10:52; el resto del código, de 17:54:42 (copia inicial). |
| V3.a | Códigos de salida del registro | CUMPLE | Reejecución: restore=1, build=1, test=0, igual que el registro. |
| V3.b | Errores NU1902/NU1903 (System.Security.Cryptography.Pkcs 9.0.0) | CUMPLE | Restore: 4 errores (Api y Functions). Build: 2 errores (Api), los mismos GHSA-2fmv-rv2c-59x7 y GHSA-846f-f764-76mx. La causa declarada se confirma en `project.assets.json`: `Microsoft.Data.SqlClient/6.0.1 -> System.Security.Cryptography.Pkcs 9.0.0` en ambos proyectos, y `TreatWarningsAsErrors=true` en ambos `.csproj`. |
| V3.c | Error del SDK de Functions | CUMPLE | `Microsoft.Azure.Functions.Worker.Sdk.targets(78,5): error : Invalid combination of TargetFramework and AzureFunctionsVersion is set.` aparece en la reejecución. La línea 78 del targets emite ese error cuando `_ToolingSuffix` está vacío. El registro lo presenta como causa "probable", sin afirmarla, lo que es correcto. |
| V3.d | Total de build: 3 errores, 0 advertencias; solo compila Comun | CUMPLE | Igual en la reejecución (`0 Advertencia(s)`, `3 Errores`). |
| V3.e | Aclara que `dotnet test` con 0 no ejecutó pruebas | CUMPLE | El registro dice: "No se ejecutó ninguna prueba; el 0 no significa que las pruebas pasaron". La salida de la reejecución también está vacía (0 bytes) y la carpeta `tests/` no existe. |
| V4.a | Español sin emojis | CUMPLE | En el registro, los únicos caracteres no ASCII son á, í, ó y ú. |
| V4.b | Sin secretos | CUMPLE | La búsqueda de `password`, `secret`, `AccountKey`, `endpoint=` y `token` en `evidencias/desarrollo/` no encontró nada. |
| V4.c | Distingue validado localmente de desplegado | CUMPLE | Sección 5 del registro: "Validado localmente: no", "Desplegado en Azure: no". |
| V4.d | Registra qué cambió, por qué, en qué archivo y con qué evidencia | CUMPLE CON OBSERVACIÓN | Incluye el qué, el porqué, el archivo y la línea, el diff y la tabla de evidencias. Observaciones O1 y O2. |

## 3. Lista de revisión general del agente QA

| Punto | Resultado | Comentario |
| --- | --- | --- |
| 1. Trazabilidad | CUMPLE | Responde a CLAUDE.md, sección 7 ("Primer paso: dotnet restore, dotnet build, dotnet test y registrar errores") y al paso 1 de la secuencia de despliegue (sección 10). |
| 2. Coherencia con la arquitectura y las decisiones | CUMPLE | El cambio solo afecta un comentario. No altera paquetes, TFM (`net10.0`), `AzureFunctionsVersion` ni el diseño. No hay regresiones a diseños descartados. |
| 3. Código .NET | NO CUMPLE (estado heredado, fuera del alcance de la corrección) | La solución no compila (3 errores) y no hay pruebas. Está documentado correctamente; no es un defecto del cambio revisado. Las reglas D4 y D6, los límites de ACS y RNF-05 no se revisaron en esta tarea (NO VERIFICADO). |
| 4. Bicep y scripts | NO APLICA | Sin cambios en `infra/` ni en `scripts/`. |
| 5. SQL | NO APLICA | Sin cambios en `sql/`. |
| 6. Seguridad | CUMPLE (alcance limitado) | Sin secretos. Se registran las vulnerabilidades NU1902/NU1903 en una dependencia transitiva; están pendientes de corrección (ver O3). |
| 7. Continuidad | NO APLICA | |
| 8. Documentación y evidencias | CUMPLE CON OBSERVACIONES | O1, O2. |
| 9. Pruebas de despliegue P01-P37 | NO APLICA | No hay nada desplegado en Azure. |

## 4. Hallazgos

| Id | Severidad | Ubicación | Descripción | Recomendación | Corresponde a |
| --- | --- | --- | --- | --- | --- |
| O1 | Baja | `evidencias/desarrollo/2026-11-05_restore.txt`, `_build.txt`, `_test.txt` | Los archivos de salida no incluyen el comando ejecutado, la hora ni el código de salida. Esos datos solo aparecen en el `.md`. `_test.txt` está vacío (0 bytes), por lo que no deja constancia del comando que lo generó. QA confirmó los valores al reejecutar. | En las próximas evidencias, anteponer a cada salida una cabecera con el comando, la fecha y hora y una línea final con el código de salida (`echo "exit=$?"`). | desarrollador |
| O2 | Baja | `evidencias/desarrollo/2026-11-05_registro_errores.md`, sección 1 | El motivo ("MSBuild no podía leer los proyectos") no tiene como evidencia la salida original de `dotnet build` anterior a la corrección. QA corroboró el defecto de forma independiente: la versión de HEAD no es XML válido (línea 5, columna 65). | En correcciones futuras, guardar la salida del error previo antes de corregir. | desarrollador |
| O3 | Media (informativa, estado heredado, no causado por este cambio) | `src/Cobranza.Api/Cobranza.Api.csproj`, `src/Cobranza.Functions/Cobranza.Functions.csproj` | Quedan 5 errores que bloquean la compilación: NU1902/NU1903 (Pkcs 9.0.0 a través de Microsoft.Data.SqlClient 6.0.1, con vulnerabilidad de gravedad alta) y la combinación TFM/AzureFunctionsVersion no admitida por Worker.Sdk 2.0.0. Bloquean el paso 1 de la secuencia de la semana 11. | Tratarlos en una tarea separada, con validación previa del `arquitecto` (implica cambiar versiones de paquetes). No suprimir NU1902/NU1903 con `NoWarn`. | desarrollador / arquitecto |
| O4 | Baja (informativa, fuera de alcance) | Raíz del repositorio | No existen archivos que CLAUDE.md, sección 7, lista como esperados: `infra/main.bicep`, `infra/main.bicepparam`, `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql`, `scripts/desplegar.sh`, `scripts/desplegar_sql.sh`, `scripts/verificar_despliegue.sh`, `scripts/validar_direccionamiento.py`, `docs/GUIA_DESPLIEGUE.md`. Tampoco estaban en HEAD. `s12_endurecer.sh` está en `scripts/s12_endurecer.sh`. | Informar al equipo para que lo confirme (probablemente están en `Implementacion_S10_Anexos.zip`). No recrearlos. | equipo / arquitecto |

Nota: la reejecución de QA regeneró archivos en `src/*/obj/` (restore) sin modificar fuentes ni evidencias. El texto nuevo usa "opcion" sin tilde, igual que el resto del comentario (ASCII). Es coherente con la codificación original y no es un hallazgo.

No hay hallazgos Críticos ni Altos atribuibles al cambio revisado.

## 5. Veredicto

APROBADO CON OBSERVACIONES.

El cambio cumple el alcance pedido: una línea por archivo, solo dentro del comentario, XML válido, misma codificación y mismos finales de línea, sin otros archivos modificados. El registro de errores coincide con las salidas reales. Las observaciones O1 y O2 son de forma de la evidencia. O3 y O4 son estado heredado del repositorio, ajeno a esta corrección, y quedan pendientes como tareas separadas.
