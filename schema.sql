-- =====================================================================
-- RSVP tracker: Supabase schema
-- Paste this whole file into Supabase > SQL Editor > New query > Run.
-- Safe to read top to bottom; each section is commented.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. TABLES  (think: tabs in a spreadsheet)
-- ---------------------------------------------------------------------

create table if not exists members (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,          -- what shows up on the page
  active     boolean not null default true, -- set false instead of deleting
  created_at timestamptz not null default now()
);

create table if not exists events (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  event_date timestamptz not null,
  location   text,
  notes      text,
  created_at timestamptz not null default now()
);

create table if not exists rsvps (
  id         uuid primary key default gen_random_uuid(),
  member_id  uuid not null references members(id) on delete cascade,
  event_id   uuid not null references events(id)  on delete cascade,
  status     text not null check (status in ('attending', 'not_attending')),
  created_at timestamptz not null default now(),
  -- The lock rule's safety net: only ONE row per person per event, ever.
  unique (member_id, event_id)
);

-- Who is an admin. Add yourself after your first magic-link login (see README).
create table if not exists admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- Every RSVP and every admin change is recorded here.
create table if not exists audit_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  actor      text not null,        -- 'member' or the admin's email
  action     text not null,        -- 'rsvp', 'admin_set', 'admin_clear'
  member_id  uuid,
  event_id   uuid,
  old_status text,
  new_status text
);


-- ---------------------------------------------------------------------
-- 2. ROW-LEVEL SECURITY  (the rules at the "front desk")
-- ---------------------------------------------------------------------
-- Turning RLS on means: nobody can touch a table unless a policy says so.

alter table members   enable row level security;
alter table events    enable row level security;
alter table rsvps     enable row level security;
alter table admins    enable row level security;
alter table audit_log enable row level security;

-- Helper: is the person making this request an admin?
create or replace function is_admin()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from admins where user_id = auth.uid());
$$;

-- Anyone (no login) can READ the member list and events.
create policy "public can read active members" on members
  for select using (active = true or is_admin());

create policy "public can read events" on events
  for select using (true);

-- Only admins can add / edit / remove members and events directly.
create policy "admins insert members" on members
  for insert with check (is_admin());
create policy "admins update members" on members
  for update using (is_admin()) with check (is_admin());
create policy "admins delete members" on members
  for delete using (is_admin());

create policy "admins insert events" on events
  for insert with check (is_admin());
create policy "admins update events" on events
  for update using (is_admin()) with check (is_admin());
create policy "admins delete events" on events
  for delete using (is_admin());

-- rsvps: NO anonymous policies at all. Members can only go through the
-- functions below. Admins can read the raw table.
create policy "admins read rsvps" on rsvps
  for select using (is_admin());

-- audit_log: admins can read it. Nobody writes to it directly; the
-- functions below do it.
create policy "admins read audit log" on audit_log
  for select using (is_admin());

-- admins table: an admin can see their own row (used by the admin page).
create policy "admins read self" on admins
  for select using (user_id = auth.uid());


-- ---------------------------------------------------------------------
-- 3. FUNCTIONS  (the only ways to change RSVPs)
-- ---------------------------------------------------------------------
-- "security definer" = the function runs with elevated rights, so it can
-- write to rsvps even though anonymous visitors cannot. All the checking
-- happens inside the function, which is what makes the lock trustworthy.

-- 3a. Member submits an RSVP. Succeeds only if none exists yet.
create or replace function submit_rsvp(
  p_member_id uuid,
  p_event_id  uuid,
  p_status    text
)
returns text   -- 'saved' | 'already_set' | 'event_closed'
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_date timestamptz;
  v_rows       integer;
begin
  if p_status not in ('attending', 'not_attending') then
    raise exception 'Invalid status';
  end if;

  if not exists (select 1 from members where id = p_member_id and active) then
    raise exception 'Unknown member';
  end if;

  select event_date into v_event_date from events where id = p_event_id;
  if v_event_date is null then
    raise exception 'Unknown event';
  end if;

  -- Don't accept RSVPs once the event has started.
  if v_event_date < now() then
    return 'event_closed';
  end if;

  -- Insert only if there's no row yet. If one exists, do nothing.
  insert into rsvps (member_id, event_id, status)
  values (p_member_id, p_event_id, p_status)
  on conflict (member_id, event_id) do nothing;

  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    return 'already_set';
  end if;

  insert into audit_log (actor, action, member_id, event_id, old_status, new_status)
  values ('member', 'rsvp', p_member_id, p_event_id, null, p_status);

  return 'saved';
end;
$$;


-- 3b. Public read: everyone active, with their status for one event.
--     Members with no row come back as 'no_response'.
create or replace function get_event_rsvps(p_event_id uuid)
returns table (member_id uuid, member_name text, status text)
language sql
security definer
stable
set search_path = public
as $$
  select m.id,
         m.name,
         coalesce(r.status, 'no_response') as status
  from members m
  left join rsvps r
         on r.member_id = m.id
        and r.event_id  = p_event_id
  where m.active
  order by m.name;
$$;


-- 3c. Admin override. p_status can be 'attending', 'not_attending',
--     or 'no_response' (which deletes the row so the member can pick again).
create or replace function admin_set_status(
  p_member_id uuid,
  p_event_id  uuid,
  p_status    text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old   text;
  v_email text;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  if p_status not in ('attending', 'not_attending', 'no_response') then
    raise exception 'Invalid status';
  end if;

  select status into v_old
  from rsvps
  where member_id = p_member_id and event_id = p_event_id;

  select email into v_email from auth.users where id = auth.uid();

  if p_status = 'no_response' then
    delete from rsvps where member_id = p_member_id and event_id = p_event_id;
    insert into audit_log (actor, action, member_id, event_id, old_status, new_status)
    values (v_email, 'admin_clear', p_member_id, p_event_id, v_old, null);
    return 'cleared';
  end if;

  insert into rsvps (member_id, event_id, status)
  values (p_member_id, p_event_id, p_status)
  on conflict (member_id, event_id) do update set status = excluded.status;

  insert into audit_log (actor, action, member_id, event_id, old_status, new_status)
  values (v_email, 'admin_set', p_member_id, p_event_id, v_old, p_status);

  return 'updated';
end;
$$;


-- ---------------------------------------------------------------------
-- 4. WHO MAY CALL WHAT
-- ---------------------------------------------------------------------
-- Functions are callable by everyone by default; lock that down first.

revoke execute on function submit_rsvp(uuid, uuid, text)       from public;
revoke execute on function get_event_rsvps(uuid)               from public;
revoke execute on function admin_set_status(uuid, uuid, text)  from public;
revoke execute on function is_admin()                          from public;

grant execute on function submit_rsvp(uuid, uuid, text)       to anon, authenticated;
grant execute on function get_event_rsvps(uuid)               to anon, authenticated;
grant execute on function admin_set_status(uuid, uuid, text)  to authenticated;
grant execute on function is_admin()                          to anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. OPTIONAL SAMPLE DATA (delete these lines if you don't want it)
-- ---------------------------------------------------------------------
-- insert into members (name) values ('Dana'), ('Sam'), ('Priya'), ('Alex');
-- insert into events (title, event_date, location)
-- values ('Winter potluck', now() + interval '14 days', 'Community Hall');
