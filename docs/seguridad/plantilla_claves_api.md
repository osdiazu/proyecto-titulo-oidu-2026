# Plantilla: emisión, rotación y revocación de claves de API

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_claves_api.md` y completar allí; no completar este archivo.
Base: `docs/seguridad/politica_credenciales_y_accesos.md` (A.5, A.9, A.10.2, A.10.4, C.1, C.2) y ADR-001 secciones 5.3 y 5.9.

Reglas para quien completa (obligatorias):
- Nunca escribir la clave completa (`cobk_<prefijo>_<secreto>`) ni su hash SHA-256. Solo el prefijo de 8 caracteres.
- Object ID del lector truncado como `xxxx…xxxx`. IP pública del operador como `<IP_OPERADOR>`.
- Los scripts los ejecutó un integrante humano fuera de Claude Code (regla SEG-H01).

## 1. Emisión

| Campo | Valor |
| --- | --- |
| Fecha y hora UTC | `<AAAA-MM-DDTHH:MMZ>` |
| Consumidor | `<ventas-demo / carga-demo>` (DEMO) |
| Rol | `Ventas` (único permitido, ADR 5.1) |
| Prefijo | `<prefijo de 8 caracteres [a-z2-7]>` |
| Nombre del secreto en Key Vault | `apikey-<consumidor>-<prefijo>` |
| Vigencia (días) y vencimiento UTC | `<30 / 1>` días; vence `<AAAA-MM-DDTHH:MMZ>` |
| Atributo `exp` del secreto igual al vencimiento en SQL | `<Sí>` |
| Lector distinto del operador | `<No / Sí: Object ID xxxx…xxxx, rol Key Vault Secrets User con alcance en el secreto>` |
| Operador | `<nombre>` |
| Script | `scripts/s11_alta_clave_api.sh --consumidor <c> --dias <n>` |
| Archivo temporal eliminado (`trap`) | `<Sí>` |
| Evento `AltaClaveApi` en `cob.LogAcceso` | `<hora UTC>` |

## 2. Prueba del consumidor DEMO (`pruebas/consumidor_ventas_demo.sh`)

| Caso | Esperado | Obtenido | Hora UTC |
| --- | --- | --- | --- |
| AUT-10 `/api/v1/clientes/{rut}/estado` con RUT DEMO | 200 | `<código>` | `<HH:MMZ>` |
| AUT-11 `/api/v1/cartera/indicadores` | 403 | `<código>` | `<HH:MMZ>` |
| Clave con formato inválido | 401 | `<código>` | `<HH:MMZ>` |

## 3. Rotación (si aplica)

| Campo | Valor |
| --- | --- |
| Motivo | `<7 días antes del vencimiento / sospecha de exposición / restauración / cambio de integrante>` |
| Prefijo anterior | `<prefijo>` |
| Prefijo nuevo | `<prefijo>` |
| Superposición (máximo 1 h DEMO, PENDIENTE de aprobación) | `<minutos>` |
| Claves activas de `ventas-demo` al terminar | `<1>` |

## 4. Revocación

| Campo | Valor |
| --- | --- |
| Prefijo revocado | `<prefijo>` |
| `sp_RevocarClaveApi` (evento `RevocacionClaveApi`) | `<hora UTC>` |
| Secreto deshabilitado y eliminado (queda 90 días en soft-delete, sin purga) | `<Sí>` |
| Asignación del lector eliminada | `<Sí / no aplica>` |
| AUT-12: 401 pasados 60 s (caché DEMO) | `<código, hora UTC>` |

## 5. Controles de `s12_verificar_seguridad.sh` relacionados

| Control | Resultado |
| --- | --- |
| SEG-KV-03 ningún usuario con `Key Vault Secrets User` sobre el vault | `<CUMPLE / NO CUMPLE>` |
| SEG-KV-04 ningún `apikey-*` sin expiración ni vencido habilitado (requiere ventana abierta) | `<CUMPLE / NO CUMPLE / NO VERIFICADO>` |
| SEG-KV-05 auditoría de Key Vault activa | `<CUMPLE / NO CUMPLE>` |

## 6. Observaciones

`<sin observaciones / texto>`
