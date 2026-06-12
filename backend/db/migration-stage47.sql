-- Stage 47: Teams. A team has a manager; leaders + mailers are members.
-- Mailer belongs to ONE team; a leader may be in multiple teams (join table allows both).
create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  manager_id uuid references users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists team_members (
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role_in_team text not null default 'mailer', -- 'team_leader' | 'mailer'
  added_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
create index if not exists idx_team_members_user on team_members(user_id);
create index if not exists idx_team_members_team on team_members(team_id);

-- enforce: a mailer can be in only one team (partial unique on mailer rows)
create unique index if not exists uniq_mailer_one_team
  on team_members(user_id) where role_in_team = 'mailer';
