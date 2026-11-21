# 🎄 Hanania Kris Kringle Generator

A family Kris Kringle (Secret Santa) site. Each person gets a private link, with no accounts or passwords. Opening it shows who they're buying for, that person's wish list, and their own wish list to edit.

## Pages

| Page | Who | What |
|---|---|---|
| `index.html#<code>` | Everyone | Their match, their match's wish list, and their own wish list |
| `admin.html#<admin-code>` | Admin only | Manage family members, set up exchanges and no-go pairs, run the draw, send links |

Codes go after `#`, so they're never sent to the web host or stored in its logs.

## How the draw works

Randomized backtracking: it shuffles, assigns the person with the fewest valid options first, and backs up on dead ends. It finds a valid draw whenever one exists, and says so if the rules make one impossible. The database re-checks every draw before saving it, rejecting anyone drawing themselves or breaking a no-go pair. Optionally, it avoids repeating matches from the previous exchange.

## Backend

Supabase project **Hanania Family** (Canada Central). Schema: [`supabase/migrations`](supabase/migrations).

- **Family tables:** `people`, `wishlist_items`. They're reusable for birthdays and other family apps.
- **Kris Kringle tables:** `kk_events`, `kk_participants`, `kk_exclusions`, `kk_assignments`.

The browser can't read tables directly. It can only call database functions, and each function checks the caller's link code first. The publishable key in `config.js` is safe to make public.

## Admin

Your admin link is in `ADMIN-LINK.txt`, which is git-ignored and never committed. If any link leaks, use **New link** on the admin page to replace it.

> Free Supabase projects pause after ~7 days without visits. If links stop working, open the Supabase dashboard and click **Restore**.
