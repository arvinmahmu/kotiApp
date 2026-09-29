# Setup

## 1. Accounts (yours to create)

| Service | Notes |
|---|---|
| **Supabase** | Create an organisation and a project. **Region: `eu-north-1` (Stockholm)** — closest to Finland and keeps data in the EU. Save the project ref, the anon key and the service-role key. |
| **Expo / EAS** | Free account at expo.dev. Needed for dev builds on real phones. |
| **Anthropic Console** | console.anthropic.com → an API key for the edge function. Also request a **DPA** here; we reference it in the in-app consent screen. |
| **Apple Developer** | €99/year. Needed for iOS dev builds, for TestFlight to your parents, and for Sign in with Apple (mandatory once Google/Facebook sign-in is offered on iOS). Android needs nothing. |

Nothing in this repo needs those accounts until step 2 of the build plan — the
schema and its tests stand on their own.

## 2. Tools

```powershell
node -v          # 24.x, already installed
npm i -g supabase
supabase --version
```

Docker Desktop is optional — see "Running the tests" below.

## 3. Apply the schema

```powershell
supabase login
supabase link --project-ref <your-project-ref>
supabase db push
```

`db push` applies `supabase/migrations/*.sql` in order:

| File | What it creates |
|---|---|
| `0001_identity.sql` | `app` helper schema, `languages` catalogue, `profiles`, signup trigger |
| `0002_tenancy.sql` | workspaces, members, roles, module flags, `module_access` matrix, all security helpers |
| `0003_items.sql` | the `items` supertype and the shared blocks: attachments, reminders, comments, activity |
| `0004_documents.sql` | documents module, analyses, explanations, help requests, storage bucket + policies |
| `0005_grants.sql` | explicit table privileges; removes all anonymous access |
| `0006_layers_and_quota.sql` | barcode/OCR result columns, full-text search, `plans`, `usage_counters` and the AI meter |

## 4. Running the RLS tests

These are the tests that decide whether one family can read another family's
post. Run them after every schema change.

**With Docker Desktop** (preferred — no cloud round-trip):

```powershell
supabase start
supabase test db
```

**Without Docker**, against the cloud project. The test file is wrapped in
`begin … rollback`, so it writes nothing permanent:

```powershell
psql "<connection string from Supabase dashboard>" -f supabase/tests/rls.test.sql
```

Expect 24 passing assertions. A failure here is never cosmetic.

## 5. What to check by hand in the dashboard

After `db push`:

- **Table editor → `languages`** — 17 rows, native names render in their own
  script (`فارسی`, `کوردیی ناوەندی`, `Русский`). If these look like boxes, it is a
  font issue in the browser, not in the data.
- **Storage** — a private `documents` bucket exists.
- **Authentication → Providers** — email is on. Google/Apple/Facebook come later.
