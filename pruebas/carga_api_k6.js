// =============================================================================
// carga_api_k6.js - Proyecto APT Cobranza Automatizada (Evidencia S14)
// Prueba de carga de la consulta de estado de clientes (KPI: respuesta < 2 s).
//
// Ejecucion:
//   k6 run -e BASE_URL=https://<dominio> -e COOKIE="AppServiceAuthSession=<valor>" \
//          -e USUARIOS=10 -e DURACION=5m pruebas/carga_api_k6.js
// La cookie se obtiene del navegador tras iniciar sesion con un usuario de rol
// Ventas.Consulta (herramientas de desarrollo > Almacenamiento > Cookies).
// Alternativa: -e TOKEN=<token Bearer con audiencia api://<clientId>>.
// El numero de usuarios simultaneos (USUARIOS) debe acordarse con Ventas: el
// tamano de la fuerza de ventas no esta documentado en el proyecto.
// =============================================================================
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL;
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

const headers = { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
if (__ENV.COOKIE) headers['Cookie'] = __ENV.COOKIE;
if (__ENV.TOKEN) headers['Authorization'] = `Bearer ${__ENV.TOKEN}`;

export default function () {
  const rut = RUTS[Math.floor(Math.random() * RUTS.length)];
  const r = http.get(`${BASE}/api/v1/clientes/${rut}/estado`, { headers, tags: { endpoint: 'estado' } });
  check(r, {
    'estado 200': (x) => x.status === 200,
    'incluye puedeTomarPedido': (x) => x.status === 200 && x.json('puedeTomarPedido') !== undefined,
  });
  sleep(1 + Math.random() * 2);   // tiempo de lectura de un vendedor entre consultas
}
