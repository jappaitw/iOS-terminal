#!/bin/sh
# Builds a Debug app and installs it on the paired iPhone over WiFi/USB —
# the fast iteration loop (no TestFlight wait). TestFlight stays for
# milestone builds via the archive/export flow.
#
#   sh scripts/deploy_device.sh            # James16pro (default)
#   sh scripts/deploy_device.sh <UDID>
set -e
UDID="${1:-00008140-001E1D4E0239801C}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/dd-device"

echo "==> building (Debug, device)"
xcodebuild build \
    -project "$ROOT/PocketCode.xcodeproj" -scheme PocketCode -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DD" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$HOME/Documents/asc/AuthKey_GVZDT8847H.p8" \
    -authenticationKeyID GVZDT8847H \
    -authenticationKeyIssuerID b6bea48d-90ff-47b4-9c5a-6099aed75e83 \
    | grep -E "BUILD (SUCCEEDED|FAILED)|error:" || true

APP="$DD/Build/Products/Debug-iphoneos/PocketCode.app"
[ -d "$APP" ] || { echo "app not found: $APP"; exit 1; }

echo "==> installing on $UDID"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "==> launching"
xcrun devicectl device process launch --device "$UDID" com.jlmxstudio.pocketcode || true
echo "OK"
