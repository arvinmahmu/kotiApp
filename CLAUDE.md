# Koti

A household app. Version 1 is the documents module: photograph an official
letter or bill, get it explained in your own language — what it is, what to do,
by when, how much — with deadlines and reminders.

**Read `docs/DECISIONS.md` before changing anything structural.** It holds the
reasoning and, more usefully, what was already tried and rejected. Several
obvious-looking improvements have been considered and turned down for reasons
that are not visible in the code.

## Commands

```
npm test                 # 22 assertions, plain Node 24, no accounts or Docker
supabase db push         # apply migrations 0001-0008
supabase test db         # 25 pgTAP assertions — tenant isolation
```

Setup and account steps: `docs/SETUP.md`.

## Layout

```
supabase/migrations/          0001-0008, applied in order
supabase/tests/rls.test.sql   tenant isolation — run after every schema change
supabase/functions/
  _shared/domain/             no vendor, no I/O — ports and the reconcile rule
  _shared/adapters/           one file per engine
  _shared/pipeline/           registry.ts is the composition root
  analyse-document/           thin HTTP shell: auth, storage, metering, persistence
```

## Invariants

Break these and something important stops being true.

- **Access control lives in RLS, not in the UI.** Every row carries
  `workspace_id`; every module policy goes through `app.can_use_module()`.
  Helpers are `SECURITY DEFINER`, `STABLE`, `set search_path = ''`, and wrap
  `auth.uid()` in a subselect. Add a test to `rls.test.sql` with every policy
  change.
- **The service role never reads its own input.** A user-scoped client proves
  the caller may touch the row; only then does the service-role client write.
- **The barcode wins.** Where the Finnish virtuaaliviivakoodi is present and its
  checksums pass, it overrides the model. Disagreements are recorded, not
  silently resolved.
- **Only two files may know about a vendor**:
  `adapters/explain/claude-vision.ts` and `pipeline/registry.ts`. Everything
  else depends on the ports in `domain/contracts.ts`.
- **A free plan must never resolve to a paid engine.** `resolvePipeline` degrades
  to the barcode floor, never to vision. There is a test asserting this.
- **Quotas and permissions are data, not code** — `module_access`, `plans`.
- **No constructor parameter properties in `_shared/`.** Node cannot strip them,
  which makes the file untestable with plain `node`.
- **Never invent a value for the user.** The prompt requires null plus a named
  uncertain field over a guess. These documents decide whether someone keeps a
  benefit or misses a deadline.

## State

The TypeScript domain logic is tested and passing. **The SQL has never been run
against a database** — expect to fix syntax on the first `db push`. There is no
app yet; the Expo client is not started.

Known gaps, including the account-deletion foreign key that will fail under
GDPR erasure, are listed at the end of `docs/DECISIONS.md`.
