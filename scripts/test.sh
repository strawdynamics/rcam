#!/bin/bash
# Run the RCamTests unit bundle (pure parsers only — no FFmpeg, no app host).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

xcodebuild test -project RCam.xcodeproj -scheme RCam -derivedDataPath build
