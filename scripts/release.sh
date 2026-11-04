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
#   NOTARY_PROFILE                       notarytool keychain profile (from
#                                        `xcrun notarytool store-credentials`).
#                                        Used locally.
#   ASC_API_KEY_PATH, ASC_API_KEY_ID,    App Store Connect API key (.p8 path, key
#   ASC_API_ISSUER_ID                    ID, issuer ID) for notarytool. Used in CI;
#                                        takes precedence over NOTARY_PROFILE.
#   SPARKLE_ED_PRIVATE_KEY               The Sparkle EdDSA private key (CI). When
#                                        unset, sign_update reads the key from the
#                                        login keychain under SPARKLE_KEY_ACCOUNT.
#   SPARKLE_KEY_ACCOUNT                  Keychain account of that key. Defaults to
#                                        the app's bundle ID, which is what the
#                                        key was generated under
#                                        (generate_keys --account <bundle ID>).
#
# Artifacts, all in build/release/:
#   RCam-<version>.dmg            notarized and stapled, app + /Applications link
#   RCam-<version>-dSYMs.zip      ours plus the FFmpeg dylibs'
#   notes.md                      this version's CHANGELOG.md section
#   appcast-item.xml              one Sparkle <item>; scripts/appcast-merge.sh
#                                 prepends it to the live appcast
#   SHA256SUMS                    for the DMG and the dSYMs zip
#
# sign_update is the copy in the Sparkle SPM artifact xcodebuild resolves into
# build/release/dd/SourcePackages for this very archive, so the signing tool is
# always the same Sparkle version the app links -- no separate download.
#
# --unsigned archives with CODE_SIGNING_ALLOWED=NO and skips export, signing,
# notarization and Sparkle signing, but still produces the DMG and every other
# artifact, so the script can be smoke-tested with no certificate, profile or
# Apple account. Its output is not runnable as a system extension host, and its
# appcast item has no sparkle:edSignature, so no Sparkle client would accept it.
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
# An if, not &&: a false test as the EXIT trap's last command would become the
# script's exit status, failing every run that started with no $VERSION_FILE.
cleanup() { if [[ -n "$RESTORE" ]]; then cp "$RESTORE" "$VERSION_FILE" && rm -f "$RESTORE"; fi; }
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

  # Everything the post-archive steps need is checked now, not after a
  # ten-minute archive and notarization round trip.

  # The DMG is signed with codesign directly (export only signs the app), so
  # pin the exact certificate: a bare "Developer ID Application" is ambiguous
  # in a keychain holding more than one team's.
  DMG_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) { print $2; exit }')"
  if [[ -z "$DMG_IDENTITY" ]]; then
    echo "error: no valid \"Developer ID Application: … ($TEAM_ID)\" identity in the keychain" >&2
    echo "       search list (security find-identity -v -p codesigning)." >&2
    exit 1
  fi

  if [[ -n "${ASC_API_KEY_PATH:-}" ]]; then
    if [[ ! -f "$ASC_API_KEY_PATH" || -z "${ASC_API_KEY_ID:-}" || -z "${ASC_API_ISSUER_ID:-}" ]]; then
      echo "error: ASC_API_KEY_PATH needs an existing .p8 file plus ASC_API_KEY_ID and" >&2
      echo "       ASC_API_ISSUER_ID (got path '$ASC_API_KEY_PATH')." >&2
      exit 1
    fi
    NOTARY_AUTH=(--key "$ASC_API_KEY_PATH" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
  elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  else
    echo "error: no notarization credentials. Set NOTARY_PROFILE to a profile saved with" >&2
    echo "       \`xcrun notarytool store-credentials\`, or ASC_API_KEY_PATH, ASC_API_KEY_ID" >&2
    echo "       and ASC_API_ISSUER_ID (or pass --unsigned)." >&2
    exit 1
  fi

  if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    SPARKLE_KEY_ARGS=(--ed-key-file -)
  else
    SPARKLE_KEY_ARGS=(--account "${SPARKLE_KEY_ACCOUNT:-$APP_ID}")
  fi
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

# Clear every artifact a previous run left, so nothing stale can be uploaded
# alongside this run's output.
rm -rf "$ARCHIVE" "$EXPORT" "$OUT/dmg" "$OUT/notarize" \
  "$OUT"/RCam-*.dmg "$OUT"/RCam-*-dSYMs.zip "$OUT/appcast-item.xml" "$OUT/SHA256SUMS"
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

# notarytool exits 0 for some rejected submissions, so trust only the status
# it reports, and print Apple's log on failure: it names the offending binary.
notarize() {
  local file="$1" result id status
  echo "Notarizing $(basename "$file")…"
  result="$(xcrun notarytool submit "$file" "${NOTARY_AUTH[@]}" --wait --output-format json)" || true
  id="$(plutil -extract id raw -o - - <<< "$result" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - - <<< "$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    echo "error: notarization of $file ended with status '${status:-unknown}':" >&2
    echo "$result" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" >&2 || true
    fi
    return 1
  fi
  echo "Notarized $(basename "$file") (submission $id)"
}

SIGN_UPDATE="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ "$SIGNED" == yes ]]; then
  if [[ ! -x "$SIGN_UPDATE" ]]; then
    echo "error: $SIGN_UPDATE not found. The Sparkle SPM artifact layout may have" >&2
    echo "       changed; look under $OUT/dd/SourcePackages/artifacts." >&2
    exit 1
  fi
  # A release shipped with the placeholder (or no) key can never be updated:
  # Sparkle refuses to start without a valid SUPublicEDKey.
  ed_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ ! "$ed_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "error: SUPublicEDKey in the built Info.plist is '$ed_key', not a Sparkle" >&2
    echo "       EdDSA public key. Set it in project.yml before releasing." >&2
    exit 1
  fi

  # The XML declaration must be the first byte of the file, hence column 0.
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

  # Notarization rejects any executable without the hardened runtime, and says
  # so only after a round trip to Apple. Check every one we ship: the app, the
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

  # Notarize and staple the app itself, not just the DMG: the ticket then
  # travels with RCam.app once it's dragged out of the image, so Gatekeeper
  # can check it offline. notarytool takes a zip, not a bare bundle.
  mkdir -p "$OUT/notarize"
  ditto -c -k --keepParent "$APP" "$OUT/notarize/RCam.zip"
  notarize "$OUT/notarize/RCam.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# A plain hdiutil image: the app plus a link to /Applications to drag it onto.
# No background art or .DS_Store layout, which would need Finder scripting
# that CI runners can't do headlessly. The app is copied in after stapling.
DMG="$OUT/RCam-$MARKETING.dmg"
mkdir -p "$OUT/dmg"
ditto "$APP" "$OUT/dmg/RCam.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname RCam -srcfolder "$OUT/dmg" -fs HFS+ -format UDZO -ov "$DMG"

if [[ "$SIGNED" == yes ]]; then
  # The DMG gets its own signature and ticket so the first thing Gatekeeper
  # sees on download already checks out. Stapling rewrites the file, so the
  # Sparkle signature has to come after it.
  codesign --sign "$DMG_IDENTITY" --timestamp "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  ed_signature="$(
    if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
      printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY"
    fi | "$SIGN_UPDATE" "${SPARKLE_KEY_ARGS[@]}" -p "$DMG"
  )"
  if [[ -z "$ed_signature" ]]; then
    echo "error: sign_update produced no EdDSA signature for $DMG" >&2
    exit 1
  fi
fi

# The appcast description is notes.md as HTML; Sparkle renders it in the update
# prompt. Only the Markdown CHANGELOG.md actually uses is handled -- headings,
# "-"/"*" bullets (indented lines continue the bullet), paragraphs, `code`,
# **bold**, *italics* and [links](url) -- in macOS's stock perl, so neither a
# runner nor a contributor needs a Markdown package. Text is escaped before
# markup is added, which also guarantees no "]]>" can end the CDATA early.
render_notes_html() {
  perl -e '
    use strict; use warnings;
    sub esc { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
    sub inline {
      my @parts = split /`/, shift, -1;
      for my $i (0 .. $#parts) {
        if ($i % 2) { $parts[$i] = "<code>" . esc($parts[$i]) . "</code>"; next }
        my $t = esc($parts[$i]);
        $t =~ s{\[([^\]]+)\]\(([^)\s]+)\)}{<a href="$2">$1</a>}g;
        $t =~ s{\*\*(.+?)\*\*}{<strong>$1</strong>}g;
        $t =~ s{(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])}{<em>$1</em>}g;
        $parts[$i] = $t;
      }
      join "", @parts;
    }
    my (@out, @para, @items, $in_list);
    sub flush {
      push @out, "<p>" . inline(join " ", @para) . "</p>" if @para;
      push @out, "<ul>\n" . join("", map { "<li>" . inline($_) . "</li>\n" } @items) . "</ul>" if @items;
      @para = (); @items = (); $in_list = 0;
    }
    while (my $line = <>) {
      chomp $line;
      if ($line =~ /^\s*$/) { flush(); next }
      if ($line =~ /^(#{1,6})\s+(.*?)\s*$/) {
        flush(); my $n = length $1; push @out, "<h$n>" . inline($2) . "</h$n>"; next;
      }
      if ($line =~ /^[-*]\s+(.*)$/) {
        push @out, "<p>" . inline(join " ", @para) . "</p>" if @para; @para = ();
        push @items, $1; $in_list = 1; next;
      }
      if ($in_list && $line =~ /^\s+(\S.*)$/) { $items[-1] .= " $1"; next }
      flush() if $in_list;
      (my $text = $line) =~ s/^\s+//;
      push @para, $text;
    }
    flush();
    print join("\n", @out), "\n";
  ' "$1"
}

# One <item> for this release. It isn't a standalone XML document (the
# sparkle: prefix is declared on the feed's <rss>); scripts/appcast-merge.sh
# prepends it to the live appcast.xml and validates the result.
#
# sparkle:version is CFBundleVersion, the epoch stamp: it's what Sparkle
# compares. The minimum system version comes from the built bundle so it can't
# drift from the deployment target.
min_os="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
dmg_length="$(stat -f %z "$DMG")"
dmg_url="https://github.com/strawdynamics/rcam/releases/download/v$MARKETING/$(basename "$DMG")"
if [[ "$SIGNED" == yes ]]; then
  signature_attr=" sparkle:edSignature=\"$ed_signature\""
  unsigned_note=""
else
  signature_attr=""
  unsigned_note=$'\n      <!-- Unsigned smoke-test build: no sparkle:edSignature, so Sparkle would reject this item. -->'
fi
{
  cat <<ITEM
    <item>
      <title>Version $MARKETING</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$app_v</sparkle:version>
      <sparkle:shortVersionString>$MARKETING</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <description><![CDATA[
ITEM
  render_notes_html "$OUT/notes.md"
  cat <<ITEM
      ]]></description>$unsigned_note
      <enclosure url="$dmg_url" length="$dmg_length" type="application/octet-stream"$signature_attr/>
    </item>
ITEM
} > "$OUT/appcast-item.xml"

DSYMS_ZIP="$OUT/RCam-$MARKETING-dSYMs.zip"
ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYMS_ZIP"

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$DSYMS_ZIP")" > SHA256SUMS)

echo
if [[ "$SIGNED" == yes ]]; then
  echo "Release $MARKETING ($app_v) is notarized, stapled and Sparkle-signed."
else
  echo "Unsigned release $MARKETING ($app_v): signing, notarization and Sparkle skipped."
fi
echo "Artifacts in $OUT:"
for f in "$(basename "$DMG")" "$(basename "$DSYMS_ZIP")" notes.md appcast-item.xml SHA256SUMS; do
  echo "  $f"
done
