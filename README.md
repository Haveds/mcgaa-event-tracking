# Event RSVP tracker

A no-login RSVP page for a small group. Members pick their name and mark each
event as attending or not attending. Once set, only an admin can change it.
Everyone can see live counts and names.

- **Front end:** plain HTML + JavaScript, hosted free on GitHub Pages
- **Back end:** Supabase (Postgres database + rules), free tier

```
index.html   the page members see
app.js       talks to Supabase, draws the page
config.js    your Supabase URL + public key (you fill this in)
schema.sql   tables, security rules, and the functions that enforce the lock
```

## Setup (about 20 minutes)

### 1. Create the Supabase project
1. Sign up at supabase.com and create a new project (any name, pick a region near you).
2. Open **SQL Editor > New query**, paste in all of `schema.sql`, and click **Run**.
   You should see "Success. No rows returned."

### 2. Add your members and a test event
In Supabase, open **Table Editor**:
- `members`: add rows with just a `name` (e.g. "Dana"). Leave the other columns alone.
- `events`: add a row with `title` and a future `event_date`.

(For many members at once, use the **Insert > Import data from CSV** option on the table.)

### 3. Connect the page
1. In Supabase, go to **Project Settings > API**.
2. Copy the **Project URL** and the **anon public** key into `config.js`.
   The anon key is meant to be public. Never put the `service_role` key anywhere in this repo.

### 4. Test locally
Modules don't load from `file://`, so serve the folder:

```bash
python3 -m http.server 8000
# then open http://localhost:8000
```

Try it: pick a name, click Attending, confirm. Reload and check that the status
is locked and the name shows up in the Attending list.

### 5. Deploy to GitHub Pages
1. Push these files to a GitHub repo.
2. Repo **Settings > Pages**, set source to your main branch, root folder.
3. Your page will be live at `https://<username>.github.io/<repo>/`.

### 6. Make yourself an admin (needed for the admin page later)
1. In Supabase, **Authentication > Users > Add user**, using your email.
   (Magic-link login will come with the admin page.)
2. Copy your user's UUID, then in the SQL Editor run:
   ```sql
   insert into admins (user_id) values ('PASTE-YOUR-USER-UUID-HERE');
   ```

Until the admin page exists, you can reset or change someone's status in the
**Table Editor** by editing or deleting their row in `rsvps`. Rows in
`audit_log` show everything that happened.

## How the lock works
Anonymous visitors have **no** permission to write to the `rsvps` table. The page
can only call `submit_rsvp`, which inserts a row only if none exists for that
member and event. A unique constraint on `(member_id, event_id)` backs this up
at the database level. Admin changes go through `admin_set_status`, which checks
the `admins` table and logs who changed what.

## Notes
- **Free-tier pausing:** Supabase has paused inactive free projects after a period
  of inactivity. Check the current policy, and consider a scheduled GitHub Action
  that makes a small request to keep it active.
- **Wrong-name risk:** with no login, anyone can pick any name. Visible names plus
  the audit log are the safeguards. If it becomes a problem, add a shared group
  code or a per-member check.
- **Next steps:** admin page (create events, add members, override statuses),
  then email reminders via a scheduled job.
