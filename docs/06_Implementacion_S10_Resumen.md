# Implementación del proyecto - Avance semana 10 (17-10-2026)

Entregables finales: Implementacion_Proyecto_S10.docx y .pdf (27 páginas, sin notas al lector, índice con páginas, Figura 1 con íconos oficiales Azure V24) e Implementacion_S10_Anexos.zip. Base: plantilla y scripts SQL entregados en semana 8 (aportados por el usuario el 17-10-2026).

## Estado
Sin suscripción de Azure; nada desplegado. **El despliegue de los recursos y las pruebas en Azure (P01-P37) quedan programados para la semana 11** (indicación del usuario, 17-10-2026). Validaciones reales del 17-10-2026: bicep build, lint y build-params (Bicep 0.48.1) sin errores ni advertencias; bash -n y ShellCheck 0.10.0 sin hallazgos; plan de direccionamiento 15/15 OK.

## Cambios main.bicep S8 a S10
C1 IP fijas de Private Endpoints (sql 10.20.2.4, kv .5 memberName default, blob .6, queue .7, table .8); C2 NIC con nombre fijo nic-pe-<x>-cobranza-dev; C3 parámetro ipOperador + regla SQL operador-temporal; C4 salidas con IP; C5 auditingSettings de SQL hacia Azure Monitor; C6 acsDataLocation = United States. 28 declaraciones / 46 recursos.

## Direccionamiento
VNet 10.20.0.0/16; snet-app 10.20.1.0/24 gw 10.20.1.1 (integración VNet, IP dinámica); snet-pe 10.20.2.0/24 gw 10.20.2.1. Reservadas Azure x.0-x.3 y x.255. IPv6 no aplica: Private Link IPv6 en preview, sin Chile Central, sin NSG.

## Hallazgos
- ACS dominio administrado: 5 correos/min y 10/h sin ampliación (30/100 son de dominio propio). Corrige S6-S8; el máximo de 90 por ejecución del job debe ajustarse.
- EPP: no aplica. Tablas 3.2 (estaciones) y 3.3 (versiones de herramientas) con PENDIENTE para completar por el equipo.
- Íconos V24: no incluyen Entra ID genérico ni Email Communication Services; se usaron Groups y Azure Communication Services rotulados.

## Scripts
scripts/desplegar.sh (8 pasos), scripts/verificar_despliegue.sh (P01-P32), scripts/validar_direccionamiento.py, docs/generar_topologia.py. Grupo de recursos rg-cobranza-apt, grupo Entra grp-cobranza-sql-admin.
