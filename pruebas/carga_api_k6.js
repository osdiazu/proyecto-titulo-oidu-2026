// =============================================================================
// carga_api_k6.js - Proyecto APT Cobranza Automatizada (Evidencia S14)
// Prueba de carga de la consulta de estado de clientes (KPI: respuesta < 2 s).
//
// Autenticacion (ADR-001): clave de API de rol Ventas en el encabezado X-Api-Key.
// La clave se toma de la variable de entorno API_KEY exportada en la sesion; NO se
// pasa con -e (quedaria en la linea de comandos y en la lista de procesos). k6 lee
// las variables de entorno del sistema en __ENV.
// Clave dedicada para la carga (carga-demo, 1 dia) o ventas-demo: PENDIENTE del equipo
// (ADR-001 seccion 6, politica A.5). Se revoca al terminar la prueba.
//
// Ejecucion (Git Bash; la clave se lee de Key Vault a la variable, sin imprimirla):
//   export API_KEY="$(az keyvault secret show --vault-name <kv> -n <secreto> --query value -o tsv)"
//   k6 run -e BASE_URL=https://<dominio> -e USUARIOS=10 -e DURACION=5m pruebas/carga_api_k6.js
//   unset API_KEY
// Ejecutarla contra Azure requiere confirmacion humana (CLAUDE.md regla 5).
// El numero de usuarios simultaneos (USUARIOS) debe acordarse con Ventas: el
// tamano de la fuerza de ventas no esta documentado en el proyecto.
// =============================================================================
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL;
const API_KEY = (__ENV.API_KEY || '').trim();
if (!BASE) throw new Error('Defina BASE_URL.');
if (!/^cobk_[a-z2-7]{8}_[A-Za-z0-9_-]{43}$/.test(API_KEY))
  throw new Error('Defina API_KEY en el entorno (formato cobk_<prefijo>_<secreto>); no use -e.');
const USUARIOS = parseInt(__ENV.USUARIOS || '10');
const DURACION = __ENV.DURACION || '5m';
const RUTS = ['76555555-8', '76666666-3', '77777777-7', '78888888-0', '76123456-0'];

export const options = {
  scenarios: {
    consulta_ventas: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '1m', target: USUARIOS },
        { duration: DURACION, target: USUARIOS },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: {
    'http_req_duration{endpoint:estado}': ['p(95)<2000'],  // KPI objetivo 6.4
    'http_req_failed': ['rate<0.01'],
    'checks': ['rate>0.99'],
  },
};

const headers = { 'Accept': 'application/json', 'X-Api-Key': API_KEY };

export default function () {
  const rut = RUTS[Math.floor(Math.random() * RUTS.length)];
  const r = http.get(`${BASE}/api/v1/clientes/${rut}/estado`, { headers, tags: { endpoint: 'estado' } });
  check(r, {
    'estado 200': (x) => x.status === 200,
    'incluye puedeTomarPedido': (x) => x.status === 200 && x.json('puedeTomarPedido') !== undefined,
  });
  sleep(1 + Math.random() * 2);   // tiempo de lectura de un vendedor entre consultas
}
