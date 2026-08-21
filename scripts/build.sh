#!/bin/bash
# Build RCam (+ extension + rcamcli) and install the app to /Applications.
#
# Stamps CFBundleVersion with the current epoch so macOS treats every build's
# extension as an upgrade (it ignores re-installed extensions at the same version).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Configs
echo "CURRENT_PROJECT_VERSION = $(date +%s)" > Configs/Version.xcconfig

xcodegen generate

xcodebuild -project RCam.xcodeproj -scheme RCam -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build

xcodebuild -project RCam.xcodeproj -scheme rcamcli -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build

APP_SRC="build/Build/Products/Debug/RCam.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build product missing at $APP_SRC" >&2
  exit 1
fi

rm -rf /Applications/RCam.app
ditto "$APP_SRC" /Applications/RCam.app

INSTALLED_VERSION="$(defaults read /Applications/RCam.app/Contents/Info CFBundleVersion)"
echo "Installed /Applications/RCam.app (CFBundleVersion ${INSTALLED_VERSION})"
