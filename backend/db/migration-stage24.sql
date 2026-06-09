-- Stage 24: account priority - priority accounts get checked/fetched first
alter table accounts add column if not exists priority boolean not null default false;
-- helpful index for ordering
create index if not exists idx_accounts_priority on accounts(priority desc);
