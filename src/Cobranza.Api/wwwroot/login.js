// Inicio de sesion del panel - Proyecto APT Cobranza Automatizada (ADR-001)
// Autenticacion propia: usuario y contrasena con cookie de sesion. Antes del POST se obtiene el
// token antifalsificacion (GET /api/v1/auth/antiforgery) y se envia en el encabezado X-CSRF-TOKEN.
"use strict";
const $ = id => document.getElementById(id);

function mostrarError(msg) { const e = $("error"); e.textContent = msg; e.hidden = false; }

async function tokenCsrf() {
  const r = await fetch("/api/v1/auth/antiforgery", { credentials: "same-origin", headers: { "Accept": "application/json" } });
  if (!r.ok) throw new Error("No se pudo preparar el inicio de sesión (" + r.status + ").");
  return (await r.json()).token;
}

$("form-login").addEventListener("submit", async ev => {
  ev.preventDefault();
  $("error").hidden = true;
  const clave = $("clave");
  try {
    const token = await tokenCsrf();
    const r = await fetch("/api/v1/auth/login", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-TOKEN": token },
      body: JSON.stringify({ usuario: $("usuario").value, clave: clave.value })
    });
    clave.value = "";
    if (r.status === 429) { mostrarError("Demasiados intentos. Espere un minuto e intente nuevamente."); return; }
    if (!r.ok) {
      let msg = "Usuario o contraseña incorrectos";
      try { const j = await r.json(); if (j && j.mensaje) msg = j.mensaje; } catch (_) { /* sin cuerpo JSON */ }
      mostrarError(msg);
      return;
    }
    location.href = "/";
  } catch (e) { clave.value = ""; mostrarError(e.message); }
});
