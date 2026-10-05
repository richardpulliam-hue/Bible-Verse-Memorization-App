-- Hidden Word: family login + progress sync
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run more than once.

create extension if not exists pgcrypto with schema extensions;

create table if not exists hw_family (
  id int primary key default 1 check (id = 1),
  name text not null,
  code_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists hw_members (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null default '#A3252B',
  pin_hash text not null,
  failed int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists hw_members_name_uq on hw_members (lower(name));

create table if not exists hw_sessions (
  token uuid primary key default gen_random_uuid(),
  member_id uuid not null references hw_members on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists hw_progress (
  member_id uuid not null references hw_members on delete cascade,
  verse_id text not null,
  box int not null,
  due int not null,
  n int not null,
  last int,
  updated_at timestamptz not null default now(),
  primary key (member_id, verse_id)
);

create table if not exists hw_days (
  member_id uuid not null references hw_members on delete cascade,
  day int not null,
  reviews int not null default 1,
  primary key (member_id, day)
);

-- Tables are locked down. The page can only use the functions below.
alter table hw_family   enable row level security;
alter table hw_members  enable row level security;
alter table hw_sessions enable row level security;
alter table hw_progress enable row level security;
alter table hw_days     enable row level security;

-- ---------- internal helpers ----------
create or replace function hw_check_code(p_code text) returns boolean
language sql security definer set search_path = public, extensions stable as $$
  select exists (select 1 from hw_family where code_hash = crypt(coalesce(p_code,''), code_hash));
$$;

create or replace function hw_me(p_token uuid) returns uuid
language sql security definer set search_path = public, extensions stable as $$
  select member_id from hw_sessions
  where token = p_token and created_at > now() - interval '365 days';
$$;

-- ---------- functions the page calls ----------
create or replace function hw_status() returns jsonb
language sql security definer set search_path = public, extensions stable as $$
  select jsonb_build_object('family', (select name from hw_family where id = 1));
$$;

create or replace function hw_create_family(p_name text, p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if exists (select 1 from hw_family) then
    return jsonb_build_object('error', 'This family is already set up. Enter the family code instead.');
  end if;
  if length(trim(coalesce(p_name,''))) = 0 then
    return jsonb_build_object('error', 'Enter a family name.');
  end if;
  if length(coalesce(p_code,'')) < 6 then
    return jsonb_build_object('error', 'Use a family code of at least 6 characters.');
  end if;
  insert into hw_family (id, name, code_hash) values (1, trim(p_name), crypt(p_code, gen_salt('bf')));
  return jsonb_build_object('ok', true, 'family', trim(p_name));
end $$;

create or replace function hw_members_list(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not hw_check_code(p_code) then
    return jsonb_build_object('error', 'That family code isn''t right.');
  end if;
  return jsonb_build_object('family', (select name from hw_family),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'color', color) order by created_at)
                         from hw_members), '[]'::jsonb));
end $$;

create or replace function hw_add_member(p_code text, p_name text, p_pin text, p_color text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_name text := trim(coalesce(p_name,''));
begin
  if not hw_check_code(p_code) then
    return jsonb_build_object('error', 'That family code isn''t right.');
  end if;
  if length(v_name) = 0 or length(v_name) > 30 then
    return jsonb_build_object('error', 'Enter a name up to 30 characters.');
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then
    return jsonb_build_object('error', 'The PIN must be 4 digits.');
  end if;
  if exists (select 1 from hw_members where lower(name) = lower(v_name)) then
    return jsonb_build_object('error', 'Someone already uses that name.');
  end if;
  insert into hw_members (name, color, pin_hash)
  values (v_name, coalesce(nullif(p_color,''), '#A3252B'), crypt(p_pin, gen_salt('bf')))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function hw_login(p_member uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m hw_members; v_token uuid;
begin
  select * into m from hw_members where id = p_member;
  if not found then
    return jsonb_build_object('error', 'That person was not found.');
  end if;
  if m.locked_until is not null and m.locked_until > now() then
    return jsonb_build_object('error', 'Too many wrong PINs. Try again in '
      || greatest(1, ceil(extract(epoch from (m.locked_until - now())) / 60))::int || ' min.');
  end if;
  if m.pin_hash = crypt(coalesce(p_pin,''), m.pin_hash) then
    update hw_members set failed = 0, locked_until = null where id = m.id;
    insert into hw_sessions (member_id) values (m.id) returning token into v_token;
    return jsonb_build_object('ok', true, 'token', v_token, 'id', m.id, 'name', m.name, 'color', m.color);
  end if;
  if m.failed + 1 >= 5 then
    update hw_members set failed = 0, locked_until = now() + interval '10 minutes' where id = m.id;
    return jsonb_build_object('error', 'Too many wrong PINs. Try again in 10 min.');
  end if;
  update hw_members set failed = m.failed + 1 where id = m.id;
  return jsonb_build_object('error', 'Wrong PIN. ' || (4 - m.failed) || case when 4 - m.failed = 1 then ' try left.' else ' tries left.' end);
end $$;

create or replace function hw_logout(p_token uuid) returns jsonb
language sql security definer set search_path = public, extensions as $$
  delete from hw_sessions where token = p_token;
  select jsonb_build_object('ok', true);
$$;

create or replace function hw_load(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := hw_me(p_token);
begin
  if v_id is null then
    return jsonb_build_object('error', 'signed_out');
  end if;
  return jsonb_build_object(
    'member', (select jsonb_build_object('id', id, 'name', name, 'color', color) from hw_members where id = v_id),
    'progress', coalesce((select jsonb_object_agg(verse_id, jsonb_build_object('box', box, 'due', due, 'n', n, 'last', last))
                          from hw_progress where member_id = v_id), '{}'::jsonb));
end $$;

create or replace function hw_save(p_token uuid, p_verse text, p_box int, p_due int, p_n int, p_last int, p_today int)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := hw_me(p_token);
begin
  if v_id is null then
    return jsonb_build_object('error', 'signed_out');
  end if;
  insert into hw_progress (member_id, verse_id, box, due, n, last, updated_at)
  values (v_id, left(p_verse, 80), p_box, p_due, p_n, p_last, now())
  on conflict (member_id, verse_id) do update
    set box = excluded.box, due = excluded.due, n = excluded.n, last = excluded.last, updated_at = now();
  insert into hw_days (member_id, day) values (v_id, p_today)
  on conflict (member_id, day) do update set reviews = hw_days.reviews + 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function hw_change_pin(p_token uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid := hw_me(p_token);
begin
  if v_id is null then return jsonb_build_object('error', 'signed_out'); end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then
    return jsonb_build_object('error', 'The PIN must be 4 digits.');
  end if;
  update hw_members set pin_hash = crypt(p_pin, gen_salt('bf')) where id = v_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function hw_board(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not hw_check_code(p_code) then
    return jsonb_build_object('error', 'That family code isn''t right.');
  end if;
  return jsonb_build_object('members', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id, 'name', m.name, 'color', m.color,
      'progress', coalesce((select jsonb_object_agg(p.verse_id, jsonb_build_object('box', p.box, 'due', p.due, 'n', p.n))
                            from hw_progress p where p.member_id = m.id), '{}'::jsonb),
      'days', coalesce((select jsonb_agg(d.day order by d.day desc)
                        from (select day from hw_days where member_id = m.id order by day desc limit 400) d), '[]'::jsonb)
    ) order by m.created_at)
    from hw_members m), '[]'::jsonb));
end $$;

-- Only these functions are callable from the page.
revoke all on function hw_check_code(text) from public, anon, authenticated;
revoke all on function hw_me(uuid) from public, anon, authenticated;
grant execute on function hw_status() to anon, authenticated;
grant execute on function hw_create_family(text, text) to anon, authenticated;
grant execute on function hw_members_list(text) to anon, authenticated;
grant execute on function hw_add_member(text, text, text, text) to anon, authenticated;
grant execute on function hw_login(uuid, text) to anon, authenticated;
grant execute on function hw_logout(uuid) to anon, authenticated;
grant execute on function hw_load(uuid) to anon, authenticated;
grant execute on function hw_save(uuid, text, int, int, int, int, int) to anon, authenticated;
grant execute on function hw_change_pin(uuid, text) to anon, authenticated;
grant execute on function hw_board(text) to anon, authenticated;
