// =============================================================================
// autenticacion_api.bicep - Proyecto APT Cobranza Automatizada (Evidencia S11)
// Habilita la autenticacion integrada de App Service (Easy Auth v2) con
// Microsoft Entra ID sobre la Web App existente de la API.
// No modifica los ajustes de aplicacion (se cargan con s11_configurar_api.sh).
// Despliegue:
//   az deployment group create -g <rg> -f infra/modulos/autenticacion_api.bicep \
//     -p webAppName=<api> clientId=<appId del registro>
// =============================================================================
targetScope = 'resourceGroup'

@description('Nombre de la Web App de la API (existente, creada en S6-S8).')
param webAppName string

@description('Id de inquilino de Entra ID.')
param tenantId string = tenant().tenantId

@description('Application (client) ID del registro creado con s11_registro_entra_id.sh.')
param clientId string

@description('Rutas que no exigen autenticacion (sondeo de salud).')
param rutasExcluidas array = [
  '/salud'
]

resource web 'Microsoft.Web/sites@2023-12-01' existing = {
  name: webAppName
}

resource auth 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: web
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      excludedPaths: rutasExcluidas
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
          clientId: clientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        }
        validation: {
          allowedAudiences: [
            'api://${clientId}'
            clientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
    httpSettings: {
      requireHttps: true
      forwardProxy: {
        // Detras de Application Gateway (S12): el gateway envia el dominio publico original en
        // X-Original-Host; Easy Auth lo usa para construir las URL de redireccion del inicio de sesion.
        convention: 'Custom'
        customHostHeaderName: 'X-Original-Host'
      }
    }
  }
}

output autenticacionHabilitada bool = auth.properties.platform.enabled
