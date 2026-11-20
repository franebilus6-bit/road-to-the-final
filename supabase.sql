-- Road to the Final: leaderboard
-- Paste all of this into Supabase → SQL Editor → New query → Run.

create table if not exists public.scores (
  id      text primary key,
  secret  text not null,
  nick    text not null default '?',
  days    jsonb not null default '{}'::jsonb,
  updated timestamptz not null default now()
);

alter table public.scores enable row level security;
-- No direct access to the table: reading goes through the view, writing through the function.
revoke all on public.scores from anon, authenticated;

-- Public view without the secret column
create or replace view public.board as
  select id, nick, days, updated from public.scores;
grant select on public.board to anon, authenticated;

-- Save a score. Only the browser that created a row (it knows the secret) can change it.
create or replace function public.save_score(p_id text, p_secret text, p_nick text, p_days jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(p_id) <> 32 or length(p_secret) <> 32 then
    raise exception 'bad id' using errcode = '42501';
  end if;
  insert into scores (id, secret, nick, days, updated)
  values (p_id, p_secret, left(coalesce(nullif(trim(p_nick), ''), '?'), 24), coalesce(p_days, '{}'::jsonb), now())
  on conflict (id) do update
    set nick = excluded.nick, days = excluded.days, updated = now()
    where scores.secret = p_secret;
  if not found then
    raise exception 'not your row' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.save_score(text, text, text, jsonb) from public;
grant execute on function public.save_score(text, text, text, jsonb) to anon, authenticated;
