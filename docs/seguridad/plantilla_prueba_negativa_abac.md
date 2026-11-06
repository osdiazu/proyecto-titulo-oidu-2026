# Plantilla: prueba negativa de la condición ABAC (SEG-DP-03b)

Plantilla sin datos. Copiar a `evidencias/seguridad/<AAAA-MM-DD>_prueba_abac.md` y completar allí; no completar este archivo.
Base: ADR-001 sección 5.5.1 (condición de la asignación `Storage Blob Data Owner` de la Function App) y tabla 6.2 (SEG-DP-03).

Objetivo: demostrar con la identidad administrada de la Function App que no puede listar, leer ni escribir blobs en el contenedor `dataprotection-keys`, y que sí puede operar en un contenedor del host (control positivo, para descartar que el 403 se deba a un token o una red inválidos).

`s12_verificar_seguridad.sh` solo comprueba que la condición exista (SEG-DP-03a). Esta prueba es la verificación real y es manual porque requiere la identidad de la Function App.

## 1. Procedimiento propuesto (PENDIENTE de verificar en Azure)

Supuestos no verificados: que la consola SSH del contenedor de la Function App (Linux, plan B1) esté disponible desde el sitio SCM, y que la sesión SSH exponga `IDENTITY_ENDPOINT` e `IDENTITY_HEADER`. Si no se cumplen, registrar el hecho y proponer otra vía antes de improvisar.

1. Abrir la ventana de publicación del SCM de la Function App: `IP_PUBLICACION_SCM=<IP_OPERADOR> scripts/s12_endurecer.sh` (agrega `operador-publicacion` solo al SCM).
2. Entrar a la consola SSH de la Function App desde el portal (Herramientas de desarrollo, SSH).
3. En la consola, sin imprimir el token:

```bash
CUENTA=<nombre de la cuenta de Storage>
TOKEN=$(curl -s -H "X-IDENTITY-HEADER: $IDENTITY_HEADER" \
  "$IDENTITY_ENDPOINT?resource=https://storage.azure.com/&api-version=2019-08-01" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
V='x-ms-version: 2023-11-03'
# Control positivo: contenedor del host (nombre a confirmar con la lista de contenedores del portal)
curl -s -o /dev/null -w 'positivo %{http_code}\n' -H "Authorization: Bearer $TOKEN" -H "$V" \
  "https://$CUENTA.blob.core.windows.net/azure-webjobs-hosts?restype=container&comp=list"
# Negativo 1: listar dataprotection-keys
curl -s -o /dev/null -w 'listar %{http_code}\n' -H "Authorization: Bearer $TOKEN" -H "$V" \
  "https://$CUENTA.blob.core.windows.net/dataprotection-keys?restype=container&comp=list"
# Negativo 2: leer el anillo de claves
curl -s -o /dev/null -w 'leer %{http_code}\n' -H "Authorization: Bearer $TOKEN" -H "$V" \
  "https://$CUENTA.blob.core.windows.net/dataprotection-keys/keys.xml"
# Negativo 3: escribir un blob distinto de keys.xml (no toca el anillo)
curl -s -o /dev/null -w 'escribir %{http_code}\n' -X PUT -H "Authorization: Bearer $TOKEN" -H "$V" \
  -H 'x-ms-blob-type: BlockBlob' --data-binary 'prueba' \
  "https://$CUENTA.blob.core.windows.net/dataprotection-keys/prueba-abac.txt"
unset TOKEN
```

4. Si el negativo 3 devuelve 201, la condición no funciona: eliminar `prueba-abac.txt` desde el portal con la cuenta del operador, registrar NO CUMPLE e informar a `devops` (no corregir a mano).
5. Cerrar el SCM: `scripts/s12_endurecer.sh` sin `IP_PUBLICACION_SCM` y verificar SEG-28 = 0.

## 2. Resultados

| Prueba | Esperado | Obtenido | Hora UTC |
| --- | --- | --- | --- |
| Control positivo (contenedor del host) | 200 | `<código>` | `<HH:MMZ>` |
| Listar `dataprotection-keys` | 403 | `<código>` | `<HH:MMZ>` |
| Leer `dataprotection-keys/keys.xml` | 403 | `<código>` | `<HH:MMZ>` |
| Escribir `dataprotection-keys/prueba-abac.txt` | 403 | `<código>` | `<HH:MMZ>` |
| SCM cerrado después (SEG-28) | 0 | `<valor>` | `<HH:MMZ>` |

| Campo | Valor |
| --- | --- |
| Ejecutó | `<nombre>` |
| Resultado SEG-DP-03b | `<CUMPLE / NO CUMPLE>` |
| Observaciones | `<texto>` |
