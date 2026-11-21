# 🎄 Kris Kringle Generator

Live at **https://kriskringle.jacobhanania.com**

A Kris Kringle (Secret Santa) site for any number of families, each in its own private space. People create an account with their email (no password: they sign in with an emailed code), see who they're buying for, read that person's wish list, and keep their own.

## How people use it

1. **An organiser** creates an account, starts a family, and adds everyone's email.
2. **Everyone else** creates an account with that email and joins the family automatically. Nothing needs to be sent to them, though organisers can send an optional "Invite" email.
3. **Family members without email** (kids, grandparents) can still be in the draw. Organisers manage their wish lists.
4. The organiser sets no-go pairs (e.g. couples) and runs the draw. Each person then sees their match when they sign in.

## Pages

| Page | Who | What |
|---|---|---|
| `index.html` | Everyone | Sign in / create account, start a family, see your match and wish lists, switch families |
| `admin.html?f=<family>` | Organisers | Family members, invites, managed wish lists, exchanges, no-go pairs, the draw |
| `super.html` | Site owner | Every family's name, size and organisers (not their draws or wish lists), delete families |

## How the draw works

Randomized backtracking: it shuffles, assigns the person with the fewest valid options first, and backs up on dead ends. It finds a valid draw whenever one exists, and the database re-checks every draw before saving it. Optionally, it avoids repeating the previous exchange's matches.

## Backend

Supabase project **Hanania Family** (Canada Central), using Supabase Auth with email one-time codes. Schema: [`supabase/migrations`](supabase/migrations).

- `families` → `people` (linked to accounts by email) → `wishlist_items`
- `kk_events`, `kk_participants`, `kk_exclusions`, `kk_assignments`

Tables can't be read directly. Signed-in users can only call database functions, each of which checks the caller's membership and role in the family they're asking about. Signed-out visitors can't call anything. The publishable key in `config.js` is safe to make public.

## Keeping it running

- **Keep-awake:** a daily GitHub Action (`.github/workflows/keep-awake.yml`) pings the database so the free project never pauses for inactivity.
- **Backups:** the free plan has none, so the super admin page has a **Download backup** button. The file contains everything, including draws and wish lists, so keep it private.
- **Emails:** sign-in codes and "names are drawn" notifications go out through Resend from `kriskringle@jacobhanania.com`. The free plan allows 100 per day.
- **Draw notifications:** sent by the `notify-draw` Supabase Edge Function (`supabase/functions/notify-draw`), which needs a `RESEND_API_KEY` secret.
