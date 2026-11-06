# Informe QA 06-11-2026: revisión previa al commit de los cambios del 05-11-2026

Revisor: agente `qa` (revisión independiente). No se modificó ningún archivo del proyecto; este informe es el único archivo creado. No se ejecutó nada contra Azure (no hizo falta repetir el what-if). Comandos usados: `git status/diff/log/ls-files/check-ignore`, `dotnet build`, `dotnet test`, `dotnet list package --vulnerable`, `az bicep version/build/lint/build-params` (salida a una carpeta temporal `mktemp -d`, borrada al terminar), `bash -n`, `grep`, `find`.

Base: `main` en `9dc69de`, cambios sin commit. Informe anterior: `evidencias/qa/2026-11-05_revision_whatif_brazilsouth_adr001.md` (RECHAZADO por C-01 y A-01).

## 1. Alcance revisado

| Grupo | Archivos |
| --- | --- |
| Modificados (11) | `.gitignore`, `CLAUDE.md`, `Cobranza.slnx`, `scripts/s10_configurar_jobs.sh`, `src/Cobranza.Api/Cobranza.Api.csproj`, `src/Cobranza.Functions/Cobranza.Functions.csproj`, `src/Cobranza.Functions/Funciones/NotificacionesFunction.cs`, `src/Cobranza.Functions/Modelos/OpcionesCobranza.cs`, `src/Cobranza.Functions/Program.cs`, `src/Cobranza.Functions/Servicios/RepositorioCobranza.cs`, `src/Cobranza.Functions/local.settings.example.json` |
| Nuevos (56, `git status -uall`) | `docs/adr/ADR-001-...md`, `docs/seguridad/politica_credenciales_y_accesos.md`, `infra/main.bicep`, `infra/main.bicepparam`, `infra/entorno.ejemplo.env`, `scripts/eliminar_entorno.sh`, `sql/01_esquema_cobranza.sql`, `sql/02_identidades_y_permisos.sql`, `src/Cobranza.Functions/Servicios/IRepositorioNotificaciones.cs`, `src/Cobranza.Functions/Servicios/LimiteAcs.cs`, 5 archivos de `tests/Cobranza.Functions.Tests/`, 42 archivos de `evidencias/` (5 carpetas del 05-11 y el informe QA anterior) |
| Ignorados (`--ignored`) | `.claude/settings.local.json`, `bin/` y `obj/` de los 4 proyectos (incluido `tests/`) |

## 2. Validaciones reejecutadas por QA

| Comando | Resultado QA | Evidencia del agente | Coincide |
| --- | --- | --- | --- |
| `dotnet build Cobranza.slnx` | Compilación correcta, 0 advertencias, 0 errores (4 proyectos) | `2026-11-05_desarrollo_build_429/02_build.txt`: 0/0 | Sí |
| `dotnet test Cobranza.slnx --no-build` | 23 superadas, 0 con error, 0 omitidas | `03_test.txt`: 23/23 | Sí |
| `dotnet list ... package --vulnerable --include-transitive` | Ningún proyecto con paquetes vulnerables | `04_paquetes_vulnerables.txt` | Sí |
| `az bicep version` | 0.48.1 | 0.48.1 | Sí |
| `az bicep build --file infra/main.bicep --outfile <tmp>` | exit 0, sin advertencias | `02_bicep_build.txt` | Sí |
| `az bicep lint --file infra/main.bicep` | exit 0, sin salida | `03_bicep_lint.txt` | Sí |
| `az bicep build-params` sin variables | BCP427 en `main.bicepparam:22` y `:23` (esperado) | BCP427 | Sí |
| `az bicep build-params --outfile <tmp>` con GUID ficticios (`0000...0001/0002`) | exit 0 | `04_build_params.txt` | Sí |
| `az bicep lint --file infra/main.bicepparam` con variables | exit 0 | `03_bicep_lint.txt` | Sí |
| Conteo sobre el JSON compilado | 31 declaraciones (sin `existing`): 26 simples + 4 bucles de 5 (`privados`) + 1 bucle de 3 (`raStorageFunc`) = 49 | 31/49 | Sí |
| Archivos `.json` creados en `infra/` | Ninguno; carpeta temporal borrada (`ls` posterior: no existe) | "ningún .json creado" | Sí |
| `bash -n` de `eliminar_entorno.sh` y `s10_configurar_jobs.sh` | OK; `file`: ASCII, sin CRLF | `09_bash_n.txt` | Sí |
| ShellCheck | No instalado (`which shellcheck`: no encontrado) | No instalado | NO VERIFICADO |
| What-if | No reejecutado (no necesario: la plantilla compila igual que en la evidencia; el informe anterior ya reprodujo el what-if) | `12_whatif_final.txt`: 48 Create | NO VERIFICADO en esta ronda |

## 3. Estado de los hallazgos del informe anterior

| Id | Estado | Evidencia verificada por QA |
| --- | --- | --- |
| C-01 | RESUELTO por análisis estático (ejecución real NO VERIFICADA) | `sql/01` reescrito: CHECK `Segmento` (`Tradicional`,`Digital`, 01:66), `OrigenCambio` (`SincronizacionAutomatica`,`Manual`, 01:110), `TipoAviso` (01:144), `EstadoEnvio` (01:147), `LogNotificacion` con `ClienteId`, `Intentos`, `FechaActualizacion` (01:137-157), `LogSincronizacion` con `Estado` DEFAULT `EnCurso` y sin `Resultado` (01:164-177). Contrastado a mano con 00:20-50 y 00:84-89, 04:168-194, 05:166-167 y 07:36-37: coinciden. Guarda contra estructura S6-S8 con `SET NOEXEC` (01:42-54, 01:209). Herramienta ScriptDom: control con el 01 original da 25 hallazgos, con el corregido 0 (`01_control_01_original.txt`, `02_validacion_01_corregido.txt`). La traza de 07 (CAMBIOS.md sección 5) es coherente. Pendiente 15 de CLAUDE.md registra la validación real |
| A-01 | ABIERTO a propósito, documentado como bloqueante de la publicación | CLAUDE.md:154 ("NO debe publicarse hasta implementar ADR-001 (hallazgo A-01)"); ADR-001 5.11 reglas 1-5 (líneas 528-537), 3.5 (línea 95), 4.6 (línea 141), 5.10 (líneas 487, 503, 506, 512). Ver hallazgo A-01 abajo: la barrera técnica de la regla 3 (restricción de IP en la Web App) todavía no está en `main.bicep` |
| M-01 | CORREGIDO | `main.bicep:401-429` (`sqlMaster` existing + `diagSqlMaster`, `sqlAuditoria` depende de él). Efecto en Azure: NO VERIFICADO |
| M-02 | CORREGIDO | `.gitignore:23` `infra/**/*.json`; `git check-ignore` confirma `infra/main.json`, `infra/main.parameters.json`, `infra/modulos/x.json`. Uso de `--outfile` documentado en `main.bicepparam:12-19` y `entorno.ejemplo.env:9-12` |
| M-03 | CORREGIDO (residuo Baja, B-N2) | `evidencias/2026-11-05_acciones_azure_operador/REGISTRO.md` con comando, resultado y aprobación textual por acción, ID truncados |
| M-04 | CORREGIDO como decisión (D17) | `main.bicepparam:50-56`, rotulados DEMO, dominio `.example`; `08_validacion_opciones_cobranza.txt` |
| M-05 | CORREGIDO (c); (a) y (b) registrados | 429 no registra intento y corta el lote (`NotificacionesFunction.cs`, pruebas `Rechazo429_*`); D12 documenta capacidad 60/día y falta de margen por hora. Ver M-N3 por divergencia con el ADR |
| M-06 | CORREGIDO | `s10_configurar_jobs.sh:59-60` 10/15000; paso de recreación del secreto retirado |
| M-07 | REGISTRADO para la ronda ADR-001 | ADR 5.5.1 y 5.10:503 (retirar `raKvApi`, alcance de `raKvFunc`, ABAC). `main.bicep:864-878` sin cambios (esperado) |
| M-08a | REGISTRADO | `sql/02:44-97`, alternativa `WITH SID ... TYPE = E` comentada, sin ID reales |
| M-08b | REGISTRADO | ADR 5.4.1 (línea 290) |
| M-09 | CORREGIDO con observaciones | CLAUDE.md 3, 5 (D16), 7 y 9. Ver M-N1 |
| B-01 | ABIERTO | TDE sigue sin declararse en `main.bicep` |
| B-02 | ABIERTO | Sin nota de "NO VERIFICADO" en `whatif_brazilsouth/CAMBIOS.md`; queda superado por la nueva cifra 31/49 |
| B-03 | ABIERTO | ShellCheck no instalado |
| B-04, B-05, B-06, B-08 | CORREGIDOS | `eliminar_entorno.sh` (cabecera solo humano, `SUBSCRIPTION_ID_ESPERADA`); `main.bicep:504` `take(unico, 6)`; comentarios de `OpcionesCobranza.cs` y `local.settings.example.json`; `main.bicep:51` y `:149` (`@maxLength(18)`, `parseCidr`) |
| B-07 | PARCIAL | Todas las tablas con guarda salvo `cob.UsuarioInterno` (01:184), documentado como dependiente de ADR-001 |
| B-09 | ABIERTO | Table Data Contributor y PE de table sin revisar |
| B-10 | REGISTRADO | ADR 4.2 (línea 113) |
| B-11 | REGISTRADO | CLAUDE.md sección 9 (costos de docs/04 deben recalcularse) |
| Build NU1902/NU1903 | CORREGIDO | Pkcs 9.0.21; build y lista de vulnerables reverificados |

## 4. Secretos e identificadores (revisión previa al commit)

Universo revisado: los 127 archivos de `git ls-files -co --exclude-standard` (todo lo que se versiona o entraría), incluida toda la carpeta `evidencias/`.

| Control | Resultado |
| --- | --- |
| GUID completos que empiecen por `7074`, `bf48`, `b492`, `72fd` | 0. Todas las apariciones están truncadas como `xxxx…yyyy` (`7074…e6be`, `bf48…f2fe`, `b492…0d49`, `72fd…e250`) o como marcador. Ninguna aparición seguida de 3 o más dígitos hexadecimales |
| GUID completos presentes | Solo (a) ID públicos de roles integrados de Azure (`main.bicep`, `seguridad_perimetral.bicep`, y los mismos en el what-if) y (b) nombres de asignaciones de rol generados por `guid()` en los what-if (`f8914996-...`, `cf318848-...`, etc.). Los de (b) son derivados deterministas, no identificadores de personas, grupos, suscripción ni tenant; no permiten recuperar los ID originales. Aceptable |
| Historial git (`git log --all -p`) | 0 coincidencias de los prefijos en forma completa |
| IPv4 públicas | 0. Solo 10.x, 0.0.0.0, 168.63.129.16 y `203.0.113.10` (RFC 5737). La IP del operador aparece como `<IP_OPERADOR>` (`whatif_brazilsouth/07_whatif_con_ip_operador.txt:704`) |
| Cadenas de conexión, claves, SAS, `-----BEGIN`, `Password=`, `InstrumentationKey=` | 0 valores. La única cadena es la plantilla `SQL_CS` de `s10_configurar_jobs.sh` (Managed Identity, sin credenciales) |
| Hash de contraseñas (PBKDF2 `AQAAAA...`) o base64 largos | 0 (solo rutas largas de recursos) |
| `infra/*.json`, `bin/`, `obj/`, `TestResults/` | No hay `.json` en `infra/`; `bin/`, `obj/` ignorados (`.gitignore:2-3`); `TestResults/` ignorado (`.gitignore:6`); ninguna carpeta `TestResults` en disco |
| `evidencias/2026-11-05_sql01_correccion_c01/herramienta/` | Solo `Program.cs` (8.171 B) y `tsqlparse.csproj` (384 B). Sin binarios, sin `bin/`/`obj/`; si se compilara en el lugar, `bin/` y `obj/` quedarían ignorados |
| Binarios en archivos versionables (`*.dll`, `*.exe`, `*.pdb`, `*.zip`, `*.nupkg`) | 0 fuera de `bin/`/`obj/` |
| `infra/entorno.ejemplo.env` | Variables vacías; entra por la negación `.gitignore:17`. `infra/entorno.local.env` ignorado (`.gitignore:15`) |
| Datos personales | `REGISTRO.md:11` y tabla de acciones incluyen el correo institucional del operador. No es un secreto; ver B-N1 |

Conclusión: no hay secretos ni identificadores completos en lo que se va a commitear.

## 5. Resultados por punto de la lista de revisión

| # | Punto | Resultado | Evidencia |
| --- | --- | --- | --- |
| 1 | Trazabilidad | CUMPLE | Cada `CAMBIOS.md` vincula cambio, hallazgo (C-01, M-xx, B-xx, SEG-Hxx) y archivo; D12-D17 en CLAUDE.md |
| 2 | Coherencia con arquitectura y decisiones | CUMPLE CON OBSERVACIONES | Sin regresiones a pasarela de pago, SMTP, PostgreSQL/MySQL, RA-GRS ni Functions de consumo. Observaciones M-N1 (D9/D10 con fundamento obsoleto) y B-N4 |
| 3 | Código .NET | CUMPLE | Build 0/0, 23/23, sin vulnerables; configuración por `Cobranza__*`; 429 tratado sin sumar intentos; `[Range(1, 60000)]` alineado con `@minValue(1)`; log con EventId 4290 (RNF-05). D4/D6 no tocados en esta ronda |
| 4 | Bicep y scripts | CUMPLE CON OBSERVACIONES | Build, lint y build-params limpios; sin `--mode Complete`; parámetros sin ID; valores inventados solo con rótulo DEMO y aprobación. ShellCheck NO VERIFICADO (B-03) |
| 5 | SQL | CUMPLE (estático) | C-01 resuelto en análisis estático; ejecución 07 = 10/10 NO VERIFICADA; idempotencia salvo `UsuarioInterno` (B-07); permisos sin cambio |
| 6 | Seguridad | CUMPLE CON OBSERVACIONES | Sin secretos; `ipOperador` validado; auditoría SQL y Key Vault hacia Log Analytics. A-01 abierto (Alta); Easy Auth NO APLICA (D13) |
| 7 | Continuidad | CUMPLE CON OBSERVACIONES | PITR/LTR/Zone sin cambios. D9/D10 deben revisarse con región pareada (M-N1). SEG-H02 (30 días de Log Analytics frente a 35 de PITR) registrado como pendiente 14 |
| 8 | Documentación y evidencias | CUMPLE CON OBSERVACIONES | Evidencias fechadas para todas las acciones; PENDIENTE no rellenados salvo los DEMO aprobados; español sin emojis. Contradicciones en CLAUDE.md (M-N1) y estados de aprobación inconsistentes (M-N2) |
| 9 | Pruebas de despliegue P01-P37 | NO APLICA | Nada desplegado; `verificar_despliegue.sh` no existe (pendiente 13) |

## 6. Hallazgos

### Crítica

Ninguno.

### Alta

**A-01 (abierto a propósito; se mantiene).** `src/Cobranza.Api/Seguridad/EasyAuthHandler.cs` sigue aceptando `X-MS-CLIENT-PRINCIPAL` sin validar. Está documentado como bloqueante de la publicación en CLAUDE.md:154 y en ADR-001 5.11. Hoy la protección es solo de procedimiento: la regla 3 de 5.11 (`ipSecurityRestrictionsDefaultAction = Deny` en la Web App) no está en `infra/main.bicep` (no hay `ipSecurityRestrictions`) y `main.bicep:623-624` mantiene el ajuste `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` con el secreto inexistente `easyauth-client-secret`. No impide el commit ni `az deployment group create` (la plantilla no publica código). Corrige: `desarrollador` (retirar `EasyAuthHandler` como primer cambio), `devops` (restricción de transición y retiro del ajuste), en la ronda ADR-001.

### Media

**M-N1. CLAUDE.md tiene valores antiguos sin marcar "Reemplazado" que contradicen otras secciones.** Corrige: orquestador / `arquitecto` (con aprobación humana).

| Ubicación | Texto vigente | Contradice |
| --- | --- | --- |
| `CLAUDE.md:3` | "D12-D15" y "en la sección 11" | La tabla llega a D17 (líneas 131-132) y no existe sección 11 (las secciones van de 0 a 10) |
| `CLAUDE.md:88` | "los valores de Finanzas van como parámetros vacíos" y "Nombre del proyecto de Functions en `src/`: PENDIENTE" | D17 (línea 132), pendiente 3 (línea 185) y línea 153 (`src/Cobranza.Functions` confirmado) |
| `CLAUDE.md:123` | D8 "Flex Consumption no confirmado en Chile Central" | Región vigente brazilsouth (línea 74, D16) |
| `CLAUDE.md:124-125` | D9 "RA-GRS descartado por no haber región pareada"; D10 brecha regional asumida | Línea 74: "Brazil South tiene ... región pareada (South Central US)". El fundamento de D9 ya no es cierto. Hay que revisar la decisión (mantener Zone con otro motivo o evaluar Geo) y su costo |
| `CLAUDE.md:157` | "Código .NET (API y Functions): escrito, nunca compilado" | Línea 154 (build en verde, 23/23) |
| `CLAUDE.md:158` | "Scripts bash: `bash -n` y ShellCheck 0.10.0 sin hallazgos" | ShellCheck no está instalado y no se ejecutó sobre `eliminar_entorno.sh` ni sobre el nuevo `s10` (B-03) |
| `CLAUDE.md:167`, `:172` | Estructura: "nombre PENDIENTE confirmar", "`s12_endurecer.sh` ubicación PENDIENTE confirmar" | Línea 153 y regla 7 (línea 17: `scripts/s12_endurecer.sh` confirmado) |

**M-N2. Estado de aprobación inconsistente entre CLAUDE.md, el ADR y la política.** CLAUDE.md:129-130 declara D14 "Vigente (aprobada 05-11-2026)" y D15 "aprobada"; CLAUDE.md:128 declara D13 "Vigente (aceptada)". Sin embargo, `ADR-001:5` dice "Revisión 1: Propuesta, pendiente de revisión de `qa` y de confirmación humana", `ADR-001:8.2` (D14) dice "Propuesta", el título de la sección 8 dice "(no aplicadas)" aunque ya se aplicaron, y `politica_credenciales_y_accesos.md:5` dice "Propuesta ... pendiente de revisión de `qa` y de aprobación humana" con aprobador PENDIENTE (línea 7). No se puede verificar quién aprobó D14/D15. Corrige: orquestador (registrar la aprobación humana con fecha y nombre) y `arquitecto`/`seguridad` (actualizar el estado de sus documentos).

**M-N3. ADR-001 5.12 no coincide con lo implementado para el 429.** El ADR (líneas 545-548) dice que la Function registra `EstadoEnvio = 'Limitado'` y que `sp_RegistrarNotificacion` lo acepta. Lo implementado no llama al procedimiento ante un 429 y deja el rastro solo en Application Insights (EventId 4290), y `sql/01:147` solo admite `Aceptado`/`Fallido`. CLAUDE.md:127 sí lo aclara. Riesgo: en la ronda siguiente el `dba` o el `desarrollador` pueden implementar `Limitado` siguiendo el ADR y duplicar o contradecir la solución. Además, la traza del 429 depende de la retención de 30 días de Log Analytics (RF-05, SEG-H02). Corrige: `arquitecto` (decidir y actualizar 5.12).

### Baja

- **B-N1** `evidencias/2026-11-05_acciones_azure_operador/REGISTRO.md:11` (y las filas 3 de acciones y "Miembros"): contiene el correo institucional del operador. No es un secreto, pero es un dato personal en un repositorio. Decisión del equipo: dejarlo o reemplazarlo por "operador (Oscar Díaz Ulloa)". Orquestador.
- **B-N2** `evidencias/2026-11-05_whatif_brazilsouth/CAMBIOS.md:3` sigue afirmando que el único comando no de solo lectura fue el what-if, sin remitir a `REGISTRO.md` (la nota de `REGISTRO.md:30` solo cubre `10_proveedores.txt`). `devops`/orquestador.
- **B-N3** `.gitignore:23` `infra/**/*.json` también ignora cualquier JSON legítimo futuro en `infra/` (por ejemplo `bicepconfig.json`). Si se agrega, habrá que usar una negación explícita. `devops`.
- **B-N4** `CLAUDE.md:90` presenta como estado actual "API sin acceso a secretos; Function App solo al secreto `acs-connection-string`", pero `main.bicep:864-878` (`raKvApi`, `raKvFunc` sobre todo el vault) aún no cambia. El texto cierra con "Estado: diseñado", lo que lo atenúa. Conviene separar "vigente" de "diseñado". Orquestador.
- **B-N5** Referencias de línea desactualizadas en ADR-001: líneas 57, 151 y 153 ("01, línea 106"; hoy `UsuarioInterno` está en 01:184 y C-01 ya se corrigió); línea 503 ("556-562", "800-808"; hoy 623-624 y 864-872). `arquitecto`.
- **B-N6** `politica_credenciales_y_accesos.md`, sección 0: el hecho "el diagnóstico de auditoría de Key Vault solo existe en el módulo" ya no es cierto (`main.bicep:353`, `diagKv`). `seguridad`.
- **B-N7** `NotificacionesFunction.cs`: `procesados++` se incrementa antes de `RegistrarNotificacionAsync`. Si el registro en SQL lanza una excepción, esta no se captura y aborta la ejecución con un correo ya enviado y sin fila en la bitácora. El comportamiento es igual al anterior y no lo introduce esta ronda. `desarrollador` (evaluar en la ronda ADR-001).
- **B-N8** Persisten B-01 (TDE no explícito), B-02, B-03 (ShellCheck), B-07 parcial y B-09 del informe anterior.
- Informativo: los identificadores de CVE/GHSA citados en `2026-11-05_desarrollo_build_429/CAMBIOS.md` no se contrastaron con una fuente externa. La ausencia de vulnerables sí se reverificó con `dotnet list package --vulnerable`.

## 7. Archivos que no deberían versionarse

- No hay archivos que excluir obligatoriamente. Lo generado (`bin/`, `obj/`, `.claude/settings.local.json`) ya está ignorado, y no existen `infra/*.json`, `TestResults/` ni `local.settings.json`.
- Opcional, a decisión del equipo (B-N1): `evidencias/2026-11-05_acciones_azure_operador/REGISTRO.md` contiene el correo institucional del operador. Se puede commitear tal cual o anonimizar antes; no se recomienda excluirlo, porque es la evidencia de M-03.
- `evidencias/2026-11-05_sql01_correccion_c01/herramienta/` puede versionarse (solo fuente). No compilarla dentro del repositorio.

## 8. Veredicto

**Para el COMMIT: APTO CON OBSERVACIONES.** No hay secretos, Object ID completos, IP públicas, cadenas de conexión, claves, hashes ni binarios en los 67 archivos que entrarían (11 modificados y 56 nuevos, más este informe). Los generados están ignorados. Las observaciones (M-N1, M-N2, M-N3, B-N1) no impiden el commit; conviene corregirlas en el commit siguiente.

**Técnico general: RECHAZADO**, únicamente por A-01 (Alta), que sigue abierto a propósito, está documentado como bloqueante de la publicación de la API y se resuelve en la ronda ADR-001. C-01 queda resuelto por análisis estático (la ejecución real de 07 = 10/10 sigue NO VERIFICADA, pendiente 15). El resto de los hallazgos del informe anterior quedaron corregidos o registrados como pendientes. El despliegue de la plantilla (`az deployment group create`) no tiene bloqueos técnicos; requiere confirmación humana, después `scripts/s12_endurecer.sh` (regla 7) y no publicar la API.
