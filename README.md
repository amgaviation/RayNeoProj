# BlueNudge

An iPhone app that sends scheduled reminders to people over iMessage, at no
per-message cost. Messages go out through Apple's Messages app from your own
Apple Account or phone number, so there is no SMS gateway, no server and no
monthly fee.

| Part | What it does |
| --- | --- |
| **BlueNudge** (iPhone/iPad) | Manage people and reminders, see what's due, send with one tap, review the delivery log. |
| **BlueNudge Relay** (Mac menu bar) | Optional. Sends automatic reminders unattended through Messages, confirms delivery, retries as SMS, honors STOP replies. |
| **ReminderCore** (Swift package) | Scheduling, message templates, phone-number handling and opt-out detection shared by both apps. Tested on Linux and macOS. |

## Why a Mac relay?

Apple does not let iPhone apps send iMessages by themselves: the system compose
sheet always needs a tap. The only way to send iMessages unattended without a
paid gateway is a Mac signed in to Messages, driven through Messages' public
AppleScript interface. So there are two delivery methods, chosen per reminder:

- **Automatic (Mac relay):** fully unattended. Needs any Mac on macOS 14+ that stays on.
- **Tap to send (iPhone):** the iPhone alerts you at the scheduled time and the
  message is one tap away. No Mac needed. A Shortcuts automation can also send
  these without a tap at fixed times of day (best-effort, see below).

```
iPhone app ──(your private iCloud / CloudKit)── Mac relay ──AppleScript──▶ Messages ──▶ iMessage / SMS
   │                                                 │
   └── tap-to-send via the Messages compose sheet    └── reads chat.db (optional) for delivery + STOP replies
```

Both apps share one SwiftData store synced through the CloudKit private
database of your Apple Account. Every message is identified by
`reminder + person + scheduled time`; whichever device handles it writes a
delivery record first, which is what prevents duplicates across devices.

## Features

- One-time or repeating reminders: hourly, daily, weekly (chosen weekdays), monthly, yearly, every N units, with an end date or a count.
- Wall-clock times survive daylight-saving changes; each reminder keeps its own time zone.
- Personalised messages: `{first_name}`, `{name}`, `{last_name}`, `{title}`, `{date}`, `{time}`, `{weekday}`, `{sender}`.
- Each person gets a private message, never a group chat.
- Import people from Contacts (no Contacts permission needed), phone numbers normalized to E.164.
- Today screen: messages ready to send, relay status, late automatic reminders with a "Send from iPhone" fallback, upcoming schedule.
- Activity log from every device with status (sent, delivered, failed, missed, skipped, opted out), search, and CSV export.
- Relay: throttling (per-hour cap, gap between messages), grace window for late sends, missed-reminder logging, delivery confirmation, SMS fallback, STOP/START handling with an optional confirmation, heartbeat and automatic single-relay election, keep-awake and open-at-login.
- iCloud sync status on both devices: last sync time, or the reason it failed (not signed in, storage full, container not set up).
- Shortcuts actions: *Get Due BlueNudge Messages*, *Mark BlueNudge Message Sent*, *Open BlueNudge Send Queue*.

## What it costs

| Item | Cost |
| --- | --- |
| Per message | $0 (iMessage; SMS fallback uses your iPhone's plan) |
| Servers / sync | $0 (your private iCloud database) |
| Apple Developer Program | $99/year, needed for iCloud sync, TestFlight and the App Store, and to keep the app installed longer than 7 days |
| Mac for automatic sending | A Mac you already own, or any Mac that can stay on |

## Requirements

- Xcode 26 or later on a Mac.
- iPhone or iPad on iOS 17 or later.
- For the relay: a Mac on macOS 14 or later, signed in to Messages and to the same Apple Account (iCloud) as the iPhone.

## Setup

### 1. Open and sign

1. Open `BlueNudge.xcodeproj`.
2. For both targets (**BlueNudge** and **BlueNudgeRelay**), open *Signing & Capabilities* and pick your Team.
3. Both targets use the iCloud container `iCloud.com.amgaviationgroup.bluenudge`. If Xcode reports it missing, tick it in the iCloud section so Xcode creates it. The same container must be ticked in both targets.
4. To use your own bundle IDs, see [Changing identifiers](#changing-identifiers).

Without a paid developer account, remove the iCloud and Push Notifications capabilities from the iPhone target: the app then runs on-device only (tap-to-send works; the relay can't see its data).

### 2. iPhone app

Run the **BlueNudge** scheme on your iPhone. The first launch asks whether you
have a Mac for automatic sending (this sets the default for new reminders) and
for notification permission.

### 3. Mac relay (for automatic sending)

1. Open Messages on the Mac and sign in with the account or number reminders should come from.
2. Run the **BlueNudgeRelay** scheme. It lives in the menu bar; the dashboard opens on first launch.
3. Click **Grant access** and allow it to control Messages.
4. Optional: add *BlueNudge Relay* to *System Settings › Privacy & Security › Full Disk Access* and click **Recheck**. This enables delivery confirmation, SMS fallback after a failed iMessage and STOP handling.
5. Turn on **Open at login** and **Keep this Mac awake**. A closed laptop lid still sleeps the Mac.
6. For SMS fallback (Android recipients): on the iPhone, *Settings › Apps › Messages › Text Message Forwarding*, allow the Mac, then enable *Fall back to SMS* in BlueNudge settings.

Use **Test** in the dashboard to send one message right away.

### 4. Optional: send tap-to-send reminders from Shortcuts

In Shortcuts create a *Time of Day* automation set to *Run Immediately*:
*Get Due BlueNudge Messages* → *Repeat with Each* → *Send Message* (Message:
Repeat Item › Text, Recipients: Repeat Item › Handle, Show When Run off) →
*Mark BlueNudge Message Sent* (Repeat Item). iOS sometimes skips automations
while the phone is locked, so treat this as best-effort.

### Shipping through TestFlight or the App Store

- Before the first TestFlight build, deploy the CloudKit schema to Production in the [CloudKit Console](https://icloud.developer.apple.com). Development builds (run from Xcode) and TestFlight/App Store builds use separate CloudKit environments, so an Xcode-built relay only sees an Xcode-built iPhone app. Build both the same way.
- The iPhone app uses only public APIs. The Mac relay cannot go on the Mac App Store (it is not sandboxed, scripts Messages and reads its database); run it from Xcode or distribute it signed with Developer ID and notarized.
- Don't use "iMessage" in the app's name; Apple's trademark rules allow it only in phrases like "works with iMessage".

## Project layout

```
App/Shared/        SwiftData models, iCloud store, repository (both apps)
App/iOS/           iPhone app: views, notifications, send queue, Shortcuts intents
App/macOS/         Mac relay: engine, Messages sender, chat.db reader, menu bar + dashboard
Packages/ReminderCore/  Platform-neutral logic + unit tests
Tests/BlueNudgeTests/   Data-layer and relay tests (macOS)
project.yml        XcodeGen spec (BlueNudge.xcodeproj is generated from it)
scripts/make_icons.py  Draws the app icons
```

## Development

```sh
# Core logic tests (macOS or Linux)
swift test --package-path Packages/ReminderCore

# App tests on a Mac: SwiftData queries, Messages database queries and the
# relay's AppleScript (compiled against Messages, nothing is sent)
xcodebuild test -project BlueNudge.xcodeproj -scheme BlueNudgeTests -destination 'platform=macOS'

# After editing project.yml
brew install xcodegen && xcodegen generate
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux, then on macOS,
builds both apps with signing disabled and runs the app tests.

### Changing identifiers

Edit `project.yml`: `bundleIdPrefix`, both `PRODUCT_BUNDLE_IDENTIFIER` values
and the iCloud container in both `entitlements` blocks (keep it identical in
both), then run `xcodegen generate`. The code reads the container from the
entitlements, so nothing else changes.

## Data model rules (CloudKit)

Models live in `App/Shared/Models.swift` and follow CloudKit's constraints:
every property has a default, there are no unique constraints and no
relationships (links are stored as UUIDs). Once the schema is deployed to
Production, properties can be added but never renamed or removed.

## Using it responsibly

- Only message people who agreed to get reminders. In the US, automated texts
  (iMessage included) fall under the TCPA: informational reminders need the
  recipient's prior consent, and opt-outs must be honored promptly. Keep
  reminders free of marketing unless you have written consent.
- STOP handling needs the relay with Full Disk Access. Opt-outs sent any other
  way (a call, an email) should be set by hand on the person.
- Apple can restrict Apple Accounts that send large volumes of unsolicited
  messages. The relay's hourly cap and message gap are there to keep sending
  patterns normal; keep volumes modest.
