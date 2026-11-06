# Cambios 05-11-2026: reconstrucción de main.bicep (S10) y validación what-if en brazilsouth

Responsable de la ejecución: agente `devops` (Claude Code), por encargo del orquestador. Nada se desplegó: el único comando contra Azure que no es de solo lectura fue `az deployment group what-if`.

## 1. Qué se reconstruyó

El archivo `infra/main.bicep` de la versión S10 (28 declaraciones / 46 recursos) no existe en el disco. Con aprobación del usuario se **reconstruyó** desde la versión S6-S8 aplicando los cambios S10 documentados. **No es el archivo original de S10.**

- Fuente: `Entorno_Base_IaC_SQL_S6-S8.zip` (Descargas del usuario), extraído en una carpeta temporal.
  - SHA-256 `main.bicep` S6-S8: `d45bfdfd…70699`
  - SHA-256 `main.bicepparam` S6-S8: `4c95d3d1…ba336`
  - SHA-256 `01_esquema_cobranza.sql` S6-S8: `70dc3878…a2923` (se copió sin cambios)
  - SHA-256 `02_identidades_y_permisos.sql` S6-S8: `4c10ae1c…6b6d3`
- Cambios S10 tomados de: `docs/06_Implementacion_S10_Resumen.md` (C1-C6), `docs/05_Evidencias_S10-S15_Resumen.md` (nombres, ipOperador, operadorObjectId, orden SQL) y CLAUDE.md secciones 3 y 4.
- Nombres y claves tomados de lo que ya consumen: `src/Cobranza.Functions` (`OpcionesCobranza`, `%CRON_*%`), `src/Cobranza.Api` (`GetConnectionString("Cobranza")`), `scripts/s10_*`, `s11_*`, `s12_*`, `s14_*`, `infra/modulos/*.bicep` y `sql/03`-`sql/06`.

## 2. Cambios respecto de S6-S8

| Id | Cambio | Por qué | Archivo |
| --- | --- | --- | --- |
| C1 | IP fijas en los PE: sql 10.20.2.4, kv 10.20.2.5 (memberName `default`), blob .6, queue .7, table .8 (`ipConfigurations` con `cidrHost`) | S10 documentado | `infra/main.bicep` |
| C2 | `customNetworkInterfaceName` = `nic-pe-<x>-cobranza-dev` | S10 documentado | `infra/main.bicep` |
| C3 | Parámetro `ipOperador` (vacío = cerrado). Si tiene valor: SQL `publicNetworkAccess Enabled` + regla `operador-temporal`; Key Vault `publicNetworkAccess Enabled` con `defaultAction Deny` e `ipRules` solo con esa IP. Acepta la IP con o sin `/32` | S10 documentado | `infra/main.bicep`, `infra/main.bicepparam` |
| C4 | Salidas `ipPeSql`, `ipPeKeyVault`, `ipPeBlob`, `ipPeQueue`, `ipPeTable` | S10 documentado | `infra/main.bicep` |
| C5 | `Microsoft.Sql/servers/auditingSettings` `default` con `isAzureMonitorTargetEnabled` (mismos grupos de acciones que `infra/modulos/seguridad_perimetral.bicep`) | S10 documentado | `infra/main.bicep` |
| C6 | `acsDataLocation` = `United States` (valor por defecto y en el bicepparam) | S10 documentado | `infra/main.bicep`, `infra/main.bicepparam` |
| N1 | Parámetro `operadorObjectId` + asignación Key Vault Secrets Officer, `principalType: User` | Pedido 05-11 (docs/05 y CLAUDE.md sección 3) | `infra/main.bicep` |
| N2 | Function App: ajustes con las claves que lee el código (`CRON_SINCRONIZACION`, `CRON_NOTIFICACIONES`, `Cobranza__SqlCobranza`, `Cobranza__SqlOrigen`, `Cobranza__VistaOrigen`, `Cobranza__AcsConnectionString` (referencia Key Vault), `Cobranza__RemitenteCorreo`, `Cobranza__DiasPreaviso/DiasMora1/DiasMora2`, `Cobranza__MaxCorreosPorEjecucion`, `Cobranza__PausaEntreCorreosMs`, `Cobranza__NombreEmpresa`, `Cobranza__CanalesPagoTexto`, `Cobranza__TelefonoContacto`, `Cobranza__CorreoContacto`). Se retiran `ConnectionStrings__CobranzaDb`, `Acs__*` y `Jobs__*` de S6-S8 porque el código no las lee | Coherencia con `OpcionesCobranza.cs` y `s10_configurar_jobs.sh` | `infra/main.bicep` |
| N3 | Días de aviso de DEMOSTRACIÓN: Preaviso 7, Vencimiento 0, Mora1 3, Mora2 7, con el comentario "valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)". Vencimiento no tiene clave: el código no la lee (el aviso de vencimiento es el día 0) | Pedido 05-11 | `infra/main.bicep`, `infra/main.bicepparam` |
| N4 | `maxCorreosPorEjecucion` 10 y `pausaEntreCorreosMs` 12000 como parámetros (antes 90 / 2100 en el script S10) | Hallazgo H1: dominio administrado 5/min y 10/h; D12 dice "debe ajustarse". **Pendiente de confirmación del equipo** | `infra/main.bicep`, `infra/main.bicepparam` |
| N5 | Textos de Finanzas (`canalesPagoTexto`, `telefonoContacto`, `correoContacto`) como parámetros vacíos | CLAUDE.md: no inventar valores de Finanzas | `infra/main.bicep`, `infra/main.bicepparam` |
| N6 | Web App: `healthCheckPath: '/salud'`; ajuste `ConnectionStrings__Cobranza` (la clave que lee la API; S6-S8 usaba `CobranzaDb`); `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` como referencia a `easyauth-client-secret` para que un redespliegue no lo borre | Coherencia con `Program.cs`, `RepositorioConsultas.cs` y `s11_configurar_api.sh` | `infra/main.bicep` |
| N7 | Cadena SQL con `TrustServerCertificate=False;` y origen con `ApplicationIntent=ReadOnly;` | Mismo formato que `s10_configurar_jobs.sh` / `s14_simulacro_pitr.sh` | `infra/main.bicep` |
| N8 | Nombres `vnet-cobranza`, `nsg-app`, `nsg-pe` (S6-S8: `vnet-cobranza-dev`, `nsg-app-cobranza-dev`, `nsg-pe-cobranza-dev`) | CLAUDE.md sección 3, docs/05 y valor por defecto `nsg-pe` de `seguridad_perimetral.bicep` | `infra/main.bicep` |
| N9 | `nsg-pe`: la denegación final pasa de `Deny-All-Inbound` (origen `*`, prioridad 4096) a `Deny-VNet-Inbound` (origen `VirtualNetwork`, prioridad 4000) | CLAUDE.md sección 3 / docs/05 ("deny VNet en prioridad 4000"); deja espacio a la regla 150 de S12 | `infra/main.bicep` |
| N10 | Región `brazilsouth` (parámetro `location` en el bicepparam; el RG ya está en brazilsouth) | Decisión del usuario: la política "Ubicaciones permitidas" del grupo de administración raíz bloquea chilecentral | `infra/main.bicepparam` |
| N11 | `main.bicepparam` sin IDs ni IP: `readEnvironmentVariable` para `SQL_ADMIN_GROUP_OBJECT_ID`, `OPERADOR_OBJECT_ID` (obligatorias, sin valor por defecto), `IP_OPERADOR` (por defecto vacío) y `CICLO_KV` (por defecto `1`). `sqlAdminGroupName = 'grp-cobranza-sql-admin'`. Validaciones `@minLength(36)/@maxLength(36)` en los Object ID | Pedido 05-11; ningún ID en git | `infra/main.bicepparam`, `infra/main.bicep` |
| N12 | Parámetro `cicloKeyVault`: el nombre del vault usa `uniqueString(resourceGroup().id, 'keyvault', cicloKeyVault)` | Redespliegue repetible (sección 3) | `infra/main.bicep` |
| N13 | Salidas nuevas: `apiAppName`, `funcHostName`, `sqlServerName`, `sqlDatabaseName`, `storageName`, `acsName`, `logAnalyticsName`, `vnetName`, `usuarioFunctionApp`, `usuarioApi`, `accesoOperadorAbierto` | Nombres que piden `s10`/`s11`/`s12`/`s14`, `seguridad_perimetral.bicep` y `sqlcmd -v` | `infra/main.bicep` |
| SQL-02 | Placeholders `<nombre-...>` reemplazados por `$(UsuarioFunctionApp)` y `$(UsuarioApi)`; `CREATE USER` idempotente. Se retiran `db_datareader` (ambas), `EXECUTE ON SCHEMA::cob` e `INSERT ON cob.LogNotificacion`: 03-06 otorgan permisos por objeto y 06 indica que la API no tiene SELECT directo. **Revisar con `dba`** | Coherencia con 03-06 | `sql/02_identidades_y_permisos.sql` |
| — | `sql/01_esquema_cobranza.sql` copiado sin cambios desde S6-S8 | — | `sql/01_esquema_cobranza.sql` |
| — | `infra/entorno.ejemplo.env` (nombres sin valores); `.gitignore`: `infra/entorno.local.env`, excepción `!infra/entorno.ejemplo.env` (la regla `*.env` existente también lo ignoraba) e `infra/*.parameters.json` | Pedido 05-11 | `infra/entorno.ejemplo.env`, `.gitignore` |
| — | `scripts/eliminar_entorno.sh` (`--dry-run`, confirmación escribiendo el nombre del RG, inventario de Key Vault y LTR, incrementa `CICLO_KV` en `infra/entorno.local.env`). **No ejecutado** | Pedido 05-11 | `scripts/eliminar_entorno.sh` |

Conteo: 29 declaraciones / 47 recursos. Diferencia con S10 (28/46): la asignación del operador (N1). Ver `09_conteo_recursos.txt`.

## 3. Redespliegue tras eliminar el grupo de recursos

| Recurso | Problema | Resolución |
| --- | --- | --- |
| Key Vault (purga activada) | El vault eliminado queda soft-deleted 90 días sin poder purgarse; el nombre derivado de `uniqueString(resourceGroup().id)` se repetiría y el despliegue fallaría | Parámetro `cicloKeyVault` (`CICLO_KV`) dentro del hash del nombre; `eliminar_entorno.sh` lo incrementa. Verificado: `CICLO_KV=2` genera `kv-cobranza-dev-d6fh4x` en vez de `kv-cobranza-dev-ahfg2w` (`08_whatif_ciclo_kv_2.txt`). Se descartó `createMode: 'recover'` porque Bicep no puede detectar si existe un vault eliminado (habría que decidirlo fuera de la plantilla) y porque recupera secretos obsoletos |
| Secreto `acs-connection-string` | — | Se crea en cada despliegue en el vault nuevo con la clave del ACS nuevo; la Function App lo referencia por `SecretUri` del vault nuevo |
| Nombre de host del PE de Key Vault | — | Cambia con el vault (`<vault nuevo>.privatelink.vaultcore.azure.net`); la zona DNS y el registro A se recrean con el despliegue. La IP 10.20.2.5 no cambia |
| Log Analytics | Soft-delete 14 días | Al recrearse con el mismo nombre, grupo y región, Azure lo recupera; no requiere cambio |
| App Insights, ACS, Email Service, dominio administrado | Sin retención de nombre conocida | El dominio administrado nuevo tiene otro subdominio: la plantilla recalcula `Cobranza__RemitenteCorreo` |
| SQL server, storage, sites | Nombres globales; se liberan al eliminar | Sin cambio. A verificar en la primera prueba de ciclo |
| Asignaciones de rol | Los nombres son deterministas (`guid(...)`) | Si quedara una asignación huérfana con el mismo nombre, el despliegue fallaría con `RoleAssignmentUpdateNotPermitted`. A verificar en la primera prueba de ciclo |
| Respaldos LTR (P8W/P12M) | Sobreviven a la eliminación del servidor y **siguen costando** hasta vencer | Solo documentado; `eliminar_entorno.sh` los lista antes y después |
| Grupo de recursos | `az group delete` también elimina el RG | Recrearlo antes de redesplegar: `az group create -n rg-cobranza-apt -l brazilsouth` |

## 4. Evidencias de este directorio

| Archivo | Contenido |
| --- | --- |
| `01_versiones.txt` | Azure CLI 2.63.0, Bicep CLI 0.48.1 (instalado el 05-11 con `az bicep install --version v0.48.1`), .NET SDK 10.0.303 |
| `02_bicep_build.txt` | `az bicep build`: exit 0, sin advertencias |
| `03_bicep_lint.txt` | `az bicep lint` de `main.bicep` y `main.bicepparam`: exit 0, sin hallazgos |
| `04_build_params.txt` | `build-params` sin variables (falla BCP427, como se espera) y con variables (exit 0, GUID truncados; JSON borrado) |
| `05_politicas.txt` | Asignaciones de política heredadas (Ubicaciones permitidas, ASC Default, bloqueo de West Europe) |
| `06_whatif_acceso_cerrado.txt` | What-if con `IP_OPERADOR` vacío: 46 Create, 0 Modify, sin errores |
| `07_whatif_con_ip_operador.txt` | What-if con `IP_OPERADOR` (valor ocultado): 47 Create (incluye `operador-temporal`) |
| `08_whatif_ciclo_kv_2.txt` | Nombre del vault con `CICLO_KV=2` |
| `09_conteo_recursos.txt` | 29 declaraciones / 47 recursos |
| `10_proveedores.txt` | Proveedores sin registrar: Microsoft.Communication, microsoft.insights, Microsoft.KeyVault, Microsoft.OperationalInsights |
| `11_bash_n_eliminar_entorno.txt` | `bash -n` OK; ShellCheck no instalado |

GUID truncados (`bf48…f2fe`) y la IP pública reemplazada por `<IP_OPERADOR>`.
