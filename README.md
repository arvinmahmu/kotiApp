# Koti

A household app: photograph an official letter or bill, get it explained in your own
language, with the deadline and the amount extracted and a reminder set.

Version 1 is the documents module. The data model is built for the modules that come
after it (calendar, shopping, chores, plans, expenses, lending) so they plug in without
a rewrite.

## Layout

    app/         Expo (React Native) client, TypeScript
    supabase/    migrations, edge functions, RLS tests
    docs/        architecture notes

## Getting started

See `docs/SETUP.md`.
