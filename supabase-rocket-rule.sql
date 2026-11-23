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

-- 2026-11-23: visitor source (TikTok / Instagram / link tag) for the owner's stats
alter table public.visits add column if not exists src text;
create or replace function public.admin_sources(p_days int default 14)
returns table(src text, visits bigint, today bigint)
language sql security definer set search_path = public as $$
  select coalesce(v.src,'unknown') as src, count(*) as visits,
         count(*) filter (where v.day::date = (now() at time zone 'Europe/Zagreb')::date) as today
  from public.visits v
  where auth.uid() = '7ddaeb6f-6afd-4cc1-ac94-a47366ba6764'::uuid
    and v.day::date > (now() at time zone 'Europe/Zagreb')::date - p_days
  group by 1 order by 2 desc;
$$;
revoke all on function public.admin_sources(int) from public, anon;
grant execute on function public.admin_sources(int) to authenticated;
