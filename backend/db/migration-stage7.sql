-- Stage 7: section access, token lifetime, request types, ISP delete

-- per-user section access (array of section keys) + per-user token lifetime (hours)
alter table users add column if not exists sections jsonb not null default '[]'::jsonb;
alter table users add column if not exists token_hours integer; -- null = use global default

-- admin-defined request types
create table if not exists request_types (
  id    uuid primary key default gen_random_uuid(),
  key   text unique not null,
  label text not null
);
insert into request_types (key, label) values
  ('message','Message / question'),
  ('problem','Report a problem'),
  ('access','Request account access'),
  ('reset','Password reset'),
  ('custom','Custom request')
on conflict do nothing;

-- app settings (global token lifetime, etc.) - settings table already exists
insert into settings (key, value) values ('token_hours', '48')
on conflict (key) do nothing;
