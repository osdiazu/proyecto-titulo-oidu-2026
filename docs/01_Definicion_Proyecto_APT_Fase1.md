# Guía Estudiante — Definición Proyecto APT (Fase 1)

Versión en texto de `1.5_GuiaEstudiante_Fase 1_Definicion Proyecto APT_G1.docx` (archivo original en el Proyecto de claude.ai). Se limpiaron marcas de formato; el contenido se mantiene. Se omitieron los RUT de los integrantes para no versionarlos en el repositorio.

Nota: esta guía es la definición inicial (Fase 1). Varias decisiones fueron reemplazadas después (pasarela de pago, SMTP, PostgreSQL/MySQL, "tiempo real"). Ver `CLAUDE.md`, secciones 2, 5 y 9.

## 1. Antecedentes

- Integrantes: José Cartes Mardones, Oscar Díaz Ulloa, Arnaldo Muñoz González, Germán Muñoz Manríquez, Dariel Zúñiga.
- Carrera: Ingeniería en Infraestructura y Plataformas Tecnológicas.
- Sede: Antonio Varas.

## 2. Descripción

- Nombre del proyecto: Proyecto cobranza automatizada.
- Áreas de desempeño: Cobranzas, informática.
- Competencias:
  1. Implementar políticas de seguridad en plataformas tecnológicas para apoyar la continuidad operacional de los servicios TI.
  2. Diseñar soluciones de infraestructura de plataformas tecnológicas para apoyar la continuidad operacional de los servicios TI.
  3. Gestionar proyectos de implementación de tecnologías controlando su avance de acuerdo a las buenas prácticas de la industria.
  4. Implementar sistemas de almacenamiento, respaldo y recuperación de información en una organización que aseguren la continuidad operacional de los servicios TI.

## 3. Fundamentación

### Relevancia
- Automatizar procesos de cobranza del cliente de forma más eficiente y certera, evitando errores humanos.
- Permite desarrollar competencias del perfil de egreso (BBDD, infraestructura cloud, ITIL, entre otros).
- Ubicación: Chile, Región Metropolitana, comuna de Buin. Embotelladora del Pacífico S.A.: producción, envasado y distribución de bebidas analcohólicas (aguas purificadas, saborizadas y sodas artesanales), 45 colaboradores, distribución regional a supermercados locales, minimarkets, hoteles y restaurantes.

### Afectados
- Clientes externos B2B (dueños o encargados de adquisiciones/finanzas):
  - Adultos jóvenes (25 a 40 años): impacto muy positivo; habituados a canales digitales.
  - Adultos mayores y tradicionales (41 a 65+): impacto sensible; preferencia por trato humano, efectivo o transferencia; desconfianza ante correos (phishing). Mitigación: interfaz simple, clara y con validación oficial de la embotelladora.
- Segmentos comerciales: clientes con crédito comercial (facturas a 30 o 60 días) y clientes suspendidos por no pago (pedidos retenidos).
- Usuarios internos: Finanzas y Tesorería (de cobranza manual a supervisión), Fuerza de Ventas (consulta del estado del cliente antes de levantar pedidos), TI/Infraestructura (monitoreo de integraciones, correo saliente y seguridad perimetral).

### Aporte de valor
- Organizacional: mejor flujo de caja y menor morosidad; menos errores y carga operativa; desbloqueo más rápido de pedidos.
- Tecnológico: integración de servicios con seguridad perimetral; información en terreno para Ventas.
- Social: autogestión simple para comercios; reducción de la brecha digital.

### Descripción (versión Fase 1)
Plataforma web e infraestructura integrada para automatizar la recaudación de facturas a crédito: alertas por correo antes y al vencimiento, portal de autoservicio con pasarela de pagos, validación y desbloqueo automático de pedidos, visibilidad para Ventas y Finanzas. Etapas: levantamiento y diseño; infraestructura y conectividad; integración de servicios; pruebas y control de calidad.

### Factibilidad
16 a 18 semanas; 4 horas semanales de asignatura más trabajo autónomo de 2 horas martes y miércoles; entornos virtuales, herramientas open source, nube y sandboxes; guía docente y documentación oficial; 5 integrantes.

## 4. Objetivos

Objetivo general: diseñar e implementar una solución automatizada de cobranzas e infraestructura de plataformas tecnológicas para Embotelladora del Pacífico S.A., integrando un portal de pagos, el envío automático de notificaciones por correo electrónico y la sincronización en tiempo real con la base de datos de clientes, con el propósito de reducir la morosidad, automatizar la liberación de pedidos retenidos y asegurar la continuidad operacional de los servicios TI.

Objetivos específicos:
1. Diseñar la arquitectura de infraestructura para los servicios de cobranza (base de datos de clientes, servidor de correo, APIs y seguridad perimetral).
2. Implementar y configurar servidores y plataformas, asegurando rendimiento, disponibilidad y respaldo.
3. Desarrollar e integrar el módulo de notificaciones y pagos.
4. Automatizar la sincronización de estados financieros y la liberación de pedidos retenidos.
5. Ejecutar pruebas integrales (E2E) y de seguridad perimetral.

## 5. Metodología

Cascada (Waterfall): Inicio y Requerimientos, Diseño, Implementación y Configuración, Pruebas y Verificación, Cierre.

| Etapa | Semanas |
| --- | --- |
| 1. Análisis de requerimientos y levantamiento | 1 a 4 |
| 2. Diseño de la solución e infraestructura | 5 a 8 |
| 3. Construcción e implementación | 9 a 12 |
| 4. Pruebas integrales y control de calidad | 13 a 15 |
| 5. Cierre y documentación final | 16 a 18 |

Roles declarados:
- Arnaldo Muñoz González — Líder de Proyecto y Gestión TI (planificación, control de avance, Carta Gantt, comunicación con el docente).
- Oscar Díaz Ulloa — Especialista en Infraestructura y Servidores (servidores backend, sistema operativo, virtualización, disponibilidad).
- Dariel Zúñiga Romero — Especialista en Bases de Datos y Almacenamiento (modelo relacional, motor, triggers y procedimientos, respaldos).
- José Cartes Mardones — Especialista en Conectividad e Integración (correo saliente, APIs, scripts de conciliación).
- Germán Muñoz Manríquez — Especialista en Ciberseguridad y Pruebas QA (firewall, cifrado, casos E2E, validación de continuidad).

## 6. Evidencias acordadas

| Tipo | Evidencia | Descripción |
| --- | --- | --- |
| Avance | Informe de Levantamiento de Requerimientos y Diseño de Arquitectura | Requisitos, topología, modelo de datos, integración de correo y API |
| Avance | Prototipeo y Despliegue de Entorno Base | Backend, motor de base de datos y reglas iniciales de seguridad |
| Final | Plataforma de Cobranza Automatizada e Integración de Servicios | Demostración del flujo completo |
| Final | Informe Final y Plan de Pruebas / Continuidad TI | Memoria técnica, manual, pruebas E2E y de seguridad, respaldo y recuperación |

## 7. Plan de trabajo

| Actividad | Duración | Responsable |
| --- | --- | --- |
| Levantamiento de requerimientos y planificación general | S1 a S3 | José Cartes Mardones |
| Diseño de arquitectura de infraestructura y conectividad | S3 a S5 | Oscar Díaz Ulloa |
| Diseño del modelo de datos y políticas de respaldo | S4 a S6 | Arnaldo Muñoz González |
| Despliegue y configuración de servidores backend | S6 a S8 | Oscar Díaz Ulloa |
| Desarrollo e integración del módulo de notificaciones y pagos | S7 a S10 | Germán Muñoz Manríquez |
| Integración del desbloqueo automático de pedidos en BD | S8 a S11 | Arnaldo Muñoz González |
| Configuración de seguridad perimetral y protección de datos | S10 a S12 | Dariel Zúñiga |
| Pruebas integrales (E2E) y de continuidad TI | S12 a S14 | Dariel Zúñiga |
| Documentación final, manuales e informe APT | S13 a S15 | José Cartes Mardones |

## 8. Carta Gantt

| Actividad | Responsable | Semanas |
| --- | --- | --- |
| 1. Levantamiento de requerimientos y planificación | José Cartes M. | S1-S3 |
| 2. Diseño de arquitectura de integración y conectividad API | Oscar Díaz U. | S3-S5 |
| 3. Modelado de base de datos y políticas de respaldo | Arnaldo Muñoz G. | S4-S6 |
| 4. Despliegue y configuración de servidores backend | Oscar Díaz U. | S6-S8 |
| 5. API de conexión entre BD y módulo de notificación | Germán Muñoz M. | S7-S10 |
| 6. Automatización de estados y desbloqueo en BD | Arnaldo Muñoz G. | S9-S11 |
| 7. Seguridad perimetral y autenticación API | Dariel Zúñiga | S10-S12 |
| 8. Pruebas integrales (E2E) y continuidad TI | Dariel Zúñiga | S12-S14 |
| 9. Documentación final, manuales e informe | José Cartes M. | S13-S15 |

Fases: Fase 1 (S1-S4) definición, requerimientos, diseño y modelo de datos. Fase 2 (S5-S11) infraestructura, backend, API, módulo de correo y seguridad. Fase 3 (S12-S15) pruebas E2E, corrección, documentación, manuales y defensa.
