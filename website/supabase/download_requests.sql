-- Wren website: who downloaded which version. Run once in Supabase › SQL Editor.
-- The website's key (anon) can only add the signed-in person's own row. Nobody can read, change or
-- delete rows with it; you read the list in the Supabase dashboard (Table Editor) as the project owner.

create table if not exists public.download_requests (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  email       text not null check (char_length(email) between 3 and 254),
  name        text check (char_length(name) <= 120),
  version     text not null check (char_length(version) <= 40),
  unique (user_id, version)
);

alter table public.download_requests enable row level security;

-- Signed-in people may add a row for themselves only.
drop policy if exists "add own download" on public.download_requests;
create policy "add own download" on public.download_requests
  for insert to authenticated
  with check (auth.uid() = user_id);

-- No select, update or delete policies: with Row Level Security on, those are refused for everyone
-- except the project owner (service role / dashboard).
revoke all on public.download_requests from anon;
grant insert on public.download_requests to authenticated;
