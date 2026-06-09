-- Stage 10: 4-digit public user code + overview as grantable section

-- short 4-digit code per user (for share-by-name without exposing the list)
alter table users add column if not exists code text;

-- backfill codes for existing users (unique 4-digit)
do $$
declare u record; newcode text;
begin
  for u in select id from users where code is null loop
    loop
      newcode := lpad((floor(random()*10000))::int::text, 4, '0');
      exit when not exists (select 1 from users where code = newcode);
    end loop;
    update users set code = newcode where id = u.id;
  end loop;
end $$;
