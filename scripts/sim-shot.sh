#!/bin/bash
# Build the Debug app, then screenshot each tab with demo data on iPhone 17 and iPhone Duo.
# Usage:
#   ./scripts/sim-shot.sh                       every tab, light mode
#   ./scripts/sim-shot.sh budget accounts       only these tabs
#   APPEARANCE=dark ./scripts/sim-shot.sh       dark mode
#   SKIP_BUILD=1 ./scripts/sim-shot.sh          reuse the last build
# Output: .sim-shots/<device>/<appearance>-<tab>.png
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
REQUIRED_XCODE="27.2"
BUNDLE_ID="net.roberth.FinanceWizard"
APPEARANCE="${APPEARANCE:-light}"
DERIVED="$ROOT/.sim-shots/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/FinanceWizard.app"
# Seconds to wait out the splash and first layout.
SETTLE="${SETTLE:-8}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Release Xcode only: the version must match and the license must not be a beta one.
version="$(xcodebuild -version | awk 'NR==1{print $2}')"
license="$(/usr/libexec/PlistBuddy -c 'Print :licenseType' "$DEVELOPER_DIR/../Resources/LicenseInfo.plist")"
if [ "$version" != "$REQUIRED_XCODE" ] || [ "$license" != "GM" ]; then
  echo "Need Xcode $REQUIRED_XCODE release; $DEVELOPER_DIR is $version ($license)" >&2
  exit 1
fi

# Prints the UDID of the named simulator on its newest supporting runtime, creating it if
# needed. Some devices (iPhone Duo) only run on their own device-specific runtime.
ensure_device() {
  local name="$1" runtime udid
  runtime="$(xcrun simctl list -j runtimes | python3 -c '
import json, sys
ios = [r for r in json.load(sys.stdin)["runtimes"]
       if r["platform"] == "iOS" and r["isAvailable"]
       and any(d["name"] == sys.argv[1] for d in r.get("supportedDeviceTypes", []))]
print(max(ios, key=lambda r: [int(p) for p in r["version"].split(".")])["identifier"] if ios else "")' "$name")"
  if [ -z "$runtime" ]; then
    echo "No iOS Simulator runtime for $name. Run: xcodebuild -downloadPlatform iOS" >&2
    return 1
  fi
  udid="$(xcrun simctl list -j devices | python3 -c '
import json, sys
for d in json.load(sys.stdin)["devices"].get(sys.argv[1], []):
    if d["name"] == sys.argv[2] and d["isAvailable"]:
        print(d["udid"]); break' "$runtime" "$name")"
  if [ -z "$udid" ]; then
    udid="$(xcrun simctl create "$name" "$name" "$runtime")"
  fi
  echo "$udid"
}

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project "$ROOT/FinanceWizard.xcodeproj" -scheme FinanceWizard \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED" -quiet build
fi

if [ "$#" -gt 0 ]; then
  screens=("$@")
else
  screens=(transactions accounts budget subscriptions settings)
fi

for device in "iPhone 17" "iPhone Duo"; do
  udid="$(ensure_device "$device")"
  out="$ROOT/.sim-shots/${device// /-}"
  mkdir -p "$out"

  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance "$APPEARANCE"
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3
  xcrun simctl install "$udid" "$APP"

  for screen in "${screens[@]}"; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$BUNDLE_ID" \
      -demoData YES -settings.onboardingCompleted YES -screen "$screen" >/dev/null
    sleep "$SETTLE"
    shot="$out/$APPEARANCE-$screen.png"
    # iPhone Duo has two displays and the inactive one captures black, so keep the larger PNG.
    xcrun simctl io "$udid" screenshot --display=primary "$shot" >/dev/null
    if xcrun simctl io "$udid" screenshot --display=primary-1 "$shot.alt.png" >/dev/null 2>&1 \
      && [ "$(stat -f %z "$shot.alt.png")" -gt "$(stat -f %z "$shot")" ]; then
      mv "$shot.alt.png" "$shot"
    fi
    rm -f "$shot.alt.png"
    echo "$shot"
  done
done
