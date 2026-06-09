-- ============================================================
-- Gmass MailScope â€” database schema (run once in Supabase SQL editor)
-- ============================================================

create extension if not exists pgcrypto;  -- for gen_random_uuid()

-- ---------- users ----------
create table if not exists users (
  id            uuid primary key default gen_random_uuid(),
  username      text unique not null,
  password_hash text not null,            -- bcrypt hash
  is_admin      boolean not null default false,
  max_accounts  integer not null default 5,
  picture       text,
  created_at    timestamptz not null default now()
);

-- ---------- ISPs (admin-managed presets shown to normal users) ----------
create table if not exists isps (
  id        uuid primary key default gen_random_uuid(),
  name      text not null,                -- e.g. "Gmail"
  host      text not null,                -- e.g. "imap.gmail.com"
  port      integer not null default 993,
  ssl       boolean not null default true,
  enabled   boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------- accounts (a connected mailbox) ----------
create table if not exists accounts (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references users(id) on delete cascade,
  type        text not null check (type in ('gmail','imap')),
  email       text not null,
  picture     text,
  active      boolean not null default true,
  scope       text not null default 'personal' check (scope in ('personal','global')),
  credentials text,                        -- AES-GCM encrypted blob
  created_at  timestamptz not null default now(),
  unique (owner_id, email)
);

-- ---------- emails (captured messages, newest kept) ----------
create table if not exists emails (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references accounts(id) on delete cascade,
  category    text not null default 'primary',
  sender_name text,
  sender_email text,
  subject     text,
  domain      text,
  ip          text,
  spf         text,
  dkim        text,
  dmarc       text,
  preview     text,
  received_at timestamptz not null default now()
);
create index if not exists emails_account_idx on emails(account_id, received_at desc);

-- ---------- account_access (admin grants a user access to a global account) ----------
create table if not exists account_access (
  account_id uuid not null references accounts(id) on delete cascade,
  user_id    uuid not null references users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (account_id, user_id)
);

-- ---------- settings (simple key/value app settings) ----------
create table if not exists settings (
  key   text primary key,
  value jsonb not null
);

-- ---------- seed: default ISP presets ----------
insert into isps (name, host, port, ssl) values
  ('Gmail',      'imap.gmail.com',     993, true),
  ('Outlook',    'outlook.office365.com', 993, true),
  ('GMX',        'imap.gmx.net',       993, true),
  ('Yahoo',      'imap.mail.yahoo.com',993, true),
  ('Web.de',     'imap.web.de',        993, true)
on conflict do nothing;
