-- 0002_tenancy.sql
-- Workspaces, members, roles, per-workspace module flags, and the security
-- helpers every module's RLS policy is built on.

create type public.workspace_role as enum ('owner', 'adult', 'child');

create table public.workspaces (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) between 1 and 60),
  icon        text,                                  -- emoji or icon key
  is_personal boolean not null default false,
  plan        text not null default 'free',          -- seam for paid tiers later
  created_by  uuid not null references public.profiles,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces on delete cascade,
  user_id      uuid not null references public.profiles on delete cascade,
  role         public.workspace_role not null default 'adult',
  invited_by   uuid references public.profiles,
  joined_at    timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

-- The index that makes every RLS check cheap: membership is always looked up
-- by the current user.
create index workspace_members_user_idx on public.workspace_members (user_id, workspace_id);

create table public.workspace_modules (
  workspace_id uuid not null references public.workspaces on delete cascade,
  module       text not null check (module in
                 ('documents','calendar','shopping','chores','plans','expenses','lending')),
  enabled      boolean not null default true,
  settings     jsonb not null default '{}',
  primary key (workspace_id, module)
);

-- ---------------------------------------------------------------------------
-- module_access: which role may do what in which module.
--
-- Data, not code. Adding a module later is a row, not an edit to seven
-- policies; and "a child never sees documents or money" is enforced by the
-- database rather than by remembering to write it into each policy.
-- ---------------------------------------------------------------------------
create table public.module_access (
  module    text not null,
  role      public.workspace_role not null,
  can_read  boolean not null,
  can_write boolean not null,
  primary key (module, role)
);

insert into public.module_access (module, role, can_read, can_write) values
  ('documents','owner',true,true), ('documents','adult',true,true), ('documents','child',false,false),
  -- calendar: children read the workspace calendar but do not edit it.
  -- Restricting them to *their own* entries is a row-level rule belonging to
  -- the calendar module's own policy (assigned_to = auth.uid()), added with it.
  ('calendar','owner',true,true),  ('calendar','adult',true,true),  ('calendar','child',true,false),
  ('shopping','owner',true,true),  ('shopping','adult',true,true),  ('shopping','child',true,true),
  ('chores','owner',true,true),    ('chores','adult',true,true),    ('chores','child',true,true),
  ('plans','owner',true,true),     ('plans','adult',true,true),     ('plans','child',true,true),
  ('expenses','owner',true,true),  ('expenses','adult',true,true),  ('expenses','child',false,false),
  ('lending','owner',true,true),   ('lending','adult',true,true),   ('lending','child',false,false);

create table public.invitations (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces on delete cascade,
  code         text not null unique,
  role         public.workspace_role not null default 'adult',
  created_by   uuid not null references public.profiles,
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_by  uuid references public.profiles,
  accepted_at  timestamptz,
  created_at   timestamptz not null default now()
);

create table public.push_tokens (
  token      text primary key,               -- Expo push token
  user_id    uuid not null references public.profiles on delete cascade,
  platform   text not null check (platform in ('ios','android')),
  updated_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens (user_id);

-- ===========================================================================
-- Security helpers
--
-- All SECURITY DEFINER, so a policy on workspace_members can query
-- workspace_members without recursing into its own policy.
-- All `set search_path = ''`, without which a SECURITY DEFINER function is a
-- privilege-escalation hole.
-- All STABLE, and auth.uid() wrapped in a subselect so Postgres evaluates it
-- once per statement instead of once per row.
-- ===========================================================================

create or replace function app.is_member(ws uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.workspace_members m
    where m.workspace_id = ws and m.user_id = (select auth.uid())
  );
$fn$;

create or replace function app.role_in(ws uuid)
returns public.workspace_role language sql stable security definer set search_path = '' as $fn$
  select m.role from public.workspace_members m
  where m.workspace_id = ws and m.user_id = (select auth.uid());
$fn$;

create or replace function app.is_adult(ws uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select app.role_in(ws) in ('owner','adult');
$fn$;

create or replace function app.is_owner(ws uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select app.role_in(ws) = 'owner';
$fn$;

-- The single check every module policy uses: membership AND the module being
-- switched on for this workspace AND the role being allowed, in one call.
-- Paid-tier gating will slot in here rather than into every policy.
create or replace function app.can_use_module(ws uuid, m text, need text)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
    from public.workspace_members wm
    join public.workspace_modules mo
      on mo.workspace_id = wm.workspace_id and mo.module = m and mo.enabled
    join public.module_access ma
      on ma.module = m and ma.role = wm.role
    where wm.workspace_id = ws
      and wm.user_id = (select auth.uid())
      and case need when 'read'  then ma.can_read
                    when 'write' then ma.can_write
                    else false end
  );
$fn$;

create or replace function app.shares_workspace_with(other uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1
    from public.workspace_members a
    join public.workspace_members b on b.workspace_id = a.workspace_id
    where a.user_id = (select auth.uid()) and b.user_id = other
  );
$fn$;

-- ===========================================================================
-- Policies
-- ===========================================================================
alter table public.workspaces        enable row level security;
alter table public.workspace_members enable row level security;
alter table public.workspace_modules enable row level security;
alter table public.module_access     enable row level security;
alter table public.invitations       enable row level security;
alter table public.push_tokens       enable row level security;

create policy workspaces_select on public.workspaces
  for select to authenticated using (app.is_member(id));
create policy workspaces_insert on public.workspaces
  for insert to authenticated with check (created_by = (select auth.uid()));
create policy workspaces_update on public.workspaces
  for update to authenticated using (app.is_adult(id)) with check (app.is_adult(id));
create policy workspaces_delete on public.workspaces
  for delete to authenticated using (app.is_owner(id) and not is_personal);

-- Reads go through the helper, so this policy never recurses into itself.
create policy members_select on public.workspace_members
  for select to authenticated using (app.is_member(workspace_id));
create policy members_write on public.workspace_members
  for all to authenticated
  using (app.is_adult(workspace_id)) with check (app.is_adult(workspace_id));

create policy modules_select on public.workspace_modules
  for select to authenticated using (app.is_member(workspace_id));
create policy modules_write on public.workspace_modules
  for all to authenticated
  using (app.is_adult(workspace_id)) with check (app.is_adult(workspace_id));

-- Reference data: readable by all signed-in users, writable only by the
-- service role (which bypasses RLS).
create policy module_access_read on public.module_access
  for select to authenticated using (true);

create policy invitations_select on public.invitations
  for select to authenticated using (app.is_adult(workspace_id));
create policy invitations_write on public.invitations
  for all to authenticated
  using (app.is_adult(workspace_id)) with check (app.is_adult(workspace_id));

create policy push_tokens_own on public.push_tokens
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Now that the helpers exist: you can see the profile of anyone you share a
-- workspace with (their name appears on comments, reminders, activity).
create policy profiles_select_shared on public.profiles
  for select to authenticated using (app.shares_workspace_with(id));

-- ===========================================================================
-- Invariants RLS cannot express
-- ===========================================================================

-- A workspace must never lose its last owner.
create or replace function app.protect_last_owner()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  ws     uuid := coalesce(old.workspace_id, new.workspace_id);
  owners integer;
begin
  if (tg_op = 'DELETE' and old.role = 'owner')
     or (tg_op = 'UPDATE' and old.role = 'owner' and new.role <> 'owner') then
    select count(*) into owners
      from public.workspace_members
      where workspace_id = ws and role = 'owner';
    if owners <= 1 then
      raise exception 'a workspace must keep at least one owner';
    end if;
  end if;
  return coalesce(new, old);
end;
$fn$;

create trigger workspace_members_protect_last_owner
  before update or delete on public.workspace_members
  for each row execute function app.protect_last_owner();

create trigger workspaces_touch
  before update on public.workspaces
  for each row execute function app.touch_updated_at();

-- ===========================================================================
-- Signup, extended: every user also gets a personal workspace with the
-- documents module on. Replaces the 0001 version of this function.
-- ===========================================================================
create or replace function app.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $fn$
declare
  new_name text;
  ws_id    uuid;
begin
  new_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
    split_part(coalesce(new.email, 'user'), '@', 1)
  );

  insert into public.profiles (id, display_name)
  values (new.id, new_name);

  insert into public.workspaces (name, icon, is_personal, created_by)
  values ('Private', 'lock', true, new.id)
  returning id into ws_id;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (ws_id, new.id, 'owner');

  insert into public.workspace_modules (workspace_id, module, enabled)
  values (ws_id, 'documents', true);

  return new;
end;
$fn$;
