-- 0006_layers_and_quota.sql
--
-- Two decisions land here.
--
-- 1. Reading a document is layered, cheapest and most certain first:
--      layer 0  barcode scan  - free, on-device, exact
--      layer 1  model call    - the image; explains, and fills in the rest
--    So a document records *where each fact came from*, not just what it says.
--    (An on-device OCR layer was considered and rejected for v1: ~10% saving
--    against a permanent second input path. The ocr_* columns below are kept
--    nullable so adding it later needs no migration.)
--
-- 2. The model call is the only metered resource, because layer 0 costs
--    nothing to run. The meter has to exist before it is needed -- retrofitting
--    usage accounting onto live data is miserable.

-- ---------------------------------------------------------------------------
-- Layer 0 and 1 results
-- ---------------------------------------------------------------------------
alter table public.documents
  add column content_hash      text,      -- sha256 of the uploaded bytes
  add column ocr_text          text,      -- layer 1 output, on-device
  add column ocr_confidence    numeric,   -- 0..1, decides text-vs-image at layer 2
  add column barcode_verified  boolean not null default false,
  add column extraction_source text not null default 'vision'
    check (extraction_source in ('barcode','ocr','vision','manual','mixed'));

comment on column public.documents.content_hash is
  'Never analyse the same image twice: on a match, reuse the existing analysis.';
comment on column public.documents.barcode_verified is
  'The virtuaaliviivakoodi agreed with the extracted IBAN, amount, reference and '
  'due date. Where barcode and model disagree, the barcode wins.';

-- One document per workspace per image. A re-photographed or forwarded bill
-- resolves to the row that already exists.
create unique index documents_content_hash_idx
  on public.documents (content_hash)
  where content_hash is not null;

-- Full-text search, fed by OCR if that layer is ever added. Until then the
-- searchable corpus is title, sender and explanation -- data the model already
-- produces, and readable by the user, unlike the raw Finnish body text.
-- 'simple' rather than 'finnish' on purpose:
-- the corpus is multilingual, and applying Finnish stemming to a Persian or
-- German letter is worse than applying none.
alter table public.documents
  add column search_vector tsvector
  generated always as (to_tsvector('simple', coalesce(ocr_text, ''))) stored;

create index documents_search_idx on public.documents using gin (search_vector);

-- ---------------------------------------------------------------------------
-- plans: quotas are data, like module_access
-- ---------------------------------------------------------------------------
create table public.plans (
  code                   text primary key,
  name                   text not null,
  ai_documents_per_month integer,        -- null = unlimited
  max_explain_languages  integer,        -- null = unlimited
  price_cents            integer,        -- indicative only; the app store is
  currency               char(3) not null default 'EUR',   -- the source of truth
  sort_order             integer not null default 100
);

insert into public.plans (code, name, ai_documents_per_month, max_explain_languages, price_cents, sort_order) values
  ('free',   'Koti',        5,    1,    0,   1),
  ('family', 'Koti Family', 50,   null, 499, 2),
  ('care',   'Koti Care',   150,  null, 999, 3);

alter table public.workspaces
  add constraint workspaces_plan_fkey foreign key (plan) references public.plans(code);

-- ---------------------------------------------------------------------------
-- usage_counters: one row per workspace per month per metered thing
-- ---------------------------------------------------------------------------
create table public.usage_counters (
  workspace_id uuid not null references public.workspaces on delete cascade,
  period       date not null,            -- first day of the month, UTC
  metric       text not null,            -- 'ai_document_read'
  used         integer not null default 0 check (used >= 0),
  updated_at   timestamptz not null default now(),
  primary key (workspace_id, period, metric)
);

alter table public.plans          enable row level security;
alter table public.usage_counters enable row level security;

create policy plans_read on public.plans
  for select to authenticated using (true);

-- Members can see what they have used -- "3 of 5 readings left this month" is
-- a screen. Nobody can write it from a client.
create policy usage_counters_read on public.usage_counters
  for select to authenticated using (app.is_member(workspace_id));

grant select on public.plans          to authenticated;
grant select on public.usage_counters to authenticated;

-- ---------------------------------------------------------------------------
-- The meter itself.
--
-- Lives in `public`, not `app`, because PostgREST only exposes functions in
-- the API schemas -- the edge function calls it as an RPC. Execute is revoked
-- from `authenticated`, so being in public does not make it reachable.
--
-- Called by the edge function under the service role, immediately before the
-- Claude call. Returns false when the workspace is out of allowance, and the
-- caller must then skip layer 2 -- layers 0 and 1 keep working, so the app
-- degrades to "we read the barcode, but explaining costs a subscription"
-- rather than to a wall.
-- ---------------------------------------------------------------------------
create or replace function public.consume_ai_document(ws uuid)
returns boolean language plpgsql security definer set search_path = '' as $fn$
declare
  allowance integer;
  used_now  integer;
  this_period date := date_trunc('month', (now() at time zone 'utc'))::date;
begin
  select p.ai_documents_per_month into allowance
    from public.workspaces w
    join public.plans p on p.code = w.plan
   where w.id = ws;

  if not found then
    raise exception 'unknown workspace %', ws;
  end if;

  -- The upsert takes a row lock, so two concurrent uploads cannot both slip
  -- past the last unit of allowance.
  insert into public.usage_counters (workspace_id, period, metric, used)
  values (ws, this_period, 'ai_document_read', 1)
  on conflict (workspace_id, period, metric)
    do update set used = public.usage_counters.used + 1, updated_at = now()
  returning used into used_now;

  if allowance is not null and used_now > allowance then
    update public.usage_counters
       set used = used - 1
     where workspace_id = ws and period = this_period and metric = 'ai_document_read';
    return false;
  end if;

  return true;
end;
$fn$;

-- Give an allowance back when the model call fails after the meter ran. A
-- failed reading must never cost a household one of its five.
create or replace function public.refund_ai_document(ws uuid)
returns void language sql security definer set search_path = '' as $fn$
  update public.usage_counters
     set used = greatest(used - 1, 0), updated_at = now()
   where workspace_id = ws
     and period = date_trunc('month', (now() at time zone 'utc'))::date
     and metric = 'ai_document_read';
$fn$;

-- Readable by the client so the UI can show the remaining allowance without
-- guessing. Returns null for an unlimited plan.
create or replace function public.ai_documents_remaining(ws uuid)
returns integer language sql stable security definer set search_path = '' as $fn$
  select case
           when p.ai_documents_per_month is null then null
           else greatest(p.ai_documents_per_month - coalesce(u.used, 0), 0)
         end
    from public.workspaces w
    join public.plans p on p.code = w.plan
    left join public.usage_counters u
      on u.workspace_id = w.id
     and u.period = date_trunc('month', (now() at time zone 'utc'))::date
     and u.metric = 'ai_document_read'
   where w.id = ws
     and app.is_member(ws);
$fn$;

-- Only the edge function may spend allowance. A client that could call this
-- could also burn someone else's quota.
revoke execute on function public.consume_ai_document(uuid) from public, authenticated;
revoke execute on function public.refund_ai_document(uuid)  from public, authenticated;
grant   execute on function public.consume_ai_document(uuid) to service_role;
grant   execute on function public.refund_ai_document(uuid)  to service_role;
grant   execute on function public.ai_documents_remaining(uuid) to authenticated;
