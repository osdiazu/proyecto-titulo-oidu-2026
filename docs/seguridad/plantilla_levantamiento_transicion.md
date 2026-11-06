# Plantilla: levantamiento de la regla de transición (ADR-001 sección 5.11)

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_levantamiento_transicion.md` y completar allí; no completar este archivo.

`scripts/s12_endurecer.sh` con `ESTADO_TRANSICION=levantada` exige `APROBACION_LEVANTAMIENTO=<ruta de la copia completada>` y rechaza el archivo si la fila "Aprobado por" está vacía. Ese control solo comprueba que la fila tenga texto: la validez de la aprobación es responsabilidad humana.

Levantar la restricción es relajar una regla de red. Solo procede con todas las condiciones de la sección 1 cumplidas y aprobación humana explícita (reglas del agente `seguridad` y CLAUDE.md regla 5). El script no abre la Web App: deja de forzar `Deny`; la apertura efectiva la define `infra/main.bicep` (cambio de `devops`).

## 1. Condiciones (ADR-001 5.11, reglas 1 y 4)

| Condición | Evidencia (ruta) | Cumple |
| --- | --- | --- |
| `EasyAuthHandler.cs` retirado y sin confianza en `X-MS-CLIENT-PRINCIPAL` | `<ruta>` | `<Sí / No>` |
| ADR-001 implementado y compilado (`dotnet build` sin errores) | `<ruta>` | `<Sí / No>` |
| Pruebas en verde (`dotnet test`) | `<ruta>` | `<Sí / No>` |
| Informe de `qa` APROBADO o APROBADO CON OBSERVACIONES | `<ruta>` | `<Sí / No>` |
| RED-02 y RED-11 a RED-16 ejecutadas desde `<IP_OPERADOR>` con resultado CUMPLE | `<ruta>` | `<Sí / No>` |
| RED-17 desde una red externa: 403 (antes de levantar) | `<ruta>` | `<Sí / No>` |
| `s12_verificar_seguridad.sh` sin NO CUMPLE en SEG-05, SEG-KV-01, SEG-KV-02, SEG-DP-01, SEG-DP-02, SEG-DP-03a, SEG-FH-01 | `<ruta>` | `<Sí / No>` |
| Prueba negativa SEG-DP-03b (403) | `<ruta>` | `<Sí / No>` |
| Si D11 está aprobado: se reemplaza por el cierre de acceso público de la opción B (no se levanta) | `<ruta o no aplica>` | `<Sí / No aplica>` |

## 2. Aprobación

| Campo | Valor |
| --- | --- |
| Aprobado por |  |
| Rol del aprobador en el equipo |  |
| Fecha y hora UTC de la aprobación |  |
| Riesgo residual aceptado | Formulario de login expuesto a Internet sin MFA ni WAF (ADR-001 4.2) |
| Cambio en `infra/main.bicep` que abre la entrada (commit) |  |

## 3. Ejecución

| Paso | Hora UTC | Resultado |
| --- | --- | --- |
| Despliegue de `main.bicep` con el cambio aprobado | `<HH:MMZ>` | `<resultado>` |
| `ESTADO_TRANSICION=levantada APROBACION_LEVANTAMIENTO=<ruta> scripts/s12_endurecer.sh` | `<HH:MMZ>` | `<resultado>` |
| `ESTADO_TRANSICION=levantada scripts/s12_verificar_seguridad.sh` | `<HH:MMZ>` | `<matriz adjunta>` |

## 4. Observaciones

`<sin observaciones / texto>`
