# BlueNudge

Reminders you won't miss. You set a reminder on your iPhone and pick how it
reaches you:

| Method | How it arrives | Needs | Cost to the user |
| --- | --- | --- | --- |
| **Text me** | A real SMS from BlueNudge's number. Reply **SNOOZE**, **STOP**, **START** or **HELP**. | An iPhone, a phone number, the BlueNudge Texts subscription | Subscription |
| **Alarm** | Rings like a Clock alarm, through silent mode and Focus, until stopped. | iOS 26 or later | Free |
| **Notification** | A regular notification with a Snooze action. | Any iPhone | Free |
| **Text from my Mac** | An iMessage sent by BlueNudge Relay on a Mac you own. | A Mac that stays on, a second Apple Account | Free |

| Part | What it does |
| --- | --- |
| **BlueNudge** (iPhone/iPad) | Create reminders, see what's next and what was sent, sign in for texts, subscribe. |
| **Texting backend** (`supabase/`) | Queues and sends "Text me" reminders as SMS through Twilio or Telnyx, handles replies, checks subscriptions with Apple. See [supabase/README.md](supabase/README.md). |
| **BlueNudge Relay** (Mac menu bar) | Optional: texts "Text from my Mac" reminders through Messages and reads replies. |
| **ReminderCore** (Swift package) | Scheduling, message templates, phone numbers and reply parsing shared by the apps. Tested on Linux and macOS. |

## Screenshots

The images in [`docs/screenshots`](docs/screenshots) come from the app running
with sample data (see [Screenshots](#screenshots-1) below).

| Today | Reminders | Editor | Settings |
| --- | --- | --- | --- |
| ![Today](docs/screenshots/iphone-today.png) | ![Reminders](docs/screenshots/iphone-reminders.png) | ![Editor](docs/screenshots/iphone-editor.png) | ![Settings](docs/screenshots/iphone-settings.png) |

## Features

- Once, hourly, daily, weekly (chosen weekdays), monthly, yearly, every N units, with an end date or a count.
- Quiet hours for hourly reminders, e.g. "every 2 hours, 9 AM–9 PM".
- Quick times for one-off reminders: in 10 minutes, in an hour, this evening, tomorrow morning, next Monday.
- Each reminder picks its own method; new reminders use the default chosen at first launch.
- Texts: sign in with a code texted to your number, subscribe in the app (monthly or yearly), pause and resume, see texts this month and what's queued, delete the account.
- Reply to a text: **SNOOZE** (10 min), **SNOOZE 30**, **2H**, **LATER**, "remind me in an hour" sends it again; **STOP** pauses every text until **START**; **HELP** explains; **DONE** is noted.
- Alarms: the next 25 are set on the iPhone and topped up whenever the app opens or refreshes in the background.
- Siri and Shortcuts: "Text me a reminder with BlueNudge" adds a one-time reminder without opening the app.
- Today screen: anything still to set up (sign in, subscribe, allow alarms), what's next, and what was texted.
- Activity log of every text, from the server and the Mac (sent, delivered, failed, missed, paused), with search and CSV export.
- Wall-clock times survive daylight-saving changes; each reminder keeps its own time zone.
- `{time}`, `{date}`, `{weekday}` and `{title}` placeholders in the text.
- Reminders sync between your devices through your private iCloud.

## What it costs to run

| Item | Cost |
| --- | --- |
| Apple Developer Program | $99/year |
| Supabase (database, auth, functions, cron) | Free plan to start; a Pro organization bills about $10/month per extra project, plus usage |
| SMS, per text (US) | Twilio about $0.0083 + carrier fee (about $0.003–0.005); Telnyx about $0.004 + carrier fee |
| Replies (SNOOZE, STOP…) | Billed as inbound SMS at similar rates |
| US carrier registration | 10DLC: brand $4.50 + vetting $41.50 + campaign $15, then $1.50–10/month; or toll-free verification (needs a business EIN) |
| Apple's commission | 15% (Small Business Program) or 30% of each subscription |

Each account is capped at 300 texts a month and 40 a day by default
(`public.app_config`), which bounds the SMS cost per subscriber. Alarms,
notifications and Mac texts cost nothing per reminder.

## Requirements

- Xcode 26 or later on a Mac.
- iPhone or iPad on iOS 17 or later; Alarm reminders need iOS 26.
- For texts: the backend deployed (see [supabase/README.md](supabase/README.md)).
- For Mac texts: a Mac on macOS 14 or later, a second Apple Account for its Messages app, and iCloud on the Mac signed in to the same Apple Account as the iPhone.

## Setup

### 1. Open and sign

1. Open `BlueNudge.xcodeproj`.
2. For each target (**BlueNudge**, and **BlueNudgeRelay** if you use it), open *Signing & Capabilities* and pick your Team.
3. Both targets use the iCloud container `iCloud.com.amgaviationgroup.bluenudge`. If Xcode reports it missing, tick it in the iCloud section so Xcode creates it.
4. To use your own bundle IDs, see [Changing identifiers](#changing-identifiers).

### 2. Texting and subscription

1. Deploy the backend: [supabase/README.md](supabase/README.md).
2. In `project.yml`, set the BlueNudge target's `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PRIVACY_POLICY_URL` and `TERMS_URL`, then run `xcodegen generate`. Without `SUPABASE_URL`, "Text me" is hidden and the app offers alarms and notifications only. Texts go to US and Canadian numbers (`TEXTING_CALLING_CODES` in the app, `SMS_ALLOWED_COUNTRY_CODES` on the backend); widen both together if you serve other countries, whose SMS rates are several times higher.
3. In App Store Connect, create the auto-renewable subscriptions listed in `SUBSCRIPTION_PRODUCT_IDS` (one group, "BlueNudge Texts").
4. Running from Xcode uses `StoreKit/BlueNudge.storekit`, so you can try the paywall with test purchases before App Store Connect is set up.

### 3. Mac relay (optional)

1. Create a second Apple Account at [account.apple.com](https://account.apple.com).
2. On the Mac, open *Messages › Settings › iMessage* and sign in with that second account. Leave *System Settings › Apple Account / iCloud* on your own account.
3. Run the **BlueNudgeRelay** scheme. It lives in the menu bar; the dashboard opens on first launch.
4. Click **Grant access** and allow it to control Messages.
5. Add *BlueNudge Relay* to *System Settings › Privacy & Security › Full Disk Access* and click **Recheck**. This turns on replies and delivery confirmation.
6. Turn on **Open at login** and **Keep this Mac awake**.
7. On the iPhone, save the second account's email as a contact, and enter your number in *Settings › Text from my Mac*.

"Text from my Mac" appears in the iPhone app once a relay has checked in.

### Shipping to the App Store

- Before the first TestFlight build, deploy the CloudKit schema to Production in the [CloudKit Console](https://icloud.developer.apple.com).
- The subscription needs a privacy policy and terms of use (set their URLs as above), a description of what the subscription includes, and App Review notes explaining the texting sign-in; give the reviewer a test number or a demo account.
- App Store privacy labels: the texting backend stores the phone number and the text of "Text me" reminders; say so in the privacy policy.
- The Mac relay cannot go on the Mac App Store (it is not sandboxed, scripts Messages and reads its database); distribute it signed with Developer ID and notarized, or run it from Xcode.
- Don't use "iMessage" in the app's name; Apple's trademark rules allow it only in phrases like "works with iMessage".

## Project layout

```
App/Shared/        SwiftData models, iCloud store, repository, texting API client (both apps)
App/iOS/           iPhone app: views, notifications, alarms, texting account, subscription, Siri intent
App/macOS/         Mac relay: engine, Messages sender, chat.db reader, menu bar + dashboard
Packages/ReminderCore/  Platform-neutral logic + unit tests
Tests/BlueNudgeTests/   Data-layer, texting client, reply and relay tests (macOS)
supabase/          Texting backend: migration, Edge Functions, tests
StoreKit/          Local StoreKit configuration for test purchases
project.yml        XcodeGen spec (BlueNudge.xcodeproj is generated from it)
scripts/           App icons and screenshot capture
```

## Development

```sh
# Core logic tests (macOS or Linux)
swift test --package-path Packages/ReminderCore

# App tests on a Mac: SwiftData queries, texting client, reply handling,
# Messages database queries and the relay's AppleScript
xcodebuild test -project BlueNudge.xcodeproj -scheme BlueNudgeTests -destination 'platform=macOS'

# Backend tests (Deno and any Postgres 15+)
deno test --allow-env supabase/tests
supabase/tests/db/run.sh

# After editing project.yml
brew install xcodegen && xcodegen generate
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux, the backend tests
against Postgres, then on macOS builds both apps with signing disabled and runs
the app tests.

### Screenshots

Debug builds have a demo mode with sample data that never touches real data:
launch the iPhone app with `-BlueNudgeDemo YES -BlueNudgeScreen today`
(or `reminders`, `editor`, `how`, `activity`, `settings`, `texts`, `onboarding`, `delivery`). The
*Screenshots* workflow captures every screen in the iOS Simulator plus the Mac
relay's windows and commits them to `docs/screenshots`; run it from the Actions
tab or add the `screenshots` label to a pull request.

### Changing identifiers

Edit `project.yml`: `bundleIdPrefix`, both `PRODUCT_BUNDLE_IDENTIFIER` values,
the iCloud container in both `entitlements` blocks (keep it identical in both),
the subscription product IDs, and the background task identifier
(`BGTaskSchedulerPermittedIdentifiers`, also in `BackgroundRefresh.swift`), then
run `xcodegen generate`. Update `APPSTORE_BUNDLE_ID` and `APPSTORE_PRODUCT_IDS`
on the backend to match.

## Data model rules (CloudKit)

Models live in `App/Shared/Models.swift` and follow CloudKit's constraints:
every property has a default, there are no unique constraints and no
relationships (links are stored as UUIDs). Once the schema is deployed to
Production, properties can be added but never renamed or removed.

## Limits

- Texts need a working connection to the backend when reminders change: the app
  sends the next 45 days of each "Text me" reminder, and tops the queue up when it
  opens and in the background.
- A text more than 60 minutes late (e.g. during a provider outage) is logged as
  missed rather than sent.
- iOS limits how many notifications and alarms an app can schedule ahead, so
  reminders more than a couple of weeks out are scheduled as the date gets
  closer; open the app now and then if you rely on alarms or notifications.
- Mac texts only go out while the Mac is on, awake and online.
