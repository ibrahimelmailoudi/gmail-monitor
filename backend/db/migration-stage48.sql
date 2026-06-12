-- Stage 48: per-user notifications + shared email packets.
-- target a notification at a specific user (null = staff broadcast, old behavior)
alter table notifications add column if not exists user_id uuid references users(id) on delete cascade;
create index if not exists notifications_user_idx on notifications(user_id, read, created_at desc);

-- Shared email packets: a named bundle of saved emails sent from one user to another.
create table if not exists shared_packets (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  from_user uuid references users(id) on delete set null,
  to_user uuid not null references users(id) on delete cascade,
  emails jsonb not null default '[]'::jsonb,   -- array of saved-email objects
  created_at timestamptz not null default now()
);
create index if not exists shared_packets_to_idx on shared_packets(to_user, created_at desc);
