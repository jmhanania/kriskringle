# 🎄 Kris Kringle Generator

A Kris Kringle (Secret Santa) site that any number of families can use, each in its own private space. Everyone gets a personal link, with no accounts or passwords. It shows who they're buying for, that person's wish list, and their own wish list to edit.

## Pages

| Page | Who | What |
|---|---|---|
| `start.html` | New families | Sign up with the invite code, and get a family admin link |
| `index.html#<code>` | Everyone | Their match, their match's wish list, and their own wish list |
| `admin.html#<code>` | Family admins | Manage family members and co-admins, run exchanges and no-go pairs, do the draw, send links |
| `super.html#<code>` | Site owner | See all families and their admins, change the invite code, recover admin links, delete families |

Codes go after `#`, so they're never sent to the web host or stored in its logs.

## Roles

- **Member:** sees only their own match and wish lists.
- **Family admin:** manages one family. Can make other members co-admins.
- **Super admin:** sees every family's name, counts and admins, but **not** their draws or wish lists.

## How the draw works

Randomized backtracking: it shuffles, assigns the person with the fewest valid options first, and backs up on dead ends. It finds a valid draw whenever one exists, and says so if the rules make one impossible. The database re-checks every draw before saving it. Optionally, it avoids repeating matches from the previous exchange.

## Backend

Supabase project **Hanania Family** (Canada Central). Schema: [`supabase/migrations`](supabase/migrations).

- `families` → `people`, `wishlist_items` (shared family data)
- `kk_events`, `kk_participants`, `kk_exclusions`, `kk_assignments` (Kris Kringle)

The browser can't read tables directly. It can only call database functions. Each function works out the caller's person and family from their link code, and only touches that family's data. The publishable key in `config.js` is safe to make public.

## Private stuff

Your codes and the family invite code are in `ADMIN-LINK.txt`, which is git-ignored and never committed. If a link leaks, use **New link** on the admin or super page.

> Free Supabase projects pause after ~7 days without visits. If links stop working, open the Supabase dashboard and click **Restore**.
