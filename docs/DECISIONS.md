# Decisions

Why Koti is built the way it is. The code says what; this says why, and what was
rejected. Read it before changing anything structural.

Last updated 2026-09-29.

---

## 1. Product

Koti is a household app. Version 1 is the **documents module only**: photograph
an official letter or bill, get it explained in your own language — what it is,
what to do, by when, how much — with deadlines and reminders, and an "Ask
[family member]" button.

The long-term goal is a "family operating system": calendar, shopping list,
chores, plans, expenses, lending circles, and much later bank/PSD2 connections.
None of that is built. All of it shaped the data model.

First users are the author's family and parents, who don't read Finnish well.
Market path: Finland → Nordics → Europe.

### The three products, in increasing value

| | What the user gets | Cost to run |
|---|---|---|
| `tracked` | The bill filed with its exact amount, payee, reference and due date, and a reminder | **€0, at any scale** |
| `translated` | The document's text in their language | fixed server cost (not deployed) |
| `explained` | What it is and what to do about it | ~€0.02–0.05 per document |

These are not better and worse versions of one thing, and `ReadingResult` in
`domain/contracts.ts` is a discriminated union so the UI cannot pretend they
are. **Free = we track your bills and remind you. Paid = we tell you what the
letter says and what to do.**

---

## 2. Tenancy: the workspace is the only access boundary

Every row in every module carries `workspace_id`. Sharing happens by adding a
member to a workspace — there is no per-row "shared with user X" flag anywhere.
Roles are `owner`, `adult`, `child`.

**Access control is enforced in Postgres with RLS, never in the UI.** Policies
call `SECURITY DEFINER` helpers in a locked-down `app` schema, which is what
stops a policy on `workspace_members` recursing into itself. Every helper is
`STABLE`, sets `search_path = ''` (without which a `SECURITY DEFINER` function
is a privilege-escalation hole), and wraps `auth.uid()` in a subselect so
Postgres evaluates it once per statement rather than once per row.

`app.can_use_module(ws, module, need)` is the single check every module policy
uses: membership AND the module being switched on AND the role being permitted,
in one call. Paid-tier gating will slot in there rather than into every policy.

**Module flags are enforced in the database.** Turning off a module in a
workspace actually revokes access to its rows. It is not a UI toggle.

**Role permissions are data, not code** — the `module_access` table. "A child
never sees documents or money" is a row, not something to remember when writing
the next policy.

### Known scaling limit

`app.can_use_module(workspace_id, module, 'read')` takes a per-row varying
argument, so it is evaluated per candidate row. Mitigation, in order:

1. Always filter by `workspace_id` in client queries — the app only ever shows
   one workspace at a time, so the candidate set stays small. This is a data-
   access-layer discipline, not an optimisation to do later.
2. When that is no longer enough: put memberships in the JWT via a Supabase
   custom access token hook, so the policy becomes an array comparison with no
   table access. Cost is staleness on membership change; pair with a short token
   TTL. Only the helpers change.

---

## 3. The `items` supertype

A bill, a borrowed drill, a chore and a hobby practice are all "a thing in a
workspace, with a title, possibly a due date and a status". That is modelled
once, in `items`, and each module's table is a subtype keyed on `item_id`.

Three things fall out, and they are the reason for the extra join:

1. **Attachments, reminders, comments and the activity feed are built once and
   secured once.** Every future module inherits them. Their RLS is one pattern:
   `app.can_read_item(item_id)`.
2. **"What's coming up" is one query** across bills, chores, appointments and
   overdue library books. For a family operating system that unified agenda is
   arguably the whole product.
3. **The activity feed is the transparency record** for helper access: when an
   adult child acts inside their parents' workspace, the parents can see what
   was done.

`title`, `due_at` and `amount_cents` live on `items`, not on `documents` — a
bill's due date and a drill's return date are the same concept.

---

## 4. Languages

Every user configures their own, and **the set is open-ended**: Persian,
Kurdish (several dialects), Swedish, English, Arabic, Dutch, German and more.

- **A language is a record, not a code.** Kurdish spans both writing directions
  — Kurmanji is Latin/LTR, Sorani is Arabic-script/RTL — so script and direction
  are stored, never inferred.
- **RTL from day one.** Logical `start`/`end` in styles, `I18nManager` wired at
  startup, a forced reload on direction change (React Native cannot flip live),
  and bidi isolation around Finnish sender names and IBANs embedded in RTL text.
- **Two different things are called "language".** UI chrome is hand-translated
  for a small fixed set (`languages.ui_supported`, enforced by a composite
  foreign key). Document explanations are generated at runtime in any language.
  A parent can read the app in English and every document in Sorani.
- **Explanations are generated for the uploader's language only.** Other members'
  languages are a separate, cheap, text-only translation — designed, not yet
  built. Generating every language up front does not scale to an open set.

---

## 5. Reading a document

```
Layer 0  Barcode scan   free, on-device, exact
         → IBAN, amount, reference, due date. No AI.
Layer 1  Model call     the image → explanation + whatever layer 0 did not give
```

**Arbitration is one rule: the barcode wins where present and its checks pass.**
A disagreement is not an error — it is the barcode catching a misreading, which
is the only reason layer 0 exists. It is recorded, and the document is shown as
unverified.

Finnish bills carry the *virtuaaliviivakoodi*, a 54-digit Code 128 barcode
encoding IBAN, amount, reference and due date. Never ask a model to guess a
value that can be read exactly.

> The field offsets in `adapters/barcode/finnish.ts` are a transcription of
> Finanssiala's *Pankkiviivakoodi-opas*. The tests encode the behaviour, not the
> authority — verify against the published spec before production.

### Engines are ports and adapters

```
domain/        contracts.ts (TextExtractor | Translator | Explainer), reconcile.ts
adapters/      one file per engine
pipeline/      registry.ts — the composition root
```

Two files are allowed to know about vendors: `adapters/explain/claude-vision.ts`
(the only file importing an AI SDK) and `pipeline/registry.ts` (the only file
naming both a plan and a vendor). Adding an engine is a new adapter plus one
line in the registry. Moving to Claude on Bedrock/Vertex in an EU region is one
file.

**Do not use constructor parameter properties in `_shared/`.** Node cannot strip
them, which would make that file untestable with plain `node`.

---

## 6. Cost and metering

Per document with `claude-opus-5`: ~1,200 token cached prefix + ~1,200 token
image + ~1,800 output tokens ≈ **$0.057**, or ~**$0.024** optimised. Family
volume (~40/month) is **€1–2/month**. The Apple Developer account at €99/year is
the larger v1 cost.

**Output tokens are roughly three quarters of the bill.** This matters: it is
why replacing vision with OCR text saves only ~10%, while the barcode
short-circuit saves ~37%.

Lever order — free wins before tradeoffs:

1. Explicit cache breakpoint on the static system prompt (every request shares
   it byte for byte; independent requests do not share an automatic cache).
   Verify with `cache_read_input_tokens` — a prompt below the model's minimum
   cacheable prefix silently does not cache.
2. Downscale before upload. Vision cost scales with pixel area (~1 token per
   28×28 patch); 1280×720 caps an image near 1,200 tokens. Also fixes storage.
3. Exact output shape in the prompt.
4. Batch API (50% off) for anything nobody is waiting on.
5. `content_hash` so the same image is never read twice.
6. **Only with an eval**: sweep `effort`, then step down the model tier.

**Effort is deliberately left at its default.** It is the first lever worth
reaching for, but lowering it without an eval trades quality on exactly what
matters — an elderly person acting on a deadline we told them.

**The family phase is the eval-collection phase.** 30–50 real Finnish documents
with hand-written correct answers are what make every cost tradeoff safe, and
the family generates exactly that corpus while using v1.

### The meter

`plans.reading_engine` is the engine a plan gets *while it has allowance*. When
the meter says no, every plan falls back to the barcode floor — **running out is
an ordinary state with its own pipeline, not an error branch.** The bill is still
filed, the due date is still set, the reminder still fires.

`consume_ai_document()` takes a row lock so concurrent uploads cannot both slip
past the last unit. `refund_ai_document()` gives it back when the model call
fails — a failed reading must never cost a household one of its five.

---

## 7. Pricing

Billing unit is the **workspace**, not the user; the owner pays. Note the buyer
is often not the user: the adult child pays, the ageing parents use it.

| | Free | Koti Family | Koti Care |
|---|---|---|---|
| | €0 | €4.99/mo, €44.90/yr | €9.99/mo, €89/yr |
| Model readings | 5/month | 50/month | 150/month |
| Barcode tracking, reminders, other modules | unlimited | unlimited | unlimited |

**Meter only the model.** Everything that costs nothing to run stays unlimited
even on free — capping it buys nothing and makes free feel mean.

At €4.99 in Finland: −25.5% VAT = €3.98, −15% app-store commission = €3.38,
−€0.60 AI, −€0.20 infrastructure ≈ **€2.58 gross margin (~76%)**. VAT and the app
store take five times what the model does. Break-even is **14 paying
households**. Consumer freemium converts at 2–5%.

Push annual hard (~25% off): monthly churn on family apps is brutal, and older
users prefer one yearly payment to a recurring charge they will query.

---

## 8. Rejected, and why

**Self-hosted Tesseract + OPUS-MT as the free tier.** The software is free; the
compute is not. Neither runs in a Deno edge function, so it needs an always-on
server (~€10–20/month plus ops) replacing a variable cost of ~€2/month. **It is
more expensive than the paid path below roughly 300–600 documents/month.** And
OPUS-MT coverage is strong for fi→en/de/sv/ru and thin to absent for Persian,
Somali and Kurdish — exactly the first users' languages. Kept as the wired but
undeployed `ocr` tier; `opusMtTranslator.supports()` returns `no` for those pairs
rather than returning confident nonsense.

**On-device OCR as a cost lever.** Saves ~10%, because output tokens dominate.
Its real costs are the "is this text clean enough?" heuristic, a permanent second
input path, and discarding layout — which is information in a document.
`documents.ocr_text` / `ocr_confidence` are kept nullable so adding it later
needs no migration.

**On-device OCR as a privacy win — withdrawn.** Sending OCR text instead of the
image is *not* a materially better GDPR position. The text carries the same
personal data, the same special categories, the same transfer. Only redaction
would change the category, and redaction requires understanding the document
first.

**On-device translation (ML Kit / Apple Translate)** is the best option *if* the
free translation tier is ever wanted — free at any scale, no server, nothing
transmitted. Its problem is coverage, not cost: ~50 languages, and Kurdish and
Somali are not among them.

**EU inference pinning.** `inference_geo` on the first-party Anthropic API
accepts `us` and `global`. There is no EU pin. Storage and Postgres stay in the
EU; the image transits to Anthropic under a DPA with an in-app consent screen.
**Revisit before a public European launch** — that is the Bedrock `eu-central-1`
/ Vertex `europe-west` path, and it is one file.

---

## 9. Known gaps

- **The SQL has never been run.** Expect to fix syntax on the first
  `supabase db push`. Only the TypeScript domain logic is verified.
- **Account deletion will fail.** `workspaces.created_by` references `profiles`
  with no delete rule, so deleting a user who created a shared workspace hits the
  foreign key. GDPR requires erasure, and the right answer is ownership transfer
  or a tombstone, not a cascade — deleting your account must not delete your
  family's documents. **This is a product decision to make before writing the
  erasure flow.**
- **Full-text search should not use `ocr_text`.** Index title, sender, doc type
  and the explanation instead — data the model already produces, and readable by
  the user, unlike the raw Finnish body text. That means a trigger-maintained
  column rather than the current generated one, since `title` lives on `items`.
- **No app yet.** The Expo client is not started. Highest-value first screen is
  capture with the barcode scanner, since that is what makes the free tier work.
- **`translate-explanation` is designed, not built** — the cheap text-only path
  that renders an explanation into other members' languages.
