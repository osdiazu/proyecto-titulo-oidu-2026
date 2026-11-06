using './main.bicep'

// RECONSTRUCCION (05-11-2026) desde la version S6-S8. Ver
// evidencias/2026-11-05_whatif_brazilsouth/CAMBIOS.md.
//
// Este archivo NO contiene identificadores ni secretos. Los valores propios
// del tenant se leen de variables de entorno (plantilla: infra/entorno.ejemplo.env;
// copia local no versionada: infra/entorno.local.env).
// La suscripcion se elige en la CLI (az account set), no aqui.
// La region la fija el grupo de recursos rg-cobranza-apt (brazilsouth).
//
// M-02: "az bicep build-params" escribe por defecto infra/main.json CON los Object ID
// reales. Usar siempre --outfile hacia una carpeta temporal fuera del repositorio y
// borrarla al terminar, por ejemplo:
//   TMP_BP=$(mktemp -d)
//   az bicep build-params --file infra/main.bicepparam --outfile "$TMP_BP/main.parameters.json"
//   ...
//   rm -rf "$TMP_BP"
// infra/**/*.json esta en .gitignore como segunda barrera, no como sustituto.

// Obligatorias: si la variable no existe, la compilacion de parametros falla.
param sqlAdminGroupObjectId = readEnvironmentVariable('SQL_ADMIN_GROUP_OBJECT_ID')
param operadorObjectId = readEnvironmentVariable('OPERADOR_OBJECT_ID')

// Opcional: vacio = SQL y Key Vault cerrados al acceso publico.
param ipOperador = readEnvironmentVariable('IP_OPERADOR', '')

// Se incrementa tras cada eliminacion del grupo de recursos (scripts/eliminar_entorno.sh).
param cicloKeyVault = readEnvironmentVariable('CICLO_KV', '1')

param sqlAdminGroupName = 'grp-cobranza-sql-admin'
param location = 'brazilsouth'
param acsDataLocation = 'United States'

param prefijo = 'cobranza'
param ambiente = 'dev'
param appServicePlanSku = 'B1'
param sqlBackupRedundancy = 'Zone'

// valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)
// Preaviso 7, Vencimiento 0 (sin clave de configuracion), Mora1 3, Mora2 7.
param diasPreaviso = 7
param diasMora1 = 3
param diasMora2 = 7

// D12, valores DEMO aprobados por el usuario (05-11-2026): maximo 10 por ejecucion y
// pausa de 15000 ms. Hallazgo H1 (ACS dominio administrado: 5/min, 10/h).
param maxCorreosPorEjecucion = 10
param pausaEntreCorreosMs = 15000

// valores de demostracion inventados, no entregados por Finanzas (pendiente 3, CLAUDE.md seccion 8)
// Aprobados por el usuario el 05-11-2026 solo para pruebas (M-04). Reemplazar por los
// textos oficiales de Finanzas antes de cualquier uso real. El dominio .example esta
// reservado (RFC 2606): no corresponde a ningun buzon real.
param canalesPagoTexto = 'Transferencia bancaria a Banco Ficticio, cuenta corriente 00-000-00000-0 (DATOS DE DEMOSTRACION)'
param telefonoContacto = '+56 2 2000 0000 (DEMO)'
param correoContacto = 'cobranza@embotelladora-demo.example'
