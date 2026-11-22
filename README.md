# Mario Party Jamboree Tracker

An installable web app (PWA) for family game night. Anyone with the link can view stats. Only approved family members can sign in to add or delete games.

All stats are computed in Postgres views (`supabase/schema.sql`). The page just draws them.

## Files

| File | Purpose |
|---|---|
| `index.html` | The whole app: UI, sign-in, stats rendering |
| `config.js` | Your Supabase URL and publishable key |
| `supabase/schema.sql` | Tables, `add_game()`, stat views, editors allowlist, security rules |
| `manifest.webmanifest`, `sw.js`, `icons/` | Make it installable and let it open offline |
| `vendor/supabase.js` | supabase-js 2.119.2, kept in the repo so the app does not depend on a CDN |

## Setup

### 1. Database
Supabase dashboard > SQL Editor > New query. Paste `supabase/schema.sql` and click **Run**.
It is safe to re-run. If you ran the older version, running this one keeps every game and switches on the editor rules.

### 2. Turn off public sign-ups
Authentication > Sign In / Providers. Keep **Email** enabled and turn **off** "Allow new users to sign up".
The editors list blocks writes either way. This just stops strangers from creating accounts.

### 3. Add each family member who should be able to add games
1. Authentication > Users > **Add user** > **Create new user**. Enter their email and a temporary password, and tick **Auto Confirm User**.
2. In the SQL Editor, add them to the allowlist (use lowercase):
   ```sql
   insert into public.editors (email) values ('name@example.com');
   ```
3. Give them the temporary password. They can change it from the account button in the app.

To remove someone's edit rights: `delete from public.editors where email = 'name@example.com';`
Anyone without an account can still view everything.

### 4. Keys
Project Settings > API (or API Keys). Copy the **Project URL** and the **publishable** key (or the legacy anon key) into `config.js`.
These are safe to publish. **Never** use the secret / service_role key.

### 5. Host it
Create a GitHub repo named `party-tracker`, push these files, then go to Settings > Pages > Deploy from branch `main` / root.
It will be live at `https://hepmatt.github.io/party-tracker/`.

### 6. Install on phones
- **iPhone:** open the link in Safari > Share > **Add to Home Screen**
- **Android:** open in Chrome > menu > **Install app**

## Updating the app
After changing any file, bump `VERSION` in `sw.js` (for example `v1` to `v2`). Installed copies pick up the change the next time they open.

## Adding characters or boards (DLC)
```sql
insert into public.characters (name) values ('New Character');
insert into public.boards (name, sort_order) values ('New Board', 8);
```

## Notes
- Free Supabase projects pause after about a week with no activity. If the app says it cannot reach Supabase, open the dashboard and click **Restore**.
- Offline, the app shows the last stats it loaded on that device. Adding a game needs a connection.
