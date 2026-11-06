# Plantilla: apertura y cierre de la ventana del operador

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_ventana_operador.md` y completar allí; no completar este archivo.

Abrir la ventana (`ipOperador` con valor) habilita temporalmente Azure SQL (regla `operador-temporal`), Key Vault (una `ipRule`) y, según el diseño de `devops`, la regla de permiso de la Web App durante la transición (ADR-001 5.11). Cada sesión de trabajo se registra y termina con la ventana cerrada. Nunca se escribe la IP: se usa `<IP_OPERADOR>`.

## 1. Apertura

| Campo | Valor |
| --- | --- |
| Fecha y hora UTC | `<AAAA-MM-DDTHH:MMZ>` |
| Operador | `<nombre>` |
| Motivo | `<despliegue SQL / altas de usuarios / claves de API / pruebas RED / publicación>` |
| Aprobación humana del despliegue (CLAUDE.md regla 5) | `<nombre, hora>` |
| Despliegue de `main.bicep` con `ipOperador = <IP_OPERADOR>` | `<hora UTC, resultado>` |
| SCM abierto con `IP_PUBLICACION_SCM` | `<No / Sí: Function App / Web App (solo con ESTADO_TRANSICION=publicacion-aprobada)>` |

## 2. Actividades

| Hora UTC | Actividad | Evidencia |
| --- | --- | --- |
| `<HH:MMZ>` | `<texto>` | `<ruta>` |

## 3. Cierre (obligatorio en la misma sesión)

| Paso | Hora UTC | Resultado |
| --- | --- | --- |
| Despliegue de `main.bicep` con `ipOperador` vacío | `<HH:MMZ>` | `<resultado>` |
| `scripts/s12_endurecer.sh` sin `IP_PUBLICACION_SCM` (y sin `IP_OPERADOR` exportada) | `<HH:MMZ>` | `<resultado>` |
| SEG-11 y SEG-18 (SQL y Key Vault sin acceso público) | `<HH:MMZ>` | `<CUMPLE / NO CUMPLE>` |
| SEG-KV-06a, SEG-KV-06b, SEG-KV-06c | `<HH:MMZ>` | `<CUMPLE / NO CUMPLE>` |
| SEG-27 y SEG-28 (SCM sin reglas de permiso) | `<HH:MMZ>` | `<CUMPLE / NO CUMPLE>` |
| SEG-TR-01 y SEG-TR-02 (si rige la transición) | `<HH:MMZ>` | `<CUMPLE / NO CUMPLE>` |
| Matriz adjunta | — | `<ruta del CSV>` |

## 4. Observaciones

`<sin observaciones / texto>`
