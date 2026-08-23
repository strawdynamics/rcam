#!/bin/bash
# Build a TestFlight/App Store archive and export it as an uploadable .pkg.
#
# Usage: scripts/release.sh [--upload]
#
# This is deliberately NOT scripts/build.sh. build.sh optimises for the dev
# loop: it installs to /Applications and keeps the extension's CFBundleVersion
# pinned so the running virtual camera survives a rebuild. Neither is wanted
# here, and one of them is actively harmful:
#
#   App Store Connect validates nested bundles against their container. The
#   extension's dev-loop version (derived from a hash of its own inputs) does
#   not track the app's epoch stamp, so an archive built the build.sh way ships
#   an app at CFBundleVersion N with a .systemextension at some unrelated M.
#   That is the ITMS-90473 shape. Here both are stamped with the same value.
#
# Nothing is installed to /Applications and the local extension is never
# touched, so running this does not disturb a working dev install.
set -euo pipefail
cd "$(dirname "$0")/.."

UPLOAD=no
for arg in "$@"; do
  case "$arg" in
    --upload) UPLOAD=yes ;;
    *) echo "usage: $(basename "$0") [--upload]" >&2; exit 2 ;;
  esac
done

OUT=build/release
ARCHIVE="$OUT/RCam.xcarchive"
EXPORT="$OUT/export"
VERSION_FILE=Configs/Version.xcconfig

mkdir -p "$OUT" Configs

# Same cross-file contracts build.sh enforces. They matter more here: this is
# the build strangers run, and two of the three (the FFmpeg version in the
# acknowledgements panel, the dylibs actually embedded in Contents/Frameworks)
# are what the LGPL notice in that panel claims to be true.
source scripts/preflight.sh

# Restore whatever the dev loop had stamped, so a bare xcodebuild afterwards
# does not silently inherit the release stamp.
RESTORE=""
if [[ -f "$VERSION_FILE" ]]; then
  RESTORE="$(mktemp)"
  cp "$VERSION_FILE" "$RESTORE"
fi
cleanup() { [[ -n "$RESTORE" ]] && cp "$RESTORE" "$VERSION_FILE" && rm -f "$RESTORE"; }
trap cleanup EXIT

# One stamp for both bundles. Epoch seconds is monotonic, which is what
# TestFlight requires of successive builds under one marketing version.
BUILD="$(date +%s)"
{
  echo "CURRENT_PROJECT_VERSION = $BUILD"
  echo "EXTENSION_PROJECT_VERSION = $BUILD"
} > "$VERSION_FILE"

MARKETING="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)"
echo "Building RCam $MARKETING ($BUILD) for App Store Connect"

xcodegen generate

rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild archive \
  -project RCam.xcodeproj -scheme RCam -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
  -allowProvisioningUpdates

# Fail loudly here rather than at Apple's validator: a mismatch means the
# version plumbing above stopped working.
APP="$ARCHIVE/Products/Applications/RCam.app"
EXT="$APP/Contents/Library/SystemExtensions/com.strawdynamics.rcam.extension.systemextension"
app_v="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
ext_v="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$EXT/Contents/Info.plist")"
if [[ "$app_v" != "$ext_v" ]]; then
  echo "error: app CFBundleVersion ($app_v) != extension ($ext_v)" >&2
  exit 1
fi
echo "Nested bundle versions agree ($app_v)"

cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>TK7EDP5B95</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates

PKG="$EXPORT/RCam.pkg"
[[ -f "$PKG" ]] || { echo "error: expected $PKG" >&2; exit 1; }
echo "Exported $PKG"

if [[ "$UPLOAD" == yes ]]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID (App Store Connect API key id)}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID (App Store Connect issuer id)}"
  # The private key is looked up as ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
  xcrun altool --upload-app -f "$PKG" -t macos \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "Uploaded. Processing takes ~10-30 min before the build appears in TestFlight."
else
  echo
  echo "Not uploaded. To upload:"
  echo "  scripts/release.sh --upload      (needs ASC_KEY_ID + ASC_ISSUER_ID)"
  echo "  or open $ARCHIVE in Xcode's Organizer and use Distribute App."
fi
