# Registro de acciones en Azure y Entra ID - 05-11-2026

Ejecutadas por la sesión principal de Claude Code (orquestador) con la cuenta del operador, previa confirmación explícita del usuario (Oscar Díaz Ulloa) en cada caso. Los identificadores se truncan (primeros y últimos 4 caracteres).

## Contexto

| Dato | Valor |
| --- | --- |
| Suscripción | Azure for Students (b492…0d49), estado Enabled |
| Tenant | Fundación Instituto Profesional Duoc UC (72fd…e250), dominio duoc.cl |
| Operador | os.diazu@duocuc.cl (bf48…f2fe) |
| Rol RBAC del operador | Owner sobre la suscripción |
| Roles de directorio del operador | Ninguno |
| Política del tenant (authorizationPolicy) | allowedToCreateApps=true, allowedToCreateSecurityGroups=true, allowedToCreateTenants=true, allowedToReadOtherUsers=true; consentimiento de usuario desactivado (sin ManagePermissionGrantsForSelf.*) |
| Política de regiones | "Ubicaciones permitidas", asignada en el grupo de administración raíz del tenant (72fd…e250), modo Default. Permite solo regiones de Brasil y EE. UU. (brazilsouth, brazilsoutheast, eastus, eastus2, northcentralus, southcentralus, westcentralus, westus, westus2, westus3, más global). chilecentral NO permitida y el operador no puede eximirla. |

## Acciones con escritura

| # | Acción | Comando | Resultado | Aprobación |
| --- | --- | --- | --- | --- |
| 1 | Prueba de creación de grupo y de app en Entra ID | `az ad group create --display-name prueba-borrar ...` y `az ad app create --display-name prueba-borrar`, luego `az ad group delete` y `az ad app delete` | Ambos creados y eliminados; la verificación posterior devuelve 0 objetos. Quedan 30 días en la papelera de Entra ID (no purgados, por decisión del usuario). | Usuario: "Sí, crear y borrar" |
| 2 | Crear grupo administrador SQL | `az ad group create --display-name grp-cobranza-sql-admin --mail-nickname grp-cobranza-sql-admin` | Creado (7074…e6be). Dueño: el operador. | Usuario: "Sí, crear el grupo" |
| 3 | Agregar al operador como miembro | `az ad group member add --group <id> --member-id <operador>` | Miembros: os.diazu@duocuc.cl | Ídem |
| 4 | Crear grupo de recursos vacío para el what-if | `az group create -n rg-cobranza-apt -l brazilsouth` | provisioningState Succeeded, región brazilsouth, sin recursos | Usuario: "Sí, crear RG vacío" |
| 5 | Registrar proveedores de recursos | `az provider register --namespace <p> --wait` para Microsoft.Communication, microsoft.insights, Microsoft.KeyVault y Microsoft.OperationalInsights | Los cuatro en estado Registered | Usuario: "autorizado el registrar 4 proveedores de recursos" |

Nota: `evidencias/2026-11-05_whatif_brazilsouth/10_proveedores.txt` se generó antes de la acción 5 y muestra NotRegistered; este registro lo reemplaza (hallazgo M-03 de qa).

## Acciones de solo lectura relevantes

- `az account show`, `az ad signed-in-user show`.
- `az role assignment list --assignee <operador> --scope /subscriptions/<id> --include-inherited`: Owner.
- `GET https://graph.microsoft.com/v1.0/me/memberOf`: 12 grupos institucionales, 0 roles de directorio.
- `GET https://graph.microsoft.com/v1.0/policies/authorizationPolicy`.
- `az policy assignment list --disable-scope-strict-match`: política de regiones descrita arriba.

## Estado tras estas acciones

- Recursos desplegados en Azure: ninguno (solo el RG vacío `rg-cobranza-apt`).
- Objetos de Entra ID creados y vigentes: el grupo `grp-cobranza-sql-admin`.
