#!/bin/bash
# Build RCam (+ extension + rcamcli) and install the app to /Applications.
#
# Usage: scripts/build.sh [--release]
#   Default configuration is Debug (keeps iteration fast); --release builds and
#   installs the Release configuration instead.
#
# Versioning: the app and rcamcli get an epoch-stamped CFBundleVersion so every
# build is distinguishable. The *extension* deliberately does not. macOS ignores
# a re-activation at the same version, but treats a new version as an upgrade —
# and an upgrade tears down the running extension, retires the old copy to
# "terminated waiting to uninstall on reboot", and leaves the virtual camera
# device missing until the machine is rebooted. Stamping the extension from the
# clock therefore cost a reboot after *every* build, including builds that only
# touched app or rcamcli code.
#
# So the extension's version is derived from the extension's own inputs
# (RCamExtension/ plus project.yml, which defines its Info.plist and
# entitlements) and stored in Configs/extension-version.txt. Unchanged inputs
# reuse the same version, the activation is a no-op, and the running extension
# and its device survive the build. Changed inputs bump a monotonic counter --
# monotonic rather than the hash itself, so that reverting the extension to a
# previous state is not seen as a version downgrade.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION=Debug
for arg in "$@"; do
  case "$arg" in
    --release) CONFIGURATION=Release ;;
    --debug)   CONFIGURATION=Debug ;;
    *)
      echo "usage: $(basename "$0") [--release|--debug]" >&2
      exit 2
      ;;
  esac
done

mkdir -p Configs

# Cross-file contracts (FFmpeg version, embedded dylib set, sink stream
# name). Shared with release.sh so the shipping artifact gets them too.
source scripts/preflight.sh

# The app icon's master render lives in docs/ (that's where the Blender icon loop
# writes it), but actool will not follow a symlink out of the .icon bundle, so the
# bundle needs its own copy. Re-sync it here rather than relying on whoever
# re-renders the icon to remember.
if ! cmp -s docs/icon-1024.png RCam/AppIcon.icon/Assets/icon-1024.png; then
  cp docs/icon-1024.png RCam/AppIcon.icon/Assets/icon-1024.png
  echo "Synced app icon from docs/icon-1024.png"
fi

# Hash everything the extension is built from.
EXTENSION_INPUT_HASH="$(
  { find RCamExtension -type f -print0 | sort -z | xargs -0 shasum -a 256
    shasum -a 256 project.yml
  } | shasum -a 256 | cut -d' ' -f1
)"

EXTENSION_STATE=Configs/extension-version.txt
PREVIOUS_HASH=""
PREVIOUS_VERSION=0
if [[ -f "$EXTENSION_STATE" ]]; then
  read -r PREVIOUS_HASH PREVIOUS_VERSION < "$EXTENSION_STATE" || true
else
  # No state yet, but a previously-installed extension may carry a much larger
  # version (this scheme replaced an epoch stamp). Seed above it: macOS refuses
  # to activate a lower version than the one already installed.
  # Globbed rather than named: the installed copy may have been built under a
  # different RCAM_BUNDLE_ID_PREFIX, and the bundle only ever holds one.
  INSTALLED_EXTENSION_PLIST="$(compgen -G '/Applications/RCam.app/Contents/Library/SystemExtensions/*.systemextension/Contents/Info.plist' | head -n1 || true)"
  if [[ -n "$INSTALLED_EXTENSION_PLIST" ]]; then
    PREVIOUS_VERSION="$(defaults read "${INSTALLED_EXTENSION_PLIST%.plist}" CFBundleVersion 2>/dev/null || echo 0)"
    [[ "$PREVIOUS_VERSION" =~ ^[0-9]+$ ]] || PREVIOUS_VERSION=0
  fi
fi

if [[ "$EXTENSION_INPUT_HASH" == "$PREVIOUS_HASH" ]]; then
  EXTENSION_VERSION="$PREVIOUS_VERSION"
  EXTENSION_CHANGED=no
else
  EXTENSION_VERSION=$((PREVIOUS_VERSION + 1))
  EXTENSION_CHANGED=yes
fi
printf '%s %s\n' "$EXTENSION_INPUT_HASH" "$EXTENSION_VERSION" > "$EXTENSION_STATE"

{
  echo "CURRENT_PROJECT_VERSION = $(date +%s)"
  echo "EXTENSION_PROJECT_VERSION = $EXTENSION_VERSION"
} > Configs/Version.xcconfig

xcodegen generate

# The team and extension bundle ID come from Configs/Signing.xcconfig (or a
# contributor's Local.xcconfig), so ask Xcode for them rather than repeat them.
EXTENSION_SETTINGS="$(xcodebuild -project RCam.xcodeproj -target RCamExtension \
  -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
extension_setting() {
  awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }' <<< "$EXTENSION_SETTINGS"
}
TEAM_ID="$(extension_setting DEVELOPMENT_TEAM)"
EXTENSION_ID="$(extension_setting PRODUCT_BUNDLE_IDENTIFIER)"
if [[ -z "$TEAM_ID" || -z "$EXTENSION_ID" ]]; then
  echo "error: could not read DEVELOPMENT_TEAM / PRODUCT_BUNDLE_IDENTIFIER for RCamExtension" >&2
  echo "       from xcodebuild -showBuildSettings. Check Configs/Signing.xcconfig." >&2
  exit 1
fi

xcodebuild -project RCam.xcodeproj -scheme RCam -configuration "$CONFIGURATION" \
  -derivedDataPath build -allowProvisioningUpdates build

xcodebuild -project RCam.xcodeproj -scheme rcamcli -configuration "$CONFIGURATION" \
  -derivedDataPath build -allowProvisioningUpdates build

APP_SRC="build/Build/Products/${CONFIGURATION}/RCam.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build product missing at $APP_SRC" >&2
  exit 1
fi

if [[ "$EXTENSION_CHANGED" == yes ]]; then
  systemextensionsctl uninstall \
    "$TEAM_ID" "$EXTENSION_ID" \
    2>/dev/null || true
fi

rm -rf /Applications/RCam.app
ditto "$APP_SRC" /Applications/RCam.app

INSTALLED_VERSION="$(defaults read /Applications/RCam.app/Contents/Info CFBundleVersion)"
echo "Installed /Applications/RCam.app from ${APP_SRC} (${CONFIGURATION}, CFBundleVersion ${INSTALLED_VERSION})"

if [[ "$EXTENSION_CHANGED" == yes ]]; then
  cat >&2 <<'WARNING'

  ⚠️  The system extension changed, so this build is an UPGRADE.
      macOS will tear down the running extension and defer the old copy's
      uninstall to the next reboot. Expect "RCam" to go missing:
      quit and relaunch RCam, and if the device does not come back, reboot.
WARNING
else
  echo "Extension unchanged (version ${EXTENSION_VERSION}) — re-activation is a no-op, the virtual device should survive this build."
fi
