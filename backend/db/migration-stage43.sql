-- Stage 43: flag-based top admin (one admin is the top admin; can transfer the role).
alter table users add column if not exists is_top_admin boolean not null default false;
-- ensure at most one top admin via a partial unique index
create unique index if not exists uniq_one_top_admin on users(is_top_admin) where is_top_admin = true;
