-- Run once in Supabase SQL editor to add the email body preview column
alter table emails add column if not exists preview text;
