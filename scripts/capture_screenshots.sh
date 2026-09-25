#!/bin/bash
# Captures the iPhone app's main screens in the iOS Simulator using demo data.
# Needs a Debug simulator build first, e.g.:
#   xcodebuild build -project BlueNudge.xcodeproj -scheme BlueNudge -configuration Debug \
#     -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData
# Usage: scripts/capture_screenshots.sh [output-folder]
set -euo pipefail

OUT="${1:-docs/screenshots}"
APP="build/DerivedData/Build/Products/Debug-iphonesimulator/BlueNudge.app"
BUNDLE_ID="com.amgaviationgroup.bluenudge"
mkdir -p "$OUT"

# Newest iOS runtime, preferring an iPhone "Pro" model.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    for device in entries:
        name = device["name"]
        if not name.startswith("iPhone"):
            continue
        rank = (version, name.endswith(" Pro"), name)
        if best is None or rank > best[0]:
            best = (rank, device["udid"], name)
print(best[1])
print(best[2], file=sys.stderr)
')
echo "Simulator: $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"

shoot() {
  local screen="$1" name="$2" wait="$3"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
    -BlueNudgeDemo YES -BlueNudgeScreen "$screen" >/dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/iphone-$name.png"
  echo "Captured $name"
}

xcrun simctl ui "$UDID" appearance light
shoot today today 12   # first launch is slow
shoot queue send-queue 7
shoot reminders reminders 7
shoot editor editor 7
shoot people people 7
shoot activity activity 7
shoot settings settings 7
shoot onboarding onboarding 7

xcrun simctl ui "$UDID" appearance dark
shoot today today-dark 7
xcrun simctl ui "$UDID" appearance light

xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
