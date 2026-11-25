-- Custom username + PIN auth for Schedy (no Supabase Auth, no emails, no rate limits).
-- Run this once in Supabase → SQL Editor. Safe to re-run.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.schedy_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  display_name text not null,
  pin_hash text not null,
  created_at timestamptz not null default now()
);

-- One row per device/session. Signing in on a new device does not log out the old one.
create table if not exists public.schedy_sessions (
  token_hash text primary key,
  account_id uuid not null references public.schedy_accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create index if not exists schedy_sessions_account_idx on public.schedy_sessions(account_id);

create table if not exists public.schedy_data (
  account_id uuid primary key references public.schedy_accounts(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Nobody reads/writes these tables directly; only the SECURITY DEFINER functions below.
alter table public.schedy_accounts enable row level security;
alter table public.schedy_sessions enable row level security;
alter table public.schedy_data enable row level security;
revoke all on public.schedy_accounts, public.schedy_sessions, public.schedy_data from anon, authenticated;

-- ---------- signup ----------
create or replace function public.schedy_signup(p_username text, p_display_name text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_norm text := lower(trim(p_username));
  v_name text := trim(p_display_name);
  v_id uuid;
  v_token text;
begin
  if v_norm !~ '^[a-z0-9_.-]{3,24}$' then
    raise exception 'INVALID_USERNAME';
  end if;
  if p_pin !~ '^[A-Za-z0-9]{4,12}$' then
    raise exception 'INVALID_PIN';
  end if;
  if exists (select 1 from schedy_accounts where username = v_norm) then
    raise exception 'USERNAME_TAKEN';
  end if;

  insert into schedy_accounts (username, display_name, pin_hash)
  values (v_norm, v_name, crypt(p_pin, gen_salt('bf', 10)))
  returning id into v_id;

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into schedy_sessions (token_hash, account_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), v_id, now() + interval '30 days');

  return jsonb_build_object(
    'id', v_id,
    'username', v_norm,
    'displayName', v_name,
    'token', v_token
  );
exception
  when unique_violation then
    raise exception 'USERNAME_TAKEN';
end;
$$;

-- ---------- login (creates a new session, keeps other devices logged in) ----------
create or replace function public.schedy_login(p_username text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  r schedy_accounts%rowtype;
  v_token text;
begin
  select * into r from schedy_accounts where username = lower(trim(p_username));
  if not found or crypt(coalesce(p_pin, ''), r.pin_hash) <> r.pin_hash then
    raise exception 'INVALID_CREDENTIALS';
  end if;

  delete from schedy_sessions where expires_at < now();

  v_token := encode(gen_random_bytes(32), 'hex');
  insert into schedy_sessions (token_hash, account_id, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), r.id, now() + interval '30 days');

  return jsonb_build_object(
    'id', r.id,
    'username', r.username,
    'displayName', r.display_name,
    'token', v_token
  );
end;
$$;

-- ---------- restore session ----------
create or replace function public.schedy_session(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_id uuid;
  v_username text;
  v_display text;
begin
  if p_token is null then return null; end if;

  select a.id, a.username, a.display_name into v_id, v_username, v_display
    from schedy_sessions s
    join schedy_accounts a on a.id = s.account_id
   where s.token_hash = encode(digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now();

  if not found then return null; end if;
  return jsonb_build_object('id', v_id, 'username', v_username, 'displayName', v_display);
end;
$$;

-- ---------- load schedule ----------
create or replace function public.schedy_load(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_id uuid;
  v_data jsonb;
begin
  select s.account_id into v_id
    from schedy_sessions s
   where s.token_hash = encode(digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now();
  if v_id is null then raise exception 'UNAUTHORIZED'; end if;

  select data into v_data from schedy_data where account_id = v_id;
  return jsonb_build_object('hasRow', v_data is not null, 'data', coalesce(v_data, '{}'::jsonb));
end;
$$;

-- ---------- save schedule ----------
create or replace function public.schedy_save(p_token text, p_data jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
declare
  v_id uuid;
begin
  select s.account_id into v_id
    from schedy_sessions s
   where s.token_hash = encode(digest(p_token, 'sha256'), 'hex')
     and s.expires_at > now();
  if v_id is null then raise exception 'UNAUTHORIZED'; end if;

  insert into schedy_data (account_id, data, updated_at)
  values (v_id, p_data, now())
  on conflict (account_id) do update set data = excluded.data, updated_at = now();
  return true;
end;
$$;

-- ---------- logout (only removes this device's session) ----------
create or replace function public.schedy_logout(p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions, pg_catalog
as $$
begin
  delete from schedy_sessions
   where token_hash = encode(digest(p_token, 'sha256'), 'hex');
end;
$$;

grant execute on function public.schedy_signup(text, text, text) to anon;
grant execute on function public.schedy_login(text, text) to anon;
grant execute on function public.schedy_session(text) to anon;
grant execute on function public.schedy_load(text) to anon;
grant execute on function public.schedy_save(text, jsonb) to anon;
grant execute on function public.schedy_logout(text) to anon;
