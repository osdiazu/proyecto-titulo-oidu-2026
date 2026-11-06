// Panel interno - Proyecto APT Cobranza Automatizada (Evidencia S11, ADR-001)
// Autenticacion propia: cookie de sesion __Host-cobranza-sesion. Sin sesion (401) se redirige a
// /login.html. Los POST envian el token antifalsificacion en el encabezado X-CSRF-TOKEN.
"use strict";
const clp = new Intl.NumberFormat("es-CL", { style: "currency", currency: "CLP", maximumFractionDigits: 0 });
const fechaCl = v => v ? new Date(v.endsWith("Z") ? v : v + "Z").toLocaleString("es-CL", { timeZone: "America/Santiago" }) : "-";
const $ = id => document.getElementById(id);

function mostrarError(msg) { const e = $("error"); e.textContent = msg; e.hidden = false; }

async function obtener(url) {
  const r = await fetch(url, { credentials: "same-origin", headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" } });
  if (r.status === 401) { location.href = "/login.html"; return null; }
  if (r.status === 403) return null;
  if (r.status === 404) return undefined;
  if (!r.ok) throw new Error("Error " + r.status + " al consultar " + url);
  return r.json();
}

// El token se pide justo antes de cada POST: queda asociado al usuario de la sesion actual.
async function tokenCsrf() {
  const r = await fetch("/api/v1/auth/antiforgery", { credentials: "same-origin", headers: { "Accept": "application/json" } });
  if (r.status === 401) { location.href = "/login.html"; return null; }
  if (!r.ok) throw new Error("Error " + r.status + " al obtener el token antifalsificación");
  return (await r.json()).token;
}

async function enviar(url, cuerpo) {
  const token = await tokenCsrf();
  if (token === null) return null;
  const headers = { "Accept": "application/json", "X-CSRF-TOKEN": token };
  if (cuerpo !== undefined) headers["Content-Type"] = "application/json";
  return fetch(url, { method: "POST", credentials: "same-origin", headers,
                      body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo) });
}

function fila(tbody, valores) {
  const tr = document.createElement("tr");
  valores.forEach(v => { const td = document.createElement("td"); td.textContent = v; tr.appendChild(td); });
  tbody.appendChild(tr);
}

function kpi(cont, titulo, valor) {
  const d = document.createElement("div"); d.className = "kpi";
  const b = document.createElement("b"); b.textContent = valor;
  d.appendChild(b); d.appendChild(document.createTextNode(titulo)); cont.appendChild(d);
}

async function cargarUsuario() {
  const yo = await obtener("/api/v1/yo");
  if (!yo) return null;
  $("usuario").textContent = "Sesión: " + (yo.nombre || "usuario") + " | Roles: " + (yo.roles.join(", ") || "sin roles asignados");
  $("btn-logout").hidden = false;
  $("btn-mostrar-cambio").hidden = false;
  return yo;
}

$("btn-logout").addEventListener("click", async () => {
  try {
    const r = await enviar("/api/v1/auth/logout");
    if (r === null) return;
    if (r.status !== 204 && r.status !== 401) throw new Error("Error " + r.status + " al cerrar la sesión");
    location.href = "/login.html";
  } catch (e) { mostrarError(e.message); }
});

$("btn-mostrar-cambio").addEventListener("click", () => { $("cambio-clave").hidden = false; });

$("form-cambio").addEventListener("submit", async ev => {
  ev.preventDefault();
  const actual = $("clave-actual"), nueva = $("clave-nueva"), repetida = $("clave-repetida");
  const res = $("resultado-cambio"); res.hidden = false;
  if (nueva.value !== repetida.value) { res.textContent = "Las contraseñas nuevas no coinciden."; return; }
  try {
    const r = await enviar("/api/v1/auth/cambiar-clave", { claveActual: actual.value, claveNueva: nueva.value });
    actual.value = ""; nueva.value = ""; repetida.value = "";
    if (r === null) return;
    if (r.status === 204) { res.textContent = "Contraseña actualizada."; location.reload(); return; }
    let msg = "Error " + r.status + " al cambiar la contraseña";
    try { const j = await r.json(); msg = j.mensaje || j.detail || msg; } catch (_) { /* sin cuerpo JSON */ }
    res.textContent = msg;
  } catch (e) { actual.value = ""; nueva.value = ""; repetida.value = ""; res.textContent = e.message; }
});

async function cargarCartera() {
  const k = await obtener("/api/v1/cartera/indicadores");
  if (!k) return;
  $("cartera").hidden = false;
  const c = $("kpis"); c.replaceChildren();
  kpi(c, "Clientes", k.totalClientes); kpi(c, "Al día", k.clientesAlDia); kpi(c, "Morosos", k.clientesMorosos);
  kpi(c, "Suspendidos", k.clientesSuspendidos); kpi(c, "Regularizados", k.clientesRegularizados);
  kpi(c, "Pedidos retenidos", k.pedidosRetenidos); kpi(c, "Pedidos liberados (30 días)", k.pedidosLiberados30d);
  kpi(c, "Avisos aceptados (30 días)", k.avisosAceptados30d); kpi(c, "Avisos fallidos (30 días)", k.avisosFallidos30d);
  kpi(c, "Última sincronización", fechaCl(k.ultimaSincronizacionUtc) + " " + (k.estadoUltimaSincronizacion || ""));
  const tb = $("tramos").tBodies[0]; tb.replaceChildren();
  fila(tb, ["Por vencer", clp.format(k.montoPorVencer)]);
  fila(tb, ["Vencido 1 a 30 días", clp.format(k.montoVencido1a30)]);
  fila(tb, ["Vencido 31 a 60 días", clp.format(k.montoVencido31a60)]);
  fila(tb, ["Vencido más de 60 días", clp.format(k.montoVencidoMas60)]);
}

async function cargarSincronizaciones() {
  const s = await obtener("/api/v1/sincronizaciones?top=10");
  if (!s) return;
  $("operacion").hidden = false;
  const tb = $("sinc").tBodies[0]; tb.replaceChildren();
  s.forEach(x => fila(tb, [fechaCl(x.fechaInicioUtc), x.estado || "-", x.clientesLeidos ?? "-", x.clientesActualizados ?? "-", x.pedidosLiberados ?? "-"]));
}

$("form-rut").addEventListener("submit", async ev => {
  ev.preventDefault();
  const rut = $("rut").value.trim();
  const caja = $("resultado-cliente"); caja.hidden = false; caja.className = "tarjeta"; caja.replaceChildren();
  try {
    const r = await obtener("/api/v1/clientes/" + encodeURIComponent(rut) + "/estado");
    if (r === undefined) { caja.textContent = "Cliente no encontrado."; return; }
    if (r === null) { caja.textContent = "No tiene permiso para esta consulta."; return; }
    caja.classList.add(r.puedeTomarPedido ? "permitido" : "bloqueado");
    [
      r.razonSocial + " (RUT " + r.rut + ")",
      "Estado: " + r.estadoActual + (r.puedeTomarPedido ? " - puede tomar pedidos" : " - NO tomar pedidos hasta regularizar"),
      "Facturas pendientes: " + r.facturasPendientes + " (" + clp.format(r.montoPendiente) + ")",
      "Facturas vencidas: " + r.facturasVencidas + " (" + clp.format(r.montoVencido) + ")",
      "Pedidos retenidos: " + r.pedidosRetenidos
    ].forEach(t => { const p = document.createElement("p"); p.textContent = t; caja.appendChild(p); });
  } catch (e) { caja.textContent = e.message; }
});

(async () => {
  try {
    const yo = await cargarUsuario();
    if (!yo) return;
    if (yo.debeCambiarClave) {
      // Con contrasena temporal solo se permite cambiarla o cerrar la sesion (AUT-06).
      $("cambio-clave").hidden = false; $("aviso-cambio").hidden = false; $("btn-mostrar-cambio").hidden = true;
      return;
    }
    $("consulta").hidden = false;
    await cargarCartera(); await cargarSincronizaciones();
  }
  catch (e) { mostrarError(e.message); }
})();
