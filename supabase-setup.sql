-- Run this once in Supabase → SQL Editor, then deploy.
-- It creates the profile table, the schedule table, row-level security,
-- a profile trigger, and enables Realtime for schedule updates.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.schedy_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.schedy_data enable row level security;

-- Profiles: each user can only see and edit their own profile.
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Schedule data: each user can only read/write their own row.
drop policy if exists "schedy_data_select_own" on public.schedy_data;
create policy "schedy_data_select_own" on public.schedy_data
  for select using (auth.uid() = user_id);

drop policy if exists "schedy_data_insert_own" on public.schedy_data;
create policy "schedy_data_insert_own" on public.schedy_data
  for insert with check (auth.uid() = user_id);

drop policy if exists "schedy_data_update_own" on public.schedy_data;
create policy "schedy_data_update_own" on public.schedy_data
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Automatically create a profile row when a user signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'username', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Enable Realtime so other devices see changes immediately.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'schedy_data'
  ) then
    alter publication supabase_realtime add table public.schedy_data;
  end if;
end $$;
