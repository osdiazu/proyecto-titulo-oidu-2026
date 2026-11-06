// =====================================================================
// Proyecto APT: Cobranza Automatizada - Embotelladora del Pacifico S.A.
// Entorno base: red, observabilidad, secretos, base de datos, computo
// backend (API + jobs) y servicio de correo.
//
// RECONSTRUCCION (05-11-2026). El archivo original de la version S10 no
// existe en el repositorio. Este archivo se reconstruyo desde la version
// S6-S8 (Entorno_Base_IaC_SQL_S6-S8.zip) aplicando los cambios S10
// documentados (C1-C6, docs/06_Implementacion_S10_Resumen.md) y los
// requisitos del 05-11-2026 (region brazilsouth, operadorObjectId, ajustes
// Cobranza__*, redespliegue repetible). Detalle: evidencias/2026-11-05_whatif_brazilsouth/CAMBIOS.md
//
// ADR-001 (06-11-2026, autenticacion propia sin Easy Auth): se retira Easy Auth
// (MICROSOFT_PROVIDER_AUTHENTICATION_SECRET) y raKvApi; raKvFunc pasa a alcance del
// secreto acs-connection-string; condicion ABAC en Blob Data Owner de la Function App;
// Data Protection de la API (contenedor dataprotection-keys y clave RSA
// dataprotection-cobranza-api); ajustes DataProtection__*, Seguridad__SaltosProxyConfiables
// y ASPNETCORE_FORWARDEDHEADERS_ENABLED=false; regla de transicion 5.11 (Web App con
// entrada Deny); SCM sin herencia y en Deny; TDE explicito (B-01).
// Detalle: evidencias/2026-11-06_adr001_devops/CAMBIOS.md
//
// Ambito: grupo de recursos (az deployment group ... --mode Incremental).
// Volver a desplegar esta plantilla restablece los ajustes de aplicacion y
// la configuracion del sitio: reaplicar scripts/s12_endurecer.sh despues.
// =====================================================================

targetScope = 'resourceGroup'

@description('Region de despliegue. Se toma la del grupo de recursos (brazilsouth: chilecentral esta bloqueada por la politica "Ubicaciones permitidas" del tenant).')
param location string = resourceGroup().location

@description('Prefijo corto del proyecto, usado en los nombres de recursos.')
@minLength(3)
@maxLength(10)
param prefijo string = 'cobranza'

@description('Ambiente de despliegue.')
@allowed([
  'dev'
  'qa'
  'prod'
])
param ambiente string = 'dev'

@description('Object ID (Entra ID) del grupo administrador de Azure SQL. Se lee de la variable de entorno SQL_ADMIN_GROUP_OBJECT_ID (no se versiona).')
@minLength(36)
@maxLength(36)
param sqlAdminGroupObjectId string

@description('Nombre visible del grupo administrador de Azure SQL en Entra ID.')
@minLength(1)
param sqlAdminGroupName string

@description('Object ID (Entra ID) del usuario operador. Recibe Key Vault Secrets Officer sobre el Key Vault. Se lee de OPERADOR_OBJECT_ID (no se versiona).')
@minLength(36)
@maxLength(36)
param operadorObjectId string

@description('IP publica IPv4 del operador (con o sin mascara; la mascara se ignora y se usa /32). Abre temporalmente Azure SQL (regla operador-temporal) y Key Vault a esa IP. Vacio = cerrado. El formato se valida con parseCidr: un valor invalido hace fallar la validacion o el what-if, antes de crear recursos.')
@maxLength(18)
param ipOperador string = ''

@description('Saltos de proxy confiables para los encabezados reenviados de la API (ADR-001 5.4.1): 1 sin WAF (topologia actual); 2 solo con WAF D11 y la Web App sin acceso publico. Lo determina la topologia, no es una preferencia.')
@minValue(1)
@maxValue(2)
param saltosProxyConfiables int = 1

@description('Ciclo del Key Vault. Con proteccion de purga, un vault eliminado conserva su nombre reservado 90 dias; cambiar este valor tras eliminar el grupo de recursos genera un nombre nuevo. Lo incrementa scripts/eliminar_entorno.sh.')
@minLength(1)
@maxLength(4)
param cicloKeyVault string = '1'

@description('SKU del plan de App Service. La integracion con VNet exige nivel Basic o superior.')
@allowed([
  'B1'
  'B2'
  'S1'
  'P0v3'
  'P1v3'
])
param appServicePlanSku string = 'B1'

@description('SKU de Azure SQL Database.')
param sqlDatabaseSku object = {
  name: 'S0'
  tier: 'Standard'
}

@description('Redundancia del almacenamiento de respaldos de Azure SQL (decision D9: Zone).')
@allowed([
  'Local'
  'Zone'
  'Geo'
  'GeoZone'
])
param sqlBackupRedundancy string = 'Zone'

@description('Ubicacion de datos de Azure Communication Services (C6, S10).')
param acsDataLocation string = 'United States'

@description('Rango de direcciones de la red virtual.')
param vnetAddressPrefix string = '10.20.0.0/16'

// ---------------------------------------------------------------------
// Parametros del job de notificaciones (claves leidas por src/Cobranza.Functions,
// clase OpcionesCobranza, seccion "Cobranza").
// ---------------------------------------------------------------------
// valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)
// Preaviso 7, Vencimiento 0, Mora1 3, Mora2 7. El aviso de Vencimiento (dia 0) no
// tiene clave de configuracion: el codigo lo trata como el dia del vencimiento.
@description('Dias antes del vencimiento para el Preaviso. Valor de demostracion, no definido por Finanzas.')
@minValue(1)
@maxValue(60)
param diasPreaviso int = 7

@description('Dias despues del vencimiento para Mora1. Valor de demostracion, no definido por Finanzas.')
@minValue(1)
@maxValue(180)
param diasMora1 int = 3

@description('Dias despues del vencimiento para Mora2 (debe ser mayor que diasMora1). Valor de demostracion, no definido por Finanzas.')
@minValue(2)
@maxValue(365)
param diasMora2 int = 7

// D12 (valores DEMO aprobados por el usuario el 05-11-2026): maximo 10 por ejecucion y
// pausa de 15000 ms. ACS con dominio administrado: 5 por minuto y 10 por hora (hallazgo H1).
// 15000 ms => 4 por minuto (margen sobre 5/min); 10 por ejecucion horaria => 10 por hora.
// Capacidad: 6 ejecuciones (12-17 UTC) x 10 = 60 por dia habil, menor que el promedio
// simulado de 111 (hallazgo M-05 de QA): requiere dominio propio o escalonar envios.
@description('Maximo de correos por ejecucion (D12, valor DEMO: 10). ACS con dominio administrado: 10 por hora (hallazgo H1); el job corre cada hora.')
@minValue(1)
@maxValue(1000)
param maxCorreosPorEjecucion int = 10

@description('Pausa entre correos en ms (D12, valor DEMO: 15000). ACS con dominio administrado: 5 por minuto (hallazgo H1); 15000 ms deja 4 por minuto.')
@minValue(1)
@maxValue(60000)
param pausaEntreCorreosMs int = 15000

// Textos de Finanzas: sin valor por defecto en la plantilla. Los valores DEMO se fijan en
// main.bicepparam. La Function App no inicia si estan vacios (ValidateOnStart).
@description('Texto de canales de pago (Finanzas). La Function App no inicia sin este valor (validacion ValidateOnStart).')
param canalesPagoTexto string = ''

@description('Telefono de contacto de cobranza (Finanzas).')
param telefonoContacto string = ''

@description('Correo de contacto de cobranza (Finanzas). Debe ser una direccion valida ([EmailAddress] en OpcionesCobranza).')
param correoContacto string = ''

@description('Expresion CRON (UTC) del job de sincronizacion (D7: cada 15 minutos).')
param cronSincronizacion string = '0 */15 * * * *'

@description('Expresion CRON (UTC) del job de notificaciones (D2: cada hora entre 12 y 17 UTC, dias habiles).')
param cronNotificaciones string = '0 0 12-17 * * 1-5'

var sufijo = '${prefijo}-${ambiente}'
var unico = uniqueString(resourceGroup().id)
var unicoKv = uniqueString(resourceGroup().id, 'keyvault', cicloKeyVault)
// B-08: parseCidr rechaza un valor que no sea una direccion valida. Se fuerza /32 y se toma
// la direccion de red, que para /32 es la propia IP. Solo se evalua si ipOperador tiene valor.
var ipOperadorSinMascara = empty(ipOperador) ? '' : parseCidr('${split(ipOperador, '/')[0]}/32').network
var accesoOperador = !empty(ipOperadorSinMascara)
// ADR-001 5.11: regla de permiso de la Web App durante la transicion (nombre registrado: SEG-H11).
var reglasTransicionApi = accesoOperador
  ? [
      {
        name: 'operador-transicion'
        action: 'Allow'
        ipAddress: '${ipOperadorSinMascara}/32'
        priority: 100
        description: 'ADR-001 5.11: IP del operador durante la ventana (ipOperador)'
      }
    ]
  : []
var etiquetas = {
  proyecto: 'APT-Cobranza-Automatizada'
  cliente: 'Embotelladora del Pacifico S.A.'
  ambiente: ambiente
  responsable: 'Oscar Diaz Ulloa'
}

var prefijoSnetApp = cidrSubnet(vnetAddressPrefix, 24, 1)
var prefijoSnetPe = cidrSubnet(vnetAddressPrefix, 24, 2)

// ---------------------------------------------------------------------
// 1. Red: VNet, subredes y NSG
// ---------------------------------------------------------------------
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-app'
  location: location
  tags: etiquetas
  properties: {
    securityRules: [
      {
        name: 'Allow-VNet-Outbound-PE'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRanges: [
            '443'
            '1433'
          ]
        }
      }
    ]
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-pe'
  location: location
  tags: etiquetas
  properties: {
    securityRules: [
      {
        name: 'Allow-App-To-SQL'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: prefijoSnetApp
          sourcePortRange: '*'
          destinationAddressPrefix: prefijoSnetPe
          destinationPortRange: '1433'
        }
      }
      {
        name: 'Allow-App-To-KeyVault-Storage'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: prefijoSnetApp
          sourcePortRange: '*'
          destinationAddressPrefix: prefijoSnetPe
          destinationPortRange: '443'
        }
      }
      {
        // S10: denegacion del resto del trafico de la VNet en prioridad 4000
        // (deja espacio a reglas posteriores, p. ej. 150 desde snet-agw en S12).
        name: 'Deny-VNet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-${prefijo}'
  location: location
  tags: etiquetas
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-app'
        properties: {
          addressPrefix: prefijoSnetApp
          networkSecurityGroup: {
            id: nsgApp.id
          }
          delegations: [
            {
              name: 'delegacion-appservice'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: prefijoSnetPe
          networkSecurityGroup: {
            id: nsgPe.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

var subnetAppId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-app')
var subnetPeId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-pe')

// ---------------------------------------------------------------------
// 2. Observabilidad: Log Analytics + Application Insights
// ---------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${sufijo}'
  location: location
  tags: etiquetas
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    // SEG-H02 (decision PENDIENTE del equipo, afecta costos): 30 dias es menos que la
    // ventana PITR de 35 dias. No se cambia sin aprobacion.
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${sufijo}'
  location: location
  tags: etiquetas
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// ---------------------------------------------------------------------
// 3. Secretos: Azure Key Vault (RBAC, proteccion de purga, sin acceso publico)
//    El nombre incluye cicloKeyVault para poder redesplegar tras eliminar el
//    grupo de recursos (el nombre anterior queda reservado por la purga).
// ---------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${take(prefijo, 8)}-${ambiente}-${take(unicoKv, 6)}'
  location: location
  tags: etiquetas
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    // C3: con ipOperador se habilita el acceso publico SOLO para esa IP (defaultAction Deny).
    publicNetworkAccess: accesoOperador ? 'Enabled' : 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: accesoOperador
        ? [
            {
              value: ipOperadorSinMascara
            }
          ]
        : []
    }
  }
}

// SEG-H03: auditoria del plano de datos de Key Vault (lecturas de secretos) hacia Log Analytics.
// Mismo nombre, ambito y contenido que diagKv de infra/modulos/seguridad_perimetral.bicep:
// en Azure es UN solo recurso (el par ambito + nombre lo identifica) y desplegar el modulo
// S12 despues no crea un duplicado ni cambia nada. Si se modifica aqui, mantener el modulo igual.
resource diagKv 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-kv'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------
// 4. Base de datos: Azure SQL (solo autenticacion Entra ID, sin acceso publico)
// ---------------------------------------------------------------------
resource sqlServer 'Microsoft.Sql/servers@2021-11-01' = {
  name: 'sql-${sufijo}-${take(unico, 6)}'
  location: location
  tags: etiquetas
  properties: {
    minimalTlsVersion: '1.2'
    // C3: acceso publico solo mientras exista ipOperador (regla operador-temporal).
    publicNetworkAccess: accesoOperador ? 'Enabled' : 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'Group'
      login: sqlAdminGroupName
      sid: sqlAdminGroupObjectId
      tenantId: subscription().tenantId
    }
  }
}

// C3: regla temporal para el operador (solo si ipOperador no esta vacio).
resource sqlFirewallOperador 'Microsoft.Sql/servers/firewallRules@2021-11-01' = if (accesoOperador) {
  parent: sqlServer
  name: 'operador-temporal'
  properties: {
    startIpAddress: ipOperadorSinMascara
    endIpAddress: ipOperadorSinMascara
  }
}

// M-01: la auditoria de servidor con destino Azure Monitor envia los eventos (de todas las
// bases) a traves de la base master; sin esta configuracion de diagnostico no llegan a
// Log Analytics. Mismo nombre, ambito y contenido que diagSqlMaster de
// infra/modulos/seguridad_perimetral.bicep: en Azure es UN solo recurso y el modulo S12 no
// lo duplica. Si se modifica aqui, mantener el modulo igual.
resource sqlMaster 'Microsoft.Sql/servers/databases@2021-11-01' existing = {
  parent: sqlServer
  name: 'master'
}

resource diagSqlMaster 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-auditoria-sql'
  scope: sqlMaster
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
        enabled: true
      }
    ]
  }
}

// C5: auditoria del servidor hacia Azure Monitor (Log Analytics). Se crea despues del
// diagnostico de master (orden de la plantilla de referencia de Microsoft).
resource sqlAuditoria 'Microsoft.Sql/servers/auditingSettings@2021-11-01' = {
  parent: sqlServer
  name: 'default'
  dependsOn: [
    diagSqlMaster
  ]
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: true
    auditActionsAndGroups: [
      'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
      'FAILED_DATABASE_AUTHENTICATION_GROUP'
      'BATCH_COMPLETED_GROUP'
      'DATABASE_PERMISSION_CHANGE_GROUP'
      'DATABASE_PRINCIPAL_CHANGE_GROUP'
      'DATABASE_ROLE_MEMBER_CHANGE_GROUP'
      'SCHEMA_OBJECT_CHANGE_GROUP'
    ]
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2021-11-01' = {
  parent: sqlServer
  name: 'sqldb-cobranza'
  location: location
  tags: etiquetas
  sku: sqlDatabaseSku
  properties: {
    collation: 'Modern_Spanish_CI_AS'
    requestedBackupStorageRedundancy: sqlBackupRedundancy
  }
}

// B-01 (ADR-001 4.3): TDE declarado explicitamente (activo por defecto en Azure SQL).
resource sqlTde 'Microsoft.Sql/servers/databases/transparentDataEncryption@2021-11-01' = {
  parent: sqlDb
  name: 'current'
  properties: {
    state: 'Enabled'
  }
}

resource sqlPitr 'Microsoft.Sql/servers/databases/backupShortTermRetentionPolicies@2021-11-01' = {
  parent: sqlDb
  name: 'default'
  properties: {
    retentionDays: 35
  }
}

// Nota de costo: los respaldos LTR sobreviven a la eliminacion del servidor y del
// grupo de recursos y se siguen cobrando hasta su vencimiento (ver scripts/eliminar_entorno.sh).
resource sqlLtr 'Microsoft.Sql/servers/databases/backupLongTermRetentionPolicies@2021-11-01' = {
  parent: sqlDb
  name: 'default'
  properties: {
    weeklyRetention: 'P8W'
    monthlyRetention: 'P12M'
  }
}

// Diagnostico de sqldb-cobranza (errores). SQLSecurityAuditEvents aqui solo recibe datos si
// se habilita auditoria a nivel de base; con auditoria de servidor los eventos llegan por
// diagSqlMaster, por lo que no hay duplicacion.
resource sqlAuditDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-sqldb'
  scope: sqlDb
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
        enabled: true
      }
      {
        category: 'Errors'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------
// 5. Almacenamiento requerido por Azure Functions (acceso por identidad)
// ---------------------------------------------------------------------
// B-05: sufijo uniqueString de 6 caracteres, como el resto de los nombres (CLAUDE.md
// seccion 3). La version S6-S8 usaba 8; nada esta desplegado, el cambio no afecta recursos.
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${take(replace(prefijo, '-', ''), 8)}${ambiente}${take(unico, 6)}'
  location: location
  tags: etiquetas
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

var nombreContenedorDp = 'dataprotection-keys'
var dataProtectionBlobUri = '${storage.properties.primaryEndpoints.blob}${nombreContenedorDp}/keys.xml'

// ADR-001 5.5: contenedor dedicado al anillo de claves de Data Protection de la API.
// Se crea por el plano de control (funciona sin clave compartida ni acceso publico).
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource dpContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: nombreContenedorDp
  properties: {
    publicAccess: 'None'
  }
}

// ADR-001 5.5: clave RSA que protege el anillo (ProtectKeysWithAzureKeyVault). ARM crea la
// clave solo si no existe; un redespliegue no genera versiones nuevas. La API usa el
// identificador sin version (DataProtection__KeyIdentifier).
resource dpKey 'Microsoft.KeyVault/vaults/keys@2023-07-01' = {
  parent: keyVault
  name: 'dataprotection-cobranza-api'
  properties: {
    kty: 'RSA'
    keySize: 2048
    keyOps: [
      'wrapKey'
      'unwrapKey'
    ]
    attributes: {
      enabled: true
      exportable: false
    }
  }
}

// ---------------------------------------------------------------------
// 6. Correo: Azure Communication Services (Email, dominio administrado)
// ---------------------------------------------------------------------
resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = {
  name: 'ecs-${sufijo}'
  location: 'global'
  tags: etiquetas
  properties: {
    dataLocation: acsDataLocation
  }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  tags: etiquetas
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource acs 'Microsoft.Communication/communicationServices@2023-04-01' = {
  name: 'acs-${sufijo}-${take(unico, 6)}'
  location: 'global'
  tags: etiquetas
  properties: {
    dataLocation: acsDataLocation
    linkedDomains: [
      emailDomain.id
    ]
  }
}

// Secreto creado por el plano de control (funciona aunque el vault no tenga acceso publico).
resource secretAcs 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'acs-connection-string'
  properties: {
    value: acs.listKeys().primaryConnectionString
  }
}

var remitente = 'DoNotReply@${emailDomain.properties.mailFromSenderDomain}'

// ---------------------------------------------------------------------
// 7. Computo backend: plan Linux, API (.NET 10) y Function App (jobs)
// ---------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-${sufijo}'
  location: location
  tags: etiquetas
  kind: 'linux'
  sku: {
    name: appServicePlanSku
  }
  properties: {
    reserved: true
  }
}

// Mismo formato que scripts/s10_configurar_jobs.sh y scripts/s11_configurar_api.sh.
var sqlConnection = 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Database=${sqlDb.name};Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;'

resource apiApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-api-${sufijo}-${take(unico, 6)}'
  location: location
  tags: etiquetas
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: subnetAppId
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      vnetRouteAllEnabled: true
      healthCheckPath: '/salud'
      // ADR-001 5.11 (regla de transicion, A-01): entrada por defecto Deny mientras la
      // transicion este vigente. Unica regla de permiso: 'operador-transicion' (SEG-H11),
      // con la IP de ipOperador /32; ipOperador vacio = sin reglas de permiso.
      // Sonda /salud: si la restriccion la afecta queda PENDIENTE de verificar en Azure
      // (ADR 5.11 regla 3); con una sola instancia B1 la sonda no reemplaza instancias.
      ipSecurityRestrictionsDefaultAction: 'Deny'
      ipSecurityRestrictions: reglasTransicionApi
      // SCM (Kudu): no hereda las reglas del sitio principal y queda en Deny sin reglas de
      // permiso. La publicacion abre temporalmente 'operador-publicacion' con
      // scripts/s12_endurecer.sh (IP_PUBLICACION_SCM), decision de seguridad (ADR 5.11 regla 3).
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // Clave leida por src/Cobranza.Api (GetConnectionString("Cobranza")).
          name: 'ConnectionStrings__Cobranza'
          value: sqlConnection
        }
        {
          // ADR-001 5.5: anillo de claves de Data Protection en Blob Storage (identidad del sistema).
          name: 'DataProtection__BlobUri'
          value: dataProtectionBlobUri
        }
        {
          // ADR-001 5.5: clave RSA de Key Vault que cifra el anillo. Identificador SIN version.
          name: 'DataProtection__KeyIdentifier'
          value: dpKey.properties.keyUri
        }
        {
          // ADR-001 5.4.1 regla 3: ForwardLimit (1 sin WAF; 2 con WAF D11).
          name: 'Seguridad__SaltosProxyConfiables'
          value: string(saltosProxyConfiables)
        }
        {
          // ADR-001 5.4.1 regla 1: una sola instancia del middleware, configurada en Program.cs.
          // Con 'true' la API no arranca (validacion del desarrollador).
          name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED'
          value: 'false'
        }
        // Los demas Seguridad__* (valores DEMO de ADR 5.4) estan en src/Cobranza.Api/appsettings.json;
        // no se repiten aqui para no tener dos fuentes del mismo valor.
      ]
    }
  }
}

resource funcApp 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-jobs-${sufijo}-${take(unico, 6)}'
  location: location
  tags: etiquetas
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    virtualNetworkSubnetId: subnetAppId
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      alwaysOn: true
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: true
      // Los jobs no reciben HTTP: entrada Deny y SCM sin herencia en Deny (igual que
      // s12_endurecer.sh), para que un redespliegue de main no deje la Function App abierta.
      ipSecurityRestrictionsDefaultAction: 'Deny'
      scmIpSecurityRestrictionsUseMain: false
      scmIpSecurityRestrictionsDefaultAction: 'Deny'
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // %CRON_SINCRONIZACION% en SincronizacionFunction (UTC).
          name: 'CRON_SINCRONIZACION'
          value: cronSincronizacion
        }
        {
          // %CRON_NOTIFICACIONES% en NotificacionesFunction (UTC). Chile continental alterna
          // UTC-3 (verano) y UTC-4 (invierno): 12:00 UTC = 09:00 u 08:00 hora local.
          name: 'CRON_NOTIFICACIONES'
          value: cronNotificaciones
        }
        {
          name: 'Cobranza__SqlCobranza'
          value: sqlConnection
        }
        {
          // Fuente simulada en la misma base mientras no se defina la BD de la embotelladora.
          name: 'Cobranza__SqlOrigen'
          value: '${sqlConnection}ApplicationIntent=ReadOnly;'
        }
        {
          name: 'Cobranza__VistaOrigen'
          value: 'origen_sim.vw_ClientesRegularizados'
        }
        {
          name: 'Cobranza__AcsConnectionString'
          value: '@Microsoft.KeyVault(SecretUri=${secretAcs.properties.secretUri})'
        }
        {
          name: 'Cobranza__RemitenteCorreo'
          value: remitente
        }
        {
          // valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)
          name: 'Cobranza__DiasPreaviso'
          value: string(diasPreaviso)
        }
        {
          // valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)
          name: 'Cobranza__DiasMora1'
          value: string(diasMora1)
        }
        {
          // valores de demostracion, no definidos por Finanzas (pendiente 3, CLAUDE.md seccion 8)
          name: 'Cobranza__DiasMora2'
          value: string(diasMora2)
        }
        {
          name: 'Cobranza__MaxCorreosPorEjecucion'
          value: string(maxCorreosPorEjecucion)
        }
        {
          name: 'Cobranza__PausaEntreCorreosMs'
          value: string(pausaEntreCorreosMs)
        }
        {
          name: 'Cobranza__NombreEmpresa'
          value: 'Embotelladora del Pacifico S.A.'
        }
        {
          name: 'Cobranza__CanalesPagoTexto'
          value: canalesPagoTexto
        }
        {
          name: 'Cobranza__TelefonoContacto'
          value: telefonoContacto
        }
        {
          name: 'Cobranza__CorreoContacto'
          value: correoContacto
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------
// 8. Private Endpoints (IP fijas, C1; NIC con nombre fijo, C2) y zonas DNS privadas
//    cidrHost(subred, n) devuelve la direccion n+1 de la subred: n=3 => x.4.
// ---------------------------------------------------------------------
var privados = [
  {
    nombre: 'sql'
    recursoId: sqlServer.id
    grupo: 'sqlServer'
    miembro: 'sqlServer'
    ip: cidrHost(prefijoSnetPe, 3)
    zona: 'privatelink${environment().suffixes.sqlServerHostname}'
  }
  {
    nombre: 'kv'
    recursoId: keyVault.id
    grupo: 'vault'
    miembro: 'default'
    ip: cidrHost(prefijoSnetPe, 4)
    zona: 'privatelink.vaultcore.azure.net'
  }
  {
    nombre: 'blob'
    recursoId: storage.id
    grupo: 'blob'
    miembro: 'blob'
    ip: cidrHost(prefijoSnetPe, 5)
    zona: 'privatelink.blob.${environment().suffixes.storage}'
  }
  {
    nombre: 'queue'
    recursoId: storage.id
    grupo: 'queue'
    miembro: 'queue'
    ip: cidrHost(prefijoSnetPe, 6)
    zona: 'privatelink.queue.${environment().suffixes.storage}'
  }
  {
    nombre: 'table'
    recursoId: storage.id
    grupo: 'table'
    miembro: 'table'
    ip: cidrHost(prefijoSnetPe, 7)
    zona: 'privatelink.table.${environment().suffixes.storage}'
  }
]

resource zonas 'Microsoft.Network/privateDnsZones@2020-06-01' = [for p in privados: {
  name: p.zona
  location: 'global'
  tags: etiquetas
}]

resource enlaces 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (p, i) in privados: {
  parent: zonas[i]
  name: 'link-${vnet.name}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

resource endpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for p in privados: {
  name: 'pe-${p.nombre}-${sufijo}'
  location: location
  tags: etiquetas
  properties: {
    subnet: {
      id: subnetPeId
    }
    customNetworkInterfaceName: 'nic-pe-${p.nombre}-${sufijo}'
    ipConfigurations: [
      {
        name: 'ipcfg-${p.nombre}'
        properties: {
          groupId: p.grupo
          memberName: p.miembro
          privateIPAddress: p.ip
        }
      }
    ]
    privateLinkServiceConnections: [
      {
        name: 'plsc-${p.nombre}'
        properties: {
          privateLinkServiceId: p.recursoId
          groupIds: [
            p.grupo
          ]
        }
      }
    ]
  }
}]

resource dnsGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (p, i) in privados: {
  parent: endpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: replace(p.zona, '.', '-')
        properties: {
          privateDnsZoneId: zonas[i].id
        }
      }
    ]
  }
}]

// ---------------------------------------------------------------------
// 9. Permisos minimos (RBAC) para las identidades administradas y el operador
// ---------------------------------------------------------------------
var rolKvSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var rolKvSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var rolKvCryptoUser = '12338af0-0e69-4776-bea7-57ae8d297424'
var rolBlobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var rolBlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var rolQueueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var rolTableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

// ADR-001 5.5.1: la API no tiene ningun rol de secretos en Key Vault (se retiro raKvApi).

// ADR-001 5.5.1: la Function App solo lee el secreto acs-connection-string
// (referencia de Cobranza__AcsConnectionString), no todo el vault.
resource raKvFunc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secretAcs.id, funcApp.id, rolKvSecretsUser)
  scope: secretAcs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rolKvSecretsUser)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Operador humano: crea, deshabilita y elimina los secretos de claves de API
// (apikey-<consumidor>-<prefijo>, ADR-001 5.9) con scripts/s11_alta_clave_api.sh y
// s11_revocar_clave_api.sh.
resource raKvOperador 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, operadorObjectId, rolKvSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rolKvSecretsOfficer)
    principalId: operadorObjectId
    principalType: 'User'
  }
}

// ADR-001 5.5.1: API con Key Vault Crypto User solo sobre la clave de Data Protection
// (Get, Wrap Key, Unwrap Key).
resource raKvCryptoApi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dpKey.id, apiApp.id, rolKvCryptoUser)
  scope: dpKey
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rolKvCryptoUser)
    principalId: apiApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ADR-001 5.5.1: API con Storage Blob Data Contributor solo sobre el contenedor dataprotection-keys.
resource raBlobApi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dpContainer.id, apiApp.id, rolBlobContributor)
  scope: dpContainer
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rolBlobContributor)
    principalId: apiApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ADR-001 5.5.1: Storage Blob Data Owner (minimo para AzureWebJobsStorage) sobre la cuenta,
// con condicion ABAC v2.0: las acciones de datos de blob listadas solo se permiten si el
// contenedor NO es dataprotection-keys. Las acciones de administracion del rol (p. ej.
// eliminar el contenedor) no admiten condiciones: riesgo residual aceptado (ADR 5.5.1).
// No se supone que funcione hasta la prueba negativa SEG-DP-03 en Azure.
var accionesBlobRestringidas = [
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/deleteBlobVersion/action'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/permanentDelete/action'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/read'
  'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/tags/write'
]
var condicionSinDataProtection = '((${join(map(accionesBlobRestringidas, a => '!(ActionMatches{\'${a}\'})'), ' AND ')}) OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringNotEquals \'${nombreContenedorDp}\'))'

resource raBlobFunc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, funcApp.id, rolBlobOwner)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rolBlobOwner)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
    description: 'AzureWebJobsStorage; sin acceso a datos del contenedor dataprotection-keys (ADR-001 5.5.1)'
    conditionVersion: '2.0'
    condition: condicionSinDataProtection
  }
}

// Cola y tabla sin cambio en ADR-001 (B-09: revisar si Queue es necesario solo con temporizadores).
resource raStorageFunc 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for rol in [
  rolQueueContributor
  rolTableContributor
]: {
  name: guid(storage.id, funcApp.id, rol)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', rol)
    principalId: funcApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

// ---------------------------------------------------------------------
// Salidas (nombres usados por scripts/s10_*, s11_*, s12_*, s14_* y por
// infra/modulos/seguridad_perimetral.bicep; usuarios SQL para sqlcmd -v)
// ---------------------------------------------------------------------
output apiHostName string = apiApp.properties.defaultHostName
output apiAppName string = apiApp.name
output funcAppName string = funcApp.name
output funcHostName string = funcApp.properties.defaultHostName
output apiPrincipalId string = apiApp.identity.principalId
output funcPrincipalId string = funcApp.identity.principalId
output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDb.name
output keyVaultName string = keyVault.name
output storageName string = storage.name
output acsName string = acs.name
output logAnalyticsName string = logAnalytics.name
output vnetName string = vnet.name
output remitenteCorreo string = remitente
output usuarioFunctionApp string = funcApp.name
output usuarioApi string = apiApp.name
output accesoOperadorAbierto bool = accesoOperador
// ADR-001 5.5: valores de DataProtection__* (para verificacion; no son secretos)
output dataProtectionBlobUri string = dataProtectionBlobUri
output dataProtectionKeyId string = dpKey.properties.keyUri
output dataProtectionContainer string = nombreContenedorDp
output saltosProxyConfiables int = saltosProxyConfiables
// C4: IP fijas de los Private Endpoints
output ipPeSql string = privados[0].ip
output ipPeKeyVault string = privados[1].ip
output ipPeBlob string = privados[2].ip
output ipPeQueue string = privados[3].ip
output ipPeTable string = privados[4].ip
