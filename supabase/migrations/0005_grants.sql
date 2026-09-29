-- 0005_grants.sql
-- Table privileges, stated explicitly.
--
-- Supabase grants generously to `anon` and `authenticated` by default. Koti
-- has no anonymous surface at all, and relying on defaults for a household's
-- private documents is not a position worth defending. RLS decides *which
-- rows*; these grants decide *which tables*, and both have to agree.

-- 1. No anonymous access to anything, ever.
revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- 2. Reference data: read-only for signed-in users.
grant select on public.languages     to authenticated;
grant select on public.module_access to authenticated;

-- 3. Tenancy.
grant select, update                 on public.profiles          to authenticated;
grant select, insert, update, delete on public.workspaces        to authenticated;
grant select, insert, update, delete on public.workspace_members to authenticated;
grant select, insert, update, delete on public.workspace_modules to authenticated;
grant select, insert, update, delete on public.invitations       to authenticated;
grant select, insert, update, delete on public.push_tokens       to authenticated;

-- 4. Items and the shared building blocks.
grant select, insert, update, delete on public.items       to authenticated;
grant select, insert, update, delete on public.attachments to authenticated;
grant select, insert, update, delete on public.reminders   to authenticated;
grant select, insert,         delete on public.comments    to authenticated;
grant select, insert                 on public.activity    to authenticated;   -- append-only

-- 5. Documents. Analyses and explanations are written only by the edge
--    function under the service role, so the client gets SELECT alone --
--    a client cannot forge what the AI supposedly said.
grant select, insert, update, delete on public.documents             to authenticated;
grant select                         on public.document_analyses     to authenticated;
grant select                         on public.document_explanations to authenticated;
grant select, insert, update         on public.help_requests         to authenticated;
grant select                         on public.document_view         to authenticated;
