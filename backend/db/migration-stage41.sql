-- Stage 41: user-saved emails (Storage section) - persistent, per user.
-- Separate from the live `emails` buffer (which is purged after 24h).
create table if not exists saved_emails (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  message_id text,
  from_name text,
  from_email text,
  subject text,
  ip text,
  category text,
  spf text,
  dkim text,
  dmarc text,
  body_text text,
  source text,                 -- full raw source when captured
  saved_at timestamptz not null default now()
);
create index if not exists idx_saved_emails_user on saved_emails(user_id, saved_at desc);
