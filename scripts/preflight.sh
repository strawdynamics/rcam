#!/bin/bash
# Cross-file contracts that nothing in the build itself checks.
#
# Sourced by both scripts/build.sh and scripts/release.sh. It lives here rather
# than in build.sh because release.sh is the path that produces the artifact
# other people run: a guard that only covers the dev loop protects the one
# person who would have noticed anyway.
#
# Every check here is a pair of files that have to agree and cannot be made to
# agree by the compiler. Run from the repo root.
set -euo pipefail

# The FFmpeg version is stated in three places: FFMPEG_VERSION in
# build-ffmpeg.sh, the string the acknowledgements panel shows the user, and the
# published build recipe. Bump one and the other two keep asserting the old
# version -- in a legal notice, where a wrong answer is indistinguishable from a
# right one. The gist is a manual step, but the in-app copy can be held to the
# script.
RECIPE_FFMPEG_VERSION="$(sed -n 's/^FFMPEG_VERSION="\(.*\)"$/\1/p' scripts/build-ffmpeg.sh)"
APP_FFMPEG_VERSION="$(sed -n 's/.*static let ffmpegVersion = "\(.*\)".*/\1/p' RCam/Acknowledgements.swift)"
if [[ -z "$RECIPE_FFMPEG_VERSION" || -z "$APP_FFMPEG_VERSION" ]]; then
  echo "error: could not read the FFmpeg version from build-ffmpeg.sh and/or Acknowledgements.swift" >&2
  exit 1
fi
if [[ "$RECIPE_FFMPEG_VERSION" != "$APP_FFMPEG_VERSION" ]]; then
  echo "error: Acknowledgements.swift says FFmpeg $APP_FFMPEG_VERSION, build-ffmpeg.sh builds $RECIPE_FFMPEG_VERSION" >&2
  echo "       Update RCam/Acknowledgements.swift, and re-publish the build recipe gist it links." >&2
  exit 1
fi

# FFmpeg's dylibs carry their soname in the file name, so project.yml's copy
# phase names them literally. Bump FFmpeg to a release with a new major version
# and those paths silently stop matching what build-ffmpeg.sh produced: the app
# links against the symlinks and builds fine, then finds nothing in
# Contents/Frameworks and dies at launch -- on a tester's Mac, not here, because
# a dev machine still has the vendor directory that rcamcli's rpath points at.
VENDORED_DYLIBS="$(cd vendor/ffmpeg/lib 2>/dev/null && ls -d lib*.[0-9]*.dylib 2>/dev/null | sort | tr '\n' ' ')"
EMBEDDED_DYLIBS="$(sed -n 's|^ *- path: vendor/ffmpeg/lib/\(lib.*\.dylib\)$|\1|p' project.yml | sort | tr '\n' ' ')"
if [[ -z "$VENDORED_DYLIBS" ]]; then
  echo "error: no FFmpeg dylibs in vendor/ffmpeg/lib -- run scripts/build-ffmpeg.sh" >&2
  exit 1
fi
if [[ "$VENDORED_DYLIBS" != "$EMBEDDED_DYLIBS" ]]; then
  echo "error: project.yml embeds a different set of FFmpeg dylibs than vendor/ffmpeg/lib holds" >&2
  echo "       vendored: $VENDORED_DYLIBS" >&2
  echo "       embedded: $EMBEDDED_DYLIBS" >&2
  echo "       Update the copyFiles entries in project.yml's RCam target." >&2
  exit 1
fi

# LGPL-2.1 §6(b) is only satisfied while FFmpeg is actually separable. A static
# build would link and archive silently -- and quietly withdraw the thing the
# acknowledgements panel tells the user they have.
if ls vendor/ffmpeg/lib/*.a >/dev/null 2>&1; then
  echo "error: vendor/ffmpeg/lib holds static archives; RCam ships FFmpeg as dylibs (LGPL §6b)" >&2
  echo "       Re-run scripts/build-ffmpeg.sh, which builds --enable-shared." >&2
  exit 1
fi

# The sink stream's name is a cross-process contract with no compile-time check:
# the extension declares it, and the app finds the stream by exact name match.
# A mismatch is not subtle -- the menu bar reads "Sink attach failed" -- but it
# is only discoverable once the device is back, and any RCamExtension/ edit takes
# the device down until a reboot. So a typo costs two reboots to find and fix.
# Catch it here instead; this file is not part of EXTENSION_INPUT_HASH, so the
# check is free of any extension-version churn.
EXT_SINK_NAME="$(awk '/RCamSinkStreamSource\(/ { found = 1 }
                      found && /localizedName:/ { match($0, /"[^"]*"/)
                                                 print substr($0, RSTART + 1, RLENGTH - 2)
                                                 exit }' RCamExtension/Provider.swift)"
APP_SINK_NAME="$(sed -n 's/.*static let sinkStreamName = "\(.*\)".*/\1/p' RCam/SinkWriter.swift)"
if [[ -z "$EXT_SINK_NAME" || -z "$APP_SINK_NAME" ]]; then
  echo "error: could not read the sink stream name from Provider.swift and/or SinkWriter.swift" >&2
  exit 1
fi
if [[ "$EXT_SINK_NAME" != "$APP_SINK_NAME" ]]; then
  echo "error: the extension names the sink stream \"$EXT_SINK_NAME\", the app looks for \"$APP_SINK_NAME\"" >&2
  echo "       They must match exactly -- SinkWriter finds the stream by name." >&2
  exit 1
fi
