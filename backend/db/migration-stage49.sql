-- Stage 49: fix the users.role column DEFAULT (was still 'user' from the original
-- schema, which violated users_role_check when inserting new users).
alter table users alter column role set default 'mailer';

-- repair any rows that still hold an old role value (defensive)
update users set role = 'mailer'  where role = 'user';
update users set role = 'manager' where role = 'support';
-- make sure your current account is owner if it holds the top-admin flag
update users set role = 'owner' where is_top_admin = true;

-- re-assert the constraint so all 6 roles are allowed
alter table users drop constraint if exists users_role_check;
alter table users add constraint users_role_check
  check (role in ('mailer','team_leader','manager','support','admin','owner'));
