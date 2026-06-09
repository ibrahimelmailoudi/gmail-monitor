-- Stage 5: password reset requests + admin notifications

create table if not exists reset_requests (
  id          uuid primary key default gen_random_uuid(),
  username    text not null,
  status      text not null default 'open' check (status in ('open','resolved')),
  note        text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

-- generic notifications targeted at admins
create table if not exists notifications (
  id         uuid primary key default gen_random_uuid(),
  type       text not null,                -- e.g. 'reset_request'
  message    text not null,
  ref_id     uuid,                          -- optional reference (e.g. reset_requests.id)
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_unread_idx on notifications(read, created_at desc);
