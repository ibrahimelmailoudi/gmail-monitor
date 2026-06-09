-- Stage 6: roles/permissions, presence, requests + messages, 24h email retention

-- role + permissions + presence on users
alter table users add column if not exists role text not null default 'user'
  check (role in ('user','support','admin'));
alter table users add column if not exists permissions jsonb not null default '{}'::jsonb;
alter table users add column if not exists last_seen timestamptz;

-- existing admins keep admin role
update users set role = 'admin' where is_admin = true and role <> 'admin';

-- requests (support tickets) + threaded messages
create table if not exists requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users(id) on delete cascade,
  type        text not null default 'message'
              check (type in ('reset','access','problem','message')),
  subject     text,
  status      text not null default 'open' check (status in ('open','resolved')),
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create table if not exists request_messages (
  id         uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  sender_id  uuid references users(id) on delete set null,
  sender_role text,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists request_msg_idx on request_messages(request_id, created_at);

-- helper: delete emails older than 24h (called periodically by the server)
create or replace function purge_old_emails() returns void as $$
  delete from emails where received_at < now() - interval '24 hours';
$$ language sql;
