// Shared helpers for every page. Requires supabase-js (loaded from the CDN) and config.js.

const sb = window.supabase.createClient(window.KK_CONFIG.url, window.KK_CONFIG.key, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
});

const ERRORS = {
  not_signed_in: "Please sign in again.",
  not_member: "You're not a member of that family.",
  not_admin: "Only the family's organisers can do that.",
  not_super_admin: "Only the site owner can see this page.",
  not_managed_member: "That person has their own account, so only they can change their wish list.",
  invalid_email: "That email address doesn't look right.",
  email_locked: "This person has already created their account, so their email can't be changed.",
  too_many_families: "You can create up to 5 families.",
  too_many_signups: "Lots of families are signing up right now. Please try again in an hour.",
  wishlist_full: "That wish list is full (50 items max).",
  invalid_draw: "That draw broke a rule, so it wasn't saved. Try again.",
  not_enough_participants: "You need at least 2 people in the exchange.",
  cannot_delete_self: "You can't remove yourself.",
  cannot_demote_self: "You can't remove your own organiser access.",
  family_full: "This family has reached the 200-person limit.",
  too_many_events: "This family has reached the 100-exchange limit.",
  no_draw_yet: "The names haven't been drawn yet.",
  too_many_messages: "That's a lot of messages for one day! Try again tomorrow.",
  already_nudged: "You've already nudged them today. Give them a little time!",
  invited_recently: "They were invited less than an hour ago. Give it a little time before resending.",
  already_joined: "They've already created their account.",
  no_email: "Add an email address for them first.",
  last_organiser: "You're this family's only organiser. Make someone else an organiser first (on the organiser page), then try again.",
};

async function rpc(fn, args = {}) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) {
    const msg = error.message || "";
    if (msg.includes("people_name_unique")) throw new Error("Someone in this family already has that name.");
    if (msg.includes("people_family_email")) throw new Error("Someone in this family already has that email.");
    if (/JWT|not_signed_in/i.test(msg)) throw new Error(ERRORS.not_signed_in);
    if (/Failed to fetch|NetworkError/i.test(msg)) throw new Error("Couldn't reach the server. Check your connection and try again.");
    throw new Error(ERRORS[msg] || msg || "Something went wrong.");
  }
  return data;
}

async function currentUser() {
  const { data } = await sb.auth.getSession();
  return data.session?.user ?? null;
}

// For pages that need a signed-in user: sends visitors to the home page to sign in.
async function requireUser() {
  const user = await currentUser();
  if (!user) { location.replace("./"); throw new Error("redirecting"); }
  return user;
}

async function signOut() {
  await sb.auth.signOut();
  try { localStorage.removeItem("kk.family"); } catch {}
  location.replace("./");
}

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const $ = id => document.getElementById(id);
const siteUrl = () => new URL("./", location.href).href;

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

// Accepts "amazon.ca/..." without the https://. Returns the cleaned URL, "" for blank, or null if invalid.
function normalizeUrl(raw) {
  let url = String(raw || "").trim();
  if (!url) return "";
  if (!/^[a-z]+:/i.test(url)) url = "https://" + url;
  return safeUrl(url) && /^https?:\/\/[^\s/]+\.[^\s/]+/i.test(url) ? url : null;
}

// Fills every .family-name element with "The <name>" and updates the tab title.
function setFamily(name, suffix) {
  document.querySelectorAll(".family-name").forEach(el => el.textContent = name ? `The ${name}` : "");
  document.querySelectorAll(".family-footer").forEach(el => el.textContent = name ? `Merry Christmas from the ${name} family 🎄` : "Merry Christmas 🎄");
  document.title = `${suffix ? suffix + " · " : ""}${name ? name + " " : ""}Kris Kringle`;
}

function showMsg(el, text, kind = "err") {
  el.innerHTML = text ? `<div class="msg ${kind}">${esc(text)}</div>` : "";
}

// Renders a wish list item. `editable` adds Edit/Remove buttons carrying data-edit/data-del.
function wishHtml(w, editable) {
  const url = safeUrl(w.url);
  const title = url ? `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer">${esc(w.title)} ↗</a>` : esc(w.title);
  return `<li>
    <div style="flex:1 1 260px">
      <div class="wish-title">${title}${w.price_cents != null ? ` <span class="muted">· ~${money(w.price_cents)}</span>` : ""}</div>
      ${w.notes ? `<div class="muted">${esc(w.notes)}</div>` : ""}
    </div>
    ${editable ? `<div class="actions"><button class="small" data-edit="${w.id}">Edit</button><button class="small link" data-del="${w.id}">Remove</button></div>` : ""}
  </li>`;
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
