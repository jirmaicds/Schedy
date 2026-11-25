# Supabase setup for Schedy

Schedy uses Supabase **only as a database**. There is no Supabase Auth, no email, no hidden email address, and no email rate limit.

## 1. Supabase project

1. Create a project at https://supabase.com.
2. Open **SQL Editor** and run `supabase-setup.sql` from this folder. It is safe to re-run.
3. Go to **Project Settings → API** and copy:
   - Project URL
   - `anon` / `publishable` key (safe for the browser)

   Never use the `service_role` key in the app or put it on GitHub.

If you previously ran the older Supabase Auth SQL, you can ignore the old `profiles` table and old `auth.users` test accounts. Custom accounts are stored in `public.schedy_accounts`.

## 2. Configure the app

Choose one:

**A. Vercel environment variables (recommended for deployment).**  
In Vercel → Project Settings → Environment Variables, add:

- `SUPABASE_URL` = `https://your-project.supabase.co`
- `SUPABASE_ANON_KEY` = your anon/publishable key

The `/api/config` function reads these at runtime and the app picks them up automatically. Other common prefixes (`NEXT_PUBLIC_`, `VITE_`, `PUBLIC_`) are also accepted.

**B. Static config file (works locally and in the desktop app).**  
Edit `supabase-config.js`:

```js
window.SUPABASE_URL = "https://your-project.supabase.co";
window.SUPABASE_ANON_KEY = "your-anon-key";
```

The app uses the file first, then falls back to `/api/config` on Vercel if the file still has placeholders. Keep real keys out of GitHub; use placeholders in the committed file and Vercel env vars for deployment.

## 3. Vercel

Deploy this folder to Vercel. The root URL serves `index.html`, which is the full app. `schedy.html` is kept as a redirect for older links.

In Vercel → Settings → Build & Development:

- Build Command: leave empty
- Output Directory: set to `.` or leave empty
- Root Directory: the folder that contains `index.html`

Redeploy after changing env vars or config files.

## 4. Desktop app

`SchedyDesktop.py` loads `index.html`, so the desktop app uses the same account and cloud data. Rebuild `Schedy.exe` from `Schedy.spec` after changes:

```powershell
py -3 -m PyInstaller Schedy.spec --noconfirm
```

`supabase-config.js` is included in the spec's data files. Vercel env vars do not apply to the desktop app, so fill `supabase-config.js` locally.

## Tables created by `supabase-setup.sql`

| Table | Purpose |
|---|---|
| `public.schedy_accounts` | One row per account: normalized username, display name, and a **bcrypt salted hash** of the PIN. No plaintext PIN. |
| `public.schedy_sessions` | One row per device/session. Only a SHA-256 hash of the random session token is stored. Signing in on a new device does not log out other devices. Sessions expire after 30 days. |
| `public.schedy_data` | One JSON row per account with the week, events, categories, school calendar, and settings. |

Direct table access is revoked from `anon`/`authenticated`. All access goes through `SECURITY DEFINER` RPC functions:

- `schedy_signup(p_username, p_display_name, p_pin)`
- `schedy_login(p_username, p_pin)`
- `schedy_session(p_token)`
- `schedy_load(p_token)`
- `schedy_save(p_token, p_data)`
- `schedy_logout(p_token)`

## How signup and login work

- Username: 3–24 letters, numbers, `.`, `-`, `_` (underscores such as `jd_` are fine).
- PIN: 4–12 letters and/or numbers.
- On signup, the database stores `crypt(pin, gen_salt('bf', 10))` — a salted bcrypt hash. The app never sends or stores the PIN in plain text after the request.
- The database returns a random 32-byte session token. Only its SHA-256 hash is saved in `schedy_sessions`; the raw token is kept in the browser's `localStorage` under `bb.auth.token.v1`.
- Login verifies the PIN with bcrypt and creates a new session without invalidating other devices.

## How sync works

- Schedule, events, categories, school calendar, and settings are one JSON row per account in `public.schedy_data`.
- The app loads the cloud row at login/session restore and polls `schedy_load` every 5 seconds for changes from other devices.
- Local browser storage/desktop JSON is kept as a cache. The cloud row is the source of truth once signed in.
- The app only uploads when local data actually changes, so two devices do not overwrite each other every 2 seconds.

## Forgot PIN?

There is no email recovery. Because the PIN is a one-way salted hash, it cannot be read back.

To reset it manually, run this in Supabase → SQL Editor, replacing the username:

```sql
update public.schedy_accounts
   set pin_hash = crypt('NEW_PIN', gen_salt('bf', 10))
 where username = lower('YOUR_USERNAME');

delete from public.schedy_sessions
 where account_id in (select id from public.schedy_accounts where username = lower('YOUR_USERNAME'));
```

Then sign in again on each device with the new PIN.
