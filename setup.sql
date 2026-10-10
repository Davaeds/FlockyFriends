-- Flocks: database setup for Supabase.
--
-- 1. Paste this whole file into Supabase > SQL Editor > New query and press Run.
--    It contains no passcode, so it is safe to keep in a public repo.
-- 2. Then, in a NEW query that you do not save anywhere, set the family passcode:
--        select flocks_set_passcode('four random words you will share');
--    Run that line again any time to change the passcode.
--
-- Running this file again is safe. It keeps every flock, photo, gift note and
-- family-added bird, and refreshes the starting bird list.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.flocks_birds  (id text primary key, data jsonb not null, updated_at timestamptz not null default now());
create table if not exists public.flocks_flocks (id text primary key, data jsonb not null, updated_at timestamptz not null default now());
create table if not exists public.flocks_photos (id text primary key, data_url text not null, updated_at timestamptz not null default now());
create table if not exists public.flocks_secret (id int primary key default 1 check (id = 1), hash text not null);
create table if not exists public.flocks_guard  (id int primary key default 1 check (id = 1), fails int not null default 0, window_start timestamptz not null default now());
insert into public.flocks_guard (id) values (1) on conflict (id) do nothing;

-- Older versions stored the passcode in plain text; drop that column if present.
alter table public.flocks_secret drop column if exists passcode;
alter table public.flocks_secret add column if not exists hash text;

-- Lock every table. The app can only call the functions below.
alter table public.flocks_birds  enable row level security;
alter table public.flocks_flocks enable row level security;
alter table public.flocks_photos enable row level security;
alter table public.flocks_secret enable row level security;
alter table public.flocks_guard  enable row level security;
revoke all on public.flocks_birds, public.flocks_flocks, public.flocks_photos, public.flocks_secret, public.flocks_guard from anon, authenticated;

-- Drop functions from earlier versions whose signatures changed.
drop function if exists public.flocks_assert(text);
drop function if exists public.flocks_check(text);
drop function if exists public.flocks_load(text);
drop function if exists public.flocks_save_flock(text, text, jsonb);
drop function if exists public.flocks_save_bird(text, text, jsonb);
drop function if exists public.flocks_delete_bird(text, text);
drop function if exists public.flocks_get_photo(text, text);
drop function if exists public.flocks_save_photo(text, text, text);
drop function if exists public.flocks_delete_photo(text, text);
drop function if exists public.flocks_set_owned(text, text, text, int);

-- Set or change the family passcode. Only the project owner can run this (in the SQL Editor).
create or replace function public.flocks_set_passcode(p_new text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_new is null or length(trim(p_new)) < 10 then raise exception 'Use at least 10 characters, for example four random words.'; end if;
  if lower(p_new) like '%change%me%' then raise exception 'Pick a real passcode, not the example.'; end if;
  insert into flocks_secret (id, hash) values (1, crypt(p_new, gen_salt('bf', 8)))
    on conflict (id) do update set hash = excluded.hash;
  update flocks_guard set fails = 0, window_start = now() where id = 1;
  return 'Passcode set.';
end $$;

-- Checks the passcode. Wrong guesses are counted (and committed, because callers
-- return an error value instead of raising). After 30 wrong guesses in 15 minutes
-- everything is refused instantly until the window passes. No sleeping, so a flood
-- of guesses cannot tie up database connections.
create or replace function public.flocks_auth(p_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare f int; ws timestamptz; h text;
begin
  select fails, window_start into f, ws from flocks_guard where id = 1;
  if ws < now() - interval '15 minutes' then
    update flocks_guard set fails = 0, window_start = now() where id = 1; f := 0;
  end if;
  if f >= 30 then return 'locked'; end if;
  select hash into h from flocks_secret where id = 1;
  if h is null then return 'unset'; end if;
  if p_code is not null and length(p_code) <= 200 and crypt(p_code, h) = h then return 'ok'; end if;
  update flocks_guard set fails = fails + 1 where id = 1;
  return 'wrong';
end $$;

create or replace function public.flocks_valid_id(p text) returns boolean
language sql immutable as $$ select p ~ '^[a-z0-9][a-z0-9-]{0,79}$' $$;

create or replace function public.flocks_err(p text) returns json
language sql immutable as $$ select json_build_object('error', p) $$;

create or replace function public.flocks_check(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_load(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  return json_build_object(
    'birds',  coalesce((select json_agg(json_build_object('id', id, 'data', data) order by id) from flocks_birds), '[]'::json),
    'flocks', coalesce((select json_agg(json_build_object('id', id, 'data', data) order by id) from flocks_flocks), '[]'::json),
    'photos', coalesce((select json_agg(json_build_object('id', id, 'v', floor(extract(epoch from updated_at) * 1000)::bigint) order by id) from flocks_photos), '[]'::json));
end $$;

-- Each change touches one field on the server, so two phones never overwrite each other.
-- p_at (optional, YYYY-MM-DD) restores the original "in my flock since" date when a removal is undone.
create or replace function public.flocks_set_owned(p_code text, p_flock text, p_bird text, p_qty int, p_at text default null) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_flock) or not flocks_valid_id(p_bird) or p_qty is null or p_qty < 0 or p_qty > 99 then return flocks_err('invalid'); end if;
  if p_qty = 0 then
    update flocks_flocks set data = data #- array['owned', p_bird], updated_at = now() where id = p_flock;
  else
    update flocks_flocks set data = jsonb_set(data, '{owned}',
        coalesce(data->'owned', '{}'::jsonb) || jsonb_build_object(p_bird, jsonb_build_object(
          'qty', p_qty, 'at', coalesce(data->'owned'->p_bird->>'at',
            case when p_at ~ '^20[0-9]{2}-[01][0-9]-[0-3][0-9]$' then p_at end, to_char(now(), 'YYYY-MM-DD'))))) #- array['wish', p_bird],
      updated_at = now() where id = p_flock;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_set_wish(p_code text, p_flock text, p_bird text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_flock) or not flocks_valid_id(p_bird) then return flocks_err('invalid'); end if;
  if p_on then
    update flocks_flocks set data = jsonb_set(data, '{wish}', coalesce(data->'wish', '{}'::jsonb) || jsonb_build_object(p_bird, true)), updated_at = now() where id = p_flock;
  else
    update flocks_flocks set data = data #- array['wish', p_bird], updated_at = now() where id = p_flock;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_set_note(p_code text, p_flock text, p_bird text, p_note text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_flock) or not flocks_valid_id(p_bird) or length(coalesce(p_note, '')) > 1000 then return flocks_err('invalid'); end if;
  if coalesce(p_note, '') = '' then
    update flocks_flocks set data = data #- array['notes', p_bird], updated_at = now() where id = p_flock;
  else
    update flocks_flocks set data = jsonb_set(data, '{notes}', coalesce(data->'notes', '{}'::jsonb) || jsonb_build_object(p_bird, p_note)), updated_at = now() where id = p_flock;
  end if;
  return json_build_object('ok', true);
end $$;

-- "I'm getting this": stored on the giver's flock so the person receiving it never sees it in the app.
create or replace function public.flocks_set_gift(p_code text, p_flock text, p_for text, p_bird text, p_on boolean) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_flock) or not flocks_valid_id(p_for) or not flocks_valid_id(p_bird) then return flocks_err('invalid'); end if;
  if p_on then
    update flocks_flocks set data = jsonb_set(data, '{gifts}', coalesce(data->'gifts', '{}'::jsonb) || jsonb_build_object(p_for,
        coalesce(data->'gifts'->p_for, '{}'::jsonb) || jsonb_build_object(p_bird, true))), updated_at = now() where id = p_flock;
  else
    update flocks_flocks set data = data #- array['gifts', p_for, p_bird], updated_at = now() where id = p_flock;
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_save_flock(p_code text, p_flock text, p_name text, p_color text, p_order int) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_flock) or length(trim(coalesce(p_name, ''))) not between 1 and 30
     or p_color !~ '^#[0-9A-Fa-f]{6}$' or p_order not between 0 and 999 then return flocks_err('invalid'); end if;
  if (select count(*) from flocks_flocks) >= 20 and not exists (select 1 from flocks_flocks where id = p_flock) then return flocks_err('too_many'); end if;
  insert into flocks_flocks (id, data) values (p_flock, jsonb_build_object('name', trim(p_name), 'color', p_color, 'order', p_order, 'owned', '{}'::jsonb, 'wish', '{}'::jsonb, 'notes', '{}'::jsonb))
    on conflict (id) do update set data = flocks_flocks.data || jsonb_build_object('name', trim(p_name), 'color', p_color), updated_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_delete_flock(p_code text, p_flock text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  delete from flocks_flocks where id = p_flock;
  -- forget any gift notes others had made for this person
  update flocks_flocks set data = data #- array['gifts', p_flock] where data->'gifts' ? p_flock;
  return json_build_object('ok', true);
end $$;

-- Family-added birds. The server builds the record from checked fields only.
create or replace function public.flocks_add_bird(p_code text, p_id text, p_name text, p_season text, p_year text, p_kind text, p_body text, p_by text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_id) or length(trim(coalesce(p_name, ''))) not between 1 and 60
     or p_season not in ('christmas','ornament','halloween','fall','muertos','valentine','spring','summer','patriotic','pride','stpatricks','other')
     or coalesce(p_year, '') !~ '^(|20[0-9]{2})$' or length(coalesce(p_kind, '')) > 80
     or p_body !~ '^#[0-9A-Fa-f]{6}$' or (coalesce(p_by, '') <> '' and not flocks_valid_id(p_by)) then return flocks_err('invalid'); end if;
  if (select count(*) from flocks_birds where data->>'source' = 'added') >= 500 then return flocks_err('too_many'); end if;
  insert into flocks_birds (id, data) values (p_id, jsonb_build_object('name', trim(p_name), 'season', p_season, 'year', coalesce(p_year, ''),
      'kind', trim(coalesce(p_kind, '')), 'body', p_body, 'source', 'added', 'addedBy', coalesce(p_by, ''), 'addedOn', to_char(now(), 'YYYY-MM-DD')))
    on conflict (id) do nothing;
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_delete_bird(p_code text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  delete from flocks_birds where id = p_id and data->>'source' = 'added';
  return json_build_object('ok', true);
end $$;

-- Family photos, one per bird, shrunk on the phone before upload.
create or replace function public.flocks_get_photo(p_code text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  return json_build_object('url', (select data_url from flocks_photos where id = p_id));
end $$;

create or replace function public.flocks_save_photo(p_code text, p_id text, p_data text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  if not flocks_valid_id(p_id) or p_data !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' or octet_length(p_data) > 700000 then return flocks_err('invalid'); end if;
  if not exists (select 1 from flocks_birds where id = p_id) then return flocks_err('invalid'); end if;
  insert into flocks_photos (id, data_url) values (p_id, p_data)
    on conflict (id) do update set data_url = excluded.data_url, updated_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function public.flocks_delete_photo(p_code text, p_id text) returns json
language plpgsql security definer set search_path = public as $$
declare a text := flocks_auth(p_code);
begin
  if a <> 'ok' then return flocks_err(a); end if;
  delete from flocks_photos where id = p_id;
  return json_build_object('ok', true);
end $$;

-- Lets the keep-awake job poke the database without knowing the passcode.
create or replace function public.flocks_ping() returns boolean
language sql security definer set search_path = public as $$ select true $$;

-- Permissions: the app (anon) may call only the app functions.
revoke all on function
  public.flocks_set_passcode(text), public.flocks_auth(text), public.flocks_valid_id(text), public.flocks_err(text),
  public.flocks_check(text), public.flocks_load(text),
  public.flocks_set_owned(text, text, text, int, text), public.flocks_set_wish(text, text, text, boolean),
  public.flocks_set_note(text, text, text, text), public.flocks_set_gift(text, text, text, text, boolean),
  public.flocks_save_flock(text, text, text, text, int), public.flocks_delete_flock(text, text),
  public.flocks_add_bird(text, text, text, text, text, text, text, text), public.flocks_delete_bird(text, text),
  public.flocks_get_photo(text, text), public.flocks_save_photo(text, text, text), public.flocks_delete_photo(text, text),
  public.flocks_ping()
from public;
revoke execute on function public.flocks_set_passcode(text), public.flocks_auth(text) from anon, authenticated;
grant execute on function
  public.flocks_check(text), public.flocks_load(text),
  public.flocks_set_owned(text, text, text, int, text), public.flocks_set_wish(text, text, text, boolean),
  public.flocks_set_note(text, text, text, text), public.flocks_set_gift(text, text, text, text, boolean),
  public.flocks_save_flock(text, text, text, text, int), public.flocks_delete_flock(text, text),
  public.flocks_add_bird(text, text, text, text, text, text, text, text), public.flocks_delete_bird(text, text),
  public.flocks_get_photo(text, text), public.flocks_save_photo(text, text, text), public.flocks_delete_photo(text, text),
  public.flocks_ping()
to anon, authenticated;
grant execute on function public.flocks_valid_id(text), public.flocks_err(text) to anon, authenticated;

-- Starting bird list (407 birds). Re-running refreshes these records only.
insert into public.flocks_birds (id, data) values
  ('astra-2026', '{"name": "Astra", "season": "valentine", "year": "2026", "kind": "Astronaut bird", "line": "Spritz", "source": "target", "body": "#F4A6C0", "acc": "helmet", "url": "https://www.target.com/p/featherly-friends-8482-valentine-39-s-day-39-astra-39-astronaut-bird-spritz-8482/-/A-94616933", "urlLabel": "Target product page", "accent": "#F06A8F"}'::jsonb),
  ('boxter-2026', '{"name": "Boxter", "season": "valentine", "year": "2026", "kind": "Chocolate box", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "heart", "accent": "#F06A8F", "url": "https://www.target.com/p/featherly-friends-8482-valentine-39-s-day-39-boxter-39-chocolate-box-bird-spritz-8482/-/A-94616958", "urlLabel": "Target"}'::jsonb),
  ('smoocher-2026', '{"name": "Smoocher", "season": "valentine", "year": "2026", "kind": "Valentine''s bird", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "lips", "accent": "#F06A8F"}'::jsonb),
  ('tinzel-2026', '{"name": "Tinzel", "season": "valentine", "year": "2026", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/146307417594", "urlLabel": "Source"}'::jsonb),
  ('clover-2026', '{"name": "Clover", "season": "stpatricks", "year": "2026", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "heart", "accent": "#2FA35B", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('finnigan-2026', '{"name": "Finnigan", "season": "stpatricks", "year": "2026", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "heart", "accent": "#2FA35B", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('goldie-2026', '{"name": "Goldie", "season": "stpatricks", "year": "2026", "source": "wiki", "body": "#6FB7E0", "acc": "", "accent": "#2FA35B"}'::jsonb),
  ('crackles-2026', '{"name": "Crackles", "season": "spring", "year": "2026", "kind": "Spring bird", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "egg", "accent": "#6DBF6A"}'::jsonb),
  ('skipster-2026', '{"name": "Skipster", "season": "spring", "year": "2026", "kind": "Spring bird", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "bunny", "accent": "#6DBF6A"}'::jsonb),
  ('sprout-2026', '{"name": "Sprout", "season": "spring", "year": "2026", "kind": "Spring bird", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "flower", "accent": "#6DBF6A"}'::jsonb),
  ('tubsy-2026', '{"name": "Tubsy", "season": "spring", "year": "2026", "kind": "Spring bird", "line": "Spritz", "source": "wiki", "body": "#6FB7E0", "acc": "flower", "accent": "#6DBF6A"}'::jsonb),
  ('patty-2026', '{"name": "Patty", "season": "summer", "year": "2026", "kind": "Burger", "line": "Bullseye''s Playground", "source": "wiki", "body": "#7CC6A4", "acc": "beret", "accent": "#3BA7D9", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('sam-2026', '{"name": "Sam", "season": "patriotic", "year": "2026", "kind": "Uncle Sam", "line": "Bullseye''s Playground", "source": "wiki", "body": "#FFD166", "acc": "trio", "accent": "#3E5BA9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('sparky-2026', '{"name": "Sparky", "season": "patriotic", "year": "2026", "kind": "Fireworks", "line": "Sun Squad", "source": "wiki", "body": "#F4A6C0", "acc": "trio", "accent": "#3E5BA9", "url": "https://www.mercari.com/us/item/m65311406233/", "urlLabel": "Source"}'::jsonb),
  ('tater-2026', '{"name": "Tater", "season": "patriotic", "year": "2026", "kind": "French fry (4th of July)", "line": "Bullseye''s Playground", "source": "wiki", "body": "#FFD166", "acc": "beret", "accent": "#3E5BA9", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('boots-2026', '{"name": "Boots", "season": "pride", "year": "2026", "kind": "Cowboy/cowgirl, fringe hat", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#B05FD0", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('dandy-2026', '{"name": "Dandy", "season": "pride", "year": "2026", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "flowercrown", "accent": "#B05FD0", "url": "https://www.ebay.com/itm/178324421438", "urlLabel": "Source"}'::jsonb),
  ('pride-festival-2026', '{"name": "Festival", "season": "pride", "year": "2026", "kind": "Rainbow fan", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "flowercrown", "accent": "#B05FD0", "url": "https://www.target.com/p/pride-festival-bird/-/A-94959759", "urlLabel": "Target"}'::jsonb),
  ('poetess-2026', '{"name": "Poetess", "season": "pride", "year": "2026", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "flowercrown", "accent": "#B05FD0", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('perfect-couple-2026', '{"name": "Perfect Couple", "season": "pride", "year": "2026", "kind": "Set of two birds", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#B05FD0"}'::jsonb),
  ('bonesly-2026', '{"name": "Bonesly", "season": "halloween", "year": "2026", "kind": "Skeleton", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#3A3245", "acc": "bones", "url": "https://www.target.com/p/featherly-friends-8482-39-bonesly-39-skeleton-fabric-bird-figurine-hyde-and-eek-boutique-8482/-/A-94895052", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_e9deebbc-65d4-4804-a036-a707af276ab7", "accent": "#8A5CC9"}'::jsonb),
  ('cathy-2026', '{"name": "Cathy", "season": "halloween", "year": "2026", "kind": "Cat ears", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#3A3245", "acc": "catears", "url": "https://www.target.com/p/featherly-friends-8482-39-cathy-39-cat-ears-fabric-bird-figurine-hyde-and-eek-boutique-8482/-/A-94895062", "urlLabel": "See it on Target", "accent": "#8A5CC9", "img": "https://target.scene7.com/is/image/Target/GUEST_38b6afd8-92e7-4cdf-b2a4-16e8cd7e10fd"}'::jsonb),
  ('cauldy-2026', '{"name": "Cauldy", "season": "halloween", "year": "2026", "kind": "Witch", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#7CC6A4", "acc": "witch", "url": "https://www.target.com/p/featherly-friends-8482-39-cauldy-39-witch-fabric-bird-figurine-hyde-and-eek-boutique-8482/-/A-94895210", "urlLabel": "See it on Target", "accent": "#8A5CC9", "img": "https://target.scene7.com/is/image/Target/GUEST_da912485-a8cc-4e66-98de-88c3f30c293d"}'::jsonb),
  ('crawsly-2026', '{"name": "Crawsly", "season": "halloween", "year": "2026", "kind": "Spider bird", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#3A3245", "acc": "spider", "url": "https://www.target.com/p/featherly-friends-8482-39-crawsly-39-spider-bird-fabric-table-top-decorative-accent-hyde-and-eek-boutique-8482/-/A-94895075", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_2369303f-453f-4022-ba1f-13cee3cf254d", "accent": "#8A5CC9"}'::jsonb),
  ('flicker-2026', '{"name": "Flicker", "season": "halloween", "year": "2026", "kind": "Pumpkin", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#F2A65A", "acc": "pumpkin", "url": "https://www.target.com/p/featherly-friends-8482-39-flicker-39-pumpkin-fabric-bird-figurine-hyde-and-eek-boutique-8482/-/A-94895076", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_33e48331-5093-4fb2-beea-b4bd1d25ee44", "accent": "#8A5CC9"}'::jsonb),
  ('furbert-2026', '{"name": "Furbert", "season": "halloween", "year": "2026", "kind": "Monster bird", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#7CC6A4", "acc": "horns", "url": "https://www.target.com/p/featherly-friends-8482-39-furbert-39-monster-bird-decorative-accent-hyde-and-eek-boutique-8482/-/A-94895066", "urlLabel": "See it on Target", "accent": "#8A5CC9", "img": "https://target.scene7.com/is/image/Target/GUEST_6f7e5ea6-845c-4268-be6c-b659302d1510"}'::jsonb),
  ('jackson-2026', '{"name": "Jackson", "season": "halloween", "year": "2026", "kind": "Jack-o''-lantern bird", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#F28C28", "acc": "pumpkin", "url": "https://www.target.com/p/featherly-friends-8482-39-jackson-39-jack-bird-decorative-accent-hyde-and-eek-boutique-8482/-/A-94895144", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_b9d7cf6b-825c-4ffa-b272-781ca493b7aa", "accent": "#8A5CC9"}'::jsonb),
  ('ripley-2026', '{"name": "Ripley", "season": "halloween", "year": "2026", "kind": "Tombstone bird", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#B7B3C2", "acc": "tombstone", "url": "https://www.target.com/p/featherly-friends-8482-39-ripley-39-tombstone-bird-fabric-tabletop-decorative-accent-hyde-and-eek-boutique-8482/-/A-94895134", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_bf5f9c26-f01f-40a3-987f-ce105557da25", "accent": "#8A5CC9"}'::jsonb),
  ('cider-2026', '{"name": "Cider", "season": "fall", "year": "2026", "kind": "Apple picker", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#F5C542", "acc": "apple", "url": "https://www.target.com/p/featherly-friends-8482-39-cider-39-halloween-harvest-apple-picker-fabric-bird-decor-hyde-and-eek-boutique-8482/-/A-95052698", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_b55d91ff-42d0-414a-af4b-fd5e2edf08a7", "accent": "#E8873A"}'::jsonb),
  ('raker-2026', '{"name": "Raker", "season": "fall", "year": "2026", "kind": "Raking leaves", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#E8873A", "acc": "rake", "url": "https://www.target.com/p/featherly-friends-8482-39-raker-39-halloween-harvest-raking-leaves-fabric-bird-decor-hyde-and-eek-boutique-8482/-/A-95052705", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_efb20ed3-7f37-4cc0-9080-ab70cccb78c5", "accent": "#E8873A"}'::jsonb),
  ('whip-2026', '{"name": "Whip", "season": "fall", "year": "2026", "kind": "Pumpkin pie", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "target", "body": "#F2A65A", "acc": "pie", "url": "https://www.target.com/p/featherly-friends-8482-39-whip-39-halloween-harvest-pumpkin-pie-fabric-bird-decor-hyde-and-eek-boutique-8482/-/A-95052706", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_7a00efbf-f57e-41ea-8043-2e1f000b807f", "accent": "#E8873A"}'::jsonb),
  ('el-catrin-2026', '{"name": "El Catrin", "season": "muertos", "year": "2026", "kind": "Día de Muertos", "price": "$5", "source": "target", "body": "#3A3245", "acc": "tophat", "url": "https://www.target.com/p/d-237-a-de-muertos-featherly-friend-el-catrin/-/A-95161295", "urlLabel": "See it on Target", "accent": "#E25FA2", "img": "https://target.scene7.com/is/image/Target/GUEST_2c06112a-03f3-4951-bb7d-f53f48d8cd06"}'::jsonb),
  ('la-catrina-2026', '{"name": "La Catrina", "season": "muertos", "year": "2026", "kind": "Día de Muertos", "price": "$5", "source": "target", "body": "#F4A6C0", "acc": "flowercrown", "url": "https://www.target.com/p/d-237-a-de-muertos-featherly-friend-la-catrina/-/A-95161305", "urlLabel": "See it on Target", "img": "https://target.scene7.com/is/image/Target/GUEST_3760be12-8d03-40fb-b378-800ceb01244c", "accent": "#E25FA2"}'::jsonb),
  ('buttons-2025', '{"name": "Buttons", "season": "valentine", "year": "2025", "kind": "Teddy bear (''Be Mine'')", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Buttons", "urlLabel": "Fan wiki"}'::jsonb),
  ('floof-2025', '{"name": "Floof", "season": "valentine", "year": "2025", "kind": "Pink/red heart glasses", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Floof", "urlLabel": "Fan wiki"}'::jsonb),
  ('toots-2025', '{"name": "Toots", "season": "valentine", "year": "2025", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Toots", "urlLabel": "Fan wiki", "kind": "Flamingo Object"}'::jsonb),
  ('deckle-2025', '{"name": "Deckle", "season": "spring", "year": "2025", "kind": "Gardener", "line": "Spritz", "source": "wiki", "body": "#8D7A6A", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Deckle", "urlLabel": "Fan wiki"}'::jsonb),
  ('hue-2025', '{"name": "Hue", "season": "spring", "year": "2025", "kind": "Chick", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Hue", "urlLabel": "Fan wiki"}'::jsonb),
  ('scribble-2025', '{"name": "Scribble", "season": "spring", "year": "2025", "kind": "Painter", "line": "Spritz", "source": "wiki", "body": "#8D7A6A", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Scribble", "urlLabel": "Fan wiki"}'::jsonb),
  ('tint-2025', '{"name": "Tint", "season": "spring", "year": "2025", "kind": "Bunny", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "bunny", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Tint", "urlLabel": "Fan wiki"}'::jsonb),
  ('cheery-2025', '{"name": "Cheery", "season": "patriotic", "year": "2025", "kind": "Red, white and blue girl (cheerleader)", "line": "Sun Squad", "source": "wiki", "body": "#E0525B", "acc": "sun", "accent": "#3E5BA9", "url": "https://target-birds.fandom.com/wiki/Cheery", "urlLabel": "Fan wiki"}'::jsonb),
  ('franky-2025', '{"name": "Franky", "season": "summer", "year": "2025", "kind": "Hot dog", "line": "Sun Squad", "source": "wiki", "body": "#9C8BE0", "acc": "sun", "accent": "#3BA7D9", "url": "https://www.target.com/p/featherly-friends-8482-hot-dog-sun-squad-8482/-/A-92593798", "urlLabel": "Target"}'::jsonb),
  ('hero-2025', '{"name": "Hero", "season": "patriotic", "year": "2025", "kind": "Red, white and blue boy", "line": "Sun Squad", "source": "wiki", "body": "#E0525B", "acc": "sun", "accent": "#3E5BA9", "url": "https://www.target.com/p/featherly-friends-8482-red-white-and-blue-boy-sun-squad-8482/-/A-92593805", "urlLabel": "Target"}'::jsonb),
  ('sprinkles-2025', '{"name": "Sprinkles", "season": "summer", "year": "2025", "kind": "Ice cream cone", "line": "Sun Squad", "source": "wiki", "body": "#F5F1EA", "acc": "sun", "accent": "#3BA7D9", "url": "https://www.target.com/p/featherly-friends-8482-ice-cream-sun-squad-8482/-/A-92593803", "urlLabel": "Target"}'::jsonb),
  ('heiress-2025', '{"name": "Heiress", "season": "pride", "year": "2025", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "wave", "accent": "#B05FD0", "url": "https://www.target.com/p/pride-featherly-friend-8482-collectible-bird-figurine-heiress/-/A-93459270", "urlLabel": "Target", "kind": "Heiress"}'::jsonb),
  ('mrs-pride-2025', '{"name": "Mrs. Pride", "season": "pride", "year": "2025", "kind": "Drag queen princess (pink wig, tiara)", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "crown", "accent": "#B05FD0", "url": "https://www.target.com/p/pride-featherly-friend-collectible-bird-figurine-mrs-pride/-/A-93459267", "urlLabel": "Target"}'::jsonb),
  ('queen-2025', '{"name": "Queen", "season": "pride", "year": "2025", "kind": "Drag queen", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "crown", "accent": "#B05FD0", "url": "https://www.target.com/p/pride-featherly-friend-collectible-bird-figurine-queen/-/A-93459269", "urlLabel": "Target"}'::jsonb),
  ('gal-and-pal-2025', '{"name": "Gal and Pal", "season": "pride", "year": "2025", "kind": "Mini birds (pair)", "line": "Spritz", "source": "wiki", "body": "#6FB7E0", "acc": "wave", "accent": "#B05FD0", "url": "https://target-birds.fandom.com/wiki/Gal_and_Pal", "urlLabel": "Fan wiki"}'::jsonb),
  ('bonita-2025', '{"name": "Bonita", "season": "halloween", "year": "2025", "kind": "Skeleton", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "bones", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Bonita", "urlLabel": "Fan wiki"}'::jsonb),
  ('charmer-2025', '{"name": "Charmer", "season": "halloween", "year": "2025", "kind": "Vampire", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Charmer", "urlLabel": "Fan wiki"}'::jsonb),
  ('glitzy-2025', '{"name": "Glitzy", "season": "halloween", "year": "2025", "kind": "Good witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-good-witch-bird-figurine-hyde-and-eek-boutique-8482-pink/-/A-93350862", "urlLabel": "Target"}'::jsonb),
  ('gloomer-2025', '{"name": "Gloomer", "season": "halloween", "year": "2025", "kind": "Dark witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-bad-witch-bird-figurine-hyde-and-eek-boutique-8482/-/A-93350847", "urlLabel": "Target"}'::jsonb),
  ('lewis-2025', '{"name": "Lewis", "season": "halloween", "year": "2025", "kind": "Grim Reaper", "line": "Hyde and EEK! Boutique", "price": "$5", "source": "wiki", "body": "#E0525B", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-lewis-halloween-bird-figurine-hyde-and-eek-boutique-8482/-/A-93350837", "urlLabel": "Target"}'::jsonb),
  ('moldy-2025', '{"name": "Moldy", "season": "halloween", "year": "2025", "kind": "Zombie", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-zombie-halloween-bird-figurine-hyde-and-eek-boutique-8482/-/A-93350844", "urlLabel": "Target"}'::jsonb),
  ('moony-2025', '{"name": "Moony", "season": "halloween", "year": "2025", "kind": "Werewolf", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#9C8BE0", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-werewolf-halloween-bird-figurine-hyde-and-eek-boutique-8482/-/A-93350834", "urlLabel": "Target"}'::jsonb),
  ('shady-2025', '{"name": "Shady", "season": "halloween", "year": "2025", "kind": "Black cat", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "catears", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Shady", "urlLabel": "Fan wiki"}'::jsonb),
  ('whisper-2025', '{"name": "Whisper", "season": "halloween", "year": "2025", "kind": "Ghost", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F5F1EA", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-shimmer-ghost-bird-figurine-hyde-and-eek-boutique-8482-white/-/A-93350845", "urlLabel": "Target"}'::jsonb),
  ('lindoro-2025', '{"name": "Lindoro", "season": "muertos", "year": "2025", "kind": "Día de Muertos", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Lindoro_2025", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('glaze-2025', '{"name": "Glaze", "season": "christmas", "year": "2025", "kind": "Gingerbread", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-gingerbread-wondershop-8482/-/A-94339964", "urlLabel": "Target"}'::jsonb),
  ('dash-2025', '{"name": "Dash", "season": "christmas", "year": "2025", "kind": "Chef''s hat and glasses", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Dash", "urlLabel": "Fan wiki"}'::jsonb),
  ('smidgen-2025', '{"name": "Smidgen", "season": "christmas", "year": "2025", "kind": "With cookbook", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Smidgen", "urlLabel": "Fan wiki"}'::jsonb),
  ('tally-ho-2025', '{"name": "Tally-ho", "season": "christmas", "year": "2025", "kind": "Top hat", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "tophat", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-suit-and-umbrella-wondershop-8482/-/A-94339999", "urlLabel": "Target"}'::jsonb),
  ('vestie-2025', '{"name": "Vestie", "season": "christmas", "year": "2025", "kind": "With binoculars", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "vest", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-suit-and-binoculars-wondershop-8482/-/A-94339959", "urlLabel": "Target"}'::jsonb),
  ('stirrup-2025', '{"name": "Stirrup", "season": "christmas", "year": "2025", "kind": "Riding gear", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-red-coat-wondershop-8482/-/A-94339925", "urlLabel": "Target"}'::jsonb),
  ('ballyhoo-2025', '{"name": "Ballyhoo", "season": "christmas", "year": "2025", "kind": "Heart glasses", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "heart", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-heart-glasses-wondershop-8482/-/A-94339965", "urlLabel": "Target"}'::jsonb),
  ('gala-2025', '{"name": "Gala", "season": "christmas", "year": "2025", "kind": "Crown (''Holiday Cheer'')", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "crown", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Gala", "urlLabel": "Fan wiki"}'::jsonb),
  ('soiree-2025', '{"name": "Soiree", "season": "christmas", "year": "2025", "kind": "Pink dress", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "skirt", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-pink-dress-wondershop-8482/-/A-94339966", "urlLabel": "Target"}'::jsonb),
  ('sanki-2025', '{"name": "Sanki", "season": "christmas", "year": "2025", "kind": "With snowshoes", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "snow", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-bird-decor-snow-shoes-wondershop-8482/-/A-94339936", "urlLabel": "Target"}'::jsonb),
  ('trineo-2025', '{"name": "Trineo", "season": "christmas", "year": "2025", "kind": "With wooden sticks", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "beanie", "accent": "#E0525B", "url": "https://www.target.com/p/christmas-fabric-brid-decor-sticks-wondershop-8482/-/A-94340191", "urlLabel": "Target"}'::jsonb),
  ('kelkka-other', '{"name": "Kelkka", "season": "christmas", "source": "wiki", "body": "#FFD166", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Kelkka", "urlLabel": "Fan wiki", "year": "2025", "kind": "Decor Star Headband", "line": "Wondershop"}'::jsonb),
  ('aurum-2025', '{"name": "Aurum", "season": "christmas", "year": "2025", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('glaze-mini-2025', '{"name": "Glaze Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Glaze_Mini", "urlLabel": "Fan wiki", "body": "#F2A65A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('dash-mini-2025', '{"name": "Dash Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Dash_Mini", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('smidgen-mini-2025', '{"name": "Smidgen Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Smidgen_Mini", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('tally-ho-mini-other', '{"name": "Tally-ho Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#F5F1EA", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Tally-ho_Mini", "urlLabel": "Fan wiki", "year": "2025"}'::jsonb),
  ('vestie-mini-2025', '{"name": "Vestie Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Vestie_Mini", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('stirrup-mini-2025', '{"name": "Stirrup Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Stirrup_Mini", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('ballyhoo-mini-2025', '{"name": "Ballyhoo Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Ballyhoo_Mini", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('gala-mini-2025', '{"name": "Gala Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Gala_Mini", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('soiree-mini-2025', '{"name": "Soiree Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Soiree_Mini", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('sanki-mini-2025', '{"name": "Sanki Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Sanki_Mini", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('trineo-mini-2025', '{"name": "Trineo Mini", "season": "christmas", "year": "2025", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Trineo_Mini", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('kelkka-mini-other', '{"name": "Kelkka Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#7CC6A4", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Kelkka_Mini", "urlLabel": "Fan wiki", "year": "2025"}'::jsonb),
  ('cherie-2024', '{"name": "Chérie", "season": "valentine", "year": "2024", "kind": "Parisian", "line": "Spritz", "price": "$5", "source": "wiki", "body": "#F4A6C0", "acc": "beret", "accent": "#F06A8F", "url": "https://www.target.com/p/valentine-fabric-featherly-friends-bird-bonjour-spritz-8482/-/A-88401555", "urlLabel": "Target", "about": "Sold at Target as the \"Bonjour\" Valentine bird."}'::jsonb),
  ('kingsley-2024', '{"name": "Kingsley", "season": "valentine", "year": "2024", "kind": "King of Hearts", "line": "Spritz", "price": "$5", "source": "wiki", "body": "#FFD166", "acc": "crown", "accent": "#F06A8F", "url": "https://www.target.com/p/valentine-fabric-featherly-friends-bird-king-of-hearts-spritz-8482/-/A-88401458", "urlLabel": "Target", "about": "Sold at Target as the King of Hearts bird."}'::jsonb),
  ('queenie-2024', '{"name": "Queenie", "season": "valentine", "year": "2024", "kind": "Queen of Hearts", "line": "Spritz", "price": "$5", "source": "wiki", "body": "#E0525B", "acc": "crown", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Queenie", "urlLabel": "Fan wiki", "about": "Sold at Target as the Queen of Hearts bird."}'::jsonb),
  ('flutter-2024', '{"name": "Flutter", "season": "spring", "year": "2024", "kind": "Butterfly", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Flutter", "urlLabel": "Fan wiki"}'::jsonb),
  ('lady-2024', '{"name": "Lady", "season": "spring", "year": "2024", "kind": "Ladybug", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Lady", "urlLabel": "Fan wiki"}'::jsonb),
  ('truffle-2024', '{"name": "Truffle", "season": "spring", "year": "2024", "kind": "Botanist", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Truffle", "urlLabel": "Fan wiki"}'::jsonb),
  ('tuft-2024', '{"name": "Tuft", "season": "spring", "year": "2024", "kind": "Easter bunny", "line": "Spritz", "source": "wiki", "body": "#8D7A6A", "acc": "bunny", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Tuft", "urlLabel": "Fan wiki"}'::jsonb),
  ('bubba-2024', '{"name": "Bubba", "season": "patriotic", "year": "2024", "kind": "July 4th", "line": "Sun Squad", "source": "wiki", "body": "#3A3245", "acc": "sun", "accent": "#3E5BA9", "url": "https://target-birds.fandom.com/wiki/Bubba", "urlLabel": "Fan wiki"}'::jsonb),
  ('coral-2024', '{"name": "Coral", "season": "summer", "year": "2024", "kind": "Pink", "line": "Sun Squad", "source": "wiki", "body": "#F4A6C0", "acc": "wave", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Coral", "urlLabel": "Fan wiki"}'::jsonb),
  ('junior-2024', '{"name": "Junior", "season": "summer", "year": "2024", "kind": "Summer swimmer", "line": "Sun Squad", "source": "wiki", "body": "#FFD166", "acc": "wave", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Junior", "urlLabel": "Fan wiki"}'::jsonb),
  ('starla-2025', '{"name": "Starla", "season": "patriotic", "year": "2024", "kind": "4th of July", "line": "Sun Squad", "source": "wiki", "body": "#E0525B", "acc": "wave", "accent": "#3E5BA9", "url": "https://www.target.com/p/featherly-friends-red-white-and-blue-girl-sun-squad-8482/-/A-92593835", "urlLabel": "Target"}'::jsonb),
  ('beach-2024', '{"name": "Beach", "season": "pride", "year": "2024", "kind": "Poolside", "line": "Spritz", "source": "wiki", "body": "#F2A65A", "acc": "wave", "accent": "#B05FD0", "url": "https://target-birds.fandom.com/wiki/Beach", "urlLabel": "Fan wiki"}'::jsonb),
  ('movie-star-2024', '{"name": "Movie Star", "season": "pride", "year": "2024", "kind": "Movie star (''Tippi'', The Birds)", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "wave", "accent": "#B05FD0", "url": "https://target-birds.fandom.com/wiki/Movie_Star", "urlLabel": "Fan wiki"}'::jsonb),
  ('batrick-2024', '{"name": "Batrick", "season": "halloween", "year": "2024", "kind": "Bat", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Batrick", "urlLabel": "Fan wiki"}'::jsonb),
  ('glitters-2024', '{"name": "Glitters", "season": "halloween", "year": "2024", "kind": "Punk rocker", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Glitters", "urlLabel": "Fan wiki"}'::jsonb),
  ('gourdon-2024', '{"name": "Gourdon", "season": "halloween", "year": "2024", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F5F1EA", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Gourdon", "urlLabel": "Fan wiki", "kind": "Felt"}'::jsonb),
  ('hoodie-2024', '{"name": "Hoodie", "season": "halloween", "year": "2024", "kind": "Reaper", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#FFD166", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friend-felt-bird-39-hoodie-39-halloween-decorative-figurine-hyde-38-eek-boutique-8482/-/A-89599846", "urlLabel": "Target"}'::jsonb),
  ('pawson-2024', '{"name": "Pawson", "season": "halloween", "year": "2024", "kind": "Jack-o''-lantern", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F5F1EA", "acc": "catears", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Pawson", "urlLabel": "Fan wiki"}'::jsonb),
  ('skitter-2024', '{"name": "Skitter", "season": "halloween", "year": "2024", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#FFD166", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friends-8482-39-skitter-39-felt-bird-halloween-decorative-figurine-hyde-and-eek-boutique-8482/-/A-89599889", "urlLabel": "Target", "kind": "Felt"}'::jsonb),
  ('spellma-2024', '{"name": "Spellma", "season": "halloween", "year": "2024", "kind": "Witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.target.com/p/featherly-friend-felt-witch-bird-halloween-decorative-figurine-hyde-38-eek-boutique-8482/-/A-89599857", "urlLabel": "Target"}'::jsonb),
  ('x-ray-2024', '{"name": "X-Ray", "season": "halloween", "year": "2024", "kind": "Skeleton", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "bones", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/X-Ray", "urlLabel": "Fan wiki"}'::jsonb),
  ('pixan-2024', '{"name": "Pixán", "season": "muertos", "year": "2024", "kind": "Sugar skull", "source": "wiki", "body": "#7CC6A4", "acc": "wave", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Pixán", "urlLabel": "Fan wiki"}'::jsonb),
  ('acorn-2024', '{"name": "Acorn", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#6FB7E0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Acorn", "urlLabel": "Fan wiki", "kind": "Holding Mushroom"}'::jsonb),
  ('berry-2024', '{"name": "Berry", "season": "christmas", "year": "2024", "kind": "Holding holly", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Berry", "urlLabel": "Fan wiki"}'::jsonb),
  ('capster-2024', '{"name": "Capster", "season": "christmas", "year": "2024", "kind": "Mushroom", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Capster", "urlLabel": "Fan wiki"}'::jsonb),
  ('conifer-2024', '{"name": "Conifer", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#F2A65A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Conifer", "urlLabel": "Fan wiki", "kind": "Holding Wreath"}'::jsonb),
  ('fern-2024', '{"name": "Fern", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Fern", "urlLabel": "Fan wiki", "kind": "Holding Gift"}'::jsonb),
  ('gezellig-2024', '{"name": "Gezellig", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "wave", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Gezellig", "urlLabel": "Fan wiki", "kind": "Pink Hat and White Faux Fur Scarf"}'::jsonb),
  ('heiwa-2024', '{"name": "Heiwa", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#F2A65A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Heiwa", "urlLabel": "Fan wiki", "kind": "Wearing Glasses and Earmuffs"}'::jsonb),
  ('mepak-2024', '{"name": "Mepak", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Mepak", "urlLabel": "Fan wiki", "kind": "Pink Scarf"}'::jsonb),
  ('merry-2024', '{"name": "Merry", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Merry", "urlLabel": "Fan wiki", "kind": "Neon"}'::jsonb),
  ('mormor-2024', '{"name": "Mormor", "season": "christmas", "year": "2024", "kind": "Winter (Reunion Collection)", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Mormor", "urlLabel": "Fan wiki"}'::jsonb),
  ('powder-2024', '{"name": "Powder", "season": "christmas", "year": "2024", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Powder", "urlLabel": "Fan wiki", "kind": "Dressed as Snowman"}'::jsonb),
  ('sparkles-2024', '{"name": "Sparkles", "season": "christmas", "year": "2024", "kind": "Tree", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Sparkles", "urlLabel": "Fan wiki"}'::jsonb),
  ('ubuntu-2024', '{"name": "Ubuntu", "season": "christmas", "year": "2024", "kind": "Cream Hat and Sweater", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Ubuntu", "urlLabel": "Fan wiki", "body": "#F5F1EA", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('acorn-mini-2024', '{"name": "Acorn Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('berry-mini-2024', '{"name": "Berry Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('capster-mini-2024', '{"name": "Capster Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('fern-mini-2024', '{"name": "Fern Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('gezellig-mini-2024', '{"name": "Gezellig Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('mepak-mini-2024', '{"name": "Mepak Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('merry-mini-2024', '{"name": "Merry Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('sparkle-mini-2024', '{"name": "Sparkle Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('ubuntu-mini-2024', '{"name": "Ubuntu Mini", "season": "christmas", "year": "2024", "kind": "Mini", "source": "wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('aerial-2023', '{"name": "Aerial", "season": "valentine", "year": "2023", "kind": "With LOVE", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Aerial", "urlLabel": "Fan wiki"}'::jsonb),
  ('avi-2023', '{"name": "Avi", "season": "valentine", "year": "2023", "kind": "Chef hat", "line": "Spritz", "source": "wiki", "body": "#8D7A6A", "acc": "beanie", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Avi", "urlLabel": "Fan wiki"}'::jsonb),
  ('fledge-2023', '{"name": "Fledge", "season": "valentine", "year": "2023", "kind": "With glasses", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "crown", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Fledge", "urlLabel": "Fan wiki"}'::jsonb),
  ('jet-2023', '{"name": "Jet", "season": "valentine", "year": "2023", "kind": "With bouquet", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Jet", "urlLabel": "Fan wiki"}'::jsonb),
  ('bloom-2023', '{"name": "Bloom", "season": "spring", "year": "2023", "kind": "Gnome", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Bloom", "urlLabel": "Fan wiki"}'::jsonb),
  ('bud-2023', '{"name": "Bud", "season": "spring", "year": "2023", "kind": "Gnome", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Bud", "urlLabel": "Fan wiki"}'::jsonb),
  ('carrot-other', '{"name": "Carrot", "season": "spring", "source": "wiki", "body": "#FFD166", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Carrot", "urlLabel": "Fan wiki", "acc": "", "year": "2023", "kind": "Bunny Carrot", "line": "Spritz"}'::jsonb),
  ('kale-2023', '{"name": "Kale", "season": "spring", "year": "2023", "kind": "Gardener", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Kale", "urlLabel": "Fan wiki"}'::jsonb),
  ('labird-other', '{"name": "Labird", "season": "pride", "source": "wiki", "body": "#F5F1EA", "accent": "#B05FD0", "url": "https://target-birds.fandom.com/wiki/Labird", "urlLabel": "Fan wiki", "acc": "", "year": "2023", "kind": "Drag Queen"}'::jsonb),
  ('diver-other', '{"name": "Diver", "season": "summer", "source": "wiki", "body": "#3A3245", "acc": "wave", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Diver", "urlLabel": "Fan wiki", "year": "2023"}'::jsonb),
  ('mellie-2023', '{"name": "Mellie", "season": "summer", "year": "2023", "kind": "Watermelon shirt and stars", "line": "Sun Squad", "source": "wiki", "body": "#9C8BE0", "acc": "sun", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Mellie", "urlLabel": "Fan wiki"}'::jsonb),
  ('scoop-2023', '{"name": "Scoop", "season": "summer", "year": "2023", "source": "wiki", "body": "#3A3245", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Scoop", "urlLabel": "Fan wiki", "acc": "", "kind": "Scoop", "line": "Sun Squad", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('tanji-2023', '{"name": "Tanji", "season": "summer", "year": "2023", "line": "Sun Squad", "source": "wiki", "body": "#F4A6C0", "acc": "sun", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Tanji", "urlLabel": "Fan wiki", "kind": "Tanji from Sun Squad"}'::jsonb),
  ('count-2023', '{"name": "Count", "season": "halloween", "year": "2023", "kind": "Vampire", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "wave", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Count", "urlLabel": "Fan wiki"}'::jsonb),
  ('duchess-2023', '{"name": "Duchess", "season": "halloween", "year": "2023", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#8D7A6A", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Duchess", "urlLabel": "Fan wiki", "kind": "Bootiful Butterfly Princess from Hyde & EEK! Boutique"}'::jsonb),
  ('freda-2023', '{"name": "Freda", "season": "halloween", "year": "2023", "kind": "Frankenstein''s monster bride", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F5F1EA", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Freda", "urlLabel": "Fan wiki"}'::jsonb),
  ('gomez-2023', '{"name": "Gomez", "season": "halloween", "year": "2023", "kind": "Frankenstein''s monster", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#8D7A6A", "acc": "beanie", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Gomez", "urlLabel": "Fan wiki"}'::jsonb),
  ('radley-2023', '{"name": "Radley", "season": "halloween", "year": "2023", "kind": "Bootiful Tuxedo", "line": "Hyde and EEK! Boutique", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Radley", "urlLabel": "Fan wiki", "body": "#3A3245", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('shadow-2023', '{"name": "Shadow", "season": "halloween", "year": "2023", "kind": "Raven", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "beanie", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Shadow", "urlLabel": "Fan wiki"}'::jsonb),
  ('soarin-2023', '{"name": "Soarin", "season": "halloween", "year": "2023", "kind": "Ghost", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Soarin", "urlLabel": "Fan wiki"}'::jsonb),
  ('webber-2023', '{"name": "Webber", "season": "halloween", "year": "2023", "kind": "Spider", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#E0525B", "acc": "spider", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Webber", "urlLabel": "Fan wiki"}'::jsonb),
  ('chaparrito-2023', '{"name": "Chaparrito", "season": "muertos", "year": "2023", "kind": "Día de Muertos (designed by Luis Pinto)", "source": "wiki", "body": "#F4A6C0", "acc": "flowercrown", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Chaparrito", "urlLabel": "Fan wiki"}'::jsonb),
  ('apple-2023', '{"name": "Apple", "season": "fall", "year": "2023", "kind": "Yellow bird (harvest)", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#FFD166", "acc": "vest", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Apple", "urlLabel": "Fan wiki", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('coco-2023', '{"name": "Coco", "season": "fall", "year": "2023", "kind": "Turkey", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "vest", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Coco", "urlLabel": "Fan wiki"}'::jsonb),
  ('oats-2023', '{"name": "Oats", "season": "fall", "year": "2023", "kind": "Vest and Hat", "line": "Hyde and EEK! Boutique", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Oats", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('bauble-2023', '{"name": "Bauble", "season": "christmas", "year": "2023", "kind": "Elf, polka dots (Santa series)", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "santa", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bauble", "urlLabel": "Fan wiki"}'::jsonb),
  ('bay-2023', '{"name": "Bay", "season": "christmas", "year": "2023", "kind": "Gray cap (winter series)", "line": "Wondershop", "source": "wiki", "body": "#B9B4C4", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bay", "urlLabel": "Fan wiki"}'::jsonb),
  ('brook-2023', '{"name": "Brook", "season": "christmas", "year": "2023", "kind": "Knit cap (winter series)", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Brook", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection."}'::jsonb),
  ('chip-2023', '{"name": "Chip", "season": "christmas", "year": "2023", "kind": "Yellow scarf (cookie series)", "line": "Wondershop", "source": "wiki", "body": "#FFD166", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Chip", "urlLabel": "Fan wiki"}'::jsonb),
  ('cove-2023', '{"name": "Cove", "season": "christmas", "year": "2023", "kind": "Knit hat and sweater (winter series)", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Cove", "urlLabel": "Fan wiki"}'::jsonb),
  ('crinkle-2023', '{"name": "Crinkle", "season": "christmas", "year": "2023", "kind": "Wearing Blue Scarf Holding Wreath", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Crinkle", "urlLabel": "Fan wiki", "about": "Re-released in the 2025 Anniversary Collection.", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('dapper-2023', '{"name": "Dapper", "season": "christmas", "year": "2023", "kind": "Santa Claus", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "santa", "accent": "#E0525B", "url": "https://www.target.com/p/6-75-34-featherly-friends-fabric-bird-figurine-dressed-as-santa-claus-wondershop-8482-red-white-green/-/A-87765472", "urlLabel": "Target"}'::jsonb),
  ('ginger-2023', '{"name": "Ginger", "season": "christmas", "year": "2023", "kind": "With gift (cookie series)", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://www.target.com/p/6-75-34-featherly-friends-fabric-bird-figurine-with-gift-wondershop-8482-red/-/A-87765429", "urlLabel": "Target"}'::jsonb),
  ('gingerbread-blue-christmas', '{"name": "Gingerbread Blue", "season": "christmas", "kind": "Gingerbread", "source": "wiki", "body": "#6FB7E0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Gingerbread_Blue", "urlLabel": "Fan wiki", "year": "2023", "line": "Wondershop"}'::jsonb),
  ('gingerbread-pink-christmas', '{"name": "Gingerbread Pink", "season": "christmas", "kind": "Gingerbread", "source": "wiki", "body": "#F4A6C0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Gingerbread_Pink", "urlLabel": "Fan wiki", "year": "2023", "line": "Wondershop"}'::jsonb),
  ('joseph-nativity-2023', '{"name": "Joseph Nativity", "season": "christmas", "year": "2023", "kind": "Nativity set", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Joseph_Nativity", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('loch-2023', '{"name": "Loch", "season": "christmas", "year": "2023", "kind": "Gray earmuffs (winter series)", "line": "Wondershop", "source": "wiki", "body": "#B9B4C4", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Loch", "urlLabel": "Fan wiki"}'::jsonb),
  ('mary-nativity-2023', '{"name": "Mary Nativity", "season": "christmas", "year": "2023", "kind": "Nativity set", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Mary_Nativity", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('ruby-2023', '{"name": "Ruby", "season": "christmas", "year": "2023", "kind": "Leopard print scarf", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "scarf", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Ruby", "urlLabel": "Fan wiki"}'::jsonb),
  ('snap-2023', '{"name": "Snap", "season": "christmas", "year": "2023", "kind": "Red scarf (cookie series)", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "scarf", "accent": "#E0525B", "url": "https://www.target.com/p/6-5-34-featherly-friends-fabric-bird-figurine-wearing-red-scarf-wondershop-8482-brown/-/A-87765378", "urlLabel": "Target"}'::jsonb),
  ('tinsel-2023', '{"name": "Tinsel", "season": "christmas", "year": "2023", "kind": "String lights (Santa series)", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "santa", "accent": "#E0525B", "url": "https://www.target.com/p/6-5-34-featherly-friends-fabric-bird-figurine-with-string-lights-wondershop-8482-pink-white/-/A-87765384", "urlLabel": "Target"}'::jsonb),
  ('wafer-2023', '{"name": "Wafer", "season": "christmas", "year": "2023", "kind": "Green scarf (cookie series)", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "scarf", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Wafer", "urlLabel": "Fan wiki"}'::jsonb),
  ('bauble-mini-other', '{"name": "Bauble Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#FFD166", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bauble_Mini", "urlLabel": "Fan wiki", "year": "2023"}'::jsonb),
  ('bay-mini-2023', '{"name": "Bay Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Bay_Mini", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('brook-mini-other', '{"name": "Brook Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#6FB7E0", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Brook_Mini", "urlLabel": "Fan wiki", "year": "2023"}'::jsonb),
  ('chip-mini-2023', '{"name": "Chip Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Chip_Mini", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('cove-mini-2023', '{"name": "Cove Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Cove_Mini", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('crinkle-mini-other', '{"name": "Crinkle Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#7CC6A4", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Crinkle_Mini", "urlLabel": "Fan wiki", "year": "2023"}'::jsonb),
  ('ginger-mini-2023', '{"name": "Ginger Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Ginger_Mini", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('jesus-nativity-mini-2023', '{"name": "Jesus Nativity Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Jesus_Nativity", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('peppermint-gingerbread-mini-2023', '{"name": "Peppermint Gingerbread Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Peppermint_Gingerbread_Mini", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('snap-mini-2023', '{"name": "Snap Mini", "season": "christmas", "year": "2023", "kind": "Mini", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Snap_Mini", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('tinsel-mini-other', '{"name": "Tinsel Mini", "season": "christmas", "kind": "Mini", "source": "wiki", "body": "#3A3245", "acc": "trio", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Tinsel_Mini", "urlLabel": "Fan wiki", "year": "2023"}'::jsonb),
  ('carmine-2022', '{"name": "Carmine", "season": "valentine", "year": "2022", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Carmine", "urlLabel": "Fan wiki"}'::jsonb),
  ('flynn-2022', '{"name": "Flynn", "season": "valentine", "year": "2022", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Flynn", "urlLabel": "Fan wiki", "kind": "Cupids Arrow ’s Day with Love Shirt Pink from Spritz"}'::jsonb),
  ('harkin-2025', '{"name": "Harkin", "season": "valentine", "year": "2022", "kind": "Valentine mail carrier (Anniversary Collection)", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Harkin", "urlLabel": "Fan wiki", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('radley-2022', '{"name": "Radley", "season": "valentine", "year": "2022", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Radley_(Valentine''s_Day_2022)", "urlLabel": "Fan wiki", "kind": "Heart Face ’s Day Purple from Spritz"}'::jsonb),
  ('primrose-2022', '{"name": "Primrose", "season": "spring", "year": "2022", "kind": "Flower Basket", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Primrose_(Easter_2022)", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('splash-2021', '{"name": "Splash", "season": "spring", "year": "2022", "kind": "Spring Showers", "price": "$5", "source": "wiki", "body": "#6FB7E0", "acc": "wave", "url": "https://target-birds.fandom.com/wiki/Splash", "urlLabel": "Fan wiki", "line": "Spritz", "accent": "#6DBF6A"}'::jsonb),
  ('zipp-2022', '{"name": "Zipp", "season": "spring", "year": "2022", "kind": "Butterfly hunter", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Zipp", "urlLabel": "Fan wiki"}'::jsonb),
  ('drummer-2022', '{"name": "Drummer", "season": "summer", "year": "2022", "line": "Sun Squad", "source": "wiki", "body": "#8D7A6A", "acc": "sun", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Drummer", "urlLabel": "Fan wiki", "kind": "Décor Americana Swim Trunks Red/White/Blue"}'::jsonb),
  ('pearl-other', '{"name": "Pearl", "season": "summer", "source": "wiki", "body": "#6FB7E0", "acc": "wave", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Pearl", "urlLabel": "Fan wiki", "year": "2022", "kind": "Décor Americana Floral Swimsuit with Floppy Hat", "line": "Sun Squad"}'::jsonb),
  ('star-2022', '{"name": "Star", "season": "patriotic", "year": "2022", "line": "Sun Squad", "source": "wiki", "body": "#8D7A6A", "acc": "sun", "accent": "#3E5BA9", "url": "https://target-birds.fandom.com/wiki/Star", "urlLabel": "Fan wiki", "kind": "Décor Americana Star Swimsuit with Bow"}'::jsonb),
  ('tanner-2022', '{"name": "Tanner", "season": "summer", "year": "2022", "kind": "Pool floaty", "line": "Sun Squad", "source": "wiki", "body": "#6FB7E0", "acc": "wave", "accent": "#3BA7D9", "url": "https://target-birds.fandom.com/wiki/Tanner", "urlLabel": "Fan wiki"}'::jsonb),
  ('gourdo-other', '{"name": "Gourdo", "season": "halloween", "source": "wiki", "body": "#6FB7E0", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Gourdo", "urlLabel": "Fan wiki", "acc": "", "year": "2022", "kind": "Pumpkin", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('laspell-2022', '{"name": "Laspell", "season": "halloween", "year": "2022", "kind": "Witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Laspell", "urlLabel": "Fan wiki"}'::jsonb),
  ('screech-2022', '{"name": "Screech", "season": "halloween", "year": "2022", "kind": "Black cat / bat", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "catears", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Screech", "urlLabel": "Fan wiki"}'::jsonb),
  ('socket-2022', '{"name": "Socket", "season": "halloween", "year": "2022", "kind": "Skull / skeleton", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#FFD166", "acc": "bones", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Socket", "urlLabel": "Fan wiki"}'::jsonb),
  ('sugar-2022', '{"name": "Sugar", "season": "halloween", "year": "2022", "kind": "Candy corn", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Sugar", "urlLabel": "Fan wiki"}'::jsonb),
  ('wingit-other', '{"name": "Wingit", "season": "halloween", "source": "wiki", "body": "#F4A6C0", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Wingit", "urlLabel": "Fan wiki", "acc": "", "year": "2022", "kind": "Bat", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('amavida-2022', '{"name": "Amavida", "season": "muertos", "year": "2022", "kind": "Día de Muertos", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "flowercrown", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Amavida", "urlLabel": "Fan wiki"}'::jsonb),
  ('griffin-2022', '{"name": "Griffin", "season": "fall", "year": "2022", "kind": "Turkey", "line": "Spritz", "source": "wiki", "body": "#F2A65A", "acc": "leaf", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Griffin", "urlLabel": "Fan wiki"}'::jsonb),
  ('jora-other', '{"name": "Jora", "season": "fall", "source": "wiki", "body": "#F4A6C0", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Jora", "urlLabel": "Fan wiki", "acc": "", "year": "2022", "kind": "Pinecone", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('oakley-2022', '{"name": "Oakley", "season": "fall", "year": "2022", "kind": "Fall bird", "price": "$5", "source": "wiki", "body": "#E8873A", "acc": "leaf", "url": "https://target-birds.fandom.com/wiki/Oakley", "urlLabel": "Fan wiki", "line": "Hyde and EEK! Boutique", "accent": "#E8873A"}'::jsonb),
  ('bells-2022', '{"name": "Bells", "season": "christmas", "year": "2022", "kind": "Festive series", "line": "Wondershop", "source": "wiki", "body": "#3FA877", "acc": "bell", "url": "https://target-birds.fandom.com/wiki/Bells", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection.", "accent": "#E0525B"}'::jsonb),
  ('bow-2022', '{"name": "Bow", "season": "christmas", "year": "2022", "kind": "Festive series", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "bow", "url": "https://target-birds.fandom.com/wiki/Bow", "urlLabel": "Fan wiki", "accent": "#E0525B"}'::jsonb),
  ('fika-2022', '{"name": "Fika", "season": "christmas", "year": "2022", "kind": "Red sweater with wreath", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "flowercrown", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Fika", "urlLabel": "Fan wiki"}'::jsonb),
  ('fractal-2022', '{"name": "Fractal", "season": "christmas", "year": "2022", "kind": "Festive series", "line": "Wondershop", "source": "wiki", "body": "#6FB7E0", "acc": "snow", "url": "https://target-birds.fandom.com/wiki/Fractal", "urlLabel": "Fan wiki", "accent": "#E0525B"}'::jsonb),
  ('freezy-2022', '{"name": "Freezy", "season": "christmas", "year": "2022", "kind": "Festive series", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "url": "https://target-birds.fandom.com/wiki/Freezy", "urlLabel": "Fan wiki", "accent": "#E0525B"}'::jsonb),
  ('iskall-2022', '{"name": "Iskall", "season": "christmas", "year": "2022", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Iskall", "urlLabel": "Fan wiki", "kind": "Black Hat and Holly"}'::jsonb),
  ('koselig-2022', '{"name": "Koselig", "season": "christmas", "year": "2022", "kind": "Santa-like", "line": "Wondershop", "source": "wiki", "body": "#6FB7E0", "acc": "santa", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Koselig", "urlLabel": "Fan wiki"}'::jsonb),
  ('loop-2022', '{"name": "Loop", "season": "christmas", "year": "2022", "kind": "Season not stated", "price": "$5", "source": "wiki", "body": "#9C8BE0", "url": "https://target-birds.fandom.com/wiki/Loop", "urlLabel": "Fan wiki", "line": "Wondershop", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('purl-2022', '{"name": "Purl", "season": "christmas", "year": "2022", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Purl", "urlLabel": "Fan wiki", "kind": "White Scarf"}'::jsonb),
  ('tricot-2022', '{"name": "Tricot", "season": "christmas", "year": "2022", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Tricot", "urlLabel": "Fan wiki", "kind": "Gray Scarf"}'::jsonb),
  ('varma-2022', '{"name": "Varma", "season": "christmas", "year": "2022", "line": "Wondershop", "source": "wiki", "body": "#F2A65A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Varma", "urlLabel": "Fan wiki", "kind": "Gray Knit Sweater and Bell"}'::jsonb),
  ('weft-2022', '{"name": "Weft", "season": "christmas", "year": "2022", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Weft", "urlLabel": "Fan wiki", "kind": "Blue Striped Scarf"}'::jsonb),
  ('loop-mini-2022', '{"name": "Loop Mini", "season": "christmas", "year": "2022", "kind": "Mini", "source": "wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('purl-mini-2022', '{"name": "Purl Mini", "season": "christmas", "year": "2022", "kind": "Mini", "source": "wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('weft-mini-2022', '{"name": "Weft Mini", "season": "christmas", "year": "2022", "kind": "Mini", "source": "wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('beau-2021', '{"name": "Beau", "season": "valentine", "year": "2021", "kind": "Top Hat", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Beau", "urlLabel": "Fan wiki", "body": "#F5F1EA", "acc": "", "accent": "#F06A8F"}'::jsonb),
  ('poppy-2021', '{"name": "Poppy", "season": "valentine", "year": "2021", "kind": "Strawberry", "line": "Spritz", "source": "wiki", "body": "#3A3245", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Poppy", "urlLabel": "Fan wiki"}'::jsonb),
  ('rowan-2021', '{"name": "Rowan", "season": "valentine", "year": "2021", "kind": "Chocolate strawberry", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Rowan", "urlLabel": "Fan wiki"}'::jsonb),
  ('vida-2021', '{"name": "Vida", "season": "valentine", "year": "2021", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Vida", "urlLabel": "Fan wiki", "kind": "Heart Headband"}'::jsonb),
  ('beezy-2021', '{"name": "Beezy", "season": "spring", "year": "2021", "kind": "Bee", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Beezy", "urlLabel": "Fan wiki"}'::jsonb),
  ('coopster-2021', '{"name": "Coopster", "season": "spring", "year": "2021", "kind": "Rooster", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Coopster", "urlLabel": "Fan wiki"}'::jsonb),
  ('patches-2021', '{"name": "Patches", "season": "spring", "year": "2021", "kind": "Bunny", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Patches", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('gauzy-other', '{"name": "Gauzy", "season": "halloween", "source": "wiki", "body": "#E0525B", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Gauzy", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Mummy", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('kettle-2021', '{"name": "Kettle", "season": "halloween", "year": "2021", "kind": "Witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#8D7A6A", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Kettle", "urlLabel": "Fan wiki"}'::jsonb),
  ('pumper-2021', '{"name": "Pumper", "season": "halloween", "year": "2021", "kind": "Pumpkin", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "pumpkin", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Pumper", "urlLabel": "Fan wiki"}'::jsonb),
  ('trapper-2021', '{"name": "Trapper", "season": "halloween", "year": "2021", "kind": "Ghoulish Garden Purple/Pink", "line": "Hyde and EEK! Boutique", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Trapper_(Halloween_2021)", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('trumpet-2021', '{"name": "Trumpet", "season": "halloween", "year": "2021", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F4A6C0", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Trumpet", "urlLabel": "Fan wiki", "kind": "Ghoulish Garden Orange"}'::jsonb),
  ('venus-2021', '{"name": "Venus", "season": "halloween", "year": "2021", "kind": "Ghoulish green", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Venus", "urlLabel": "Fan wiki"}'::jsonb),
  ('amado-2021', '{"name": "Amado", "season": "muertos", "year": "2021", "kind": "Día de Muertos (designed by Luis Fitch)", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "wave", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Amado", "urlLabel": "Fan wiki"}'::jsonb),
  ('gradey-2021', '{"name": "Gradey", "season": "fall", "year": "2021", "kind": "Holding pumpkin", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#8D7A6A", "acc": "pumpkin", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Gradey", "urlLabel": "Fan wiki"}'::jsonb),
  ('olive-2021', '{"name": "Olive", "season": "fall", "year": "2021", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Olive", "urlLabel": "Fan wiki", "kind": "Scarf"}'::jsonb),
  ('speck-2021', '{"name": "Speck", "season": "fall", "year": "2021", "source": "wiki", "body": "#FFD166", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Speck", "urlLabel": "Fan wiki", "acc": "", "kind": "Harvest", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('clef-2021', '{"name": "Clef", "season": "christmas", "year": "2021", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Clef", "urlLabel": "Fan wiki", "kind": "Santa Hat Overalls & Buffalo Plaid"}'::jsonb),
  ('dewy-other', '{"name": "Dewy", "season": "christmas", "source": "wiki", "body": "#E0525B", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Dewy", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Bow Tie & Vest Green", "line": "Wondershop"}'::jsonb),
  ('flurry-other', '{"name": "Flurry", "season": "christmas", "source": "wiki", "body": "#E0525B", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Flurry", "urlLabel": "Fan wiki", "year": "2021", "kind": "Knit Hat & Scarf White", "line": "Wondershop"}'::jsonb),
  ('gale-other', '{"name": "Gale", "season": "christmas", "source": "wiki", "body": "#8D7A6A", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Gale", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Plaid Scarf & Trapper Hat Gray/White", "line": "Wondershop"}'::jsonb),
  ('glee-other', '{"name": "Glee", "season": "christmas", "source": "wiki", "body": "#6FB7E0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Glee", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Sweater Bells and Earmuffs Red", "line": "Wondershop"}'::jsonb),
  ('jolly-2021', '{"name": "Jolly", "season": "christmas", "year": "2021", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Jolly_(Christmas_2021)", "urlLabel": "Fan wiki", "kind": "Dressed as Santa"}'::jsonb),
  ('jubilee-2021', '{"name": "Jubilee", "season": "christmas", "year": "2021", "kind": "Drummer", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Jubilee", "urlLabel": "Fan wiki"}'::jsonb),
  ('lyric-2021', '{"name": "Lyric", "season": "christmas", "year": "2021", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "beanie", "accent": "#E0525B", "kind": "Scarf & Wreath Red", "url": "https://target-birds.fandom.com/wiki/Lyric", "urlLabel": "Fan wiki"}'::jsonb),
  ('nippy-other', '{"name": "Nippy", "season": "christmas", "source": "wiki", "body": "#F4A6C0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Nippy", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Sled and Stocking Hat Red", "line": "Wondershop"}'::jsonb),
  ('rime-other', '{"name": "Rime", "season": "christmas", "source": "wiki", "body": "#FFD166", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Rime", "urlLabel": "Fan wiki", "acc": "", "year": "2021", "kind": "Snowflake Scarf & Skates", "line": "Wondershop"}'::jsonb),
  ('tinsel-2021', '{"name": "Tinsel", "season": "christmas", "year": "2021", "kind": "Dressed as Tree", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Tinsel_(Christmas_2021)", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection.", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('tundra-2021', '{"name": "Tundra", "season": "christmas", "year": "2021", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Tundra", "urlLabel": "Fan wiki", "kind": "Dressed as Snowman"}'::jsonb),
  ('fuchsia-2020', '{"name": "Fuchsia", "season": "valentine", "year": "2020", "kind": "Pink Hawaiian with lei", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Fuchsia", "urlLabel": "Fan wiki"}'::jsonb),
  ('peabo-2020', '{"name": "Peabo", "season": "valentine", "year": "2020", "kind": "Peacock", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Peabo", "urlLabel": "Fan wiki"}'::jsonb),
  ('preener-2020', '{"name": "Preener", "season": "valentine", "year": "2020", "kind": "Peacock", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('yucca-2020', '{"name": "Yucca", "season": "valentine", "year": "2020", "kind": "Love bird", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('laddie-2020', '{"name": "Laddie", "season": "stpatricks", "year": "2020", "line": "Spritz", "source": "wiki", "body": "#E0525B", "acc": "tophat", "accent": "#2FA35B", "url": "https://www.ebay.com/itm/205461888039", "urlLabel": "Source"}'::jsonb),
  ('lucky-2020', '{"name": "Lucky", "season": "stpatricks", "year": "2020", "kind": "''Kiss Me'' rainbow", "line": "Spritz", "source": "wiki", "body": "#F2A65A", "acc": "lips", "accent": "#2FA35B", "url": "https://poshmark.com/listing/Target-Featherly-Friends-Bird-2020-Lucky-St-Patricks-Day-669b087bd253f12f6b51fba5", "urlLabel": "Source"}'::jsonb),
  ('rainn-2020', '{"name": "Rainn", "season": "spring", "year": "2020", "kind": "Crown (Easter)", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "crown", "accent": "#6DBF6A", "url": "https://www.ebay.com/itm/176513645121", "urlLabel": "Source"}'::jsonb),
  ('skylar-other', '{"name": "Skyler", "season": "spring", "source": "wiki", "body": "#3A3245", "accent": "#6DBF6A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2020"}'::jsonb),
  ('stormy-2025', '{"name": "Stormy", "season": "spring", "year": "2020", "kind": "Anniversary Collection", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "beanie", "accent": "#6DBF6A", "url": "https://www.mercari.com/us/brand/6241/657/", "urlLabel": "Source", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('bonesy-2020', '{"name": "Bonesy", "season": "halloween", "year": "2020", "kind": "Skeleton", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "bones", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Bonesy", "urlLabel": "Fan wiki"}'::jsonb),
  ('clipper-2020', '{"name": "Clipper", "season": "halloween", "year": "2020", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Clipper_(Halloween_2020)", "urlLabel": "Fan wiki", "kind": "Pirate"}'::jsonb),
  ('ferris-2020', '{"name": "Ferris", "season": "halloween", "year": "2020", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#FFD166", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Ferris", "urlLabel": "Fan wiki", "kind": "Pumpkin"}'::jsonb),
  ('jouster-other', '{"name": "Jouster", "season": "halloween", "source": "wiki", "body": "#9C8BE0", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Jouster", "urlLabel": "Fan wiki", "acc": "", "year": "2020", "kind": "Knight", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('juliote-other', '{"name": "Juliote", "season": "halloween", "source": "wiki", "body": "#6FB7E0", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Juliote", "urlLabel": "Fan wiki", "acc": "", "year": "2020", "kind": "Princess", "line": "Hyde and EEK! Boutique"}'::jsonb),
  ('spella-2025', '{"name": "Spella", "season": "halloween", "year": "2020", "kind": "Witch with gold trim (Anniversary Collection)", "line": "Wondershop", "source": "wiki", "body": "#FFD166", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Spella", "urlLabel": "Fan wiki", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('amorosa-2020', '{"name": "Amorosa", "season": "muertos", "year": "2020", "kind": "Female Día de Muertos", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Amorosa", "urlLabel": "Fan wiki", "body": "#3A3245", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('caballero-2020', '{"name": "Caballero", "season": "muertos", "year": "2020", "kind": "Male Día de Muertos", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Caballero", "urlLabel": "Fan wiki", "body": "#3A3245", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('recuerdo-2020', '{"name": "Recuerdo", "season": "muertos", "year": "2020", "kind": "Skeleton Día de Muertos", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Recuerdo", "urlLabel": "Fan wiki", "body": "#3A3245", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('filbert-other', '{"name": "Filbert", "season": "fall", "source": "wiki", "body": "#8D7A6A", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Filbert_(Harvest_2020)", "urlLabel": "Fan wiki", "acc": "", "year": "2020", "kind": "Green", "line": "Spritz"}'::jsonb),
  ('maple-2020', '{"name": "Maple", "season": "fall", "year": "2020", "kind": "Fall harvest", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "vest", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Maple", "urlLabel": "Fan wiki"}'::jsonb),
  ('spruce-2020', '{"name": "Spruce", "season": "fall", "year": "2020", "kind": "Autumn/Thanksgiving", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "snow", "accent": "#E8873A", "url": "https://target-birds.fandom.com/wiki/Spruce", "urlLabel": "Fan wiki"}'::jsonb),
  ('amber-2020', '{"name": "Amber", "season": "christmas", "year": "2020", "kind": "Winter (gray/white)", "line": "Wondershop", "source": "wiki", "body": "#B9B4C4", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Amber", "urlLabel": "Fan wiki"}'::jsonb),
  ('cornice-2020', '{"name": "Cornice", "season": "christmas", "year": "2020", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Cornice", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('frost-2020', '{"name": "Frost", "season": "christmas", "year": "2020", "kind": "White (winter)", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Frost", "urlLabel": "Fan wiki"}'::jsonb),
  ('klaus-other', '{"name": "Klaus", "season": "christmas", "source": "wiki", "body": "#F5F1EA", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Klaus", "urlLabel": "Fan wiki", "acc": "", "year": "2020"}'::jsonb),
  ('mikkel-2020', '{"name": "Mikkel", "season": "christmas", "year": "2020", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Mikkel", "urlLabel": "Fan wiki", "kind": "Nutcracker"}'::jsonb),
  ('pere-2020', '{"name": "Pere", "season": "christmas", "year": "2020", "kind": "Reindeer Ears", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Pere", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('piton-2020', '{"name": "Piton", "season": "christmas", "year": "2020", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Piton", "urlLabel": "Fan wiki", "body": "#6FB7E0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('primrose-winter', '{"name": "Primrose", "season": "christmas", "kind": "Winter series, grey hat", "line": "Wondershop", "source": "wiki", "body": "#F4A6C0", "acc": "beanie", "url": "https://target-birds.fandom.com/wiki/Primrose", "urlLabel": "Fan wiki", "accent": "#E0525B", "year": "2020"}'::jsonb),
  ('powell-2020', '{"name": "Powell", "season": "christmas", "year": "2020", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Powell", "urlLabel": "Fan wiki", "kind": "White Puffer Jacket & Santa Hat", "about": "Re-released in the 2024 Reunion Collection."}'::jsonb),
  ('rocky-2020', '{"name": "Rocky", "season": "christmas", "year": "2020", "kind": "Winter", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Rocky", "urlLabel": "Fan wiki"}'::jsonb),
  ('sorrel-other', '{"name": "Sorrel", "season": "christmas", "source": "wiki", "body": "#F4A6C0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Sorrel", "urlLabel": "Fan wiki", "acc": "", "year": "2020", "kind": "White Faux Fur Hat & Pink Scarf", "line": "Wondershop"}'::jsonb),
  ('yule-2020', '{"name": "Yule", "season": "christmas", "year": "2020", "kind": "Tree", "line": "Wondershop", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Yule", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('buttercup-2019', '{"name": "Buttercup", "season": "valentine", "year": "2019", "kind": "Love bird (boy)", "line": "Spritz", "source": "wiki", "body": "#F5F1EA", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Buttercup", "urlLabel": "Fan wiki"}'::jsonb),
  ('sweetpea-2019', '{"name": "Sweetpea", "season": "valentine", "year": "2019", "kind": "Love bird (girl)", "line": "Spritz", "source": "wiki", "body": "#FFD166", "acc": "heart", "accent": "#F06A8F", "url": "https://target-birds.fandom.com/wiki/Sweetpea", "urlLabel": "Fan wiki"}'::jsonb),
  ('arlo-2019', '{"name": "Arlo", "season": "spring", "year": "2019", "kind": "With glasses", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Arlo", "urlLabel": "Fan wiki"}'::jsonb),
  ('booker-2019', '{"name": "Booker", "season": "spring", "year": "2019", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Booker", "urlLabel": "Fan wiki", "kind": "Soft Blue"}'::jsonb),
  ('cora-2019', '{"name": "Cora", "season": "spring", "year": "2019", "kind": "Soft Pink", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Cora", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('goldy-2019', '{"name": "Goldy", "season": "stpatricks", "year": "2019", "kind": "Green leprechaun hat and beard", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "beanie", "accent": "#2FA35B", "url": "https://target-birds.fandom.com/wiki/Goldy", "urlLabel": "Fan wiki", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('cackles-2019', '{"name": "Cackles", "season": "halloween", "year": "2019", "kind": "Witch", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Cackles", "urlLabel": "Fan wiki"}'::jsonb),
  ('clawson-other', '{"name": "Clawson", "season": "halloween", "source": "wiki", "body": "#3A3245", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2019"}'::jsonb),
  ('jackster-2019', '{"name": "Jackster", "season": "halloween", "year": "2019", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#6FB7E0", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('magic-2019', '{"name": "Magic", "season": "halloween", "year": "2019", "kind": "Cat", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Magic", "urlLabel": "Fan wiki"}'::jsonb),
  ('spookster-2019', '{"name": "Spookster", "season": "halloween", "year": "2019", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#9C8BE0", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Spookster", "urlLabel": "Fan wiki", "kind": "Pumpkin Mask"}'::jsonb),
  ('twobert-other', '{"name": "Twobert", "season": "halloween", "source": "wiki", "body": "#F5F1EA", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2019"}'::jsonb),
  ('alma-2019', '{"name": "Alma", "season": "muertos", "year": "2019", "kind": "Día de Muertos", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F5F1EA", "acc": "flowercrown", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Alma", "urlLabel": "Fan wiki"}'::jsonb),
  ('garibaldi-2019', '{"name": "Garibaldi", "season": "muertos", "year": "2019", "kind": "Día de Muertos Guitar Player", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Garibaldi", "urlLabel": "Fan wiki", "body": "#3A3245", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('viajero-2019', '{"name": "Viajero", "season": "muertos", "year": "2019", "kind": "Día de Muertos", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#9C8BE0", "acc": "wave", "accent": "#E25FA2", "url": "https://target-birds.fandom.com/wiki/Viajero", "urlLabel": "Fan wiki"}'::jsonb),
  ('bramble-2019', '{"name": "Bramble", "season": "fall", "year": "2019", "source": "wiki", "body": "#6FB7E0", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('saffron-other', '{"name": "Saffron", "season": "fall", "source": "wiki", "body": "#8D7A6A", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2019"}'::jsonb),
  ('wheatly-other', '{"name": "Wheatly", "season": "fall", "source": "wiki", "body": "#8D7A6A", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2019"}'::jsonb),
  ('bayham-other', '{"name": "Bayham", "season": "christmas", "source": "wiki", "body": "#6FB7E0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bayham", "urlLabel": "Fan wiki", "acc": "", "year": "2019"}'::jsonb),
  ('cheeryble-2019', '{"name": "Cheeryble", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Cheeryble", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection.", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('clove-other', '{"name": "Clove", "season": "christmas", "source": "wiki", "body": "#9C8BE0", "acc": "heart", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Clove", "urlLabel": "Fan wiki", "year": "2019"}'::jsonb),
  ('dawkins-2019', '{"name": "Dawkins", "season": "christmas", "year": "2019", "line": "Wondershop", "source": "wiki", "body": "#8D7A6A", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Dawkins", "urlLabel": "Fan wiki"}'::jsonb),
  ('dazzle-2019', '{"name": "Dazzle", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Dazzle", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('deckard-2019', '{"name": "Deckard", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Deckard", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('filbert-2019', '{"name": "Filbert", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Filbert", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('hazel-2019', '{"name": "Hazel", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Hazel", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('holly-2019', '{"name": "Holly", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Holly", "urlLabel": "Fan wiki", "body": "#F2A65A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('langdale-2019', '{"name": "Langdale", "season": "christmas", "year": "2019", "kind": "Reindeer", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "horns", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Langdale", "urlLabel": "Fan wiki"}'::jsonb),
  ('pepper-other', '{"name": "Pepper", "season": "christmas", "source": "wiki", "body": "#E0525B", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Pepper", "urlLabel": "Fan wiki", "acc": "", "year": "2019"}'::jsonb),
  ('razzle-2019', '{"name": "Razzle", "season": "christmas", "year": "2019", "line": "Wondershop", "source": "wiki", "body": "#FFD166", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Razzle", "urlLabel": "Fan wiki"}'::jsonb),
  ('rowan-2019', '{"name": "Rowan", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Rowan_(Christmas_2019)", "urlLabel": "Fan wiki", "body": "#F4A6C0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('rue-2019', '{"name": "Rue", "season": "christmas", "year": "2019", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Rue", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('spruce-2019', '{"name": "Spruce", "season": "christmas", "year": "2019", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Spruce_(Christmas_2019)", "urlLabel": "Fan wiki"}'::jsonb),
  ('yarrow-2019', '{"name": "Yarrow", "season": "christmas", "year": "2019", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Yarrow", "urlLabel": "Fan wiki"}'::jsonb),
  ('ami-2018', '{"name": "Ami", "season": "valentine", "year": "2018", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#F06A8F"}'::jsonb),
  ('beau-2018', '{"name": "Beau", "season": "valentine", "year": "2018", "line": "Spritz", "source": "wiki", "body": "#9C8BE0", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('joli-2018', '{"name": "Joli", "season": "valentine", "year": "2018", "line": "Spritz", "source": "wiki", "body": "#8D7A6A", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/196201364571", "urlLabel": "Source"}'::jsonb),
  ('daisy-2018', '{"name": "Daisy", "season": "spring", "year": "2018", "kind": "Yellow", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Daisy", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('poppy-2018', '{"name": "Poppy", "season": "spring", "year": "2018", "kind": "Blue", "line": "Spritz", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Poppy_(Easter_2018)", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('tulip-2018', '{"name": "Tulip", "season": "spring", "year": "2018", "kind": "Pink", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "flower", "accent": "#6DBF6A", "url": "https://target-birds.fandom.com/wiki/Tulip", "urlLabel": "Fan wiki"}'::jsonb),
  ('amethyst-2018', '{"name": "Amethyst", "season": "halloween", "year": "2018", "kind": "Vampire", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#7CC6A4", "acc": "witch", "accent": "#8A5CC9", "url": "https://target-birds.fandom.com/wiki/Amethyst", "urlLabel": "Fan wiki"}'::jsonb),
  ('barney-2018', '{"name": "Barney", "season": "halloween", "year": "2018", "kind": "Owl", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('brewster-other', '{"name": "Brewster", "season": "halloween", "source": "wiki", "body": "#6FB7E0", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2018"}'::jsonb),
  ('brisby-2018', '{"name": "Brisby", "season": "halloween", "year": "2018", "kind": "Raven", "source": "wiki", "body": "#6FB7E0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('buzz-2018', '{"name": "Buzz", "season": "halloween", "year": "2018", "kind": "Kneeling Vulture", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('citrine-2018', '{"name": "Citrine", "season": "halloween", "year": "2018", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('dapper-2018', '{"name": "Dapper", "season": "halloween", "year": "2018", "kind": "Black bird / crow / raven", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "tophat", "accent": "#8A5CC9"}'::jsonb),
  ('patches-2018', '{"name": "Patches", "season": "halloween", "year": "2018", "kind": "Pumpkin", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#3A3245", "acc": "pumpkin", "accent": "#8A5CC9", "url": "https://poshmark.com/listing/Target-Spritz-fabric-bird-pumpkin-Patches-Halloween-Hyde-Eek-2018-66d5eef2b142f3adf6db7ccc", "urlLabel": "Source"}'::jsonb),
  ('peridot-2018', '{"name": "Peridot", "season": "halloween", "year": "2018", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('sapphire-2018', '{"name": "Sapphire", "season": "halloween", "year": "2018", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('scraps-2018', '{"name": "Scraps", "season": "halloween", "year": "2018", "kind": "Standing Vulture", "source": "wiki", "body": "#E0525B", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('speckles-other', '{"name": "Speckles", "season": "halloween", "source": "wiki", "body": "#6FB7E0", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2018", "kind": "Raven"}'::jsonb),
  ('whiskers-other', '{"name": "Whiskers", "season": "halloween", "source": "wiki", "body": "#8D7A6A", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2018"}'::jsonb),
  ('allegre-2018', '{"name": "Allegre", "season": "muertos", "year": "2018", "source": "wiki", "body": "#6FB7E0", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('flora-2018', '{"name": "Flora", "season": "muertos", "year": "2018", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('silbador-2018', '{"name": "Silbador", "season": "muertos", "year": "2018", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('barney-2018-fall', '{"name": "Barney", "season": "fall", "year": "2018", "kind": "Owl", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('hops-other', '{"name": "Hops", "season": "fall", "source": "wiki", "body": "#6FB7E0", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2018"}'::jsonb),
  ('juniper-other', '{"name": "Juniper", "season": "fall", "source": "wiki", "body": "#8D7A6A", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2018"}'::jsonb),
  ('oats-2018', '{"name": "Oats", "season": "fall", "year": "2018", "source": "wiki", "body": "#F2A65A", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('sunflower-2018', '{"name": "Sunflower", "season": "fall", "year": "2018", "kind": "Fall harvest", "line": "Spritz", "source": "wiki", "body": "#6FB7E0", "acc": "vest", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source"}'::jsonb),
  ('alder-2018', '{"name": "Alder", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Alder", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('aquilo-other', '{"name": "Aquilo", "season": "christmas", "source": "wiki", "body": "#E0525B", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Aquilo", "urlLabel": "Fan wiki", "acc": "", "year": "2018"}'::jsonb),
  ('forrest-2018', '{"name": "Forrest", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Forrest", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('hansy-2018', '{"name": "Hansy", "season": "christmas", "year": "2018", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Hansy", "urlLabel": "Fan wiki"}'::jsonb),
  ('isley-christmas', '{"name": "Isley", "season": "christmas", "line": "Wondershop", "source": "wiki", "body": "#F2A65A", "acc": "bow", "accent": "#E0525B", "year": "2018", "url": "https://target-birds.fandom.com/wiki/Isley", "urlLabel": "Fan wiki"}'::jsonb),
  ('juniper-2018', '{"name": "Juniper", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Juniper_(Christmas_2018)", "urlLabel": "Fan wiki", "body": "#6FB7E0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('maus-other', '{"name": "Maus", "season": "christmas", "source": "wiki", "body": "#7CC6A4", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Maus", "urlLabel": "Fan wiki", "acc": "", "year": "2018"}'::jsonb),
  ('nieva-2018', '{"name": "Nieva", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Nieva", "urlLabel": "Fan wiki", "body": "#6FB7E0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('noelle-other', '{"name": "Noelle", "season": "christmas", "source": "wiki", "body": "#FFD166", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Noelle", "urlLabel": "Fan wiki", "acc": "", "year": "2018"}'::jsonb),
  ('peary-2024', '{"name": "Peary", "season": "christmas", "year": "2018", "kind": "Reunion Collection (hatched 2018)", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Peary", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection."}'::jsonb),
  ('rose-2018', '{"name": "Rose", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Rose", "urlLabel": "Fan wiki", "body": "#6FB7E0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('schatzi-other', '{"name": "Schatzi", "season": "christmas", "source": "wiki", "body": "#9C8BE0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Schatzi", "urlLabel": "Fan wiki", "acc": "", "year": "2018"}'::jsonb),
  ('toby-2018', '{"name": "Toby", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Toby", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('zinny-2018', '{"name": "Zinny", "season": "christmas", "year": "2018", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Zinny", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('george-2017', '{"name": "George", "season": "valentine", "year": "2017", "line": "Spritz", "source": "wiki", "body": "#7CC6A4", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/176215167050", "urlLabel": "Source"}'::jsonb),
  ('rosie-2017', '{"name": "Rosie", "season": "valentine", "year": "2017", "kind": "Pink and red", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "heart", "accent": "#F06A8F", "url": "https://www.ebay.com/itm/196201364571", "urlLabel": "Source"}'::jsonb),
  ('blossom-2017-2017', '{"name": "Blossom", "season": "spring", "year": "2017", "kind": "Pink with pearls", "line": "Spritz", "source": "wiki", "body": "#F4A6C0", "acc": "flower", "accent": "#6DBF6A"}'::jsonb),
  ('melody-2017', '{"name": "Melody", "season": "spring", "year": "2017", "source": "wiki", "body": "#F2A65A", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('sprout-2017', '{"name": "Sprout", "season": "spring", "year": "2017", "source": "wiki", "body": "#F2A65A", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('tweet-2017', '{"name": "Tweet", "season": "spring", "year": "2017", "source": "wiki", "body": "#F2A65A", "acc": "", "accent": "#6DBF6A"}'::jsonb),
  ('carver-2017', '{"name": "Carver", "season": "halloween", "year": "2017", "kind": "Pumpkin", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#8D7A6A", "acc": "pumpkin", "accent": "#8A5CC9", "url": "https://poshmark.com/style-tag/Target%20Birds", "urlLabel": "Source"}'::jsonb),
  ('haunter-2017', '{"name": "Haunter", "season": "halloween", "year": "2017", "kind": "Ghost", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#6FB7E0", "acc": "witch", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/405149649595", "urlLabel": "Source"}'::jsonb),
  ('hissy-2017', '{"name": "Hissy", "season": "halloween", "year": "2017", "kind": "Cat", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#F2A65A", "acc": "catears", "accent": "#8A5CC9", "url": "https://poshmark.com/listing/Target-2017-HISSY-CAT-Hyde-and-Eek-Halloween-Bird-64bc93d0253a8c175f77b368", "urlLabel": "Source"}'::jsonb),
  ('seeker-2017', '{"name": "Seeker", "season": "halloween", "year": "2017", "source": "wiki", "about": "Re-released in 2025 in the 2017 Anniversary 3-pack.", "body": "#E0525B", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('skelly-2025', '{"name": "Skelly", "season": "halloween", "year": "2017", "kind": "Skeleton (2017 reunion)", "line": "Hyde and EEK! Boutique", "source": "wiki", "body": "#6FB7E0", "acc": "bones", "accent": "#8A5CC9", "url": "https://www.ebay.com/itm/167910168944", "urlLabel": "Source", "about": "Re-released in 2025 in the 2017 Anniversary 3-pack."}'::jsonb),
  ('stitch-2017', '{"name": "Stitch", "season": "halloween", "year": "2017", "source": "wiki", "about": "Re-released in 2025 in the 2017 Anniversary 3-pack.", "body": "#E0525B", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('cantante-2025', '{"name": "Cantante", "season": "muertos", "year": "2017", "kind": "Día de Muertos sugar skull (Anniversary Collection)", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "flowercrown", "accent": "#E25FA2", "url": "https://www.ebay.com/itm/136929969950", "urlLabel": "Source", "about": "Re-released in the 2025 Anniversary Collection."}'::jsonb),
  ('guitarrista-2017', '{"name": "Guitarrista", "season": "muertos", "year": "2017", "source": "wiki", "body": "#FFD166", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('trompetista-2017', '{"name": "Trompetista", "season": "muertos", "year": "2017", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#E25FA2"}'::jsonb),
  ('baker-other', '{"name": "Baker", "season": "fall", "source": "wiki", "body": "#3A3245", "acc": "pie", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "year": "2017"}'::jsonb),
  ('copper-other', '{"name": "Copper", "season": "fall", "source": "wiki", "body": "#3A3245", "accent": "#E8873A", "url": "https://www.ebay.com/itm/235742790161", "urlLabel": "Source", "acc": "", "year": "2017"}'::jsonb),
  ('farmer-2017', '{"name": "Farmer", "season": "fall", "year": "2017", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('fisher-2017', '{"name": "Fisher", "season": "fall", "year": "2017", "source": "wiki", "body": "#F2A65A", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('hazel-2017', '{"name": "Hazel", "season": "fall", "year": "2017", "source": "wiki", "body": "#7CC6A4", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('rusty-2017', '{"name": "Rusty", "season": "fall", "year": "2017", "source": "wiki", "body": "#F4A6C0", "acc": "", "accent": "#E8873A"}'::jsonb),
  ('aspen-other', '{"name": "Aspen", "season": "christmas", "source": "wiki", "body": "#E0525B", "acc": "wave", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Aspen", "urlLabel": "Fan wiki", "year": "2017"}'::jsonb),
  ('bradford-other', '{"name": "Bradford", "season": "christmas", "source": "wiki", "body": "#3A3245", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bradford", "urlLabel": "Fan wiki", "acc": "", "year": "2017"}'::jsonb),
  ('briggs-other', '{"name": "Briggs", "season": "christmas", "source": "wiki", "body": "#3A3245", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Briggs", "urlLabel": "Fan wiki", "acc": "", "year": "2017"}'::jsonb),
  ('digby-other', '{"name": "Digby", "season": "christmas", "source": "wiki", "body": "#6FB7E0", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Digby", "urlLabel": "Fan wiki", "acc": "", "year": "2017"}'::jsonb),
  ('kicker-2017', '{"name": "Kicker", "season": "christmas", "year": "2017", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Kicker", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('parker-2017', '{"name": "Parker", "season": "christmas", "year": "2017", "kind": "Hoodie with candy cane", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Parker", "urlLabel": "Fan wiki"}'::jsonb),
  ('piper-2024', '{"name": "Piper", "season": "christmas", "year": "2017", "kind": "Snowboarding; Reunion Collection re-release (hatched 2017)", "line": "Wondershop", "source": "wiki", "body": "#F5F1EA", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Piper", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection."}'::jsonb),
  ('quincy-2017', '{"name": "Quincy", "season": "christmas", "year": "2017", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Quincy", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('sierra-christmas', '{"name": "Sierra", "season": "christmas", "kind": "Fur (winter)", "line": "Wondershop", "source": "wiki", "body": "#7CC6A4", "acc": "snow", "accent": "#E0525B", "year": "2017", "url": "https://target-birds.fandom.com/wiki/Sierra", "urlLabel": "Fan wiki"}'::jsonb),
  ('snoozer-2017', '{"name": "Snoozer", "season": "christmas", "year": "2017", "kind": "PJs and nightcap", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Snoozer", "urlLabel": "Fan wiki"}'::jsonb),
  ('tahoe-2017', '{"name": "Tahoe", "season": "christmas", "year": "2017", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Tahoe", "urlLabel": "Fan wiki", "body": "#9C8BE0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('whistler-christmas', '{"name": "Whistler", "season": "christmas", "kind": "Fur (winter)", "line": "Wondershop", "source": "wiki", "body": "#6FB7E0", "acc": "snow", "accent": "#E0525B", "year": "2017", "url": "https://target-birds.fandom.com/wiki/Whistler", "urlLabel": "Fan wiki"}'::jsonb),
  ('mummy-2016', '{"name": "Mummy", "season": "halloween", "year": "2016", "source": "wiki", "body": "#9C8BE0", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('witch-2016', '{"name": "Witch", "season": "halloween", "year": "2016", "source": "wiki", "body": "#7CC6A4", "acc": "", "accent": "#8A5CC9"}'::jsonb),
  ('blazer-other', '{"name": "Blazer", "season": "christmas", "source": "wiki", "body": "#F2A65A", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Blazer", "urlLabel": "Fan wiki", "acc": "", "year": "2016"}'::jsonb),
  ('blizzard-2016', '{"name": "Blizzard", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Blizzard", "urlLabel": "Fan wiki", "body": "#FFD166", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('bucky-2016', '{"name": "Bucky", "season": "christmas", "year": "2016", "kind": "Reindeer antlers", "line": "Wondershop", "source": "wiki", "body": "#F2A65A", "acc": "horns", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Bucky", "urlLabel": "Fan wiki"}'::jsonb),
  ('camper-2016', '{"name": "Camper", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Camper", "urlLabel": "Fan wiki", "body": "#8D7A6A", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('clipper-2016', '{"name": "Clipper", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Clipper_(Christmas_2016)", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('flurry-2016', '{"name": "Flurry", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Flurry_(Christmas_2016)", "urlLabel": "Fan wiki", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('jolly-2016', '{"name": "Jolly", "season": "christmas", "year": "2016", "kind": "Santa Claus", "line": "Wondershop", "source": "wiki", "body": "#3A3245", "acc": "santa", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Jolly", "urlLabel": "Fan wiki"}'::jsonb),
  ('glacier-2016', '{"name": "Glacier", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Glacier", "urlLabel": "Fan wiki", "body": "#7CC6A4", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('roller-2016', '{"name": "Roller", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Roller", "urlLabel": "Fan wiki", "about": "Re-released in the 2024 Reunion Collection.", "body": "#E0525B", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('scout-2016', '{"name": "Scout", "season": "christmas", "year": "2016", "kind": "Winter", "line": "Wondershop", "source": "wiki", "body": "#9C8BE0", "acc": "snow", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Scout", "urlLabel": "Fan wiki"}'::jsonb),
  ('tinker-2016', '{"name": "Tinker", "season": "christmas", "year": "2016", "source": "wiki", "url": "https://target-birds.fandom.com/wiki/Tinker", "urlLabel": "Fan wiki", "body": "#6FB7E0", "acc": "", "accent": "#E0525B"}'::jsonb),
  ('trapper-2016', '{"name": "Trapper", "season": "christmas", "year": "2016", "kind": "Plaid red hat", "line": "Wondershop", "source": "wiki", "body": "#E0525B", "acc": "beanie", "accent": "#E0525B", "url": "https://target-birds.fandom.com/wiki/Trapper_(Christmas_2016)", "urlLabel": "Fan wiki"}'::jsonb),
  ('vim-2026', '{"name": "Vim", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#E0525B", "acc": "santa", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-vim-39-fabric-bird-decor-wondershop-8482/-/A-95013606", "urlLabel": "See it on Target", "accent": "#E0525B", "img": "https://target.scene7.com/is/image/Target/GUEST_19c180d0-778e-4418-853f-4cbc91469fae", "about": "Red scarf and blue beanie, holding a candy cane. 7.5 in tall. (From Target''s product listing.)"}'::jsonb),
  ('mokki-2026', '{"name": "Mokki", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#8D7A6A", "acc": "beanie", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-mokki-39-fabric-bird-decor-wondershop-8482/-/A-95013648", "urlLabel": "See it on Target", "accent": "#E0525B", "img": "https://target.scene7.com/is/image/Target/GUEST_33d6755f-b5d8-4c34-9244-86b1ac41f94d", "about": "Wears a red balaclava and plaid skirt. 6 in tall. (From Target''s product listing.)"}'::jsonb),
  ('pep-2026', '{"name": "Pep", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#7CC6A4", "acc": "scarf", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-pep-39-fabric-bird-decor-wondershop-8482/-/A-95013837", "urlLabel": "See it on Target", "accent": "#E0525B", "img": "https://target.scene7.com/is/image/Target/GUEST_5b8ce707-83a8-4ebd-991a-0f8e9ed2e1a0", "about": "Blue bird in a red beanie, white scarf and red jacket. 7 in tall. (From Target''s product listing.)"}'::jsonb),
  ('bobbin-2026', '{"name": "Bobbin", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#6FB7E0", "acc": "beanie", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-bobbin-39-fabric-bird-decor-wondershop-8482/-/A-95013660", "urlLabel": "See it on Target", "accent": "#F5F1EA", "img": "https://target.scene7.com/is/image/Target/GUEST_00aedeff-8252-44a2-8c9f-f6f3593bd9a4", "about": "Red bird with plaid vest, bow tie, hat and a holiday wreath. 6.5 in tall. (From Target''s product listing.)"}'::jsonb),
  ('ray-2026', '{"name": "Ray", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#FFD166", "acc": "scarf", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-ray-39-fabric-bird-decor-wondershop-8482/-/A-95013835", "urlLabel": "See it on Target", "accent": "#6FB7E0", "img": "https://target.scene7.com/is/image/Target/GUEST_bd7dc8c6-f098-4493-8ada-a7a7810782c8", "about": "Cream bird in a blue beanie, blue ski goggles and silver hooded jacket. 7 in tall. (From Target''s product listing.)"}'::jsonb),
  ('sleet-2026', '{"name": "Sleet", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#F5F1EA", "acc": "snow", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-sleet-39-fabric-bird-decor-wondershop-8482/-/A-95013651", "urlLabel": "See it on Target", "accent": "#6FB7E0", "img": "https://target.scene7.com/is/image/Target/GUEST_8d1a3801-622a-4e51-8d93-111962819e17", "about": "White bird in a green beanie and scarf. 7 in tall. (From Target''s product listing.)"}'::jsonb),
  ('squall-2026', '{"name": "Squall", "season": "christmas", "year": "2026", "kind": "Fabric bird", "line": "Wondershop", "price": "$5", "source": "target", "body": "#6FB7E0", "acc": "snow", "url": "https://www.target.com/p/christmas-featherly-friends-8482-39-squall-39-fabric-bird-decor-wondershop-8482/-/A-95013655", "urlLabel": "See it on Target", "accent": "#F5F1EA", "img": "https://target.scene7.com/is/image/Target/GUEST_5aa31333-3c48-4f37-84b2-3130c0eff63c", "about": "Beige sweater and beanie, holding square craft bells. 7 in tall. (From Target''s product listing.)"}'::jsonb)
on conflict (id) do update set data = excluded.data, updated_at = now() where flocks_birds.data->>'source' is distinct from 'added';

-- The two starting flocks. Re-running never changes existing flocks.
insert into public.flocks_flocks (id, data) values
  ('flock-norma', '{"name": "Norma", "color": "#C24E33", "order": 1, "owned": {}, "wish": {}, "notes": {}}'::jsonb),
  ('flock-ashton', '{"name": "Ashton", "color": "#1E7A4F", "order": 2, "owned": {}, "wish": {}, "notes": {}}'::jsonb)
on conflict (id) do nothing;

-- Birds that were listed twice are merged into the record that stays: anyone's flock, wish list,
-- note, gift plan and family photo move with them. A bird taken off the list (no record to move to)
-- is removed only if nobody has it, wants it, or has a note or photo for it.
do $$
declare m record; f record; d jsonb; k text; g text;
begin
  for m in select * from (values
      ('bells-2024'::text, 'bells-2022'::text),
      ('bonjour-2024'::text, 'cherie-2024'::text),
      ('king-of-hearts-2024'::text, 'kingsley-2024'::text),
      ('queen-of-hearts-2024'::text, 'queenie-2024'::text),
      ('rocker-2024'::text, null::text),
      ('tinsel-2026'::text, 'tinzel-2026'::text)) as t(o, n) loop
    if m.n is null then
      delete from flocks_birds b where b.id = m.o and b.data->>'source' is distinct from 'added'
        and not exists (select 1 from flocks_flocks x where (x.data->'owned') ? m.o or (x.data->'wish') ? m.o or (x.data->'notes') ? m.o)
        and not exists (select 1 from flocks_photos p where p.id = m.o);
      continue;
    end if;
    if not exists (select 1 from flocks_birds where id = m.n) then continue; end if;
    for f in select id, data from flocks_flocks loop
      d := f.data;
      foreach k in array array['owned', 'wish', 'notes'] loop
        if jsonb_typeof(d->k) = 'object' and (d->k) ? m.o then
          if not ((d->k) ? m.n) then d := jsonb_set(d, array[k, m.n], d->k->m.o); end if;
          d := d #- array[k, m.o];
        end if;
      end loop;
      if jsonb_typeof(d->'gifts') = 'object' then
        for g in select jsonb_object_keys(f.data->'gifts') loop
          if jsonb_typeof(d->'gifts'->g) = 'object' and (d->'gifts'->g) ? m.o then
            if not ((d->'gifts'->g) ? m.n) then d := jsonb_set(d, array['gifts', g, m.n], d->'gifts'->g->m.o); end if;
            d := d #- array['gifts', g, m.o];
          end if;
        end loop;
      end if;
      if d is distinct from f.data then update flocks_flocks set data = d, updated_at = now() where id = f.id; end if;
    end loop;
    update flocks_photos set id = m.n where id = m.o and not exists (select 1 from flocks_photos where id = m.n);
    delete from flocks_photos where id = m.o;
    delete from flocks_birds where id = m.o and data->>'source' is distinct from 'added';
  end loop;
end $$;
