-- Rocket rule: from the 5th SIUUU (rocket) answer in a day, every rocket resets that day's km to 0.
create or replace function public.apply_rocket_rule() returns trigger
language plpgsql as $$
declare
  e jsonb; total int := 0; rockets int := 0;
begin
  if new.log is null then return new; end if;
  for e in select * from jsonb_array_elements(new.log::jsonb) loop
    if coalesce((e->>'ti')::int, -1) = 6 then
      rockets := rockets + 1;
      if rockets > 4 then total := 0; continue; end if;
    end if;
    total := total + coalesce((e->>'k')::int, 0);
  end loop;
  if rockets > 4 then new.km := total; end if;  -- leave everyone else untouched
  return new;
end $$;

drop trigger if exists rocket_rule on public.results;
create trigger rocket_rule before insert or update on public.results
  for each row execute function public.apply_rocket_rule();

-- recompute today's (and older) results that already exist
update public.results set log = log where log is not null;

-- check: who was affected
select p.name, r.day, r.km from public.results r join public.profiles p on p.id=r.user_id
where (select count(*) from jsonb_array_elements(r.log::jsonb) x where x->>'ti'='6') > 4;
