// Emails the whole family about a new organiser update or poll.
// Called by an organiser from admin.html with their own session, so the database checks they
// run the family. Needs the RESEND_API_KEY secret.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return json({ error: "Emails aren't set up yet (missing RESEND_API_KEY)." }, 500);

  let family: string, kind: string, id: string;
  try { ({ family, kind, id } = await req.json()); } catch { return json({ error: "bad_request" }, 400); }
  if (!family || !id || !["post", "poll"].includes(kind)) return json({ error: "bad_request" }, 400);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: d, error } = await sb.rpc("admin_broadcast_info", { p_family: family, p_kind: kind, p_id: id });
  if (error) return json({ error: error.message }, 403);

  const recipients = d.recipients as { name: string; email: string; has_account: boolean }[];
  if (!recipients.length) return json({ sent: 0 });

  const isPoll = d.kind === "poll";
  const subject = isPoll ? `🗳️ New family poll: ${d.content.question}` : `📣 Update from ${d.author} about the ${d.family} family Kris Kringle`;
  const inner = isPoll
    ? `<p style="margin:0 0 12px">${esc(d.author)} wants to know what everyone thinks:</p>
       <p style="margin:0 0 8px;font-size:18px;font-weight:bold">${esc(d.content.question)}</p>
       <ul style="margin:0 0 12px;padding-left:20px">${(d.content.options as string[]).map(o => `<li>${esc(o)}</li>`).join("")}</ul>
       <p style="margin:0 0 12px;color:#7a6a5c">Your vote is private: nobody sees who picked what.</p>`
    : `<p style="margin:0 0 12px">${esc(d.author)} posted an update:</p>
       <blockquote style="margin:0 0 12px;padding:10px 14px;border-left:4px solid #d4a64a;background:#fffaf0">${esc(d.content.body).replace(/\n/g, "<br>")}</blockquote>`;

  const emails = recipients.map(r => ({
    from: FROM, to: [r.email], subject,
    html: `<div style="font-family:Georgia,serif;max-width:480px;margin:0 auto;padding:24px;color:#2a1f1a">
  <h2 style="color:#b3201e;margin:0 0 12px">${isPoll ? "🗳️ New family poll" : "📣 Family update"}</h2>
  <p style="margin:0 0 12px">Hi ${esc(r.name)},</p>
  ${inner}
  <p style="margin:20px 0 0"><a href="${SITE_URL}" style="background:#b3201e;color:#ffffff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${isPoll ? (r.has_account ? "Vote now" : "Create your account to vote") : (r.has_account ? "Open Kris Kringle" : "Create your account")}</a></p>
${NO_REPLY}</div>`,
  }));

  let sent = 0;
  for (let i = 0; i < emails.length; i += 100) {
    const res = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(emails.slice(i, i + 100)),
    });
    if (!res.ok) return json({ error: `Email service error: ${await res.text()}`, sent }, 502);
    sent += Math.min(100, emails.length - i);
  }
  return json({ sent });
});
