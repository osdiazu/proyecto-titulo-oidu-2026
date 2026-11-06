# Plantilla: revisión de seguridad posterior a una restauración (PITR o LTR)

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_revision_post_restauracion.md` y completar allí; no completar este archivo.
Base: `docs/seguridad/politica_credenciales_y_accesos.md` (C.3) y ADR-001 sección 4.2.

Reglas para quien completa (obligatorias):
- Sin contraseñas, hashes, claves de API ni IP completas (IPv4 al /24, IPv6 al /48; operador `<IP_OPERADOR>`).
- Los eventos se listan desde `cob.sp_ListarEventosAccesoDesde` o `cob.vw_LogAccesoEvidencia` (enmascarada).
- La restauración no se da por terminada hasta completar esta revisión (C.3, punto 6).

## 1. Restauración

| Campo | Valor |
| --- | --- |
| Tipo | `<PITR / LTR>` |
| Script | `<scripts/s14_simulacro_pitr.sh / scripts/s14_revision_post_restauracion.sh>` |
| Base original | `<nombre de la base>` (existe: `<Sí / No>`) |
| Base restaurada | `<nombre de la base>` |
| Punto de restauración (UTC) | `<AAAA-MM-DDTHH:MM:SSZ>` |
| Hora de la restauración (UTC) | `<AAAA-MM-DDTHH:MM:SSZ>` |
| Ejecutó (miembro de `grp-cobranza-sql-admin`) | `<nombre>` |

## 2. Caso A: la base original existe

Eventos de la base original con `FechaUtc >= punto`:

| Tipo de evento | Cantidad | Acción aplicada en la base restaurada | Hecho |
| --- | --- | --- | --- |
| `RevocacionClaveApi` | `<n>` | `sp_RevocarClaveApi` por cada prefijo | `<Sí>` |
| `CambioEstadoUsuario` (desactivaciones) | `<n>` | `sp_CambiarEstadoUsuario @Activo = 0` | `<Sí>` |
| `CambioRolUsuario` (reducciones) | `<n>` | `sp_CambiarRolUsuario` | `<Sí>` |
| `CambioClave` / `RestablecimientoClave` | `<n>` | `sp_RestablecerClaveUsuario` y entrega presencial (plantilla de entrega) | `<Sí>` |
| `AltaClaveApi` | `<n>` | Secreto `apikey-*` huérfano deshabilitado | `<Sí>` |
| `AltaUsuario` | `<n>` | Se vuelve a crear solo si se necesita | `<Sí / no aplica>` |

## 3. Caso B: la base original no existe (regla conservadora)

| Acción | Cantidad | Hecho |
| --- | --- | --- |
| Revocar todas las claves de API presentes | `<n>` | `<Sí>` |
| Emitir claves nuevas (plantilla de claves de API) | `<n>` | `<Sí>` |
| Desactivar todos los usuarios que no son `Admin` | `<n>` | `<Sí>` |
| Restablecer las contraseñas de todos | `<n>` | `<Sí>` |

## 4. Invalidación de sesiones

| Campo | Valor |
| --- | --- |
| `cob.sp_InvalidarTodasLasSesiones` (evento `InvalidacionSesiones`) | `<hora UTC>` |

## 5. Verificaciones

| Caso | Esperado | Obtenido |
| --- | --- | --- |
| AUT-08 sesión de usuario desactivado rechazada | En a lo más 5 min (DEMO) | `<resultado>` |
| AUT-12 clave revocada responde 401 | 401 | `<código>` |
| AUT-17 clave revocada antes del punto sigue revocada | Revocada | `<resultado>` |

## 6. Observaciones

`<sin observaciones / texto>`
