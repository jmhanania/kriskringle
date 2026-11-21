// Emails everyone in an exchange that the names have been drawn (without revealing matches).
// Called by an organiser from admin.html. The organiser's own session is used to fetch the
// recipient list, so the database's organiser check applies. Needs the RESEND_API_KEY secret.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = Deno.env.get("SITE_URL") ?? "https://kriskringle.jacobhanania.com";
const FROM = Deno.env.get("EMAIL_FROM") ?? "Kris Kringle <kriskringle@jacobhanania.com>";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function money(cents: number | null) {
  return cents == null ? "" : (cents / 100).toLocaleString("en-CA", { style: "currency", currency: "CAD", maximumFractionDigits: cents % 100 ? 2 : 0 });
}

function prettyDate(iso: string | null) {
  return iso ? new Date(iso + "T12:00:00").toLocaleDateString("en-CA", { weekday: "long", month: "long", day: "numeric" }) : "";
}

function emailHtml(name: string, family: string, event: { name: string; exchange_date: string | null; budget_cents: number | null }, hasAccount: boolean) {
  const details = [event.exchange_date && `🗓️ ${prettyDate(event.exchange_date)}`, event.budget_cents != null && `💰 Budget ${money(event.budget_cents)}`]
    .filter(Boolean).join(" &nbsp;·&nbsp; ");
  const action = hasAccount ? "Sign in to see who you're buying for" : `Create your account with this email address to see who you're buying for`;
  return `<div style="font-family:Georgia,serif;max-width:480px;margin:0 auto;padding:24px;color:#2a1f1a">
  <h2 style="color:#b3201e;margin:0 0 12px">🎅 The names are drawn!</h2>
  <p style="margin:0 0 12px">Hi ${esc(name)},</p>
  <p style="margin:0 0 12px">The Santa hat has been shaken for <strong>${esc(event.name)}</strong> in the ${esc(family)} family Kris Kringle.</p>
  ${details ? `<p style="margin:0 0 16px;color:#7a6a5c">${details}</p>` : ""}
  <p style="margin:0 0 24px"><a href="${SITE_URL}" style="background:#b3201e;color:#ffffff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${action}</a></p>
  <p style="margin:0 0 8px">While you're there, add a few ideas to your own wish list so your Kris Kringle knows what to get you.</p>
  <p style="font-size:13px;color:#7a6a5c;margin:16px 0 0">🤫 Remember, it's a secret!</p>
</div>`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ error: "Emails aren't set up yet (missing RESEND_API_KEY)." }, 500);

  let family: string, eventId: string;
  try { ({ family, event: eventId } = await req.json()); } catch { return json({ error: "bad_request" }, 400); }
  if (!family || !eventId) return json({ error: "bad_request" }, 400);

  // Act as the calling organiser so the database enforces that they run this family.
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data, error } = await sb.rpc("admin_draw_recipients", { p_family: family, p_event: eventId });
  if (error) return json({ error: error.message }, 403);
  if (data.event?.status !== "drawn") return json({ error: "The names haven't been drawn yet." }, 400);

  const recipients = data.recipients as { name: string; email: string; has_account: boolean }[];
  if (!recipients.length) return json({ sent: 0 });

  const res = await fetch("https://api.resend.com/emails/batch", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(recipients.map(r => ({
      from: FROM,
      to: [r.email],
      subject: `🎅 Names are drawn for ${data.event.name}!`,
      html: emailHtml(r.name, data.family, data.event, r.has_account),
    }))),
  });
  if (!res.ok) return json({ error: `Email service error: ${await res.text()}` }, 502);
  return json({ sent: recipients.length });
});
