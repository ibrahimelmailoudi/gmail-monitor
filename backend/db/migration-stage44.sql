-- Stage 44: real-world role hierarchy.
-- owner > admin > manager > team_leader > mailer
-- Map existing roles: admin->admin, support->manager, user->mailer.
-- The is_top_admin flag (stage 43) represents the OWNER.

-- widen the role column values (no enum - it's text); migrate existing rows
update users set role = 'mailer'  where role = 'user';
update users set role = 'manager' where role = 'support';
-- the flagged top admin becomes 'owner' in role terms (kept in sync below)
update users set role = 'owner' where is_top_admin = true;
