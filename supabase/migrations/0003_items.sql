-- 0003_items.sql
-- The item supertype and the building blocks every module shares.
--
-- A bill, a borrowed drill, a chore and a hobby practice are all "a thing in a
-- workspace, with a title, possibly a due date and a status". Modelling that
-- once means attachments, reminders, comments and the activity feed are built
-- once and secured once -- every module added later inherits them.

create table public.items (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces on delete cascade,
  module       text not null check (module in
                 ('documents','calendar','shopping','chores','plans','expenses','lending')),
  kind         text not null,          -- bill | letter | appointment | chore | loan | ...
  title        text not null,
  due_at       timestamptz,
  all_day      boolean not null default false,   -- a bill is due on a date, not at a time
  status       text not null default 'open' check (status in ('open','done','cancelled')),
  amount_cents bigint,                 -- money is always cents + currency
  currency     char(3),
  assigned_to  uuid references public.profiles,
  created_by   uuid not null references public.profiles,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint items_amount_needs_currency
    check ((amount_cents is null) = (currency is null))
);

-- "What is coming up in this workspace", across every module, is one query
-- against this index.
create index items_due_idx on public.items (workspace_id, due_at)
  where status = 'open';
create index items_module_idx on public.items (workspace_id, module, created_at desc);
create index items_assigned_idx on public.items (assigned_to) where status = 'open';

create trigger items_touch
  before update on public.items
  for each row execute function app.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Item-level access, derived from the item's own module and workspace.
-- Every shared building block below uses these two functions and nothing else.
-- ---------------------------------------------------------------------------
create or replace function app.can_read_item(p_item uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.items i
    where i.id = p_item and app.can_use_module(i.workspace_id, i.module, 'read')
  );
$fn$;

create or replace function app.can_write_item(p_item uuid)
returns boolean language sql stable security definer set search_path = '' as $fn$
  select exists (
    select 1 from public.items i
    where i.id = p_item and app.can_use_module(i.workspace_id, i.module, 'write')
  );
$fn$;

-- Keeps a child row's workspace_id honest: it is always the parent item's, so
-- a client cannot file a comment into a workspace it has no business in.
create or replace function app.sync_item_workspace()
returns trigger language plpgsql security definer set search_path = '' as $fn$
begin
  select i.workspace_id into new.workspace_id
    from public.items i where i.id = new.item_id;
  if new.workspace_id is null then
    raise exception 'unknown item %', new.item_id;
  end if;
  return new;
end;
$fn$;

-- ---------------------------------------------------------------------------
-- Shared building blocks
-- ---------------------------------------------------------------------------
create table public.attachments (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items on delete cascade,
  workspace_id uuid not null references public.workspaces on delete cascade,
  storage_path text not null,
  mime_type    text not null,
  byte_size    integer,
  role         text not null default 'original',   -- original | page | receipt | handover
  created_by   uuid not null references public.profiles,
  created_at   timestamptz not null default now()
);
create index attachments_item_idx on public.attachments (item_id);

create table public.reminders (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items on delete cascade,
  workspace_id uuid not null references public.workspaces on delete cascade,
  user_id      uuid not null references public.profiles on delete cascade,
  remind_at    timestamptz not null,
  title        text not null,
  status       text not null default 'pending' check (status in ('pending','sent','cancelled')),
  sent_at      timestamptz,
  created_by   uuid not null references public.profiles,
  created_at   timestamptz not null default now()
);
-- The scheduled sender's only query.
create index reminders_due_idx on public.reminders (remind_at) where status = 'pending';
create index reminders_item_idx on public.reminders (item_id);

create table public.comments (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items on delete cascade,
  workspace_id uuid not null references public.workspaces on delete cascade,
  author_id    uuid not null references public.profiles,
  body         text not null check (length(trim(body)) > 0),
  created_at   timestamptz not null default now()
);
create index comments_item_idx on public.comments (item_id, created_at);

-- Who did what, when. Doubles as the transparency record for helper access:
-- when an adult child acts inside their parents' workspace, the parents can
-- see exactly what was done.
create table public.activity (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces on delete cascade,
  item_id      uuid references public.items on delete cascade,   -- null = workspace-level
  actor_id     uuid references public.profiles,                  -- null = system
  verb         text not null,       -- created | explained | verified | handled | shared | ...
  meta         jsonb not null default '{}',
  created_at   timestamptz not null default now()
);
create index activity_workspace_idx on public.activity (workspace_id, created_at desc);
create index activity_item_idx on public.activity (item_id, created_at desc);

create trigger attachments_sync_ws before insert or update on public.attachments
  for each row execute function app.sync_item_workspace();
create trigger reminders_sync_ws before insert or update on public.reminders
  for each row execute function app.sync_item_workspace();
create trigger comments_sync_ws before insert or update on public.comments
  for each row execute function app.sync_item_workspace();

-- ---------------------------------------------------------------------------
-- Policies. Note how little there is: one pattern, reused.
-- ---------------------------------------------------------------------------
alter table public.items       enable row level security;
alter table public.attachments enable row level security;
alter table public.reminders   enable row level security;
alter table public.comments    enable row level security;
alter table public.activity    enable row level security;

create policy items_select on public.items
  for select to authenticated
  using (app.can_use_module(workspace_id, module, 'read'));

create policy items_insert on public.items
  for insert to authenticated
  with check (app.can_use_module(workspace_id, module, 'write')
              and created_by = (select auth.uid()));

create policy items_update on public.items
  for update to authenticated
  using (app.can_use_module(workspace_id, module, 'write'))
  with check (app.can_use_module(workspace_id, module, 'write'));

create policy items_delete on public.items
  for delete to authenticated
  using (app.can_use_module(workspace_id, module, 'write')
         and (app.is_adult(workspace_id) or created_by = (select auth.uid())));

create policy attachments_select on public.attachments
  for select to authenticated using (app.can_read_item(item_id));
create policy attachments_write on public.attachments
  for all to authenticated
  using (app.can_write_item(item_id))
  with check (app.can_write_item(item_id) and created_by = (select auth.uid()));

-- You may only ever create or see a reminder for yourself.
create policy reminders_select on public.reminders
  for select to authenticated
  using (user_id = (select auth.uid()) and app.can_read_item(item_id));
create policy reminders_write on public.reminders
  for all to authenticated
  using (user_id = (select auth.uid()) and app.can_write_item(item_id))
  with check (user_id = (select auth.uid()) and app.can_write_item(item_id));

create policy comments_select on public.comments
  for select to authenticated using (app.can_read_item(item_id));
create policy comments_insert on public.comments
  for insert to authenticated
  with check (app.can_write_item(item_id) and author_id = (select auth.uid()));
create policy comments_delete on public.comments
  for delete to authenticated
  using (author_id = (select auth.uid()));

create policy activity_select on public.activity
  for select to authenticated
  using (case when item_id is null
              then app.is_member(workspace_id)
              else app.can_read_item(item_id) end);
-- Activity is append-only from the client's point of view: no update, no delete.
create policy activity_insert on public.activity
  for insert to authenticated
  with check (actor_id = (select auth.uid()) and app.is_member(workspace_id));
