-- Stage 33: per-ISP placement definitions
-- Each ISP carries its own set of placements + how to detect them.
-- placements jsonb = array of { key, label, detect }
--   detect: for Gmail-type = { type:'gmraw', query:'category:promotions' }
--           for folder-type = { type:'folder', path:'[Gmail]/Spam' }
--           for inbox default = { type:'inbox' }
alter table isps add column if not exists placements jsonb not null default '[]'::jsonb;

-- Seed known providers with their real placement systems
update isps set placements = '[
  {"key":"primary","label":"Primary Inbox","detect":{"type":"gmraw","query":"category:primary"}},
  {"key":"promotions","label":"Promotions","detect":{"type":"gmraw","query":"category:promotions"}},
  {"key":"social","label":"Social","detect":{"type":"gmraw","query":"category:social"}},
  {"key":"updates","label":"Updates","detect":{"type":"gmraw","query":"category:updates"}},
  {"key":"forums","label":"Forums","detect":{"type":"gmraw","query":"category:forums"}},
  {"key":"spam","label":"Spam","detect":{"type":"folder","path":"[Gmail]/Spam"}}
]'::jsonb where lower(name) = 'gmail';

update isps set placements = '[
  {"key":"inbox","label":"Inbox","detect":{"type":"inbox"}},
  {"key":"spam","label":"Spam","detect":{"type":"folder","path":"Spam"}}
]'::jsonb where lower(name) in ('gmx','web.de','web de','webde');

update isps set placements = '[
  {"key":"focused","label":"Focused","detect":{"type":"inbox"}},
  {"key":"other","label":"Other","detect":{"type":"folder","path":"Other"}},
  {"key":"spam","label":"Spam (Junk)","detect":{"type":"folder","path":"Junk"}}
]'::jsonb where lower(name) in ('outlook','outlook.com','hotmail');

update isps set placements = '[
  {"key":"inbox","label":"Inbox","detect":{"type":"inbox"}},
  {"key":"spam","label":"Spam (Bulk)","detect":{"type":"folder","path":"Bulk Mail"}}
]'::jsonb where lower(name) = 'yahoo';

-- link accounts to their ISP so we can resolve per-ISP placements at extract time
alter table accounts add column if not exists isp_id uuid references isps(id);
