// =============================================================================
// seguridad_perimetral.bicep - Proyecto APT Cobranza Automatizada (Evidencia S12)
//
// Agrega la capa de seguridad perimetral y observabilidad sobre el entorno base
// desplegado en S6-S8. Solo CREA recursos nuevos o recursos hijos; NO vuelve a
// declarar los recursos principales existentes (Web App, Function App, SQL,
// Key Vault), para no sobrescribir su configuracion. Los cambios de propiedades
// de esos recursos (restricciones de acceso, TLS) se aplican con
// scripts/s12_endurecer.sh.
//
// Contenido:
//   1. Private Endpoint de entrada para la API + zona DNS privatelink.azurewebsites.net
//   2. (desplegarWaf = true) Subred y NSG del Application Gateway, IP publica,
//      politica WAF (OWASP 3.2, modo Prevencion) y Application Gateway WAF v2
//   3. Auditoria de Azure SQL y TDE explicito
//   4. Configuraciones de diagnostico hacia Log Analytics (Key Vault, ACS, App GW)
//   5. Grupo de acciones y alertas de operacion
//
// Costo: el Application Gateway WAF v2 representa USD 400,15/mes (estimacion
// de costos v2). desplegarWaf = false por defecto hasta contar con aprobacion
// (Acta de Constitucion: todo costo se autoriza antes de habilitarse).
// =============================================================================
targetScope = 'resourceGroup'

@description('Region (la misma del entorno base).')
param location string = resourceGroup().location

@description('Recursos existentes del entorno base (S6-S8).')
param vnetName string
param subredPrivateEndpointsName string = 'snet-pe'
param webAppName string
param functionAppName string
param sqlServerName string
param sqlDatabaseName string
param keyVaultName string
param acsName string
param logAnalyticsName string

@description('Crear la zona DNS privatelink.azurewebsites.net (false si ya existe en el grupo de recursos).')
param crearZonaDnsWeb bool = true

@description('Desplegar Application Gateway WAF v2 (requiere aprobacion de costo y certificado).')
param desplegarWaf bool = false

@description('Prefijo de la subred del Application Gateway (dentro de 10.20.0.0/16, no usado por snet-app ni snet-pe).')
param prefijoSubredAgw string = '10.20.3.0/24'

@description('Nombre del NSG existente de la subred de Private Endpoints (S6-S8).')
param nsgPrivateEndpointsName string = 'nsg-pe'

@description('Prefijo de la subred de Private Endpoints (S6-S8).')
param prefijoSubredPe string = '10.20.2.0/24'

@description('Prioridad de la regla que permite 443 desde snet-agw hacia snet-pe. Debe ser menor (mas prioritaria) que la regla de denegacion existente en nsg-pe; verificar antes de desplegar.')
param prioridadReglaAgwPe int = 150

@description('Id del secreto del certificado TLS en Key Vault (https://<kv>.vault.azure.net/secrets/<nombre>). Obligatorio si desplegarWaf.')
param uriCertificadoKeyVault string = ''

@description('Correo que recibe las alertas de operacion.')
param correoAlertas string

@description('Etiquetas comunes.')
param tags object = {
  proyecto: 'cobranza-automatizada'
  evidencia: 'S12'
}

var sufijo = uniqueString(resourceGroup().id)
var nombreAgw = 'agw-cobranza-${sufijo}'

// ---------------------------------------------------------------------------
// Recursos existentes
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}
resource snetPe 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: subredPrivateEndpointsName
}
resource web 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}
resource func 'Microsoft.Web/sites@2023-12-01' existing = {
  name: functionAppName
}
resource sqlServer 'Microsoft.Sql/servers@2021-11-01' existing = {
  name: sqlServerName
}
resource sqlDb 'Microsoft.Sql/servers/databases@2021-11-01' existing = {
  parent: sqlServer
  name: sqlDatabaseName
}
resource sqlMaster 'Microsoft.Sql/servers/databases@2021-11-01' existing = {
  parent: sqlServer
  name: 'master'
}
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}
resource acs 'Microsoft.Communication/communicationServices@2023-04-01' existing = {
  name: acsName
}
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

// ---------------------------------------------------------------------------
// 1. Private Endpoint de entrada para la API
// ---------------------------------------------------------------------------
resource zonaWeb 'Microsoft.Network/privateDnsZones@2020-06-01' = if (crearZonaDnsWeb) {
  name: 'privatelink.azurewebsites.net'
  location: 'global'
  tags: tags
}
resource zonaWebExistente 'Microsoft.Network/privateDnsZones@2020-06-01' existing = if (!crearZonaDnsWeb) {
  name: 'privatelink.azurewebsites.net'
}
resource enlaceZonaWeb 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (crearZonaDnsWeb) {
  parent: zonaWeb
  name: 'link-${vnetName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource peWeb 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${webAppName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: snetPe.id
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${webAppName}'
        properties: {
          privateLinkServiceId: web.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
  }
}
resource peWebDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peWeb
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'azurewebsites'
        properties: {
          privateDnsZoneId: crearZonaDnsWeb ? zonaWeb.id : zonaWebExistente.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 2. Application Gateway WAF v2 (condicional)
// ---------------------------------------------------------------------------
resource nsgAgw 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (desplegarWaf) {
  name: 'nsg-agw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Permitir-GatewayManager'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Permitir-AzureLoadBalancer'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Permitir-HTTPS-Internet'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '443'
            '80'
          ]
        }
      }
    ]
  }
}

resource snetAgw 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = if (desplegarWaf) {
  parent: vnet
  name: 'snet-agw'
  properties: {
    addressPrefix: prefijoSubredAgw
    networkSecurityGroup: {
      id: nsgAgw.id
    }
  }
}

// El NSG de snet-pe (S6-S8) solo permite 1433 y 443 desde snet-app; se agrega 443 desde snet-agw.
resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' existing = {
  name: nsgPrivateEndpointsName
}
resource reglaAgwPe 'Microsoft.Network/networkSecurityGroups/securityRules@2023-11-01' = if (desplegarWaf) {
  parent: nsgPe
  name: 'Permitir-443-desde-snet-agw'
  properties: {
    priority: prioridadReglaAgwPe
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: prefijoSubredAgw
    sourcePortRange: '*'
    destinationAddressPrefix: prefijoSubredPe
    destinationPortRange: '443'
  }
}

resource pipAgw 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (desplegarWaf) {
  name: 'pip-${nombreAgw}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = if (desplegarWaf) {
  name: 'waf-cobranza'
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 1
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource idAgw 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (desplegarWaf) {
  name: 'id-${nombreAgw}'
  location: location
  tags: tags
}

// Key Vault Secrets User para leer el certificado TLS
resource rolKvAgw 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (desplegarWaf) {
  name: guid(kv.id, 'agw-kv-secrets-user', nombreAgw)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: desplegarWaf ? idAgw!.properties.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

resource agw 'Microsoft.Network/applicationGateways@2023-11-01' = if (desplegarWaf) {
  name: nombreAgw
  location: location
  tags: tags
  zones: [
    '1'
    '2'
    '3'
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${idAgw.id}': {}
    }
  }
  dependsOn: [
    rolKvAgw
    peWebDns
    reglaAgwPe
  ]
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 0
      maxCapacity: 2
    }
    firewallPolicy: {
      id: wafPolicy.id
    }
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }
    gatewayIPConfigurations: [
      {
        name: 'ipcfg'
        properties: {
          subnet: {
            id: snetAgw.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'fe-publica'
        properties: {
          publicIPAddress: {
            id: pipAgw.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'puerto-443'
        properties: {
          port: 443
        }
      }
      {
        name: 'puerto-80'
        properties: {
          port: 80
        }
      }
    ]
    sslCertificates: [
      {
        name: 'cert-publico'
        properties: {
          keyVaultSecretId: uriCertificadoKeyVault
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'pool-api'
        properties: {
          backendAddresses: [
            {
              fqdn: web.properties.defaultHostName
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'sondeo-salud'
        properties: {
          protocol: 'Https'
          path: '/salud'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'https-api'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', nombreAgw, 'sondeo-salud')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'escucha-https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', nombreAgw, 'fe-publica')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', nombreAgw, 'puerto-443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', nombreAgw, 'cert-publico')
          }
        }
      }
      {
        name: 'escucha-http'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', nombreAgw, 'fe-publica')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', nombreAgw, 'puerto-80')
          }
          protocol: 'Http'
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'http-a-https'
        properties: {
          redirectType: 'Permanent'
          targetListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', nombreAgw, 'escucha-https')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'regla-https'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', nombreAgw, 'escucha-https')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', nombreAgw, 'pool-api')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', nombreAgw, 'https-api')
          }
        }
      }
      {
        name: 'regla-http'
        properties: {
          ruleType: 'Basic'
          priority: 110
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', nombreAgw, 'escucha-http')
          }
          redirectConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', nombreAgw, 'http-a-https')
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 3. Azure SQL: TDE explicito y auditoria hacia Log Analytics
// ---------------------------------------------------------------------------
resource tde 'Microsoft.Sql/servers/databases/transparentDataEncryption@2021-11-01' = {
  parent: sqlDb
  name: 'current'
  properties: {
    state: 'Enabled'
  }
}

resource auditoriaSql 'Microsoft.Sql/servers/auditingSettings@2021-11-01' = {
  parent: sqlServer
  name: 'default'
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

// La auditoria con destino Azure Monitor requiere esta configuracion en la base master
resource diagSqlMaster 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-auditoria-sql'
  scope: sqlMaster
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 4. Diagnostico hacia Log Analytics
// ---------------------------------------------------------------------------
resource diagKv 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-kv'
  scope: kv
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
  }
}

resource diagAcs 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-acs'
  scope: acs
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource diagAgw 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (desplegarWaf) {
  name: 'diag-agw'
  scope: agw
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// 5. Alertas de operacion
// ---------------------------------------------------------------------------
resource grupoAcciones 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-cobranza-operacion'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'cobranza'
    enabled: true
    emailReceivers: [
      {
        name: 'operacion'
        emailAddress: correoAlertas
        useCommonAlertSchema: true
      }
    ]
  }
}

var alertasLog = [
  {
    nombre: 'alerta-job-fallido'
    descripcion: 'Una ejecucion de los jobs de sincronizacion o notificaciones termino con error.'
    severidad: 1
    frecuencia: 'PT15M'
    ventana: 'PT15M'
    consulta: 'AppRequests | where Name in ("SincronizarClientesRegularizados", "EnviarNotificacionesCobranza") and Success == false'
  }
  {
    nombre: 'alerta-sin-sincronizacion'
    descripcion: 'No hay ejecuciones exitosas del job de sincronizacion en la ultima hora (RPO de negocio).'
    severidad: 1
    frecuencia: 'PT30M'
    ventana: 'PT1H'
    consulta: 'AppRequests | where Name == "SincronizarClientesRegularizados" and Success == true | summarize n = count() | where n == 0'
  }
  {
    nombre: 'alerta-api-errores-5xx'
    descripcion: 'La API devolvio mas de 5 errores de servidor en 15 minutos.'
    severidad: 2
    frecuencia: 'PT5M'
    ventana: 'PT15M'
    consulta: 'AppRequests | where Url has "/api/v1/" and toint(ResultCode) >= 500 | summarize n = count() | where n > 5'
  }
  {
    nombre: 'alerta-acs-entrega-fallida'
    descripcion: 'Se registraron correos no entregados por ACS en la ultima hora.'
    severidad: 3
    frecuencia: 'PT1H'
    ventana: 'PT1H'
    consulta: 'ACSEmailStatusUpdateOperational | where isnotempty(DeliveryStatus) and DeliveryStatus != "Delivered"'
  }
]

resource reglasLog 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = [for a in alertasLog: {
  name: a.nombre
  location: location
  tags: tags
  properties: {
    displayName: a.nombre
    description: a.descripcion
    severity: a.severidad
    enabled: true
    evaluationFrequency: a.frecuencia
    windowSize: a.ventana
    scopes: [
      law.id
    ]
    criteria: {
      allOf: [
        {
          query: a.consulta
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        grupoAcciones.id
      ]
    }
  }
}]

resource alertaDtu 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alerta-sql-dtu-alto'
  location: 'global'
  tags: tags
  properties: {
    description: 'Consumo de DTU de la base de datos sobre 90 % durante 15 minutos.'
    severity: 2
    enabled: true
    scopes: [
      sqlDb.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'dtu'
          metricName: 'dtu_consumption_percent'
          operator: 'GreaterThan'
          threshold: 90
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: grupoAcciones.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Salidas
// ---------------------------------------------------------------------------
output privateEndpointApi string = peWeb.id
output ipPublicaWaf string = desplegarWaf ? pipAgw!.properties.ipAddress : 'no desplegado'
output functionAppRevisada string = func.name
