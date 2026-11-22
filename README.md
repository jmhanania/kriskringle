# 🎄 Kris Kringle

A Kris Kringle (Secret Santa) site for any number of families or groups, each in its own private space. People create an account with their email (no password: they sign in with an emailed code), see who they're buying for, read that person's wish list, and keep their own.

## How people use it

1. **An organiser** creates an account, starts a family, and adds everyone's email. Each person gets an invite email.
2. **Everyone else** creates an account with that email and joins the family automatically.
3. **Members without email** (kids, grandparents) can still be in the draw. Organisers manage their wish lists.
4. The organiser sets no-go pairs (e.g. couples) and runs the draw. Each person then sees their match when they sign in.

## Pages

| Page | Who | What |
|---|---|---|
| `index.html` | Everyone | Sign in / create account; pick a family; Board · Kris Kringle · My wish list tabs; account settings |
| `admin.html?f=<family>` | Organisers | Board (updates, polls) · People (invites, managed wish lists) · Exchange (rules, no-go pairs, draw, reveal) |
| `super.html` | Site owner | Every family's name, size and organisers (not their draws or wish lists); backup download |
| `privacy.html` | Everyone | What's stored, who can see it, how to delete it |

## How the draw works

Randomized backtracking: it shuffles, assigns the person with the fewest valid options first, and backs up on dead ends. It finds a valid draw whenever one exists, and the database re-checks every draw before saving it. Optionally, it avoids repeating the previous exchange's matches.

## Backend

[Supabase](https://supabase.com) (Postgres + Auth with email one-time codes). Schema: [`supabase/migrations`](supabase/migrations). Email sending: [`supabase/functions`](supabase/functions).

- `families` → `people` (linked to accounts by email) → `wishlist_items`
- `kk_events`, `kk_participants`, `kk_exclusions`, `kk_assignments`, `kk_messages`, `kk_bought`
- `family_posts`, `polls`, `poll_votes`

Tables can't be read directly. Signed-in users can only call database functions, each of which checks the caller's membership and role in the family they're asking about. Signed-out visitors can't call anything except a keep-awake ping. The Supabase URL and publishable key in `config.js` are designed to be public.

**No personal details live in this repo.** Email addresses, names, family data and the site owner's account are stored only in the database. Addresses the email functions need come from Supabase secrets.

## Email setup

Emails go out through [Resend](https://resend.com) from an address that can't receive replies, and every email says so in its footer.

Edge function secrets (Supabase → Edge Functions → Secrets):

| Secret | What |
|---|---|
| `RESEND_API_KEY` | Resend API key with sending access |
| `EMAIL_FROM` | Sender, e.g. `Kris Kringle <no-reply@your-domain>` |
| `SITE_URL` | The site's public address, used for links in emails |

Sign-in codes are sent by Supabase Auth itself, using the custom SMTP settings (Authentication → Emails → SMTP).

| Function | Sends |
|---|---|
| `send-invite` | Invite when an organiser adds someone |
| `notify-draw` | "Names are drawn" (never says who you got) |
| `notify-message` | Anonymous questions, replies and nudges |
| `notify-family` | Organiser updates and new polls |
| `send-reminders` | Daily at 9am Toronto (`pg_cron`): empty-wish-list nudge a week before gift day, reminder to everyone 2 days before |

Resend's free plan allows 100 emails per day.

## Keeping it running

- **Keep-awake:** a daily GitHub Action (`.github/workflows/keep-awake.yml`) pings the database so the free project never pauses for inactivity.
- **Backups:** the free plan has none, so the super admin page has a **Download backup** button. The file contains everything, including draws and wish lists, so keep it private.

## Follow-ups

- [ ] **Privacy contact address.** Set up a monitored address and add it to `privacy.html`. Currently it says to ask your family's organiser. Worth doing before other groups sign up.
- [ ] **Automatic backups.** Backups are manual right now (super admin → Download backup). Could be automated to somewhere private.
- [ ] **Keep-awake job.** GitHub pauses scheduled workflows after ~60 days with no repo activity. Re-enable it from the Actions tab if GitHub emails about it.
- [ ] **Rename "Family"** to a more general word for groups.
- [ ] **Feature idea:** birthday mode reusing wish lists.

## Releasing changes

- **Pages** are served by GitHub Pages from `main`. Browsers cache `theme.css`, `common.js` and `config.js` for a few minutes, so every page links to them with a version (`theme.css?v=…`). **When you change any of those three files, bump the version in every `.html` file** (search for `?v=`).
- **Database changes** go live immediately, before the pages update, so keep them backward compatible with the pages currently online.
- **Edge functions** are deployed separately to Supabase; redeploy after changing `supabase/functions`.
