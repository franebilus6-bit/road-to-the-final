-- Road to the Final: Google accounts, display names, daily results and leagues
-- Paste all of this into Supabase → SQL Editor → New query → Run (once).
-- The old anonymous "scores" table is left untouched.

-- ---------- profiles: only the name other players see ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null check (char_length(trim(name)) between 2 and 24),
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_name_ci on public.profiles (lower(trim(name)));
alter table public.profiles enable row level security;
drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select using (true);
drop policy if exists "own profile insert" on public.profiles;
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = id);
drop policy if exists "own profile update" on public.profiles;
create policy "own profile update" on public.profiles for update using (auth.uid() = id) with check (auth.uid() = id);

-- ---------- results: one row per player per day ----------
create table if not exists public.results (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  day        date not null,
  km         integer not null default 0 check (km between 0 and 10000),
  correct    integer not null default 0 check (correct between 0 and 8),
  answered   integer not null default 0 check (answered between 0 and 8),
  done       boolean not null default false,
  log        jsonb,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);
create index if not exists results_day on public.results (day);
alter table public.results enable row level security;
drop policy if exists "results readable" on public.results;
create policy "results readable" on public.results for select using (true);
-- you can only start today's (or yesterday's / tomorrow's, for time zones) attempt, once
drop policy if exists "own result insert" on public.results;
create policy "own result insert" on public.results for insert
  with check (auth.uid() = user_id and day between current_date - 1 and current_date + 1);
-- and only keep updating it while it is not finished
drop policy if exists "own result update" on public.results;
create policy "own result update" on public.results for update
  using (auth.uid() = user_id and done = false)
  with check (auth.uid() = user_id);

-- import of a player's earlier days played on this device before accounts existed (only once, only days not saved yet)
create or replace function public.import_history(p_days jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; n integer := 0;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if exists (select 1 from results where user_id = auth.uid() and day < current_date - 1) then return 0; end if;
  for k, v in select * from jsonb_each(coalesce(p_days, '{}'::jsonb)) loop
    begin
      if k::date < current_date - 1 and k::date >= date '2026-11-20' then
        insert into results (user_id, day, km, correct, answered, done)
        values (auth.uid(), k::date, least(greatest(coalesce((v->>'km')::int, 0), 0), 10000),
                least(greatest(coalesce((v->>'correct')::int, 0), 0), 8), least(greatest(coalesce((v->>'answered')::int, 0), 0), 8), true)
        on conflict do nothing;
        n := n + 1;
      end if;
    exception when others then null;
    end;
  end loop;
  return n;
end $$;
grant execute on function public.import_history(jsonb) to authenticated;

-- ---------- leagues ----------
create table if not exists public.leagues (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(trim(name)) between 2 and 40),
  code       text not null unique,
  owner      uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.league_members (
  league_id uuid not null references public.leagues(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (league_id, user_id)
);
alter table public.leagues enable row level security;
alter table public.league_members enable row level security;

create or replace function public.is_member(p_league uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from league_members where league_id = p_league and user_id = auth.uid());
$$;

drop policy if exists "member sees league" on public.leagues;
create policy "member sees league" on public.leagues for select using (public.is_member(id));
drop policy if exists "member sees members" on public.league_members;
create policy "member sees members" on public.league_members for select using (public.is_member(league_id));
drop policy if exists "leave league" on public.league_members;
create policy "leave league" on public.league_members for delete using (auth.uid() = user_id);

create or replace function public.create_league(p_name text)
returns table (id uuid, name text, code text) language plpgsql security definer set search_path = public as $$
declare c text; l uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from profiles where profiles.id = auth.uid()) then raise exception 'pick a name first'; end if;
  if (select count(*) from leagues where owner = auth.uid()) >= 10 then raise exception 'too many leagues'; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from leagues where leagues.code = c);
  end loop;
  insert into leagues (name, code, owner) values (trim(p_name), c, auth.uid()) returning leagues.id into l;
  insert into league_members (league_id, user_id) values (l, auth.uid());
  return query select l, trim(p_name), c;
end $$;

create or replace function public.join_league(p_code text)
returns table (id uuid, name text, code text) language plpgsql security definer set search_path = public as $$
declare l leagues%rowtype;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from profiles where profiles.id = auth.uid()) then raise exception 'pick a name first'; end if;
  select * into l from leagues where leagues.code = upper(trim(p_code));
  if not found then raise exception 'no league with that code'; end if;
  insert into league_members (league_id, user_id) values (l.id, auth.uid()) on conflict do nothing;
  return query select l.id, l.name, l.code;
end $$;

revoke all on function public.create_league(text) from public, anon;
revoke all on function public.join_league(text) from public, anon;
grant execute on function public.create_league(text) to authenticated;
grant execute on function public.join_league(text) to authenticated;
grant execute on function public.is_member(uuid) to authenticated, anon;

grant select on public.profiles, public.results to anon, authenticated;
grant insert, update on public.profiles, public.results to authenticated;
grant select on public.leagues, public.league_members to authenticated;
grant delete on public.league_members to authenticated;

-- all-time totals per player
create or replace view public.alltime as
  select r.user_id, p.name, sum(r.km)::int as km, (count(*) filter (where r.km > 0))::int as days
  from public.results r join public.profiles p on p.id = r.user_id
  group by r.user_id, p.name;
grant select on public.alltime to anon, authenticated;
