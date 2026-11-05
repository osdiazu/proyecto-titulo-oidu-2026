// Parametros de seguridad_perimetral.bicep - completar los valores PENDIENTE con los
// nombres reales del entorno base (salidas de main.bicep de S6-S8 o portal).
using './seguridad_perimetral.bicep'

param vnetName = 'PENDIENTE'
param webAppName = 'PENDIENTE'
param functionAppName = 'PENDIENTE'
param sqlServerName = 'PENDIENTE'
param sqlDatabaseName = 'PENDIENTE'
param keyVaultName = 'PENDIENTE'
param acsName = 'PENDIENTE'
param logAnalyticsName = 'PENDIENTE'
param correoAlertas = 'PENDIENTE@dominio'

// Verificar en nsg-pe la prioridad de la regla de denegacion antes de desplegar el WAF
param prioridadReglaAgwPe = 150

// Cambiar a true solo con aprobacion de costo (USD 400,15/mes) y certificado cargado en Key Vault
param desplegarWaf = false
param uriCertificadoKeyVault = ''
