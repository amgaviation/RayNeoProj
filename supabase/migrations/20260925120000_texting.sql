-- BlueNudge texting: accounts, subscriptions and the outbox of scheduled texts.
--
-- The iPhone app computes each text reminder's upcoming occurrences (the same
-- code that shows "Next up") and hands them to sync_outbox(). A cron job calls
-- the send-due Edge Function every minute, which claims due rows with
-- claim_due_texts() and sends them through the SMS provider.
--
-- Clients can only read their own rows. Every write goes through the functions
-- below, which check the caller and the limits.

-- Tables ---------------------------------------------------------------------

create table public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  -- E.164, with the leading "+". Verified by the SMS code at sign-in.
  phone text not null default '',
  texts_paused boolean not null default false,
  paused_at timestamptz,
  time_zone text not null default 'UTC',
  -- When the one-time opt-in confirmation text went out.
  welcomed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_phone on public.profiles (phone);

create table public.subscriptions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  original_transaction_id text not null unique,
  product_id text not null,
  -- App Store status: 1 active, 2 expired, 3 billing retry, 4 grace period, 5 revoked.
  status int not null,
  -- Texts are sent while this is in the future.
  entitled_until timestamptz,
  environment text not null default 'Production',
  updated_at timestamptz not null default now()
);

create table public.outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  -- "<reminder>|sms|<epoch seconds>" from the app, "snooze|<id>|<epoch>" for snoozes.
  occurrence_key text not null,
  reminder_id uuid,
  title text not null default '',
  body text not null check (char_length(body) between 1 and 480),
  fire_at timestamptz not null,
  source text not null default 'app' check (source in ('app', 'snooze')),
  status text not null default 'pending'
    check (status in ('pending', 'sending', 'sent', 'delivered', 'failed', 'missed', 'skipped')),
  attempts int not null default 0,
  provider_message_id text,
  error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, occurrence_key)
);
create index outbox_due on public.outbox (fire_at) where status = 'pending';
create index outbox_user_recent on public.outbox (user_id, fire_at desc);

create table public.inbound_messages (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete cascade,
  from_phone text not null,
  body text not null,
  command text,
  provider_message_id text unique,
  received_at timestamptz not null default now()
);

-- Server-side knobs. Only the service role reads them.
create table public.app_config (
  key text primary key,
  value text not null
);
insert into public.app_config (key, value) values
  ('monthly_text_cap', '300'),
  ('daily_text_cap', '40'),
  ('grace_minutes', '60'),
  ('max_queue', '1000');

-- Row level security ---------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.subscriptions enable row level security;
alter table public.outbox enable row level security;
alter table public.inbound_messages enable row level security;
alter table public.app_config enable row level security;

create policy "Read own profile" on public.profiles
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Read own subscription" on public.subscriptions
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Read own texts" on public.outbox
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Read own replies" on public.inbound_messages
  for select to authenticated using ((select auth.uid()) = user_id);

revoke insert, update, delete, truncate on public.profiles, public.subscriptions, public.outbox,
  public.inbound_messages, public.app_config from anon, authenticated;
revoke select on public.app_config from anon, authenticated;

-- Profiles follow auth.users -------------------------------------------------

create function public.handle_auth_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  normalized text := case
    when new.phone is null or new.phone = '' then ''
    when left(new.phone, 1) = '+' then new.phone
    else '+' || new.phone
  end;
begin
  insert into public.profiles (user_id, phone) values (new.id, normalized)
  on conflict (user_id) do update set phone = excluded.phone, updated_at = now();
  return new;
end $$;

create trigger on_auth_user_saved
  after insert or update of phone on auth.users
  for each row execute function public.handle_auth_user();

-- Called by the app ----------------------------------------------------------

-- Replaces the caller's queued texts with the app's latest plan. Texts already
-- sent (or due right now) are never touched, and snoozes stay queued.
create function public.sync_outbox(p_items jsonb, p_time_zone text default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  max_items int := coalesce((select value::int from public.app_config where key = 'max_queue'), 1000);
  inserted int;
begin
  if uid is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'p_items must be a JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > max_items then
    raise exception 'Too many texts in one sync (max %)', max_items using errcode = '22023';
  end if;

  delete from public.outbox
   where user_id = uid and status = 'pending' and source = 'app' and fire_at > now();

  insert into public.outbox (user_id, occurrence_key, reminder_id, title, body, fire_at, source)
  select uid, x.key, x.reminder_id, left(coalesce(x.title, ''), 120), x.body, x.fire_at, 'app'
    from jsonb_to_recordset(p_items) as x (key text, reminder_id uuid, title text, body text, fire_at timestamptz)
   where x.key is not null and char_length(x.key) <= 200
     and x.body is not null and char_length(x.body) between 1 and 480
     and x.fire_at > now() and x.fire_at < now() + interval '62 days'
  on conflict (user_id, occurrence_key) do nothing;
  get diagnostics inserted = row_count;

  if p_time_zone is not null and char_length(p_time_zone) between 1 and 64 then
    update public.profiles set time_zone = p_time_zone, updated_at = now() where user_id = uid;
  end if;
  return inserted;
end $$;

-- Everything the app shows about the account in one call.
create function public.account_status() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'phone', p.phone,
    'texts_paused', p.texts_paused,
    'subscribed', coalesce(s.entitled_until > now(), false),
    'entitled_until', s.entitled_until,
    'product_id', s.product_id,
    'sent_this_month', (
      select count(*) from public.outbox o
       where o.user_id = p.user_id and o.status in ('sending', 'sent', 'delivered')
         and o.sent_at >= date_trunc('month', now())),
    'monthly_cap', (select value::int from public.app_config where key = 'monthly_text_cap'),
    'queued', (
      select count(*) from public.outbox o
       where o.user_id = p.user_id and o.status = 'pending' and o.fire_at > now()))
  from public.profiles p
  left join public.subscriptions s on s.user_id = p.user_id
  where p.user_id = auth.uid();
$$;

create function public.set_texts_paused(p_paused boolean) returns void
language sql security definer set search_path = '' as $$
  update public.profiles
     set texts_paused = p_paused,
         paused_at = case when p_paused then now() end,
         updated_at = now()
   where user_id = auth.uid();
$$;

-- Called by the Edge Functions (service role only) ---------------------------

-- Hands out due texts to exactly one sender. Also retires rows that can no
-- longer be sent: too late, no subscription, paused, or over the caps.
create function public.claim_due_texts(p_limit int default 100)
returns setof public.outbox
language plpgsql security definer set search_path = '' as $$
declare
  grace interval := make_interval(mins => coalesce(
    (select value::int from public.app_config where key = 'grace_minutes'), 60));
  monthly_cap int := coalesce((select value::int from public.app_config where key = 'monthly_text_cap'), 300);
  daily_cap int := coalesce((select value::int from public.app_config where key = 'daily_text_cap'), 40);
begin
  -- A send that never reported back (function crashed or timed out).
  update public.outbox
     set status = 'failed', error = 'The send did not report back, so it was not retried.'
   where status = 'sending' and sent_at < now() - interval '10 minutes';

  update public.outbox
     set status = 'missed', error = 'Not sent: more than ' || (extract(epoch from grace) / 60)::int || ' minutes late.'
   where status = 'pending' and fire_at <= now() - grace;

  update public.outbox o
     set status = 'skipped', error = 'No active subscription.'
   where o.status = 'pending' and o.fire_at <= now()
     and not exists (
       select 1 from public.subscriptions s where s.user_id = o.user_id and s.entitled_until > now());

  update public.outbox o
     set status = 'skipped', error = 'Texts are paused.'
   where o.status = 'pending' and o.fire_at <= now()
     and exists (select 1 from public.profiles p where p.user_id = o.user_id and p.texts_paused);

  update public.outbox o
     set status = 'skipped', error = 'Monthly text limit reached.'
   where o.status = 'pending' and o.fire_at <= now()
     and (select count(*) from public.outbox x
           where x.user_id = o.user_id and x.status in ('sending', 'sent', 'delivered')
             and x.sent_at >= date_trunc('month', now())) >= monthly_cap;

  update public.outbox o
     set status = 'skipped', error = 'Daily text limit reached.'
   where o.status = 'pending' and o.fire_at <= now()
     and (select count(*) from public.outbox x
           where x.user_id = o.user_id and x.status in ('sending', 'sent', 'delivered')
             and x.sent_at >= now() - interval '24 hours') >= daily_cap;

  return query
  with due as (
    select o.id from public.outbox o
     where o.status = 'pending' and o.fire_at <= now()
     order by o.fire_at
     limit greatest(1, least(p_limit, 500))
     for update skip locked
  ), claimed as (
    update public.outbox o
       set status = 'sending', attempts = o.attempts + 1, sent_at = now(), error = null
      from due
     where o.id = due.id
    returning o.*
  )
  select * from claimed;
end $$;

create function public.mark_text_result(
  p_id bigint, p_status text, p_provider_message_id text default null, p_error text default null
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_status not in ('sent', 'delivered', 'failed') then
    raise exception 'Unexpected status %', p_status using errcode = '22023';
  end if;
  update public.outbox
     set status = p_status,
         provider_message_id = coalesce(p_provider_message_id, provider_message_id),
         error = p_error
   where id = p_id and status in ('sending', 'sent');
end $$;

-- Queues the caller's most recent text again, p_minutes from now.
create function public.snooze_last_text(p_user uuid, p_minutes int)
returns public.outbox
language plpgsql security definer set search_path = '' as $$
declare
  last public.outbox;
  created public.outbox;
  minutes int := least(greatest(coalesce(p_minutes, 10), 1), 1440);
begin
  select * into last from public.outbox
   where user_id = p_user and status in ('sent', 'delivered') and sent_at > now() - interval '24 hours'
   order by sent_at desc
   limit 1;
  if not found then
    return null;
  end if;
  insert into public.outbox (user_id, occurrence_key, reminder_id, title, body, fire_at, source)
  values (
    p_user,
    'snooze|' || last.id || '|' || floor(extract(epoch from now()))::bigint,
    last.reminder_id,
    left('Snoozed: ' || regexp_replace(last.title, '^Snoozed: ', ''), 120),
    last.body,
    date_trunc('minute', now() + make_interval(mins => minutes)) + interval '1 minute',
    'snooze')
  returning * into created;
  return created;
end $$;

create function public.user_for_phone(p_phone text) returns uuid
language sql stable security definer set search_path = '' as $$
  select user_id from public.profiles where phone = p_phone order by created_at limit 1;
$$;

create function public.set_paused_for_user(p_user uuid, p_paused boolean) returns void
language sql security definer set search_path = '' as $$
  update public.profiles
     set texts_paused = p_paused,
         paused_at = case when p_paused then now() end,
         updated_at = now()
   where user_id = p_user;
$$;

-- Returns false when the provider already delivered this message (webhook retry).
create function public.record_inbound(
  p_user uuid, p_from text, p_body text, p_command text, p_provider_message_id text
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  inserted int;
begin
  insert into public.inbound_messages (user_id, from_phone, body, command, provider_message_id)
  values (p_user, p_from, left(p_body, 1000), p_command, p_provider_message_id)
  on conflict (provider_message_id) do nothing;
  get diagnostics inserted = row_count;
  return inserted > 0;
end $$;

-- Links a verified App Store subscription to an account. A transaction that is
-- already linked to someone else is refused.
create function public.upsert_subscription(
  p_user uuid, p_original_transaction_id text, p_product_id text, p_status int,
  p_entitled_until timestamptz, p_environment text
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (
    select 1 from public.subscriptions
     where original_transaction_id = p_original_transaction_id and user_id <> p_user
  ) then
    raise exception 'This subscription belongs to another account' using errcode = '42501';
  end if;
  insert into public.subscriptions (user_id, original_transaction_id, product_id, status, entitled_until, environment)
  values (p_user, p_original_transaction_id, p_product_id, p_status, p_entitled_until, p_environment)
  on conflict (user_id) do update
    set original_transaction_id = excluded.original_transaction_id,
        product_id = excluded.product_id,
        status = excluded.status,
        entitled_until = excluded.entitled_until,
        environment = excluded.environment,
        updated_at = now();
end $$;

-- The number to send the one-time opt-in confirmation to, or null when it
-- already went out (or texts are paused). Marks it as sent.
create function public.claim_welcome(p_user uuid) returns text
language sql security definer set search_path = '' as $$
  update public.profiles
     set welcomed_at = now(), updated_at = now()
   where user_id = p_user and welcomed_at is null and not texts_paused and phone <> ''
  returning phone;
$$;

create function public.user_for_transaction(p_original_transaction_id text) returns uuid
language sql stable security definer set search_path = '' as $$
  select user_id from public.subscriptions where original_transaction_id = p_original_transaction_id;
$$;

-- Function permissions -------------------------------------------------------

revoke all on function public.handle_auth_user() from public, anon, authenticated;

revoke all on function public.sync_outbox(jsonb, text) from public, anon;
revoke all on function public.account_status() from public, anon;
revoke all on function public.set_texts_paused(boolean) from public, anon;
grant execute on function public.sync_outbox(jsonb, text) to authenticated;
grant execute on function public.account_status() to authenticated;
grant execute on function public.set_texts_paused(boolean) to authenticated;

revoke all on function public.claim_due_texts(int) from public, anon, authenticated;
revoke all on function public.mark_text_result(bigint, text, text, text) from public, anon, authenticated;
revoke all on function public.snooze_last_text(uuid, int) from public, anon, authenticated;
revoke all on function public.user_for_phone(text) from public, anon, authenticated;
revoke all on function public.set_paused_for_user(uuid, boolean) from public, anon, authenticated;
revoke all on function public.record_inbound(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.upsert_subscription(uuid, text, text, int, timestamptz, text) from public, anon, authenticated;
revoke all on function public.user_for_transaction(text) from public, anon, authenticated;
revoke all on function public.claim_welcome(uuid) from public, anon, authenticated;
grant execute on function public.claim_due_texts(int) to service_role;
grant execute on function public.mark_text_result(bigint, text, text, text) to service_role;
grant execute on function public.snooze_last_text(uuid, int) to service_role;
grant execute on function public.user_for_phone(text) to service_role;
grant execute on function public.set_paused_for_user(uuid, boolean) to service_role;
grant execute on function public.record_inbound(uuid, text, text, text, text) to service_role;
grant execute on function public.upsert_subscription(uuid, text, text, int, timestamptz, text) to service_role;
grant execute on function public.user_for_transaction(text) to service_role;
grant execute on function public.claim_welcome(uuid) to service_role;

-- Every minute: send what's due --------------------------------------------
-- Needs two Vault secrets, created once per project:
--   select vault.create_secret('https://<ref>.supabase.co', 'bluenudge_project_url');
--   select vault.create_secret('<same value as the CRON_SECRET function secret>', 'bluenudge_cron_secret');
-- Skipped where pg_cron isn't available (plain Postgres in CI).

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
    create extension if not exists pg_cron;
    perform cron.schedule(
      'bluenudge-send-due-texts',
      '* * * * *',
      $cron$
        select net.http_post(
          url := (select decrypted_secret from vault.decrypted_secrets where name = 'bluenudge_project_url')
                 || '/functions/v1/send-due',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || (
              select decrypted_secret from vault.decrypted_secrets where name = 'bluenudge_cron_secret')),
          body := '{}'::jsonb,
          timeout_milliseconds := 25000)
        where exists (select 1 from vault.decrypted_secrets where name = 'bluenudge_cron_secret');
      $cron$);
  end if;
end $$;
