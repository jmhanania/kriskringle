// Sends any reminder emails that are due today. Run daily by pg_cron (see the migration
// "reminder_schedule"). Safe to call by anyone: the database hands out each reminder exactly
// once, so extra calls send nothing. Needs the RESEND_API_KEY secret.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE_URL = Deno.env.get("SITE_URL") ?? "https://kriskringle.jacobhanania.com";
const FROM = Deno.env.get("EMAIL_FROM") ?? "Kris Kringle <kriskringle@jacobhanania.com>";
// kriskringle@jacobhanania.com can't receive replies, so every email says so.
const NO_REPLY = `<p style="font-size:12px;color:#9a8c7e;margin:24px 0 0;padding-top:12px;border-top:1px solid #eadfca">This is an automated email from Kris Kringle, so please don't reply: this address can't receive messages. Questions? Ask your family's organiser.</p>`;

const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const money = (cents: number | null) =>
  cents == null ? "" : (cents / 100).toLocaleString("en-CA", { style: "currency", currency: "CAD", maximumFractionDigits: cents % 100 ? 2 : 0 });
const prettyDate = (iso: string) => new Date(iso + "T12:00:00").toLocaleDateString("en-CA", { weekday: "long", month: "long", day: "numeric" });

type Reminder = {
  kind: "wishlist_week" | "gift_day_soon";
  family: string;
  event: { name: string; exchange_date: string; budget_cents: number | null };
  recipients: { name: string; email: string; has_account: boolean }[];
};

function email(r: Reminder, to: Reminder["recipients"][number]) {
  const day = prettyDate(r.event.exchange_date);
  const button = (label: string) =>
    `<p style="margin:20px 0 24px"><a href="${SITE_URL}" style="background:#b3201e;color:#ffffff;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:bold">${label}</a></p>`;
  const wrap = (title: string, inner: string) =>
    `<div style="font-family:Georgia,serif;max-width:480px;margin:0 auto;padding:24px;color:#2a1f1a"><h2 style="color:#b3201e;margin:0 0 12px">${title}</h2><p style="margin:0 0 12px">Hi ${esc(to.name)},</p>${inner}${NO_REPLY}</div>`;
  if (r.kind === "wishlist_week") {
    return {
      subject: `🎁 A week to go! Your Kris Kringle needs gift ideas`,
      html: wrap("🎁 One week until gift day!",
        `<p style="margin:0 0 12px">${esc(r.event.name)} in the ${esc(r.family)} family Kris Kringle is on <strong>${day}</strong>, and your wish list is still empty. Add a few ideas so your Kris Kringle knows what to get you.</p>` +
        button(to.has_account ? "Add to my wish list" : "Create your account to add ideas")),
    };
  }
  const budget = r.event.budget_cents != null ? ` The budget is <strong>${money(r.event.budget_cents)}</strong>.` : "";
  return {
    subject: `🎅 ${r.event.name} is ${day}!`,
    html: wrap("🎅 Gift day is almost here!",
      `<p style="margin:0 0 12px">Just a reminder: ${esc(r.event.name)} in the ${esc(r.family)} family Kris Kringle is on <strong>${day}</strong>.${budget}</p>` +
      `<p style="margin:0 0 12px">Need a last look at who you're buying for, or their wish list?</p>` +
      button(to.has_account ? "See my Kris Kringle" : "Create your account to see who you got") +
      `<p style="font-size:13px;color:#7a6a5c;margin:0">🤫 Remember, it's a secret!</p>`),
  };
}

Deno.serve(async () => {
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) return Response.json({ error: "missing RESEND_API_KEY" }, { status: 500 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await sb.rpc("claim_due_reminders");
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const emails = (data as Reminder[]).flatMap(r => r.recipients.map(to => ({ from: FROM, to: [to.email], ...email(r, to) })));
  let sent = 0;
  // Resend's batch endpoint takes up to 100 emails per call.
  for (let i = 0; i < emails.length; i += 100) {
    const res = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(emails.slice(i, i + 100)),
    });
    if (!res.ok) return Response.json({ error: await res.text(), sent }, { status: 502 });
    sent += Math.min(100, emails.length - i);
  }
  return Response.json({ reminders: (data as Reminder[]).length, sent });
});
