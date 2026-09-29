-- 0001_identity.sql
-- Security helper schema, the language catalogue, and user profiles.

-- ---------------------------------------------------------------------------
-- app schema: SECURITY DEFINER helpers live here, never in public.
-- Nothing in here is callable by anon.
-- ---------------------------------------------------------------------------
create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, service_role;

create or replace function app.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- Safe cast used by storage policies, where a malformed object path would
-- otherwise raise instead of simply denying access.
create or replace function app.try_uuid(t text)
returns uuid language plpgsql immutable as $$
begin
  return t::uuid;
exception when others then
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- languages
--
-- A language is a record, not a two-letter code: Kurdish spans both writing
-- directions (Kurmanji is Latin/LTR, Sorani is Arabic-script/RTL), so direction
-- and script must be stored, never inferred.
--
-- ui_supported = we ship a hand-written translation bundle for the app chrome.
-- Any language may be used for AI-generated document explanations.
-- ---------------------------------------------------------------------------
create table public.languages (
  code         text primary key,                 -- BCP-47
  name_native  text not null,                    -- shown in its own script
  name_en      text not null,
  script       text not null,                    -- ISO 15924: Latn, Arab, Cyrl
  direction    text not null check (direction in ('ltr','rtl')),
  ui_supported boolean not null default false,
  sort_order   integer not null default 100,
  -- lets profiles.ui_language be constrained to ui_supported rows via a
  -- composite foreign key (see profiles below)
  unique (code, ui_supported)
);

insert into public.languages (code, name_native, name_en, script, direction, ui_supported, sort_order) values
  ('en',  'English',            'English',          'Latn', 'ltr', true,  1),
  ('fi',  'Suomi',              'Finnish',          'Latn', 'ltr', true,  2),
  ('sv',  'Svenska',            'Swedish',          'Latn', 'ltr', false, 3),
  ('de',  'Deutsch',            'German',           'Latn', 'ltr', false, 4),
  ('nl',  'Nederlands',         'Dutch',            'Latn', 'ltr', false, 5),
  ('et',  'Eesti',              'Estonian',         'Latn', 'ltr', false, 6),
  ('fr',  'Français',           'French',           'Latn', 'ltr', false, 7),
  ('es',  'Español',            'Spanish',          'Latn', 'ltr', false, 8),
  ('fa',  'فارسی',               'Persian',          'Arab', 'rtl', false, 20),
  ('ckb', 'کوردیی ناوەندی',        'Kurdish (Sorani)', 'Arab', 'rtl', false, 21),
  ('kmr', 'Kurmancî',           'Kurdish (Kurmanji)','Latn','ltr', false, 22),
  ('ar',  'العربية',              'Arabic',           'Arab', 'rtl', false, 23),
  ('ru',  'Русский',            'Russian',          'Cyrl', 'ltr', false, 30),
  ('uk',  'Українська',         'Ukrainian',        'Cyrl', 'ltr', false, 31),
  ('tr',  'Türkçe',             'Turkish',          'Latn', 'ltr', false, 32),
  ('so',  'Soomaali',           'Somali',           'Latn', 'ltr', false, 33),
  ('sq',  'Shqip',              'Albanian',         'Latn', 'ltr', false, 34);

alter table public.languages enable row level security;

-- Public reference data: any signed-in user may read it, nobody may write it
-- from the client.
create policy languages_read on public.languages
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- profiles (1:1 with auth.users)
--
-- ui_language  = app chrome, restricted to languages we actually translated
-- explain_language = what Claude explains documents in, any language
-- ---------------------------------------------------------------------------
create table public.profiles (
  id               uuid primary key references auth.users on delete cascade,
  display_name     text not null,
  ui_language      text not null default 'en',
  explain_language text not null default 'en' references public.languages(code),
  avatar_emoji     text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- Constant column existing only so the composite FK below can require
  -- languages.ui_supported = true. The CHECK pins it, so the FK can only ever
  -- resolve to a language we ship a translation bundle for.
  ui_language_supported boolean not null default true check (ui_language_supported),
  constraint profiles_ui_language_fkey
    foreign key (ui_language, ui_language_supported)
    references public.languages (code, ui_supported)
);

create trigger profiles_touch
  before update on public.profiles
  for each row execute function app.touch_updated_at();

alter table public.profiles enable row level security;

-- Reading other members' profiles is granted in 0002, once the workspace
-- helpers exist. Until then a user sees only themselves.
create policy profiles_select_self on public.profiles
  for select to authenticated using (id = (select auth.uid()));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- No INSERT policy on purpose: rows are created by the signup trigger below,
-- which runs as SECURITY DEFINER. A client cannot fabricate a profile.

-- ---------------------------------------------------------------------------
-- signup: create the profile. 0002 extends this to also create the user's
-- personal workspace.
-- ---------------------------------------------------------------------------
create or replace function app.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(coalesce(new.email, 'user'), '@', 1)
    )
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function app.handle_new_user();
