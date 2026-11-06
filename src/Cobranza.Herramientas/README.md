# Cobranza.Herramientas

Herramienta de consola (net10.0) para emitir credenciales del panel y claves de API (ADR-001 sección 5.9; política de credenciales, sección A). La usan los scripts `scripts/s11_alta_usuario.sh`, `s11_restablecer_clave.sh` y `s11_alta_clave_api.sh` (los escribe `devops`).

Estado: compilada y con pruebas unitarias en proceso (`tests/Cobranza.Api.Tests/UnitariasTests.cs`). El binario no fue ejecutado por ningún agente (regla SEG-H01). La escritura real en la terminal en Git Bash para Windows está PENDIENTE de verificación humana (sección 6).

## 1. Regla SEG-H01 (obligatoria)

Solo la ejecuta un integrante humano, miembro de `grp-cobranza-sql-admin`, en su propia terminal y fuera de Claude Code. Ningún agente la ejecuta: la salida de la terminal del agente queda en la conversación.

## 2. Compilación e invocación

No usar `dotnet run`: puede escribir mensajes de compilación en la salida estándar y contaminar el valor capturado. Compilar una vez a una carpeta y ejecutar la DLL:

```bash
HERR_DIR="$(mktemp -d)"
dotnet build src/Cobranza.Herramientas/Cobranza.Herramientas.csproj -c Release -o "$HERR_DIR" >/dev/null
HERR="$HERR_DIR/Cobranza.Herramientas.dll"
# ... uso ...
rm -rf "$HERR_DIR"
```

Requisito: runtime `Microsoft.AspNetCore.App` 10.x (viene con el SDK de .NET 10). La herramienta usa ese framework compartido para que `PasswordHasher` sea el mismo que usa la API.

## 3. Comando `hash-clave`

```
dotnet "$HERR" hash-clave
```

- Sin argumentos. Cualquier argumento adicional es error de uso.
- Genera una contraseña temporal de 20 caracteres con `RandomNumberGenerator`, alfabeto `ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789` (sin `0`, `O`, `1`, `l`, `I`).
- Escribe la contraseña SOLO en la terminal, nunca en la salida estándar:
  - Linux y macOS: `/dev/tty`.
  - Windows: `CONOUT$`, y solo si la entrada estándar es una consola real (`Console.IsInputRedirected = false`).
- Salida estándar: una sola línea con el hash `PasswordHasher` V3 (Base64, hoy 84 caracteres) y salto de línea. Es el valor de `@HashClave` de `cob.sp_CrearUsuarioInterno` y `cob.sp_RestablecerClaveUsuario`.
- Error estándar: solo mensajes de error (nunca la contraseña ni el hash).
- Si no hay terminal utilizable, termina con código 2 y no escribe nada en la salida estándar (ADR 5.9: falla en lugar de escribir la contraseña en stdout).

Uso en el script:

```bash
# No redirigir la entrada estandar: la herramienta la usa para comprobar que hay una consola.
if ! HASH="$(dotnet "$HERR" hash-clave)"; then
  echo "No se pudo generar la contrasena temporal (sin terminal)." >&2
  exit 1
fi
# ... sqlcmd con EXEC cob.sp_CrearUsuarioInterno ... @HashClave = '$HASH' ...
read -r -p "El destinatario leyo la contrasena. Presione Enter para limpiar la pantalla..." _
clear; printf '\033[3J'
unset HASH
```

## 4. Comando `nueva-clave-api`

```
dotnet "$HERR" nueva-clave-api --consumidor <nombre> --salida-archivo <ruta>
```

- `--consumidor`: obligatorio, patrón `^[a-z0-9-]{3,50}$` (el mismo CHECK de `cob.ClaveApi.Consumidor`). Solo se valida; no forma parte de la clave.
- `--salida-archivo`: obligatorio. El directorio debe existir. Se acepta un archivo inexistente o vacío (el que crea `mktemp`); si el archivo ya tiene contenido, no se sobrescribe y el comando falla con código 3.
- Los argumentos pueden ir en cualquier orden; repetir uno es error de uso.
- Clave: `cobk_<prefijo>_<secreto>` (57 caracteres): prefijo de 8 caracteres `[a-z2-7]` y secreto de 43 caracteres Base64url sin relleno (ADR 5.3).
- Archivo: solo la clave, en UTF-8 sin BOM y SIN salto de línea final (así `az keyvault secret set --file <ruta> --encoding utf-8` guarda exactamente la clave).
- Salida estándar: una sola línea `<prefijo> <hash>` separada por un espacio, donde `<hash>` es el SHA-256 de la clave completa en UTF-8, en hexadecimal MAYÚSCULAS de 64 caracteres, sin `0x`.
- Error estándar: solo mensajes de error (nunca la clave).

Uso en el script:

```bash
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
# En Git Bash para Windows conviene pasar la ruta en formato Windows al ejecutable nativo.
RUTA="$TMP"; command -v cygpath >/dev/null && RUTA="$(cygpath -w "$TMP")"
SALIDA="$(dotnet "$HERR" nueva-clave-api --consumidor "$CONSUMIDOR" --salida-archivo "$RUTA")"
read -r PREFIJO HASH_HEX <<< "$SALIDA"
# Key Vault: az keyvault secret set --vault-name "$KV_NAME" -n "apikey-$CONSUMIDOR-$PREFIJO" --file "$TMP" --encoding utf-8 ...
# SQL:       EXEC cob.sp_RegistrarClaveApi @Prefijo = '$PREFIJO', @HashClave = 0x$HASH_HEX, ...
rm -f "$TMP"
```

## 5. Códigos de salida

| Código | Significado | Salida estándar |
| --- | --- | --- |
| 0 | Correcto | `hash-clave`: el hash. `nueva-clave-api`: `<prefijo> <hash>` |
| 1 | Error de uso (comando, argumentos o consumidor inválidos) | Vacía |
| 2 | `hash-clave` sin terminal utilizable | Vacía |
| 3 | `nueva-clave-api` no pudo escribir el archivo (directorio inexistente, archivo con contenido, permisos) | Vacía |

## 6. Verificación pendiente (humano, una vez por equipo)

En Git Bash para Windows, la herramienta solo escribe en la consola si la entrada estándar es una consola real. Esto ocurre si Git Bash corre con pseudoconsola (ConPTY), por ejemplo dentro de Windows Terminal o con la opción de pseudoconsola de Git para Windows. En mintty sin pseudoconsola, la entrada estándar es una tubería y el comando termina con código 2. Si la instalación del equipo cumple esa condición: PENDIENTE de verificación.

Prueba sugerida (la ejecuta el integrante humano en su terminal; la contraseña generada se descarta):

```bash
dotnet "$HERR" hash-clave > /dev/null; echo "codigo=$?"
```

Resultado esperado: la contraseña aparece en la pantalla, no se guarda en ningún archivo y el código es 0. Con código 2, abrir Git Bash dentro de Windows Terminal y repetir. Registrar el resultado (sin la contraseña) en `evidencias/`.
