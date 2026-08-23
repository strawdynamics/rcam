#!/bin/bash
# Build a minimal static FFmpeg (demux-only) for the in-process RTSP reader.
# Produces vendor/ffmpeg/{include,lib} (committed); source tree stays in
# vendor/ffmpeg/src (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_VERSION="7.1.1"

# Must match project.yml's deploymentTarget. ./configure otherwise inherits the
# *build machine's* SDK version as the minimum, which stamps the static libs
# with a minos far above what the app claims to support -- the app links and
# runs fine on the build machine and can fail with missing symbols on an older
# one, which is exactly the failure a beta tester finds and the author cannot.
MACOS_MIN="15.0"
PREFIX="$(pwd)/vendor/ffmpeg"
SRC_DIR="$PREFIX/src"
TARBALL="$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"
TREE="$SRC_DIR/ffmpeg-$FFMPEG_VERSION"

mkdir -p "$SRC_DIR"
if [[ ! -f "$TARBALL" ]]; then
  curl -fL --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
if [[ ! -d "$TREE" ]]; then
  tar -xf "$TARBALL" -C "$SRC_DIR"
fi

cd "$TREE"
./configure \
  --prefix="$PREFIX" \
  --arch=arm64 \
  --cc=clang \
  --extra-cflags="-mmacosx-version-min=$MACOS_MIN" \
  --extra-ldflags="-mmacosx-version-min=$MACOS_MIN" \
  --disable-everything \
  --disable-shared \
  --enable-static \
  --disable-programs \
  --disable-doc \
  --disable-autodetect \
  --enable-network \
  --enable-protocol=tcp,rtp,udp \
  --enable-demuxer=rtsp,sdp \
  --enable-parser=h264,hevc \
  `# hevc parser is only here for aom_film_grain.o: h264's h2645_sei.o refs it but only HEVC_SEI builds it` \
  --enable-bsf=h264_mp4toannexb,extract_extradata \
  --disable-decoders \
  --disable-encoders \
  --disable-muxers \
  --disable-filters \
  --disable-swscale \
  --disable-swresample \
  --disable-avdevice

make -j"$(sysctl -n hw.ncpu)"
make install

echo "=== Installed static libs ==="
ls -la "$PREFIX/lib"/*.a
lipo -info "$PREFIX/lib/libavformat.a"

# Guard the whole point of MACOS_MIN: a silently-ignored flag looks identical to
# a working one until someone on an older macOS runs the app.
for lib in avformat avcodec avutil; do
  actual="$(otool -l "$PREFIX/lib/lib$lib.a" | awk '/minos/ {print $2; exit}')"
  if [[ "$actual" != "$MACOS_MIN" ]]; then
    echo "error: lib$lib.a has minos $actual, expected $MACOS_MIN" >&2
    exit 1
  fi
done
echo "All libs stamped minos $MACOS_MIN"
