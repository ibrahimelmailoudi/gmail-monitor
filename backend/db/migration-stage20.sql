-- Stage 20: make sure all ISPs are enabled so they appear in the Add-Account dropdown
update isps set enabled = true where enabled is null or enabled = false;

-- (re)seed the common providers if they are missing, all enabled
insert into isps (name, host, port, ssl, enabled)
select v.name, v.host, v.port, true, true
from (values
  ('Gmail',   'imap.gmail.com',    993),
  ('GMX',     'imap.gmx.com',      993),
  ('Outlook', 'outlook.office365.com', 993),
  ('Web.de',  'imap.web.de',       993),
  ('Yahoo',   'imap.mail.yahoo.com', 993)
) as v(name, host, port)
where not exists (select 1 from isps i where lower(i.name) = lower(v.name));
