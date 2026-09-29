-- 0007_engine_tier.sql
--
-- Which reading engine a plan gets, and somewhere to put a machine-translated
-- document.
--
-- The free tier and the paid tier are not better and worse versions of one
-- thing. Free returns the document in your language; paid returns what to do
-- about it. The schema says so, so the UI cannot quietly blur the two.

alter table public.plans
  add column reading_engine text not null default 'ai'
    check (reading_engine in ('free','ai'));

update public.plans set reading_engine = 'free' where code = 'free';

comment on column public.plans.reading_engine is
  'free = OCR + machine translation (self-hosted, no per-document cost); '
  'ai = vision model, metered. Engines are data, like module_access.';

-- The free tier produces a body of text rather than an explanation.
alter table public.document_explanations
  add column full_text text;

alter table public.document_explanations
  drop constraint document_explanations_source_check;

alter table public.document_explanations
  add constraint document_explanations_source_check
    check (source in ('vision','translation','machine'));
