#!/bin/bash
# Build a Developer ID-signed release of RCam.
#
# Usage: scripts/release.sh [--unsigned]
#
# Environment:
#   RELEASE_TAG                          Optional. When set (CI sets it to the pushed
#                                        tag), it must equal v$MARKETING_VERSION.
#   RCAM_APP_PROVISIONING_PROFILE        Path to the Developer ID profile for the app.
#   RCAM_EXTENSION_PROVISIONING_PROFILE  Path to the Developer ID profile for the
#                                        extension. Both are required when signing:
#                                        system-extension.install and the app group
#                                        are profile-gated, so neither bundle can be
#                                        signed for Developer ID without one.
#
# --unsigned archives with CODE_SIGNING_ALLOWED=NO and skips export and every
# signing check, so the script can be smoke-tested with no certificate, profile
# or Apple account. Its output is not runnable as a system extension host.
#
# Signing needs a "Developer ID Application" identity in a keychain on the
# search list. The archive is signed with it directly (Manual style) rather
# than with Apple Development and re-signed at export: CI only ever has the
# Developer ID certificate.
#
# This is deliberately NOT scripts/build.sh. build.sh optimises for the dev
# loop: it installs to /Applications and keeps the extension's CFBundleVersion
# pinned so the running virtual camera survives a rebuild. Neither is wanted
# here. A release stamps the app and the extension with the same epoch value,
# so a shipped extension's version always moves forward with the app's and
# the two can be matched up from either bundle.
#
# Nothing is installed to /Applications and the local extension is never
# touched, so running this does not disturb a working dev install.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNED=yes
for arg in "$@"; do
  case "$arg" in
    --unsigned) SIGNED=no ;;
    *) echo "usage: $(basename "$0") [--unsigned]" >&2; exit 2 ;;
  esac
done

OUT=build/release
ARCHIVE="$OUT/RCam.xcarchive"
EXPORT="$OUT/export"
VERSION_FILE=Configs/Version.xcconfig
# Overridable only so the extraction can be exercised against a scratch file.
CHANGELOG="${RCAM_CHANGELOG:-CHANGELOG.md}"

mkdir -p "$OUT" Configs

# Same cross-file contracts build.sh enforces. They matter more here: this is
# the build strangers run, and two of the three (the FFmpeg version in the
# acknowledgements panel, the dylibs actually embedded in Contents/Frameworks)
# are what the LGPL notice in that panel claims to be true.
source scripts/preflight.sh

# project.yml is the one source of truth for the version. The tag, the
# changelog and the bundle all have to agree with it, and it is far cheaper to
# find out they don't before a ten-minute archive and notarization.
MARKETING="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)"
if [[ -z "$MARKETING" ]]; then
  echo "error: could not read MARKETING_VERSION from project.yml" >&2
  exit 1
fi
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$MARKETING" ]]; then
  echo "error: tag $RELEASE_TAG does not match project.yml MARKETING_VERSION $MARKETING" >&2
  echo "       (expected v$MARKETING). Bump MARKETING_VERSION or re-tag." >&2
  exit 1
fi

# The section body, minus its heading, becomes the GitHub release notes and the
# appcast description. Keep a Changelog headings look like "## [1.0.2] - date".
if [[ ! -f "$CHANGELOG" ]]; then
  echo "error: $CHANGELOG not found; it needs a \"## [$MARKETING]\" section for this release" >&2
  exit 1
fi
if ! grep -qF "## [$MARKETING]" "$CHANGELOG"; then
  echo "error: $CHANGELOG has no \"## [$MARKETING]\" section. Add one before releasing." >&2
  exit 1
fi
awk -v heading="## [$MARKETING]" '
  index($0, heading) == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$CHANGELOG" \
  | sed -e '/./,$!d' \
  | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' > "$OUT/notes.md"
if [[ ! -s "$OUT/notes.md" ]]; then
  echo "error: the \"## [$MARKETING]\" section of $CHANGELOG is empty" >&2
  exit 1
fi
echo "Release notes: $OUT/notes.md ($(wc -l < "$OUT/notes.md" | tr -d ' ') lines)"

# Restore whatever the dev loop had stamped, so a bare xcodebuild afterwards
# does not silently inherit the release stamp.
RESTORE=""
if [[ -f "$VERSION_FILE" ]]; then
  RESTORE="$(mktemp)"
  cp "$VERSION_FILE" "$RESTORE"
fi
cleanup() { [[ -n "$RESTORE" ]] && cp "$RESTORE" "$VERSION_FILE" && rm -f "$RESTORE"; }
trap cleanup EXIT

# One stamp for both bundles. Epoch seconds is monotonic, which is what Sparkle
# compares (sparkle:version is CFBundleVersion) and what sysextd needs to treat
# the new extension as an upgrade rather than a no-op.
BUILD="$(date +%s)"
{
  echo "CURRENT_PROJECT_VERSION = $BUILD"
  echo "EXTENSION_PROJECT_VERSION = $BUILD"
} > "$VERSION_FILE"

echo "Building RCam $MARKETING ($BUILD), $([[ "$SIGNED" == yes ]] && echo "Developer ID" || echo "unsigned")"

xcodegen generate

# The team and bundle IDs come from Configs/Signing.xcconfig (or a
# Local.xcconfig override), so ask Xcode for them rather than repeat them.
target_setting() {
  xcodebuild -project RCam.xcodeproj -target "$1" -configuration Release \
    -showBuildSettings 2>/dev/null \
    | awk -v key="$2" '$1 == key && $2 == "=" { print $3; exit }'
}
TEAM_ID="$(target_setting RCamExtension DEVELOPMENT_TEAM)"
APP_ID="$(target_setting RCam PRODUCT_BUNDLE_IDENTIFIER)"
EXTENSION_ID="$(target_setting RCamExtension PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$TEAM_ID" || -z "$APP_ID" || -z "$EXTENSION_ID" ]]; then
  echo "error: could not read DEVELOPMENT_TEAM / PRODUCT_BUNDLE_IDENTIFIER for RCam and" >&2
  echo "       RCamExtension from xcodebuild -showBuildSettings. Check Configs/Signing.xcconfig." >&2
  exit 1
fi

# Checks a Developer ID profile is for this team and bundle ID, installs it
# where Xcode looks, and prints its UUID. Catching a swapped or wrong-team
# profile here gives a readable error instead of an opaque codesign failure.
PROFILE_DIRS=(
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"  # Xcode 16+
  "$HOME/Library/MobileDevice/Provisioning Profiles"              # older Xcode
)
install_profile() {
  local var="$1" bundle_id="$2" path decoded uuid team app_identifier all_devices dir
  path="${!var:-}"
  if [[ -z "$path" ]]; then
    echo "error: set $var to the Developer ID provisioning profile for $bundle_id" >&2
    echo "       (or pass --unsigned to smoke-test without signing)." >&2
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    echo "error: $var=$path does not exist" >&2
    return 1
  fi
  decoded="$(mktemp)"
  if ! security cms -D -i "$path" > "$decoded" 2>/dev/null; then
    rm -f "$decoded"
    echo "error: $var=$path is not a provisioning profile (security cms -D failed)" >&2
    return 1
  fi
  pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$decoded" 2>/dev/null || true; }
  uuid="$(pb UUID)"
  team="$(pb TeamIdentifier:0)"
  app_identifier="$(pb Entitlements:com.apple.application-identifier)"
  # Set only on Developer ID profiles; development profiles list devices.
  all_devices="$(pb ProvisionsAllDevices)"
  rm -f "$decoded"
  if [[ "$team" != "$TEAM_ID" || "$app_identifier" != "$TEAM_ID.$bundle_id" ]]; then
    echo "error: $var=$path is for $app_identifier (team $team)," >&2
    echo "       but this build needs $TEAM_ID.$bundle_id" >&2
    return 1
  fi
  if [[ "$all_devices" != true ]]; then
    echo "error: $var=$path is not a Developer ID profile (no ProvisionsAllDevices)" >&2
    return 1
  fi
  for dir in "${PROFILE_DIRS[@]}"; do
    mkdir -p "$dir"
    cp "$path" "$dir/$uuid.provisionprofile"
  done
  echo "$uuid"
}

ARCHIVE_SIGNING=()
if [[ "$SIGNED" == yes ]]; then
  APP_PROFILE_UUID="$(install_profile RCAM_APP_PROVISIONING_PROFILE "$APP_ID")"
  EXTENSION_PROFILE_UUID="$(install_profile RCAM_EXTENSION_PROVISIONING_PROFILE "$EXTENSION_ID")"
  echo "Profiles: app $APP_PROFILE_UUID, extension $EXTENSION_PROFILE_UUID"
  # The two *_PROFILE_SPECIFIER settings feed each target's
  # PROVISIONING_PROFILE_SPECIFIER in project.yml; the rest apply everywhere,
  # which is fine because only those two targets take a profile.
  ARCHIVE_SIGNING=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=Developer ID Application"
    "RCAM_APP_PROFILE_SPECIFIER=$APP_PROFILE_UUID"
    "RCAM_EXTENSION_PROFILE_SPECIFIER=$EXTENSION_PROFILE_UUID"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
else
  ARCHIVE_SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi

rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild archive \
  -project RCam.xcodeproj -scheme RCam -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" \
  "${ARCHIVE_SIGNING[@]}"

# Fail loudly here rather than on a user's Mac: a mismatch means the version
# plumbing above stopped working.
APP="$ARCHIVE/Products/Applications/RCam.app"
EXT="$APP/Contents/Library/SystemExtensions/$EXTENSION_ID.systemextension"
app_v="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
ext_v="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$EXT/Contents/Info.plist")"
if [[ "$app_v" != "$ext_v" ]]; then
  echo "error: app CFBundleVersion ($app_v) != extension ($ext_v)" >&2
  exit 1
fi
echo "Nested bundle versions agree ($app_v)"

# Xcode only puts dSYMs in the archive for targets it built. FFmpeg is copied
# in prebuilt, so its three dylibs arrive with no symbols, and a crash inside
# libav would be unsymbolicatable. Copy ours in next to the ones Xcode
# generated, so the release's dSYM bundle is complete.
#
# The UUID is the whole contract -- symbolication matches dSYM to binary by
# UUID, not by name -- so verify against the dylib as it sits in the archive
# rather than trusting that vendor/ still holds what was linked into this build.
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
  name="$(basename "$dylib")"
  dsym="vendor/ffmpeg/lib/$name.dSYM"
  if [[ ! -d "$dsym" ]]; then
    echo "error: no $dsym to accompany the embedded $name -- run scripts/build-ffmpeg.sh" >&2
    exit 1
  fi
  archive_uuid="$(dwarfdump --uuid "$dylib" | awk '{print $2; exit}')"
  dsym_uuid="$(dwarfdump --uuid "$dsym" | awk '{print $2; exit}')"
  if [[ "$archive_uuid" != "$dsym_uuid" ]]; then
    echo "error: $name in the archive is UUID $archive_uuid, but $dsym is $dsym_uuid" >&2
    echo "       The vendored dSYMs are stale -- re-run scripts/build-ffmpeg.sh." >&2
    exit 1
  fi
  ditto "$dsym" "$ARCHIVE/dSYMs/$name.dSYM"
done
echo "Bundled dSYMs: $(cd "$ARCHIVE/dSYMs" && ls -d *.dSYM | tr '\n' ' ')"

if [[ "$SIGNED" == no ]]; then
  echo
  echo "Unsigned archive at $ARCHIVE (export and signing checks skipped)."
  exit 0
fi

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>$APP_ID</key><string>$APP_PROFILE_UUID</string>
    <key>$EXTENSION_ID</key><string>$EXTENSION_PROFILE_UUID</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist"

APP="$EXPORT/RCam.app"
EXT="$APP/Contents/Library/SystemExtensions/$EXTENSION_ID.systemextension"
[[ -d "$APP" ]] || { echo "error: expected $APP after export" >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP"

# Notarization rejects any executable without the hardened runtime, and says so
# only after a round trip to Apple. Check every one we ship: the app, the
# extension, Sparkle's helpers (re-signed at export) and the FFmpeg dylibs.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for code in \
  "$APP" \
  "$EXT" \
  "$SPARKLE/Autoupdate" \
  "$SPARKLE/Updater.app" \
  "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/XPCServices/Downloader.xpc" \
  "$APP/Contents/Frameworks"/libav*.dylib
do
  if [[ ! -e "$code" ]]; then
    echo "error: expected $code in the exported app" >&2
    exit 1
  fi
  details="$(codesign -d --verbose=2 "$code" 2>&1)"
  if ! grep -q '^CodeDirectory .*flags=.*(runtime)' <<< "$details"; then
    echo "error: ${code#"$APP"/} is not signed with the hardened runtime:" >&2
    grep '^CodeDirectory' <<< "$details" >&2 || true
    exit 1
  fi
  if ! grep -q "^TeamIdentifier=$TEAM_ID\$" <<< "$details"; then
    echo "error: ${code#"$APP"/} is not signed by team $TEAM_ID" >&2
    exit 1
  fi
done
echo "Signed with Developer ID and the hardened runtime: $APP"
