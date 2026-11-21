// Emails the other side of an anonymous Kris Kringle message (question, reply or nudge).
// Uses the sender's own session, so only they can trigger it, and the database never hands
// over anything that identifies the giver. Needs the RESEND_API_KEY secret.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = Deno.env.get("SITE_URL") ?? "https://kriskringle.jacobhanania.com";
const FROM = Deno.env.get("EMAIL_FROM") ?? "Kris Kringle <kriskringle@jacobhanania.com>";
// kriskringle@jacobhanania.com can't receive replies, so every email says so.
const NO_REPLY = `<p style="font-size:12px;color:#9a8c7e;margin:24px 0 0;padding-top:12px;border-top:1px solid #eadfca">This is an automated email from Kris Kringle, so please don't reply: this address can't receive messages. Questions? Ask your family's organiser.</p>`;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function wrap(title: string, inner: string, button: string) {
  return `<div style="font-family:Georgia,serif;max-width:480px;margin:0 auto;padding:24px;color:#2a1f1a">
  <h2 style="color:#b3201e;margin:0 0 12px">${title}</h2>
  ${inner}
  <p style="margin:20px 0 24px"><a href="${SITE_URL}" style="background:#b3201e;color:#ffffff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${button}</a></p>
  <p style="font-size:13px;color:#7a6a5c;margin:0">🤫 Kris Kringle keeps it secret: replies stay anonymous.</p>
${NO_REPLY}</div>`;
}
const quote = (body: string) =>
  `<blockquote style="margin:0 0 12px;padding:10px 14px;border-left:4px solid #d4a64a;background:#fffaf0;font-style:italic">${esc(body).replace(/\n/g, "<br>")}</blockquote>`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ error: "Emails aren't set up yet (missing RESEND_API_KEY)." }, 500);

  let messageId: string;
  try { ({ message: messageId } = await req.json()); } catch { return json({ error: "bad_request" }, 400); }
  if (!messageId) return json({ error: "bad_request" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: m, error } = await sb.rpc("message_email", { p_message: messageId });
  if (error) return json({ error: error.message }, 403);
  if (!m.to_email) return json({ sent: 0, reason: "no_email" });

  const signIn = m.to_has_account ? "Sign in to reply" : "Create your account with this email to reply";
  let subject: string, html: string;
  if (m.to_giftee && m.kind === "nudge") {
    subject = "🎁 Your Kris Kringle would love some gift ideas!";
    html = wrap("🎁 Psst… gift ideas, please!",
      `<p style="margin:0 0 12px">Hi ${esc(m.to_name)},</p><p style="margin:0 0 12px">Whoever is buying for you in the ${esc(m.family)} family Kris Kringle would love a few ideas. Add some things to your wish list and they'll see them straight away.</p>`,
      m.to_has_account ? "Add to my wish list" : "Create your account to add ideas");
  } else if (m.to_giftee) {
    subject = "🎅 Your Kris Kringle has a question for you";
    html = wrap("🎅 Your Kris Kringle asked you something",
      `<p style="margin:0 0 12px">Hi ${esc(m.to_name)},</p><p style="margin:0 0 12px">Whoever is buying for you in the ${esc(m.family)} family Kris Kringle asked:</p>${quote(m.body)}<p style="margin:0">Reply on the site. You won't find out who asked, and that's half the fun!</p>`,
      signIn);
  } else {
    // No giftee name anywhere: notifications can show up on a lock screen next to the giftee.
    subject = "💌 Your giftee replied to your question";
    html = wrap("💌 Your giftee replied",
      `<p style="margin:0 0 12px">Hi ${esc(m.to_name)},</p><p style="margin:0 0 12px">The person you're buying for answered your Kris Kringle question:</p>${quote(m.body)}`,
      "See the conversation");
  }

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [m.to_email], subject, html }),
  });
  if (!res.ok) return json({ error: `Email service error: ${await res.text()}` }, 502);
  return json({ sent: 1 });
});
