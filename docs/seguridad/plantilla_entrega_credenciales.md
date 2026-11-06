# Plantilla: entrega de credenciales del panel

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_entrega_credenciales.md` y completar allí; no completar este archivo.
Base: `docs/seguridad/politica_credenciales_y_accesos.md` (A.3, A.4, A.8, A.10) y ADR-001 sección 5.9.

Reglas para quien completa (obligatorias):
- No escribir la contraseña temporal ni la definitiva, ni el hash, ni capturas de pantalla.
- No escribir la IP pública del operador: usar `<IP_OPERADOR>`.
- No escribir Object IDs completos: truncar como `xxxx…xxxx` (4 primeros y 4 últimos caracteres).
- El script de alta o restablecimiento lo ejecutó un integrante humano en su propia terminal, no un agente de Claude Code (regla SEG-H01).
- Antes del commit, ejecutar la búsqueda de cadenas sospechosas (política, sección 0).

## 1. Operación

| Campo | Valor |
| --- | --- |
| Fecha y hora UTC de la operación | `<AAAA-MM-DDTHH:MMZ>` |
| Tipo | `<Alta / Restablecimiento / Desbloqueo / Baja>` |
| Usuario (nombre de usuario, patrón `[a-z0-9._-]`) | `<usuario>` |
| Rol | `<Finanzas / Ventas / Admin>` |
| Solicitud registrada por | `<nombre>` |
| Autoriza (responsable humano; CLAUDE.md sección 10) | `<nombre o PENDIENTE>` |
| Operador que ejecutó el script (miembro de `grp-cobranza-sql-admin`) | `<nombre>` |
| Script y modo | `<scripts/s11_alta_usuario.sh / s11_restablecer_clave.sh [--solo-desbloquear] / s11_baja_usuario.sh>` |
| Ejecutado fuera de Claude Code | `<Sí>` |
| Ventana de red usada | `ipOperador = <IP_OPERADOR>`; registro de la ventana: `<ruta a evidencias/seguridad/..._ventana_operador.md>` |

## 2. Entrega (solo alta y restablecimiento)

| Campo | Valor |
| --- | --- |
| Canal | Presencial con uso inmediato (política A.3) |
| Destinatario presente | `<Sí / No: si es No, la operación se posterga y no se entrega>` |
| Pantalla limpiada tras la lectura (`clear` y `\033[3J`) | `<Sí>` |
| Primer inicio de sesión del destinatario en su propio equipo | `<HH:MMZ>` |
| Evento `CambioClave` registrado (hora UTC) | `<HH:MMZ>` |
| Verificación `--verificar <usuario>` (resultado) | `<CambioClave confirmado / no confirmado>` |
| Confirmación del destinatario (nombre e iniciales) | `<Nombre Apellido, NA>` |

## 3. Baja o desbloqueo

| Campo | Valor |
| --- | --- |
| Motivo | `<texto breve, sin datos personales adicionales>` |
| Evento en `cob.LogAcceso` | `<CambioEstadoUsuario / DesbloqueoManual>` (hora UTC `<HH:MMZ>`) |
| Sesiones abiertas invalidadas (revalidación 5 min DEMO) | `<verificado / no aplica>` |

## 4. Cierre de la ventana

| Control | Resultado |
| --- | --- |
| `main.bicep` redesplegado con `ipOperador` vacío | `<Sí, hora UTC>` |
| `scripts/s12_endurecer.sh` ejecutado | `<Sí, hora UTC>` |
| `s12_verificar_seguridad.sh`: SEG-11, SEG-18, SEG-KV-06a, SEG-KV-06b | `<CUMPLE / NO CUMPLE>` |

## 5. Observaciones

`<sin observaciones / texto>`
