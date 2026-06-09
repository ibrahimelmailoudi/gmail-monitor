-- Stage 9: email storage toggle (default OFF = do not store incoming emails)
insert into settings (key, value) values ('store_emails', 'false')
on conflict (key) do nothing;
