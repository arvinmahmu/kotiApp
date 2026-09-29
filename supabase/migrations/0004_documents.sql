-- 0004_documents.sql
-- The documents module: the v1 feature. A document is an item subtype.
--
-- Metadata on `items`/`documents` is canonical and human-correctable.
-- Claude's output is a *proposal* stored in document_analyses -- versioned,
-- re-runnable, cost-tracked, and auditable when someone asks "why does it say
-- 248 euro?".

create type public.document_status as enum ('uploaded','processing','ready','failed');

create table public.documents (
  item_id          uuid primary key references public.items on delete cascade,
  storage_path     text not null,
  source           text not null default 'camera'
                     check (source in ('camera','upload','email','share')),
  mime_type        text not null,
  byte_size        integer,
  status           public.document_status not null default 'uploaded',
  error_message    text,

  -- canonical metadata, promoted from an analysis, editable by a human.
  -- title, due_at and amount_cents live on `items` -- they are not
  -- document-specific concepts.
  doc_type         text,     -- bill | letter | tax | insurance | health | bank | school | contract | other
  sender_name      text,
  issue_date       date,
  reference_number text,     -- Finnish viitenumero
  iban             text,
  barcode_raw      text,     -- 54-char virtuaaliviivakoodi, when present
  source_language  text references public.languages(code),

  verified_by      uuid references public.profiles,   -- a human confirmed the fields
  verified_at      timestamptz
);

-- One row per Claude call. Stage 1 ("analyse") reads the image; stage 2
-- ("translate") is text-only and cheap. Keeping cost_micros from day one means
-- cost per workspace is measurable long before it has to be priced.
create table public.document_analyses (
  id             uuid primary key default gen_random_uuid(),
  item_id        uuid not null references public.documents(item_id) on delete cascade,
  workspace_id   uuid not null references public.workspaces on delete cascade,
  stage          text not null check (stage in ('analyse','translate')),
  model          text not null,
  prompt_version text not null,
  extracted      jsonb not null default '{}',
  input_tokens   integer,
  output_tokens  integer,
  cost_micros    bigint,           -- millionths of a euro
  created_at     timestamptz not null default now()
);
create index document_analyses_item_idx on public.document_analyses (item_id, created_at desc);

-- What a person actually reads, in their own language.
create table public.document_explanations (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.documents(item_id) on delete cascade,
  workspace_id uuid not null references public.workspaces on delete cascade,
  analysis_id  uuid not null references public.document_analyses on delete cascade,
  language     text not null references public.languages(code),
  source       text not null check (source in ('vision','translation')),
  what_it_is   text not null,
  what_to_do   text not null,
  by_when      text,
  how_much     text,
  details      text,
  created_at   timestamptz not null default now(),
  unique (item_id, language)
);

-- "Ask [family member]": a request for help on a document that already lives
-- in a workspace you both belong to. The conversation itself is `comments`.
create table public.help_requests (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items on delete cascade,
  workspace_id uuid not null references public.workspaces on delete cascade,
  requested_by uuid not null references public.profiles,
  requested_of uuid references public.profiles,      -- null = anyone in the workspace
  status       text not null default 'open' check (status in ('open','answered','closed')),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz
);
create index help_requests_open_idx on public.help_requests (workspace_id, status)
  where status = 'open';

create trigger document_analyses_sync_ws before insert or update on public.document_analyses
  for each row execute function app.sync_item_workspace();
create trigger document_explanations_sync_ws before insert or update on public.document_explanations
  for each row execute function app.sync_item_workspace();
create trigger help_requests_sync_ws before insert or update on public.help_requests
  for each row execute function app.sync_item_workspace();

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
alter table public.documents             enable row level security;
alter table public.document_analyses     enable row level security;
alter table public.document_explanations enable row level security;
alter table public.help_requests         enable row level security;

create policy documents_select on public.documents
  for select to authenticated using (app.can_read_item(item_id));
create policy documents_write on public.documents
  for all to authenticated
  using (app.can_write_item(item_id)) with check (app.can_write_item(item_id));

-- Analyses are written by the edge function under the service role. Clients
-- read them (to show model and confidence) but never write them.
create policy analyses_select on public.document_analyses
  for select to authenticated using (app.can_read_item(item_id));

create policy explanations_select on public.document_explanations
  for select to authenticated using (app.can_read_item(item_id));

create policy help_requests_select on public.help_requests
  for select to authenticated using (app.can_read_item(item_id));
create policy help_requests_insert on public.help_requests
  for insert to authenticated
  with check (app.can_write_item(item_id) and requested_by = (select auth.uid()));
create policy help_requests_update on public.help_requests
  for update to authenticated
  using (app.can_write_item(item_id)) with check (app.can_write_item(item_id));

-- ---------------------------------------------------------------------------
-- Convenience view: security_invoker keeps RLS applying as the calling user,
-- so the view is not a way around the policies above.
-- ---------------------------------------------------------------------------
create view public.document_view with (security_invoker = true) as
  select
    i.id as item_id, i.workspace_id, i.title, i.due_at, i.all_day, i.status as item_status,
    i.amount_cents, i.currency, i.created_by, i.created_at, i.updated_at,
    d.storage_path, d.source, d.mime_type, d.status as document_status, d.error_message,
    d.doc_type, d.sender_name, d.issue_date, d.reference_number, d.iban,
    d.barcode_raw, d.source_language, d.verified_by, d.verified_at
  from public.items i
  join public.documents d on d.item_id = i.id
  where i.module = 'documents';

-- ---------------------------------------------------------------------------
-- Storage: private bucket, object path is <workspace_id>/<item_id>/<file>
-- The first path segment carries the tenant, so one membership check secures
-- every object.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 26214400,
        array['image/jpeg','image/png','image/heic','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy documents_storage_read on storage.objects
  for select to authenticated
  using (bucket_id = 'documents'
         and app.can_use_module(
               app.try_uuid((storage.foldername(name))[1]), 'documents', 'read'));

create policy documents_storage_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'documents'
              and app.can_use_module(
                    app.try_uuid((storage.foldername(name))[1]), 'documents', 'write'));

create policy documents_storage_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'documents'
         and app.can_use_module(
               app.try_uuid((storage.foldername(name))[1]), 'documents', 'write'));
