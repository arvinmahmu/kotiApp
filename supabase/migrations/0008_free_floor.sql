-- 0008_free_floor.sql
--
-- The free tier is the barcode, not machine translation.
--
-- For a Finnish bill, the virtuaaliviivakoodi already gives the payee, the
-- exact amount, the exact reference and the exact due date. That is enough to
-- file the bill and fire the reminder -- most of the day-to-day value -- and it
-- costs nothing at any number of users, is exact rather than approximate, and
-- needs no language at all, so it serves the users no translation engine
-- covers (Kurdish, Somali).
--
-- Machine translation stays a wired-but-undeployed option ('ocr'), to be
-- revisited only if the eval corpus says it earns its server.

alter table public.plans
  drop constraint plans_reading_engine_check;

alter table public.plans
  add constraint plans_reading_engine_check
    check (reading_engine in ('barcode','ocr','ai'));

comment on column public.plans.reading_engine is
  'The engine a plan gets WHILE it has allowance. When the meter says no, every '
  'plan falls back to the barcode floor -- running out is an ordinary state, not '
  'an error. barcode = free and exact; ocr = self-hosted OCR + MT, wired but not '
  'deployed; ai = vision model, metered.';

-- Every plan reads with the model while it has allowance. The free plan simply
-- has less of it, and lands on the barcode floor for the rest of the month.
update public.plans set reading_engine = 'ai';
