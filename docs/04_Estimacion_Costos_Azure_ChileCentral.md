# Estimación de costos Azure en producción — Cobranza Automatizada

Proyecto APT Cobranza Automatizada — Embotelladora del Pacífico S.A.
Versión 2 — 10 de octubre de 2026. Reemplaza la estimación del entorno base.

- Fuente de precios: Azure Retail Prices API (precios de lista públicos que usa la Calculadora de Azure), consultados el 10-10-2026.
- Moneda y modalidad: USD, pago por uso, sin impuestos ni descuentos.
- Mes de cálculo: 730 horas.
- Arquitectura: entorno base S6-S8 más la opción B (Application Gateway WAF v2 delante de App Service con Private Endpoint, sin acceso público).

## 1. Validación de región

| Servicio | Región de precio | Observación |
| --- | --- | --- |
| App Service (Linux B1) | Chile Central | Disponible |
| Azure SQL Database (S0) | Chile Central | Disponible |
| Application Gateway WAF v2 | Chile Central | Disponible |
| IP pública Standard | Chile Central | Disponible |
| VPN Gateway (VpnGw1AZ) | Chile Central | Disponible |
| Key Vault | Chile Central | Disponible |
| Storage (Hot ZRS) | Chile Central | Disponible |
| Log Analytics / Application Insights | Chile Central | Disponible |
| Private Endpoint | Global | El recurso se despliega en la VNet de Chile Central; la tarifa es Global |
| DNS privado | Global | Recurso global |
| Azure Communication Services (Email) | Estados Unidos (East US) | Chile no es una ubicación de datos disponible (Brasil es la única opción en Sudamérica). Se usa Estados Unidos por decisión del equipo. Precio idéntico a la tarifa Global |

## 2. Flujo simulado de correos (supuestos a validar con Finanzas)

| Concepto | Supuesto | Correos al mes |
| --- | --- | --- |
| Base de facturación | 250 clientes con crédito, 4 facturas al mes cada uno (1.000 facturas) | — |
| Preaviso 5 días antes del vencimiento | Todas las facturas | 1.000 |
| Aviso el día del vencimiento | Todas las facturas | 1.000 |
| Recordatorios por mora | 20 % de las facturas, 2 recordatorios cada una | 400 |
| Aviso de suspensión | 5 % de los clientes | 12 |
| Resumen diario a Finanzas | 22 días hábiles | 22 |
| Total | 60 KB por correo (142,6 MB) | 2.434 |

Consideración operativa: el promedio es de 111 correos por día hábil, lo que supera el límite inicial de 100 correos por hora del dominio administrado de ACS. En producción se requiere el dominio propio de la embotelladora verificado (SPF, DKIM, DMARC) y solicitar aumento de límite, o que el job escalone los envíos.

## 3. Costo mensual — escenario base de producción

| Componente | Supuesto / cantidad | Precio unitario | USD/mes |
| --- | --- | --- | --- |
| Application Gateway WAF v2, costo fijo | 1 gateway, 730 h | 0,50292 por hora | 367,13 |
| Application Gateway WAF v2, unidades de capacidad | Autoescalado con mínimo 0, promedio 2 CU | 0,020117 por CU-hora | 29,37 |
| IP pública Standard (Application Gateway) | 1 | 0,005 por hora | 3,65 |
| Private Endpoints | 6 (5 del entorno base + 1 de App Service) | 0,01 por hora cada uno | 43,80 |
| Zonas DNS privadas | 6 (una por endpoint) | 0,50 por zona al mes | 3,00 |
| Consultas de DNS privado | 0,5 millones | 0,40 por millón | 0,20 |
| Datos procesados por Private Link | 10 GB | 0,01 por GB | 0,10 |
| Azure SQL Database | Standard S0; PITR de 35 días incluido en el precio (modelo DTU) | 0,67746 por día | 20,61 |
| Respaldo LTR de SQL | Base de 2 GB × 20 copias (8 semanales + 12 mensuales) = 40 GB | 0,035 por GB al mes | 1,40 |
| App Service Plan Linux (API y Functions) | Basic B1, 1 instancia | 0,0238 por hora | 17,37 |
| Storage Hot ZRS (Functions) | 1 GB, 300.000 escrituras, 300.000 lecturas | 0,0322 por GB; 0,0875 y 0,0056 por 10.000 operaciones | 2,83 |
| Log Analytics / Application Insights | 6 GB de ingesta (primeros 5 GB sin costo) | 3,2131 por GB | 3,21 |
| Key Vault Standard | 50.000 operaciones | 0,03 por 10.000 | 0,15 |
| Azure Communication Services Email (East US) | 2.434 correos, 142,6 MB | 0,00025 por correo; 0,00012 por MB | 0,63 |
| Salida a internet | Menos de 100 GB | Primeros 100 GB sin costo | 0,00 |
| VNet, NSG, identidades administradas, Entra ID Free | — | Sin cargo | 0,00 |
| Total mensual | | | 493,45 |
| Total anual | | | 5.921,36 |

Notas:
- La documentación de Microsoft confirma que en el modelo DTU el almacenamiento PITR está incluido en el precio de la base de datos; el LTR se cobra por consumo real.
- Se agregó un sexto Private Endpoint porque la opción B requiere uno de entrada para App Service. Si uno de los 5 endpoints del entorno base ya correspondía a App Service, se deben restar USD 7,80 al mes (endpoint y su zona DNS).

## 4. Componente condicional: VPN S2S hacia la base de datos de la embotelladora

Aplica solo si la base de datos de la embotelladora está en servidores propios.

| Componente | Precio unitario | USD/mes |
| --- | --- | --- |
| VPN Gateway VpnGw1AZ (incluye hasta 10 túneles S2S) | 0,21 por hora | 153,30 |
| IP pública Standard | 0,005 por hora | 3,65 |
| Total VPN | | 156,95 |

| Escenario | USD/mes | USD/año |
| --- | --- | --- |
| Producción sin VPN | 493,45 | 5.921,36 |
| Producción con VPN S2S | 650,40 | 7.804,76 |

## 5. Sensibilidad

| Variación | Impacto mensual |
| --- | --- |
| Application Gateway con 2 instancias mínimas reservadas (20 CU) | +264,34 USD |
| Volumen de correos × 10 (24.340 al mes) | +5,60 USD |

## 6. No incluido

- Certificado TLS público para el listener del Application Gateway (costo externo a Azure).
- Entra ID P1 (requerido para acceso condicional).
- Microsoft Defender for Cloud.
- Planes de soporte de Azure.
- IVA y conversión a pesos chilenos.

## 7. Observaciones de arquitectura

- El WAF v2 representa el 80 % del costo base; es el costo de la seguridad perimetral exigida por la opción B.
- App Service B1 con una instancia no tiene redundancia de zona ni autoescalado; es el punto débil en continuidad operacional.

## 8. Fuentes

- Azure Retail Prices API: https://prices.azure.com/api/retail/prices
- Precios de VPN Gateway: https://azure.microsoft.com/en-us/pricing/details/vpn-gateway/
- Ubicación de datos de Azure Communication Services: https://learn.microsoft.com/en-us/azure/communication-services/concepts/privacy
- Respaldos automatizados de Azure SQL Database: https://learn.microsoft.com/en-us/azure/azure-sql/database/automated-backups-overview
- Calculadora de precios de Azure: https://azure.microsoft.com/es-es/pricing/calculator/
