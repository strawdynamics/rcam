#!/bin/bash
# Serve a throwaway, higher-versioned RCam as a Sparkle update from a local
# feed, so the update path (scheduled prompt, deferral while the camera is in
# use, install, relaunch, extension upgrade) can be tested end to end without
# publishing anything.
#
# Usage: scripts/update-test.sh [--port N]     (default port 8765)
#
# What it does:
#   1. Builds the RCam scheme (Release, Apple Development signing, the same
#      automatic signing scripts/build.sh uses) into build/update-test/, as
#      marketing version <MARKETING_VERSION with the patch bumped>-test and a
#      fresh epoch CFBundleVersion for both the app and the extension -- so it
#      is newer than any installed release, and sysextd sees an extension
#      upgrade, exactly as a real update would.
#   2. Overrides SUFeedURL through the RCAM_SPARKLE_FEED_URL build setting
#      (project.yml) to http://127.0.0.1:<port>/appcast.xml. No committed file
#      is edited; Configs/Version.xcconfig is restored afterwards, as
#      release.sh does.
#   3. Zips the app and signs the zip with the local Sparkle key (login
#      keychain, account SPARKLE_KEY_ACCOUNT, default: the app's bundle ID),
#      after checking that key's public half is the SUPublicEDKey in the build.
#   4. Writes a one-item appcast.xml and serves build/update-test/serve/ with
#      `python3 -m http.server` on 127.0.0.1 until you press Ctrl-C.
#
# It never touches /Applications or the installed extension, and serves only
# on loopback.
#
# The installed copy is the one that has to look at the local feed, and it was
# built with the real SUFeedURL. Sparkle still honours a SUFeedURL in the app's
# user defaults (it logs a deprecation warning that, per its own message, can
# be ignored "if the feed url was set via a defaults write command for testing
# purposes"). RCam is sandboxed, so that's the container's preferences. The
# script prints the exact defaults commands to point the installed app at the
# local feed, force a scheduled check, and undo both afterwards; it doesn't
# run them itself.
#
# Plain http needs no App Transport Security exception here: ATS doesn't apply
# to IP-address hosts, which is why the feed is 127.0.0.1 and not localhost.
# Sparkle logs that the feed "may need to change to use HTTPS" and carries on;
# the EdDSA signature is what authenticates the update.
#
# Signing mismatch is expected and fine: the installed release is Developer ID,
# this build is Apple Development (same team). Sparkle accepts an update whose
# code signature differs from the host's as long as the EdDSA signature
# verifies and the new code signature is itself valid.
#
# Environment:
#   SPARKLE_KEY_ACCOUNT   Keychain account of the Sparkle private key.
#                         Defaults to the app's bundle ID.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8765
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { echo "error: --port needs a number" >&2; exit 2; }
      PORT="$2"; shift 2 ;;
    *) echo "usage: $(basename "$0") [--port N]" >&2; exit 2 ;;
  esac
done

OUT=build/update-test
SERVE="$OUT/serve"
VERSION_FILE=Configs/Version.xcconfig
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
INSTALLED=/Applications/RCam.app

MARKETING="$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)"
if [[ ! "$MARKETING" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: project.yml MARKETING_VERSION is '$MARKETING', expected X.Y.Z" >&2
  exit 1
fi
TEST_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))-test"

# Fail before a multi-minute build if the port is already taken.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "error: something is already listening on port $PORT; pass --port N" >&2
  exit 1
fi

mkdir -p "$OUT" Configs

# Same restore as release.sh: the next bare xcodebuild must not inherit this
# throwaway stamp.
RESTORE=""
if [[ -f "$VERSION_FILE" ]]; then
  RESTORE="$(mktemp)"
  cp "$VERSION_FILE" "$RESTORE"
fi
restore_version() {
  if [[ -n "$RESTORE" ]]; then
    cp "$RESTORE" "$VERSION_FILE" && rm -f "$RESTORE"
  else
    rm -f "$VERSION_FILE"
  fi
  RESTORE=""
}
trap restore_version EXIT

# One epoch stamp for both bundles, as in a release: newer than whatever is
# installed, and an extension upgrade rather than a no-op re-activation.
BUILD="$(date +%s)"
{
  echo "CURRENT_PROJECT_VERSION = $BUILD"
  echo "EXTENSION_PROJECT_VERSION = $BUILD"
} > "$VERSION_FILE"

echo "Building RCam $TEST_VERSION ($BUILD) with SUFeedURL $FEED_URL"

xcodegen generate

APP_ID="$(xcodebuild -project RCam.xcodeproj -target RCam -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk '$1 == "PRODUCT_BUNDLE_IDENTIFIER" && $2 == "=" { print $3; exit }')"
if [[ -z "$APP_ID" ]]; then
  echo "error: could not read RCam's PRODUCT_BUNDLE_IDENTIFIER from xcodebuild -showBuildSettings" >&2
  exit 1
fi

rm -rf "$OUT/dd/Build/Products" "$SERVE"
xcodebuild -project RCam.xcodeproj -scheme RCam -configuration Release \
  -derivedDataPath "$OUT/dd" -allowProvisioningUpdates \
  MARKETING_VERSION="$TEST_VERSION" \
  RCAM_SPARKLE_FEED_URL="$FEED_URL" \
  build

restore_version
trap - EXIT

APP="$OUT/dd/Build/Products/Release/RCam.app"
[[ -d "$APP" ]] || { echo "error: build product missing at $APP" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# Each of these would make the test fail in a confusing way on the client
# side, so check them here.
EXT="$(compgen -G "$APP/Contents/Library/SystemExtensions/*.systemextension" | head -n1 || true)"
[[ -n "$EXT" ]] || { echo "error: no system extension inside $APP" >&2; exit 1; }
app_v="$(plist "$APP" CFBundleVersion)"
ext_v="$(plist "$EXT" CFBundleVersion)"
if [[ "$app_v" != "$BUILD" || "$ext_v" != "$BUILD" ]]; then
  echo "error: expected CFBundleVersion $BUILD on both bundles, got app $app_v, extension $ext_v" >&2
  exit 1
fi
built_feed="$(plist "$APP" SUFeedURL)"
if [[ "$built_feed" != "$FEED_URL" ]]; then
  echo "error: built SUFeedURL is '$built_feed', expected $FEED_URL" >&2
  echo "       (is SUFeedURL still \$(RCAM_SPARKLE_FEED_URL) in project.yml?)" >&2
  exit 1
fi
ed_key="$(plist "$APP" SUPublicEDKey)"
if [[ ! "$ed_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "error: SUPublicEDKey in the build is '$ed_key', not a Sparkle EdDSA public key." >&2
  echo "       Set it in project.yml first; Sparkle won't start without it." >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

if [[ -d "$INSTALLED" ]]; then
  installed_v="$(plist "$INSTALLED" CFBundleVersion)"
  if [[ ! "$installed_v" =~ ^[0-9]+$ || "$installed_v" -ge "$BUILD" ]]; then
    echo "error: installed $INSTALLED is CFBundleVersion '$installed_v', not older than $BUILD;" >&2
    echo "       Sparkle would not offer this build." >&2
    exit 1
  fi
  installed_key="$(plist "$INSTALLED" SUPublicEDKey)"
  if [[ "$installed_key" != "$ed_key" ]]; then
    echo "warning: installed RCam's SUPublicEDKey ($installed_key) differs from this build's;" >&2
    echo "         it will reject the update's signature." >&2
  fi
else
  echo "warning: nothing at $INSTALLED yet; install the release there before testing." >&2
fi

# sign_update and generate_keys from the very Sparkle version the app links,
# resolved by this build (the same choice release.sh makes).
SPARKLE_BIN="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/sign_update" || ! -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "error: sign_update/generate_keys not found in $SPARKLE_BIN. The Sparkle SPM" >&2
  echo "       artifact layout may have changed; look under $OUT/dd/SourcePackages/artifacts." >&2
  exit 1
fi
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-$APP_ID}"
# A signature from the wrong key only shows up as a vague "update is improperly
# signed" alert on the client, so compare the keychain key to the plist first.
keychain_key="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p 2>/dev/null || true)"
if [[ "$keychain_key" != "$ed_key" ]]; then
  echo "error: the Sparkle key in the login keychain (account $KEY_ACCOUNT) has public" >&2
  echo "       key '${keychain_key:-<none found>}', but the build's SUPublicEDKey is $ed_key." >&2
  echo "       Set SPARKLE_KEY_ACCOUNT, or check the key with generate_keys -p." >&2
  exit 1
fi

# ditto, not zip: it keeps the bundle's symlinks and extended attributes,
# which the code signature depends on.
mkdir -p "$SERVE"
ARCHIVE_NAME="RCam-$TEST_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SERVE/$ARCHIVE_NAME"
ed_signature="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" -p "$SERVE/$ARCHIVE_NAME")"
if [[ -z "$ed_signature" ]]; then
  echo "error: sign_update produced no EdDSA signature" >&2
  exit 1
fi

min_os="$(plist "$APP" LSMinimumSystemVersion)"
length="$(stat -f %z "$SERVE/$ARCHIVE_NAME")"
cat > "$SERVE/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>RCam (local update test)</title>
    <link>$FEED_URL</link>
    <description>Throwaway feed from scripts/update-test.sh.</description>
    <language>en</language>
    <item>
      <title>Version $TEST_VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$TEST_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>Local update test build $TEST_VERSION ($BUILD). Not a release.</p>]]></description>
      <enclosure url="http://127.0.0.1:$PORT/$ARCHIVE_NAME" length="$length" type="application/octet-stream" sparkle:edSignature="$ed_signature"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$SERVE/appcast.xml"

PREFS="\$HOME/Library/Containers/$APP_ID/Data/Library/Preferences/$APP_ID"
cat <<STEPS

Update $TEST_VERSION ($BUILD) is signed and ready in $SERVE.

To test (quit RCam first; defaults written while it runs can be lost):

  # Point the installed RCam at this feed, and make its next launch a
  # scheduled check by backdating the last one.
  defaults write "$PREFS" SUFeedURL "$FEED_URL"
  defaults write "$PREFS" SULastCheckTime -date "2001-01-01 00:00:00 +0000"

  Then: start Photo Booth on the RCam camera, launch RCam, and confirm no
  update prompt appears. Close Photo Booth; the prompt should follow. Install,
  confirm RCam relaunches, and check \`systemextensionsctl list\` for extension
  $BUILD [activated enabled] with no stuck sibling. "Check for Updates…"
  should show the prompt at once even while the camera is in use.

Afterwards, undo the override (the update itself also points at this feed,
so reinstall the release to get back to the real one):

  defaults delete "$PREFS" SUFeedURL

Serving on http://127.0.0.1:$PORT/ -- Ctrl-C to stop.
STEPS

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVE"
