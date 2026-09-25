# BlueNudge texting backend

Sends "Text me" reminders as SMS for subscribers, so an iPhone alone is enough.
It runs on [Supabase](https://supabase.com) (Postgres, Auth, Edge Functions,
pg_cron) with Twilio or Telnyx for the texts, and checks subscriptions with
Apple's App Store Server API.

```
iPhone app ──sign in with SMS code──▶ Supabase Auth ──Send SMS hook──▶ send-sms-hook ─▶ Twilio/Telnyx
    │
    ├─ sync_outbox(): the next 45 days of "Text me" reminders
    ├─ verify-subscription: StoreKit transaction ─▶ App Store Server API
    │
pg_cron (every minute) ─▶ send-due ─▶ claim_due_texts() ─▶ Twilio/Telnyx ─▶ your phone
your reply (SNOOZE, STOP, HELP…) ─▶ Twilio/Telnyx ─▶ sms-inbound
Apple (renewals, refunds) ─▶ appstore-notifications ─▶ App Store Server API
```

The app computes each reminder's upcoming times itself (the same code that shows
"Next up") and replaces its queue on the server whenever reminders change, when
it opens, and about twice a day in the background. The server only sends what is
due, checks the subscription and the limits, and handles replies.

## What's here

| Path | What it does |
| --- | --- |
| `migrations/` | Tables (profiles, subscriptions, outbox, inbound messages, config), row-level security, the functions the app and Edge Functions call, and the every-minute cron job. |
| `functions/send-due` | Sends due texts. Called by pg_cron with `CRON_SECRET`. |
| `functions/sms-inbound` | Provider webhook for replies: SNOOZE, STOP/START, HELP, DONE. Checks the provider's signature. |
| `functions/send-sms-hook` | Supabase Auth hook that texts sign-in codes through the same provider. |
| `functions/verify-subscription` | Links a purchase to the signed-in account after checking it with Apple. Sends the one-time opt-in confirmation. |
| `functions/appstore-notifications` | App Store Server Notifications V2: renewals, expirations, refunds. |
| `functions/delete-account` | Deletes the signed-in account and everything stored for it. |
| `tests/` | Deno tests for the functions, and SQL checks for the migration (`tests/db/run.sh`). |

## Limits and knobs

`public.app_config` holds the limits; change them with SQL:

| Key | Default | Meaning |
| --- | --- | --- |
| `monthly_text_cap` | 300 | Texts per account per calendar month. Further texts are skipped and shown in the app. |
| `daily_text_cap` | 40 | Texts per account per day. |
| `grace_minutes` | 60 | A text more than this late (outage) is marked missed instead of sent. |
| `max_queue` | 1000 | Most queued texts one sync may create. |

## Deploy

You need: a Supabase project, the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started),
an SMS number from Twilio or Telnyx that is registered for application-to-person
texting (US: 10DLC or toll-free verification), and an Apple Developer account
with the app and its subscriptions in App Store Connect.

1. **Link and migrate**

   ```sh
   supabase login
   supabase link --project-ref <project-ref>
   supabase db push
   ```

2. **Deploy the functions** (`config.toml` turns off the gateway's JWT check;
   each function checks its own caller)

   ```sh
   supabase functions deploy send-due sms-inbound send-sms-hook verify-subscription appstore-notifications delete-account
   ```

3. **Set the secrets** (`supabase secrets set --env-file .env`, with a `.env`
   that is never committed):

   | Secret | Value |
   | --- | --- |
   | `CRON_SECRET` | A long random string, e.g. `openssl rand -hex 32`. |
   | `SMS_PROVIDER` | `twilio` or `telnyx` |
   | `SMS_FROM_NUMBER` | The sending number in E.164 (`+15125550100`). Can be empty with a Twilio Messaging Service or Telnyx profile that picks the number. |
   | `SMS_INBOUND_URL` | `https://<project-ref>.supabase.co/functions/v1/sms-inbound`, exactly as entered at the provider (Twilio signs this URL). |
   | `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` | Twilio only. |
   | `TWILIO_MESSAGING_SERVICE_SID` | Twilio only, optional. |
   | `TELNYX_API_KEY`, `TELNYX_PUBLIC_KEY` | Telnyx only. The public key is under Keys & Credentials › Public Key. |
   | `TELNYX_MESSAGING_PROFILE_ID` | Telnyx only, optional. |
   | `SMS_HELP_TEXT` | Optional. Empty uses the built-in answer to HELP; `off` if your provider already answers HELP; or your own text with a support contact. |
   | `SMS_ALLOWED_COUNTRY_CODES` | Optional. Calling codes that may be texted, comma-separated. Default `1` (US and Canada); `*` for any. Keep the app's `TEXTING_CALLING_CODES` the same. |
   | `SEND_SMS_HOOK_SECRETS` | The `v1,whsec_…` secret from step 5. |
   | `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID` | App Store Connect › Users and Access › Integrations › In-App Purchase. |
   | `APPSTORE_PRIVATE_KEY` | The contents of the downloaded `.p8` In-App Purchase key (it can be downloaded only once). |
   | `APPSTORE_BUNDLE_ID` | `com.amgaviationgroup.bluenudge` |
   | `APPSTORE_PRODUCT_IDS` | Same list as the app's `SUBSCRIPTION_PRODUCT_IDS`. |

   `SUPABASE_URL` and the service keys are provided to functions automatically.

4. **Turn on the cron job.** In the SQL editor, create the two Vault secrets the
   job reads (the migration already scheduled it; it does nothing until these exist):

   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co', 'bluenudge_project_url');
   select vault.create_secret('<same value as CRON_SECRET>', 'bluenudge_cron_secret');
   ```

5. **Phone sign-in.** In the dashboard, enable the Phone provider under
   Authentication, then add a Send SMS hook (Authentication › Hooks) of type HTTPS
   pointing at `https://<project-ref>.supabase.co/functions/v1/send-sms-hook`.
   Generate its secret and store it as `SEND_SMS_HOOK_SECRETS`.

6. **Replies.** At the SMS provider, set the number's (or messaging
   service/profile's) incoming-message webhook to the `SMS_INBOUND_URL` above,
   method POST. Also limit outbound texts to the countries you serve in the
   provider's settings (Twilio: Messaging Geographic Permissions; Telnyx: the
   outbound profile's allowed destinations) as a second guard against SMS
   pumping through the sign-in code.

7. **Subscriptions.** In App Store Connect, create an auto-renewable subscription
   group with the product IDs from `SUBSCRIPTION_PRODUCT_IDS`, and under App
   Information › App Store Server Notifications set both the production and
   sandbox URLs to `https://<project-ref>.supabase.co/functions/v1/appstore-notifications`
   (version 2).

8. **The app.** Set the `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (Project
   Settings › API Keys, the publishable key), `PRIVACY_POLICY_URL` and `TERMS_URL`
   build settings of the BlueNudge target in `project.yml` (or in Xcode), then
   regenerate the project. With `SUPABASE_URL` empty, "Text me" is hidden.

## Test

```sh
deno test --allow-env supabase/tests          # function logic, signatures, App Store JWTs
deno check supabase/functions/*/index.ts
supabase/tests/db/run.sh                      # migration + SQL checks on any Postgres 15+
```

CI runs all three. In Xcode, the BlueNudge scheme uses `StoreKit/BlueNudge.storekit`,
so subscriptions can be bought locally without App Store Connect (the server
can't verify those test purchases; use a sandbox account for end-to-end tests).

## Rules to know before launch

- **Carrier registration.** US carriers block unregistered application-to-person
  texts. Register a 10DLC brand and campaign, or verify a toll-free number
  (needs a business EIN), before sending to anyone but test numbers.
- **Consent and opt-out.** Texts go only to the number verified by code at sign-in,
  after the consent line on the sign-in screen. STOP pauses texts (the provider
  also blocks the number), START resumes, HELP answers, and the first text after
  subscribing is the opt-in confirmation.
- **Privacy.** The server stores the phone number, the text and time of each
  queued reminder for the next 45 days, and what was sent. Your privacy policy
  and the App Store privacy labels must say so. Deleting the account in the app
  removes all of it.
