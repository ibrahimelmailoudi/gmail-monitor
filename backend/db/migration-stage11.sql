-- Stage 11: Gmail API enable toggle + OAuth config stored in settings
insert into settings (key, value) values ('gmail_api_enabled', 'false') on conflict (key) do nothing;
insert into settings (key, value) values ('gmail_client_id', '""') on conflict (key) do nothing;
insert into settings (key, value) values ('gmail_client_secret', '""') on conflict (key) do nothing;
insert into settings (key, value) values ('gmail_redirect_uri', '""') on conflict (key) do nothing;
