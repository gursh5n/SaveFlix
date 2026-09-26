create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 32),
  avatar_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.username_changes (
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  changed_at timestamptz not null default now()
);

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  check (requester_id <> recipient_id)
);

create unique index if not exists friend_requests_unique_pair
  on public.friend_requests (least(requester_id, recipient_id), greatest(requester_id, recipient_id));
create index if not exists friend_requests_recipient_status
  on public.friend_requests (recipient_id, status);

create table if not exists public.recommendations (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  title_id text not null,
  message text not null default '',
  created_at timestamptz not null default now(),
  check (sender_id <> recipient_id)
);
create index if not exists recommendations_recipient_created
  on public.recommendations (recipient_id, created_at desc);

alter table public.profiles enable row level security;
alter table public.username_changes enable row level security;
alter table public.friend_requests enable row level security;
alter table public.recommendations enable row level security;

grant select on public.profiles to authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;
grant select, insert, delete on public.friend_requests to authenticated;
grant update (status) on public.friend_requests to authenticated;
grant select, insert on public.recommendations to authenticated;

 drop policy if exists "Read own profile" on public.profiles;
create policy "Read own profile" on public.profiles for select to authenticated
  using (id = (select auth.uid()));
drop policy if exists "Update own profile" on public.profiles;
create policy "Update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists "Read involved friend requests" on public.friend_requests;
create policy "Read involved friend requests" on public.friend_requests for select to authenticated
  using (requester_id = (select auth.uid()) or recipient_id = (select auth.uid()));
drop policy if exists "Send friend requests as self" on public.friend_requests;
create policy "Send friend requests as self" on public.friend_requests for insert to authenticated
  with check (requester_id = (select auth.uid()) and status = 'pending' and requester_id <> recipient_id);
drop policy if exists "Accept incoming friend requests" on public.friend_requests;
create policy "Accept incoming friend requests" on public.friend_requests for update to authenticated
  using (recipient_id = (select auth.uid()) and status = 'pending')
  with check (recipient_id = (select auth.uid()) and status = 'accepted');
drop policy if exists "Delete involved friend requests" on public.friend_requests;
create policy "Delete involved friend requests" on public.friend_requests for delete to authenticated
  using (requester_id = (select auth.uid()) or recipient_id = (select auth.uid()));

drop policy if exists "Read received recommendations" on public.recommendations;
create policy "Read received recommendations" on public.recommendations for select to authenticated
  using (recipient_id = (select auth.uid()));
drop policy if exists "Send recommendations to friends" on public.recommendations;
create policy "Send recommendations to friends" on public.recommendations for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and exists (
      select 1 from public.friend_requests f
      where f.status = 'accepted'
        and ((f.requester_id = sender_id and f.recipient_id = recommendations.recipient_id)
          or (f.recipient_id = sender_id and f.requester_id = recommendations.recipient_id))
    )
  );

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    lower(regexp_replace(coalesce(new.raw_user_meta_data ->> 'username', ''), '^@', '')),
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''), 'SaveFlix user')
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create or replace function public.change_username(new_username text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := auth.uid();
  normalized_username text := lower(regexp_replace(btrim(new_username), '^@', ''));
  recent_changes integer;
begin
  if caller_id is null then
    raise exception 'You must be signed in to change your username.' using errcode = '28000';
  end if;
  if normalized_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username must be 3-20 letters, numbers, or underscores.' using errcode = '22023';
  end if;
  perform 1 from public.profiles where id = caller_id for update;
  if not found then
    raise exception 'Profile not found.' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.profiles where id = caller_id and username = normalized_username) then
    raise exception 'That is already your username.' using errcode = '22023';
  end if;
  select count(*) into recent_changes
    from public.username_changes
    where profile_id = caller_id and changed_at > now() - interval '14 days';
  if recent_changes >= 2 then
    raise exception 'You can change your username only twice in a rolling 14-day period.' using errcode = 'P0001';
  end if;
  update public.profiles set username = normalized_username where id = caller_id;
  insert into public.username_changes (profile_id) values (caller_id);
  return normalized_username;
end;
$$;

create or replace function public.username_changes_remaining()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(0, 2 - count(*)::integer)
  from public.username_changes
  where profile_id = auth.uid() and changed_at > now() - interval '14 days';
$$;

create or replace function public.lookup_user_by_username(requested_username text)
returns table (id uuid, username text, display_name text, avatar_url text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from public.profiles p
  where auth.uid() is not null
    and p.username = lower(regexp_replace(btrim(requested_username), '^@', ''))
  limit 1;
$$;

create or replace function public.list_friends()
returns table (id uuid, username text, display_name text, avatar_url text)
language sql
stable
security definer
set search_path = ''
as $$
  select distinct p.id, p.username, p.display_name, p.avatar_url
  from public.friend_requests f
  join public.profiles p on p.id = case when f.requester_id = auth.uid() then f.recipient_id else f.requester_id end
  where f.status = 'accepted'
    and (f.requester_id = auth.uid() or f.recipient_id = auth.uid())
  order by p.username;
$$;

create or replace function public.list_friend_requests()
returns table (id uuid, username text, display_name text, is_incoming boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select f.id, p.username, p.display_name, f.recipient_id = auth.uid()
  from public.friend_requests f
  join public.profiles p on p.id = case when f.requester_id = auth.uid() then f.recipient_id else f.requester_id end
  where f.status = 'pending'
    and (f.requester_id = auth.uid() or f.recipient_id = auth.uid())
  order by f.created_at desc;
$$;

create or replace function public.get_friend_recommendations()
returns table (
  id uuid,
  title_id text,
  message text,
  created_at timestamptz,
  sender_username text,
  sender_display_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.title_id, r.message, r.created_at, p.username, p.display_name
  from public.recommendations r
  join public.profiles p on p.id = r.sender_id
  where r.recipient_id = auth.uid()
  order by r.created_at desc;
$$;

revoke all on function public.change_username(text) from public, anon;
revoke all on function public.username_changes_remaining() from public, anon;
revoke all on function public.lookup_user_by_username(text) from public, anon;
revoke all on function public.list_friends() from public, anon;
revoke all on function public.list_friend_requests() from public, anon;
revoke all on function public.get_friend_recommendations() from public, anon;
grant execute on function public.change_username(text) to authenticated;
grant execute on function public.username_changes_remaining() to authenticated;
grant execute on function public.lookup_user_by_username(text) to authenticated;
grant execute on function public.list_friends() to authenticated;
grant execute on function public.list_friend_requests() to authenticated;
grant execute on function public.get_friend_recommendations() to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 524288, array['image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public avatar reads" on storage.objects;
create policy "Public avatar reads" on storage.objects for select to public
  using (bucket_id = 'avatars');
drop policy if exists "Users upload own avatar" on storage.objects;
create policy "Users upload own avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "Users update own avatar" on storage.objects;
create policy "Users update own avatar" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "Users delete own avatar" on storage.objects;
create policy "Users delete own avatar" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
