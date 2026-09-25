-- Checks for the texting migration. Run after stub_supabase.sql and the
-- migrations; any failed check raises and stops psql (ON_ERROR_STOP).
\set ON_ERROR_STOP on
-- Only failures print.
\o /dev/null

create or replace function pg_temp.check(condition boolean, message text) returns void
language plpgsql as $$
begin
  if condition is distinct from true then
    raise exception 'CHECK FAILED: %', message;
  end if;
end $$;

-- Two users; the profile trigger adds "+" to the phone.
insert into auth.users (id, phone) values
  ('11111111-1111-1111-1111-111111111111', '15125550142'),
  ('22222222-2222-2222-2222-222222222222', '+15125550199');
select pg_temp.check((select phone from public.profiles where user_id = '11111111-1111-1111-1111-111111111111') = '+15125550142', 'profile phone normalized');
select pg_temp.check((select count(*) from public.profiles) = 2, 'profiles created');

-- As user 1: sync three texts (one too far out, one in the past) --------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select pg_temp.check(public.sync_outbox(jsonb_build_array(
  jsonb_build_object('key', 'r1|sms|1', 'reminder_id', gen_random_uuid(), 'title', 'Vitamins', 'body', 'Take your vitamins', 'fire_at', now() + interval '1 hour'),
  jsonb_build_object('key', 'r1|sms|2', 'title', 'Vitamins', 'body', 'Take your vitamins', 'fire_at', now() + interval '2 days'),
  jsonb_build_object('key', 'r1|sms|3', 'title', 'Too far', 'body', 'x', 'fire_at', now() + interval '90 days'),
  jsonb_build_object('key', 'r1|sms|0', 'title', 'Past', 'body', 'x', 'fire_at', now() - interval '1 hour')
), 'America/Chicago') = 2, 'only future texts within 62 days are queued');
select pg_temp.check((select count(*) from public.outbox) = 2, 'user sees own queued texts');
select pg_temp.check((public.account_status() ->> 'queued')::int = 2, 'account status counts the queue');
select pg_temp.check((public.account_status() ->> 'subscribed')::boolean = false, 'not subscribed yet');
select pg_temp.check((select time_zone from public.profiles) = 'America/Chicago', 'time zone saved');

-- A second sync replaces the future queue.
select pg_temp.check(public.sync_outbox(jsonb_build_array(
  jsonb_build_object('key', 'r1|sms|2', 'title', 'Vitamins', 'body', 'Take your vitamins now', 'fire_at', now() + interval '2 days')
)) = 1, 'resync inserts the new plan');
select pg_temp.check((select count(*) from public.outbox) = 1, 'old queued texts removed');
select pg_temp.check((select body from public.outbox) = 'Take your vitamins now', 'edited text replaces the old one');

-- Clients can't write directly or read config.
do $$ begin
  begin
    insert into public.outbox (user_id, occurrence_key, body, fire_at)
    values ('11111111-1111-1111-1111-111111111111', 'x', 'x', now());
    raise exception 'direct insert should have failed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform * from public.app_config;
    raise exception 'config read should have failed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.claim_due_texts(10);
    raise exception 'claim should be service-only';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- As user 2: can't see user 1's texts ----------------------------------------
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', true);
select pg_temp.check((select count(*) from public.outbox) = 0, 'RLS hides other users texts');
select public.set_texts_paused(true);
select pg_temp.check((public.account_status() ->> 'texts_paused')::boolean, 'pause saved');
commit;

-- Not signed in: sync refused -------------------------------------------------
begin;
set local role anon;
do $$ begin
  begin
    perform public.sync_outbox('[]'::jsonb);
    raise exception 'anon sync should have failed';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- Sending (service role) -----------------------------------------------------
-- Due rows for both users: user 1 has no subscription yet, user 2 is paused.
insert into public.outbox (user_id, occurrence_key, title, body, fire_at) values
  ('11111111-1111-1111-1111-111111111111', 'due|1', 'Due', 'Due now', now() - interval '1 minute'),
  ('11111111-1111-1111-1111-111111111111', 'late|1', 'Late', 'Way late', now() - interval '3 hours'),
  ('22222222-2222-2222-2222-222222222222', 'due|2', 'Due', 'Due now', now() - interval '1 minute');

begin;
set local role service_role;
select pg_temp.check((select count(*) from public.claim_due_texts(10)) = 0, 'nothing sent without subscription or while paused');
commit;
select pg_temp.check((select status from public.outbox where occurrence_key = 'late|1') = 'missed', 'very late text marked missed');
select pg_temp.check((select status from public.outbox where occurrence_key = 'due|1') = 'skipped', 'unsubscribed text skipped');
select pg_temp.check((select error from public.outbox where occurrence_key = 'due|2') in ('Texts are paused.', 'No active subscription.'), 'paused user skipped');

-- Subscribe user 1 and queue another due text.
begin;
set local role service_role;
select public.upsert_subscription('11111111-1111-1111-1111-111111111111', '2000000111', 'texts.monthly', 1, now() + interval '30 days', 'Sandbox');
commit;
do $$ begin
  begin
    perform public.upsert_subscription('22222222-2222-2222-2222-222222222222', '2000000111', 'texts.monthly', 1, now() + interval '30 days', 'Sandbox');
    raise exception 'transaction reuse should have failed';
  exception when insufficient_privilege then null;
  end;
end $$;
insert into public.outbox (user_id, occurrence_key, reminder_id, title, body, fire_at) values
  ('11111111-1111-1111-1111-111111111111', 'due|3', gen_random_uuid(), 'Call Mom', 'Call Mom', now() - interval '30 seconds');

begin;
set local role service_role;
create temp table claimed on commit drop as select * from public.claim_due_texts(10);
select pg_temp.check((select count(*) from claimed) = 1, 'subscribed user gets the due text');
select pg_temp.check((select count(*) from public.claim_due_texts(10)) = 0, 'a claimed text is not handed out twice');
select public.mark_text_result((select id from claimed), 'sent', 'SM123', null);
commit;
select pg_temp.check((select status from public.outbox where occurrence_key = 'due|3') = 'sent', 'marked sent');
select pg_temp.check((select provider_message_id from public.outbox where occurrence_key = 'due|3') = 'SM123', 'provider id stored');

-- Snooze the last text.
begin;
set local role service_role;
select pg_temp.check((public.snooze_last_text('11111111-1111-1111-1111-111111111111', 20)).title = 'Snoozed: Call Mom', 'snooze copies the last text');
select pg_temp.check(public.snooze_last_text('22222222-2222-2222-2222-222222222222', 20) is null, 'nothing to snooze');
select pg_temp.check(public.user_for_phone('+15125550142') = '11111111-1111-1111-1111-111111111111', 'lookup by phone');
select pg_temp.check(public.record_inbound('11111111-1111-1111-1111-111111111111', '+15125550142', 'snooze 20', 'snooze', 'IN1'), 'first delivery recorded');
select pg_temp.check(not public.record_inbound('11111111-1111-1111-1111-111111111111', '+15125550142', 'snooze 20', 'snooze', 'IN1'), 'webhook retry ignored');
commit;
select pg_temp.check((select fire_at from public.outbox where source = 'snooze') >= now() + interval '20 minutes', 'snooze is never early');

-- The opt-in confirmation goes out once, and never while paused.
begin;
set local role service_role;
select pg_temp.check(public.claim_welcome('11111111-1111-1111-1111-111111111111') = '+15125550142', 'welcome text claimed');
select pg_temp.check(public.claim_welcome('11111111-1111-1111-1111-111111111111') is null, 'welcome text only once');
select pg_temp.check(public.claim_welcome('22222222-2222-2222-2222-222222222222') is null, 'no welcome text while paused');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
do $$ begin
  begin
    perform public.claim_welcome('11111111-1111-1111-1111-111111111111');
    raise exception 'claim_welcome should be service-only';
  exception when insufficient_privilege then null;
  end;
end $$;
commit;

-- A resync from the app keeps the snooze.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);
select public.sync_outbox('[]'::jsonb);
select pg_temp.check((select count(*) from public.outbox where source = 'snooze' and status = 'pending') = 1, 'snooze survives a resync');
select pg_temp.check((public.account_status() ->> 'subscribed')::boolean, 'subscribed now');
select pg_temp.check((public.account_status() ->> 'sent_this_month')::int = 1, 'sent count');
commit;

-- Deleting the account removes everything.
delete from auth.users where id = '11111111-1111-1111-1111-111111111111';
select pg_temp.check((select count(*) from public.outbox where user_id = '11111111-1111-1111-1111-111111111111') = 0, 'texts deleted with the account');
select pg_temp.check((select count(*) from public.subscriptions) = 0, 'subscription deleted with the account');

\o
\echo 'All database checks passed.'
