#!/bin/sh
# Compila, instala y abre la app en el iPhone conectado. IOS_DEVICE elige uno si hay varios.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
DERIVED=.tmp/ios-derived-device
BUNDLE=dev.nndsk.MedicationTracker

test -f apps/ios/Config/Local.xcconfig || { echo 'Create apps/ios/Config/Local.xcconfig first. See the README.' >&2; exit 1; }

DEVICE=${IOS_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '$NF == "physical" { for (i = 2; i < NF; i++) if ($i == "(UDID)" && ($(i + 1) == "connected" || $(i + 1) == "available")) print $(i - 1) }' | head -1)}
test -n "$DEVICE" || { echo 'No connected iPhone found. Unlock it and check the cable or Wi-Fi pairing.' >&2; exit 1; }

xcodebuild -project apps/ios/MedicationTracker.xcodeproj -derivedDataPath "$DERIVED" -scheme MedicationTracker \
	-configuration Debug -destination "platform=iOS,id=$DEVICE" -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVICE" "$DERIVED/Build/Products/Debug-iphoneos/MedicationTracker.app"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE"
