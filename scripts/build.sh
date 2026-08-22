#!/bin/bash
# Build RCam (+ extension + rcamcli) and install the app to /Applications.
#
# Usage: scripts/build.sh [--release]
#   Default configuration is Debug (keeps iteration fast); --release builds and
#   installs the Release configuration instead.
#
# Stamps CFBundleVersion with the current epoch so macOS treats every build's
# extension as an upgrade (it ignores re-installed extensions at the same version).
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
echo "CURRENT_PROJECT_VERSION = $(date +%s)" > Configs/Version.xcconfig

xcodegen generate

xcodebuild -project RCam.xcodeproj -scheme RCam -configuration "$CONFIGURATION" \
  -derivedDataPath build -allowProvisioningUpdates build

xcodebuild -project RCam.xcodeproj -scheme rcamcli -configuration "$CONFIGURATION" \
  -derivedDataPath build -allowProvisioningUpdates build

APP_SRC="build/Build/Products/${CONFIGURATION}/RCam.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build product missing at $APP_SRC" >&2
  exit 1
fi

rm -rf /Applications/RCam.app
ditto "$APP_SRC" /Applications/RCam.app

INSTALLED_VERSION="$(defaults read /Applications/RCam.app/Contents/Info CFBundleVersion)"
echo "Installed /Applications/RCam.app from ${APP_SRC} (${CONFIGURATION}, CFBundleVersion ${INSTALLED_VERSION})"
