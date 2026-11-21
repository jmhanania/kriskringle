// Shared helpers for the personal and admin pages.

const ERRORS = {
  invalid_code: "That link doesn't look right. Ask Jacob for a fresh one.",
  not_admin: "This link doesn't have admin access.",
  wishlist_full: "Your wish list is full (50 items max).",
  invalid_draw: "That draw broke a rule, so it wasn't saved. Try again.",
  not_enough_participants: "You need at least 2 people in the exchange.",
  cannot_delete_self: "You can't remove yourself as the admin.",
};

async function rpc(fn, args = {}) {
  const { url, key } = window.KK_CONFIG;
  let res;
  try {
    res = await fetch(`${url}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
  } catch {
    throw new Error("Couldn't reach the server. Check your connection and try again.");
  }
  const body = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) {
    const code = body?.message || "";
    if (code.includes("people_name_unique")) throw new Error("Someone with that name is already in the family list.");
    throw new Error(ERRORS[code] || code || `Something went wrong (${res.status}).`);
  }
  return body;
}

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const $ = id => document.getElementById(id);

function codeFromHash() {
  return decodeURIComponent(location.hash.replace(/^#/, "")).trim();
}

function money(cents) {
  if (cents == null) return "";
  return (cents / 100).toLocaleString("en-CA", { style: "currency", currency: "CAD", maximumFractionDigits: cents % 100 ? 2 : 0 });
}

function toCents(value) {
  const n = parseFloat(String(value).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

function prettyDate(iso) {
  if (!iso) return "";
  return new Date(iso + "T12:00:00").toLocaleDateString("en-CA", { weekday: "long", month: "long", day: "numeric", year: "numeric" });
}

function safeUrl(u) {
  return /^https?:\/\//i.test(u || "") ? u : null;
}

function showMsg(el, text, kind = "err") {
  el.innerHTML = text ? `<div class="msg ${kind}">${esc(text)}</div>` : "";
}

// Falling snow
(() => {
  const c = document.getElementById("snow");
  if (!c || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const ctx = c.getContext("2d");
  let flakes = [];
  function size() {
    c.width = innerWidth; c.height = innerHeight;
    flakes = Array.from({ length: Math.min(140, Math.floor(innerWidth / 8)) }, () => ({
      x: Math.random() * c.width, y: Math.random() * c.height,
      r: Math.random() * 2.4 + 0.8, s: Math.random() * 0.8 + 0.3, d: Math.random() * Math.PI * 2,
    }));
  }
  function tick() {
    ctx.clearRect(0, 0, c.width, c.height);
    ctx.fillStyle = "rgba(255,255,255,0.85)";
    for (const f of flakes) {
      f.y += f.s; f.d += 0.01; f.x += Math.sin(f.d) * 0.4;
      if (f.y > c.height + 4) { f.y = -4; f.x = Math.random() * c.width; }
      ctx.beginPath(); ctx.arc(f.x, f.y, f.r, 0, Math.PI * 2); ctx.fill();
    }
    requestAnimationFrame(tick);
  }
  addEventListener("resize", size); size(); tick();
})();
