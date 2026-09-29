-- rls.test.sql -- tenant isolation tests. Run with: supabase test db
--
-- One RLS bug in this app leaks another family's official correspondence.
-- These tests are the reason the schema is worth trusting; add one every time
-- a policy changes.

begin;
create extension if not exists pgtap with schema extensions;
select plan(25);

-- ===========================================================================
-- Test helpers
-- ===========================================================================
create schema tests;

create or replace function tests.create_user(p_email text, p_name text)
returns uuid language plpgsql as $fn$
declare uid uuid := gen_random_uuid();
begin
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
  ) values (
    '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated',
    p_email, 'x', now(), now(), now(),
    '{"provider":"email"}'::jsonb, jsonb_build_object('display_name', p_name)
  );
  return uid;
end;
$fn$;

-- Impersonate a user the way PostgREST does: role + JWT claims.
create or replace function tests.login(uid uuid)
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
end;
$fn$;

create or replace function tests.logout()
returns void language plpgsql as $fn$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', null, true);
end;
$fn$;

-- ===========================================================================
-- Fixture: the real-world shape. A "Parents" workspace where Alice (owner)
-- and Bob (adult helper) can see documents and Kid (child) cannot. Eve is
-- unrelated to any of them.
-- ===========================================================================
create temporary table ids (k text primary key, v uuid);

insert into ids values
  ('alice', tests.create_user('alice@example.com', 'Alice')),
  ('bob',   tests.create_user('bob@example.com',   'Bob')),
  ('kid',   tests.create_user('kid@example.com',   'Kid')),
  ('eve',   tests.create_user('eve@example.com',   'Eve'));

-- ---------------------------------------------------------------------------
-- 1-4. The signup trigger
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from public.profiles), 4,
  'signup trigger creates a profile for every user');

select is(
  (select count(*)::int from public.workspaces where is_personal), 4,
  'signup trigger creates a personal workspace for every user');

select is(
  (select role::text from public.workspace_members m
    join public.workspaces w on w.id = m.workspace_id
   where m.user_id = (select v from ids where k='alice') and w.is_personal),
  'owner',
  'you own your personal workspace');

select is(
  (select count(*)::int from public.workspace_modules mo
     join public.workspaces w on w.id = mo.workspace_id
    where w.is_personal and mo.module = 'documents' and mo.enabled), 4,
  'the documents module is on in every personal workspace');

-- ---------------------------------------------------------------------------
-- Shared workspace fixture
-- ---------------------------------------------------------------------------
insert into public.workspaces (id, name, icon, is_personal, created_by)
values ('11111111-1111-1111-1111-111111111111', 'Parents', 'home', false,
        (select v from ids where k='alice'));

insert into public.workspace_members (workspace_id, user_id, role) values
  ('11111111-1111-1111-1111-111111111111', (select v from ids where k='alice'), 'owner'),
  ('11111111-1111-1111-1111-111111111111', (select v from ids where k='bob'),   'adult'),
  ('11111111-1111-1111-1111-111111111111', (select v from ids where k='kid'),   'child');

insert into public.workspace_modules (workspace_id, module, enabled) values
  ('11111111-1111-1111-1111-111111111111', 'documents', true),
  ('11111111-1111-1111-1111-111111111111', 'shopping',  true);

-- A bill photographed by Alice.
insert into public.items (id, workspace_id, module, kind, title, due_at, amount_cents, currency, created_by)
values ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111', 'documents', 'bill',
        'Sähkölasku', now() + interval '14 days', 4820, 'EUR',
        (select v from ids where k='alice'));

insert into public.documents (item_id, storage_path, mime_type, status, doc_type, sender_name)
values ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222/original.jpg',
        'image/jpeg', 'ready', 'bill', 'Helen Oy');

-- A shopping item in the same workspace.
insert into public.items (id, workspace_id, module, kind, title, created_by)
values ('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'shopping', 'entry',
        'Maito', (select v from ids where k='alice'));

-- ---------------------------------------------------------------------------
-- 5-7. Cross-tenant isolation -- the tests that matter most
-- ---------------------------------------------------------------------------
select tests.login((select v from ids where k='eve'));

select is(
  (select count(*)::int from public.workspaces
    where id = '11111111-1111-1111-1111-111111111111'), 0,
  'an outsider cannot see a workspace they are not a member of');

select is(
  (select count(*)::int from public.items), 0,
  'an outsider sees no items at all');

select is(
  (select count(*)::int from public.documents), 0,
  'an outsider sees no documents at all');

-- ---------------------------------------------------------------------------
-- 8-9. An outsider cannot write into someone else's workspace
-- ---------------------------------------------------------------------------
select throws_ok(
  $$insert into public.items (workspace_id, module, kind, title, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'documents', 'bill', 'Forged',
            (select v from ids where k='eve'))$$,
  '42501',
  'new row violates row-level security policy for table "items"',
  'an outsider cannot insert an item into another workspace');

select throws_ok(
  $$insert into public.workspace_members (workspace_id, user_id, role)
    values ('11111111-1111-1111-1111-111111111111',
            (select v from ids where k='eve'), 'adult')$$,
  '42501',
  'new row violates row-level security policy for table "workspace_members"',
  'an outsider cannot add themselves to a workspace');

-- ---------------------------------------------------------------------------
-- 10-12. Members see what they should
-- ---------------------------------------------------------------------------
select tests.login((select v from ids where k='bob'));

select is(
  (select count(*)::int from public.items
    where id = '22222222-2222-2222-2222-222222222222'), 1,
  'an adult member sees documents in their workspace');

select is(
  (select title from public.document_view
    where item_id = '22222222-2222-2222-2222-222222222222'),
  'Sähkölasku',
  'document_view respects RLS and joins item metadata');

-- Alice, Bob and Kid share the Parents workspace; Eve shares nothing.
select is(
  (select count(*)::int from public.profiles), 3,
  'you can read the profiles of people you share a workspace with, and no others');

-- ---------------------------------------------------------------------------
-- 13-15. The child role -- module access enforced in the database
-- ---------------------------------------------------------------------------
select tests.login((select v from ids where k='kid'));

select is(
  (select count(*)::int from public.items where module = 'documents'), 0,
  'a child cannot see documents, even as a workspace member');

select is(
  (select count(*)::int from public.items where module = 'shopping'), 1,
  'a child CAN see the shopping list in the same workspace');

select throws_ok(
  $$insert into public.items (workspace_id, module, kind, title, created_by)
    values ('11111111-1111-1111-1111-111111111111', 'documents', 'bill', 'Nope',
            (select v from ids where k='kid'))$$,
  '42501',
  'new row violates row-level security policy for table "items"',
  'a child cannot create a document');

-- ---------------------------------------------------------------------------
-- 16. Turning a module off actually revokes access, it is not a UI flag
-- ---------------------------------------------------------------------------
select tests.logout();
update public.workspace_modules set enabled = false
 where workspace_id = '11111111-1111-1111-1111-111111111111' and module = 'documents';

select tests.login((select v from ids where k='bob'));
select is(
  (select count(*)::int from public.items where module = 'documents'), 0,
  'disabling a module hides its rows from an adult member in the database');

select tests.logout();
update public.workspace_modules set enabled = true
 where workspace_id = '11111111-1111-1111-1111-111111111111' and module = 'documents';

-- ---------------------------------------------------------------------------
-- 17-18. Shared building blocks inherit item access
-- ---------------------------------------------------------------------------
select tests.login((select v from ids where k='bob'));
insert into public.comments (item_id, workspace_id, author_id, body)
values ('22222222-2222-2222-2222-222222222222',
        '00000000-0000-0000-0000-000000000000',   -- deliberately wrong
        (select v from ids where k='bob'), 'What is this?');

select is(
  (select workspace_id from public.comments limit 1),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'a comment cannot be filed into the wrong workspace -- the trigger corrects it');

select tests.login((select v from ids where k='eve'));
select is(
  (select count(*)::int from public.comments), 0,
  'an outsider cannot read comments on another workspace''s document');

-- ---------------------------------------------------------------------------
-- 19. Reminders are private to the person being reminded
-- ---------------------------------------------------------------------------
select tests.login((select v from ids where k='alice'));
insert into public.reminders (item_id, workspace_id, user_id, remind_at, title, created_by)
values ('22222222-2222-2222-2222-222222222222',
        '11111111-1111-1111-1111-111111111111',
        (select v from ids where k='alice'), now() + interval '7 days',
        'Sähkölasku due', (select v from ids where k='alice'));

select tests.login((select v from ids where k='bob'));
select is(
  (select count(*)::int from public.reminders), 0,
  'one member cannot see another member''s reminders');

-- ---------------------------------------------------------------------------
-- 20. A workspace cannot lose its last owner
-- ---------------------------------------------------------------------------
select tests.logout();
select throws_ok(
  $$delete from public.workspace_members
     where workspace_id = '11111111-1111-1111-1111-111111111111'
       and role = 'owner'$$,
  'a workspace must keep at least one owner',
  'the last owner of a workspace cannot be removed');

-- ---------------------------------------------------------------------------
-- 21-24. The AI meter: layers 0 and 1 are free, layer 2 is the metered one
-- ---------------------------------------------------------------------------
select tests.logout();

select is(
  (select bool_and(public.consume_ai_document('11111111-1111-1111-1111-111111111111'))
     from generate_series(1, 5)),
  true,
  'a free workspace may spend its five monthly document readings');

select is(
  public.consume_ai_document('11111111-1111-1111-1111-111111111111'),
  false,
  'the sixth reading is refused on the free plan');

select is(
  (select used from public.usage_counters
    where workspace_id = '11111111-1111-1111-1111-111111111111'
      and metric = 'ai_document_read'),
  5,
  'a refused reading does not consume allowance');

select is(
  (select public.refund_ai_document('11111111-1111-1111-1111-111111111111') is null
     and (select used from public.usage_counters
           where workspace_id = '11111111-1111-1111-1111-111111111111'
             and metric = 'ai_document_read') = 4),
  true,
  'a failed reading is refunded, so it never costs the household an allowance');

select tests.login((select v from ids where k='eve'));
select is(
  (select count(*)::int from public.usage_counters), 0,
  'an outsider cannot read another workspace''s usage');

select * from finish();
rollback;
