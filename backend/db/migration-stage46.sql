-- Stage 46: add 'support' role (ranks just below admin, all-access like admin).
-- Order: owner > admin > support > manager > team_leader > mailer
alter table users drop constraint if exists users_role_check;
alter table users add constraint users_role_check
  check (role in ('mailer','team_leader','manager','support','admin','owner'));

-- user display order (for drag-to-reorder in the Users section)
alter table users add column if not exists sort_order integer;
