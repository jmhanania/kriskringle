// Emails a family member an invitation to join their family's Kris Kringle.
// Called by an organiser from admin.html; the organiser's own session is used, so the database
// checks they run that family (and limits resends to once an hour). Needs RESEND_API_KEY.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// Site address and sender come from Supabase secrets (SITE_URL, EMAIL_FROM) so no addresses live in the repo.
const SITE_URL = Deno.env.get("SITE_URL") ?? "";
const FROM = Deno.env.get("EMAIL_FROM") ?? "";
// The sending address can't receive replies, so every email says so.
const NO_REPLY = `<p style="font-size:12px;color:#9a8c7e;margin:24px 0 0;padding-top:12px;border-top:1px solid #eadfca">This is an automated email from Kris Kringle, so please don't reply: this address can't receive messages. Questions? Ask your family's organiser.</p>`;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ error: "Emails aren't set up yet (missing RESEND_API_KEY)." }, 500);
  if (!SITE_URL || !FROM) return json({ error: "Emails aren't set up yet (missing SITE_URL or EMAIL_FROM secret)." }, 500);

  let family: string, person: string;
  try { ({ family, person } = await req.json()); } catch { return json({ error: "bad_request" }, 400); }
  if (!family || !person) return json({ error: "bad_request" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: p, error } = await sb.rpc("admin_invite_info", { p_family: family, p_person: person });
  if (error) return json({ error: error.message }, 403);

  const html = `<div style="font-family:Georgia,serif;max-width:480px;margin:0 auto;padding:24px;color:#2a1f1a">
  <h2 style="color:#b3201e;margin:0 0 12px">🎄 You're invited to the ${esc(p.family)} family Kris Kringle!</h2>
  <p style="margin:0 0 12px">Hi ${esc(p.name)},</p>
  <p style="margin:0 0 12px">${esc(p.inviter)} has added you to your family's Kris Kringle (Secret Santa). Create your account to see who you're buying for once the names are drawn, and to share your own wish list.</p>
  <p style="margin:0 0 12px">Use this email address (<strong>${esc(p.email)}</strong>) and you'll land in the family automatically. No password needed: we'll email you a sign-in code.</p>
  <p style="margin:20px 0 24px"><a href="${SITE_URL}" style="background:#b3201e;color:#ffffff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">Create my account</a></p>
  <p style="font-size:13px;color:#7a6a5c;margin:0">Not expecting this? You can ignore this email.</p>
${NO_REPLY}</div>`;

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [p.email], subject: `🎄 ${p.inviter} invited you to the ${p.family} family Kris Kringle`, html }),
  });
  if (!res.ok) return json({ error: `Email service error: ${await res.text()}` }, 502);
  return json({ sent: 1 });
});
