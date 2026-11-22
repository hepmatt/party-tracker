-- =====================================================================
-- Mario Party Jamboree Tracker: Supabase (Postgres) schema
--
-- Run once: Supabase dashboard > SQL Editor > New query > paste > Run.
-- Safe to re-run: tables use IF NOT EXISTS, views and functions use
-- CREATE OR REPLACE, and seed rows use ON CONFLICT DO NOTHING.
--
-- Access model:
--   * anyone with the link can READ every table and view
--   * only EDITORS can add or delete games. An editor is a signed-in
--     Supabase Auth user whose email is in public.editors (section 0).
--     Signing in alone is not enough, so a stray sign-up cannot write.
--   * nobody can INSERT or UPDATE tables directly; new games go through
--     add_game(), which checks the editor and validates the whole game
--     in one transaction
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Editors allowlist. Add family members here AND create their login
--    under Authentication > Users. Emails are stored lowercase.
--      insert into public.editors (email) values ('someone@example.com');
--      delete from public.editors where email = 'someone@example.com';
-- ---------------------------------------------------------------------
create table if not exists public.editors (
  email    text primary key check (email = lower(btrim(email)) and email like '%_@_%'),
  added_on timestamptz not null default now()
);

-- True when the caller is signed in with an allowlisted email.
-- SECURITY DEFINER so it can read editors without exposing the list.
create or replace function public.is_editor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.editors
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;


-- ---------------------------------------------------------------------
-- 1. Lookup tables. Dropdowns on the page are loaded from these, so to
--    add a DLC character or board, insert a row here.
-- ---------------------------------------------------------------------
create table if not exists public.characters (
  name text primary key check (char_length(name) between 1 and 30)
);

create table if not exists public.boards (
  name       text primary key check (char_length(name) between 1 and 60),
  sort_order int  not null default 100
);

-- Optional picture per character, uploaded from the Profiles tab.
alter table public.characters add column if not exists image text;
alter table public.characters drop constraint if exists characters_image_check;
alter table public.characters add constraint characters_image_check
  check (image is null or (image ~ '^data:image/(png|jpeg|webp);base64,' and length(image) < 150000));

insert into public.characters (name) values
  ('Mario'), ('Luigi'), ('Peach'), ('Daisy'), ('Wario'), ('Waluigi'),
  ('Yoshi'), ('Birdo'), ('Rosalina'), ('Donkey Kong'), ('Toad'), ('Toadette'),
  ('Boo'), ('Shy Guy'), ('Bowser'), ('Bowser Jr.'), ('Goomba'), ('Koopa Troopa'),
  ('Monty Mole'), ('Pauline'), ('Ninji'), ('Spike')
on conflict do nothing;

-- Western Land (the train board, home of Wiggler's Milk Saloon) goes by
-- MILK PARTY!!! here. Renaming the key cascades to every logged game.
update public.boards set name = 'MILK PARTY!!!'
where name = 'Western Land'
  and not exists (select 1 from public.boards where name = 'MILK PARTY!!!');

insert into public.boards (name, sort_order) values
  ('Mega Wiggler''s Tree Party', 1), ('Rainbow Galleria', 2), ('Goomba Lagoon', 3),
  ('Roll ''em Raceway', 4), ('King Bowser''s Keep', 5),
  ('Mario''s Rainbow Castle', 6), ('MILK PARTY!!!', 7)
on conflict do nothing;


-- ---------------------------------------------------------------------
-- 2. Core tables
-- ---------------------------------------------------------------------
create table if not exists public.games (
  id         bigint generated always as identity primary key,
  played_on  date        not null default current_date,
  board      text        not null references public.boards (name) on update cascade,
  mode       text        not null default 'Party'
                         check (mode in ('Party', 'Partner Party', 'Other')),
  turns      smallint    not null check (turns between 1 and 99),
  created_at timestamptz not null default now()
);

-- One row per seat in a game. CPUs take a place but have no name.
create table if not exists public.game_players (
  game_id     bigint   not null references public.games (id) on delete cascade,
  seat        smallint not null check (seat between 1 and 8),
  player_name text     check (char_length(player_name) between 1 and 30),
  -- Grouping key so "Matt", "matt " and "MATT" count as one person.
  player_key  text     generated always as
                       (regexp_replace(lower(btrim(player_name)), '\s+', ' ', 'g')) stored,
  is_cpu      boolean  not null default false,
  character   text     not null references public.characters (name) on update cascade,
  place       smallint not null check (place between 1 and 8),
  stars       smallint not null default 0 check (stars between 0 and 99),
  coins       smallint not null default 0 check (coins between 0 and 999),
  primary key (game_id, seat),
  constraint cpu_has_no_name check (is_cpu = (player_name is null))
);

-- Partner Party team (1-4). NULL in every other mode.
alter table public.game_players add column if not exists team smallint check (team between 1 and 4);

-- The same person cannot sit in one game twice.
create unique index if not exists game_players_one_seat_per_person
  on public.game_players (game_id, player_key) where not is_cpu;

create index if not exists game_players_player_key on public.game_players (player_key);

-- Photos live in their own table so history queries stay small.
create table if not exists public.game_photos (
  game_id bigint primary key references public.games (id) on delete cascade,
  data    text   not null
          check (data like 'data:image/jpeg;base64,%' and length(data) < 900000)
);


-- One profile per person (keyed like game_players.player_key). Holds the
-- avatar: an uploaded picture, or a character to borrow the picture from.
create table if not exists public.player_profiles (
  player_key       text primary key
                   check (player_key = regexp_replace(lower(btrim(player_key)), '\s+', ' ', 'g')
                          and char_length(player_key) between 1 and 30),
  display_name     text not null check (char_length(display_name) between 1 and 30),
  avatar           text check (avatar is null or (avatar ~ '^data:image/(png|jpeg|webp);base64,' and length(avatar) < 150000)),
  avatar_character text references public.characters (name) on update cascade on delete set null,
  updated_at       timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- 2b. Editor-only setters for pictures. SECURITY DEFINER so the public
--     roles need no write grants; each checks is_editor() first.
-- ---------------------------------------------------------------------
create or replace function public.set_character_image(p_name text, p_image text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_editor() then
    raise exception 'Only approved editors can change pictures.' using errcode = '42501';
  end if;
  update characters set image = p_image where name = p_name;
  if not found then raise exception 'Unknown character: %', p_name; end if;
end;
$$;

-- Add a person to the roster with no picture yet. Safe to call twice.
create or replace function public.add_player(p_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if not public.is_editor() then
    raise exception 'Only approved editors can add players.' using errcode = '42501';
  end if;
  if v_name = '' then raise exception 'A player name is required.'; end if;
  insert into player_profiles (player_key, display_name)
  values (lower(v_name), v_name)
  on conflict (player_key) do nothing;
end;
$$;

-- Pass NULL for both p_avatar and p_character to clear the picture (the player stays).
create or replace function public.set_player_avatar(p_name text, p_avatar text, p_character text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_key  text := lower(v_name);
begin
  if not public.is_editor() then
    raise exception 'Only approved editors can change avatars.' using errcode = '42501';
  end if;
  if v_name = '' then raise exception 'A player name is required.'; end if;
  insert into player_profiles (player_key, display_name, avatar, avatar_character, updated_at)
  values (v_key, v_name, p_avatar, p_character, now())
  on conflict (player_key) do update
    set display_name = excluded.display_name, avatar = excluded.avatar,
        avatar_character = excluded.avatar_character, updated_at = now();
end;
$$;


-- ---------------------------------------------------------------------
-- 3. The only way to add a game. SECURITY DEFINER lets it insert even
--    though the public role has no INSERT grant, so every game is
--    validated here before it lands.
-- ---------------------------------------------------------------------
create or replace function public.add_game(p_game jsonb, p_photo text default null)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id      bigint;
  v_n       int  := coalesce(jsonb_array_length(p_game -> 'players'), 0);
  v_partner bool := coalesce(p_game ->> 'mode', 'Party') = 'Partner Party';
begin
  if not public.is_editor() then
    raise exception 'Only approved editors can add games. Sign in first.'
      using errcode = '42501';
  end if;

  if v_n not between 2 and 8 then
    raise exception 'A game needs 2 to 8 players (got %).', v_n;
  end if;

  insert into games (played_on, board, mode, turns)
  values ((p_game ->> 'played_on')::date,
          p_game ->> 'board',
          coalesce(p_game ->> 'mode', 'Party'),
          (p_game ->> 'turns')::smallint)
  returning id into v_id;

  insert into game_players (game_id, seat, player_name, is_cpu, character, place, stars, coins, team)
  select v_id,
         t.ord,
         case when coalesce((t.p ->> 'cpu')::boolean, false) then null
              else nullif(btrim(t.p ->> 'name'), '') end,
         coalesce((t.p ->> 'cpu')::boolean, false),
         t.p ->> 'character',
         (t.p ->> 'place')::smallint,
         coalesce((t.p ->> 'stars')::smallint, 0),
         coalesce((t.p ->> 'coins')::smallint, 0),
         case when v_partner then (t.p ->> 'team')::smallint end
  from jsonb_array_elements(p_game -> 'players') with ordinality as t (p, ord);

  -- Partner Party: everyone on a team of exactly 2, teammates share a place.
  if v_partner then
    if exists (select 1 from game_players where game_id = v_id and team is null) then
      raise exception 'In Partner Party every player needs a team.';
    end if;
    if exists (select 1 from game_players where game_id = v_id group by team having count(*) <> 2) then
      raise exception 'Each Partner Party team needs exactly 2 players.';
    end if;
    if exists (select 1 from game_players where game_id = v_id group by team having count(distinct place) > 1) then
      raise exception 'Teammates must finish in the same place.';
    end if;
  end if;

  if not exists (select 1 from game_players where game_id = v_id and place = 1) then
    raise exception 'Someone has to finish 1st.';
  end if;
  if not exists (select 1 from game_players where game_id = v_id and not is_cpu) then
    raise exception 'At least one player must be a person.';
  end if;
  if exists (select 1 from game_players where game_id = v_id and place > v_n) then
    raise exception 'A place is higher than the number of players.';
  end if;

  if p_photo is not null then
    insert into game_photos (game_id, data) values (v_id, p_photo);
  end if;

  -- Guests typed in on the spot join the roster for next time.
  insert into player_profiles (player_key, display_name)
  select distinct on (player_key) player_key, player_name
  from game_players
  where game_id = v_id and not is_cpu
  on conflict (player_key) do nothing;

  return v_id;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Views: the aggregated results. security_invoker makes each view
--    run with the caller's permissions, so table RLS still applies.
--    "Ranked" means at least 3 games (2 for a player + character pair),
--    so one lucky game does not top the leaderboard.
-- ---------------------------------------------------------------------

-- Display name per person: the spelling they used most often.
create or replace view public.player_names with (security_invoker = true) as
select player_key,
       mode() within group (order by player_name) as player
from public.game_players
where not is_cpu
group by player_key;


-- Leaderboard: one row per person.
create or replace view public.player_stats with (security_invoker = true) as
with sides as (
  -- Competing sides per game: each team counts once, everyone else (CPUs too) on their own.
  select game_id, count(distinct coalesce('t' || team, 's' || seat)) as n_sides
  from public.game_players
  group by game_id
),
seats as (
  select gp.*, g.board, g.mode, s.n_sides
  from public.game_players gp
  join public.games g on g.id = gp.game_id
  join sides s on s.game_id = gp.game_id
),
humans as (
  select * from seats where not is_cpu
),
agg as (
  select player_key,
         count(*)::int                              as games,
         (count(*) filter (where place = 1))::int   as wins,
         -- Wins that pure luck would give in these same games:
         -- 1 / number of sides (players, or teams in Partner Party).
         sum(1.0 / n_sides)                         as expected_wins,
         sum(stars)::int                            as stars,
         avg(stars)                                 as avg_stars,
         avg(place)                                 as avg_place
  from humans
  group by player_key
),
mains as (
  select distinct on (player_key) player_key, character as main_character
  from humans
  group by player_key, character
  order by player_key, count(*) desc, character
),
best_boards as (
  select distinct on (player_key) player_key, board as best_board, count(*)::int as best_board_wins
  from humans
  where place = 1
  group by player_key, board
  order by player_key, count(*) desc, board
)
select case when a.games >= 3 then
         rank() over (partition by a.games >= 3
                      order by a.wins::numeric / a.games desc, a.wins desc, a.stars desc)
       end                                        as rank,
       n.player,
       a.player_key,
       a.games,
       a.wins,
       round(100.0 * a.wins / a.games, 1)         as win_pct,
       round(a.wins / a.expected_wins, 2)         as vs_luck,
       a.stars,
       round(a.avg_stars, 1)                      as stars_per_game,
       round(a.avg_place, 2)                      as avg_place,
       m.main_character,
       b.best_board,
       b.best_board_wins
from agg a
join public.player_names n using (player_key)
left join mains m using (player_key)
left join best_boards b using (player_key);


-- Characters: every character, even ones nobody has picked yet.
create or replace view public.character_stats with (security_invoker = true) as
with humans as (
  select * from public.game_players where not is_cpu
),
agg as (
  select character,
         count(*)::int                            as picks,
         (count(*) filter (where place = 1))::int as wins,
         avg(stars)                               as avg_stars,
         avg(place)                               as avg_place
  from humans
  group by character
),
fans as (
  select distinct on (h.character) h.character, n.player as top_player, count(*)::int as top_player_picks
  from humans h
  join public.player_names n using (player_key)
  group by h.character, n.player
  order by h.character, count(*) desc, n.player
),
-- MILK PARTY!!! attendance: every seat on that board, CPUs included.
milk as (
  select gp.character, count(*)::int as milk_parties
  from public.game_players gp
  join public.games g on g.id = gp.game_id
  where g.board = 'MILK PARTY!!!'
  group by gp.character
)
select case when coalesce(a.picks, 0) >= 3 then
         rank() over (partition by coalesce(a.picks, 0) >= 3
                      order by a.wins::numeric / nullif(a.picks, 0) desc nulls last, a.wins desc, a.picks desc)
       end                                                  as rank,
       c.name                                               as character,
       coalesce(a.picks, 0)                                 as picks,
       coalesce(a.wins, 0)                                  as wins,
       round(100.0 * a.wins / nullif(a.picks, 0), 1)        as win_pct,
       round(a.avg_stars, 1)                                as stars_per_game,
       round(a.avg_place, 2)                                as avg_place,
       f.top_player,
       f.top_player_picks,
       coalesce(m.milk_parties, 0)                          as milk_parties
from public.characters c
left join agg  a on a.character = c.name
left join fans f on f.character = c.name
left join milk m on m.character = c.name;


-- The aggregated ranking: one row per (player, character) pair, ranked
-- three ways by win ratio.
--   rank_for_player:    a player's best character         (PARTITION BY player)
--   rank_for_character: who plays each character best     (PARTITION BY character)
--   rank_overall:       best player + character combos    (2+ games only)
create or replace view public.player_character_stats with (security_invoker = true) as
with combo as (
  select player_key,
         character,
         count(*)::int                            as games,
         (count(*) filter (where place = 1))::int as wins,
         sum(stars)::int                          as stars,
         avg(place)                               as avg_place
  from public.game_players
  where not is_cpu
  group by player_key, character
)
select n.player,
       c.player_key,
       c.character,
       c.games,
       c.wins,
       round(100.0 * c.wins / c.games, 1)   as win_pct,
       c.stars,
       round(c.stars::numeric / c.games, 1) as stars_per_game,
       round(c.avg_place, 2)                as avg_place,
       rank() over (partition by c.player_key
                    order by c.wins::numeric / c.games desc, c.wins desc, c.games desc) as rank_for_player,
       rank() over (partition by c.character
                    order by c.wins::numeric / c.games desc, c.wins desc, c.games desc) as rank_for_character,
       case when c.games >= 2 then
         rank() over (partition by c.games >= 2
                      order by c.wins::numeric / c.games desc, c.wins desc, c.games desc)
       end                                  as rank_overall
from combo c
join public.player_names n using (player_key);


-- Head to head: a self-join on game_players. Only games both people
-- played count, which is the fair comparison when the group changes.
create or replace view public.head_to_head with (security_invoker = true) as
select a.player_key,
       na.player,
       b.player_key                                          as opponent_key,
       nb.player                                             as opponent,
       count(*)::int                                         as games,
       (count(*) filter (where a.place < b.place))::int      as ahead,
       (count(*) filter (where a.place > b.place))::int      as behind,
       (count(*) filter (where a.place = b.place))::int      as ties,
       round(100.0 * count(*) filter (where a.place < b.place) / count(*), 1) as ahead_pct
from public.game_players a
join public.game_players b
  on b.game_id = a.game_id
 and b.player_key <> a.player_key
join public.player_names na on na.player_key = a.player_key
join public.player_names nb on nb.player_key = b.player_key
where not a.is_cpu and not b.is_cpu
  and (a.team is null or b.team is null or a.team <> b.team)   -- teammates are not opponents
group by a.player_key, na.player, b.player_key, nb.player;


-- Partner Party duos: how each pair does as teammates.
create or replace view public.partner_stats with (security_invoker = true) as
with duos as (
  select a.player_key as key_a, b.player_key as key_b, a.place
  from public.game_players a
  join public.game_players b
    on b.game_id = a.game_id and b.team = a.team and b.player_key > a.player_key
  where a.team is not null and not a.is_cpu and not b.is_cpu
)
select na.player                                         as player_a,
       nb.player                                         as player_b,
       d.key_a,
       d.key_b,
       count(*)::int                                     as games,
       (count(*) filter (where d.place = 1))::int        as wins,
       round(100.0 * count(*) filter (where d.place = 1) / count(*), 1) as win_pct,
       round(avg(d.place), 2)                            as avg_place
from duos d
join public.player_names na on na.player_key = d.key_a
join public.player_names nb on nb.player_key = d.key_b
group by na.player, nb.player, d.key_a, d.key_b;


create or replace view public.board_stats with (security_invoker = true) as
with played as (
  select board, count(*)::int as games from public.games group by board
),
top_winner as (
  select distinct on (g.board) g.board, n.player as top_winner, count(*)::int as top_winner_wins
  from public.games g
  join public.game_players gp on gp.game_id = g.id
  join public.player_names n  on n.player_key = gp.player_key
  where gp.place = 1 and not gp.is_cpu
  group by g.board, n.player
  order by g.board, count(*) desc, n.player
),
stars as (
  select g.board, avg(gp.stars) as avg_stars
  from public.games g
  join public.game_players gp on gp.game_id = g.id
  where not gp.is_cpu
  group by g.board
)
select b.name                       as board,
       b.sort_order,
       coalesce(p.games, 0)         as games,
       t.top_winner,
       t.top_winner_wins,
       round(s.avg_stars, 1)        as stars_per_player
from public.boards b
left join played     p on p.board = b.name
left join top_winner t on t.board = b.name
left join stars      s on s.board = b.name;


-- Game list for the History tab, players nested as JSON.
create or replace view public.game_history with (security_invoker = true) as
select g.id,
       g.played_on,
       g.board,
       g.mode,
       g.turns,
       g.created_at,
       exists (select 1 from public.game_photos ph where ph.game_id = g.id) as has_photo,
       (select json_agg(json_build_object(
                  'name', gp.player_name, 'cpu', gp.is_cpu, 'character', gp.character,
                  'place', gp.place, 'stars', gp.stars, 'coins', gp.coins, 'team', gp.team)
                order by gp.place, gp.team, gp.seat)
        from public.game_players gp
        where gp.game_id = g.id)                                         as players
from public.games g;


-- Everyone who has already played is on the roster too.
insert into public.player_profiles (player_key, display_name)
select player_key, player from public.player_names
on conflict (player_key) do nothing;


-- ---------------------------------------------------------------------
-- 5. Permissions and row level security
-- ---------------------------------------------------------------------
alter table public.characters   enable row level security;
alter table public.boards       enable row level security;
alter table public.games        enable row level security;
alter table public.game_players enable row level security;
alter table public.game_photos  enable row level security;
alter table public.editors      enable row level security;   -- no policies: only is_editor() reads it
alter table public.player_profiles enable row level security;
drop policy if exists "public read" on public.player_profiles;
create policy "public read" on public.player_profiles for select to anon, authenticated using (true);

drop policy if exists "public read" on public.characters;
drop policy if exists "public read" on public.boards;
drop policy if exists "public read" on public.games;
drop policy if exists "public read" on public.game_players;
drop policy if exists "public read" on public.game_photos;
drop policy if exists "public delete" on public.games;
drop policy if exists "editor delete" on public.games;

create policy "public read"   on public.characters   for select to anon, authenticated using (true);
create policy "public read"   on public.boards       for select to anon, authenticated using (true);
create policy "public read"   on public.games        for select to anon, authenticated using (true);
create policy "public read"   on public.game_players for select to anon, authenticated using (true);
create policy "public read"   on public.game_photos  for select to anon, authenticated using (true);
create policy "editor delete" on public.games        for delete to authenticated using (public.is_editor());

-- Supabase grants broad table rights to anon by default. Narrow them.
revoke all on public.characters, public.boards, public.games,
              public.game_players, public.game_photos, public.editors,
              public.player_profiles
  from anon, authenticated;

grant select on public.characters, public.boards, public.games,
                public.game_players, public.game_photos, public.player_profiles,
                public.player_names, public.player_stats, public.character_stats,
                public.player_character_stats, public.head_to_head, public.partner_stats,
                public.board_stats, public.game_history
  to anon, authenticated;

-- Deletes: signed-in users only, and the policy above narrows that to editors.
grant delete on public.games to authenticated;

-- add_game() checks is_editor() itself, so anon gets a clear error, not a silent no-op.
revoke execute on function public.add_game(jsonb, text) from public, anon;
grant  execute on function public.add_game(jsonb, text) to authenticated;

revoke execute on function public.set_character_image(text, text) from public, anon;
grant  execute on function public.set_character_image(text, text) to authenticated;
revoke execute on function public.add_player(text) from public, anon;
grant  execute on function public.add_player(text) to authenticated;
revoke execute on function public.set_player_avatar(text, text, text) from public, anon;
grant  execute on function public.set_player_avatar(text, text, text) to authenticated;

revoke execute on function public.is_editor() from public;
grant  execute on function public.is_editor() to anon, authenticated;
