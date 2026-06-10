-- Stage 42: personal Vault - encrypted secrets (app passwords + notes) per user.
-- The 'secret' column stores AES-256-GCM encrypted text (same crypto as account creds).
create table if not exists vault_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  label text not null,
  account_email text,
  username text,
  secret text,          -- encrypted (app password / token)
  notes text,           -- encrypted (free notes)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_vault_user on vault_items(user_id, created_at desc);
