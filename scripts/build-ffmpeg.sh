#!/bin/bash
# Build a minimal SHARED FFmpeg (demux-only) for the in-process RTSP reader.
# Produces vendor/ffmpeg/{include,lib} (committed); source tree stays in
# vendor/ffmpeg/src (gitignored).
#
# Shared, not static, and that is a licensing decision rather than a technical
# one. FFmpeg is LGPL-2.1, and §6 lets a work that links the library satisfy
# the relink obligation either by shipping the object files (§6a) or by using
# "a suitable shared library mechanism" (§6b). A statically linked, signed app
# bundle offers neither, which is what RCam used to ship. Embedding these
# dylibs in RCam.app/Contents/Frameworks is the §6b path: the libraries are
# separable, replaceable artifacts with stable install names.
#
# The install names are @rpath-relative so the same dylibs work embedded in the
# app bundle and, via an explicit rpath, from the rcamcli dev tool.
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

# Switching between static and shared leaves stale objects that configure will
# happily reuse, so start from a clean tree rather than trusting the flags.
make distclean >/dev/null 2>&1 || true
rm -rf "$PREFIX/lib" "$PREFIX/include"

./configure \
  --prefix="$PREFIX" \
  --arch=arm64 \
  --cc=clang \
  --extra-cflags="-mmacosx-version-min=$MACOS_MIN" \
  `# @loader_path so each dylib can resolve its siblings from wherever the` \
  `# set is installed, without depending on the loading binary's rpaths.` \
  --extra-ldflags="-mmacosx-version-min=$MACOS_MIN -Wl,-rpath,@loader_path" \
  --install-name-dir='@rpath' \
  --disable-everything \
  --enable-shared \
  --disable-static \
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
  --disable-avfilter \
  --disable-swscale \
  --disable-swresample \
  --disable-avdevice

make -j"$(sysctl -n hw.ncpu)"
make install

# Flatten the install layout.
#
# FFmpeg installs three names per library: the full version (libavcodec.61.19.101
# .dylib, the real file), the soname (libavcodec.61.dylib) and the linker name
# (libavcodec.dylib), the latter two symlinks. But the install name it stamps in
# is the *soname*, so the soname is what the loader looks for inside the app
# bundle -- and a bundle full of symlinks is a code-signing problem nobody needs.
#
# So make the soname the real file and drop the full-version name. What is left
# is one real dylib per library plus the linker-name symlink, which never leaves
# this directory: it exists so `-lavcodec` resolves at build time.
for lib in avformat avcodec avutil; do
  full="$(ls "$PREFIX/lib/lib$lib".[0-9]*.[0-9]*.[0-9]*.dylib)"
  soname="$(basename "$(otool -D "$full" | tail -1)")"
  mv -f "$full" "$PREFIX/lib/$soname"
  ln -sf "$soname" "$PREFIX/lib/lib$lib.dylib"
done

echo "=== Installed shared libs ==="
ls -la "$PREFIX/lib"/*.dylib

for lib in avformat avcodec avutil; do
  dylib="$PREFIX/lib/$(basename "$(readlink "$PREFIX/lib/lib$lib.dylib")")"

  # Guard the whole point of MACOS_MIN: a silently-ignored flag looks identical
  # to a working one until someone on an older macOS runs the app.
  actual="$(otool -l "$dylib" | awk '/minos/ {print $2; exit}')"
  if [[ "$actual" != "$MACOS_MIN" ]]; then
    echo "error: $(basename "$dylib") has minos $actual, expected $MACOS_MIN" >&2
    exit 1
  fi

  # A wrong install name is the failure this whole change can produce: the app
  # links and archives fine, then dies at launch on a machine that has no copy
  # of FFmpeg anywhere but inside the bundle.
  install_name="$(otool -D "$dylib" | tail -1)"
  if [[ "$install_name" != "@rpath/$(basename "$dylib")" ]]; then
    echo "error: $(basename "$dylib") install name is '$install_name'," >&2
    echo "       expected '@rpath/$(basename "$dylib")'" >&2
    exit 1
  fi

  lipo -info "$dylib"
done
echo "All libs stamped minos $MACOS_MIN with @rpath install names"

# project.yml names these files literally in the Frameworks copy phase, so a
# soname bump on an FFmpeg upgrade has to be noticed here rather than at the
# next launch on someone else's Mac. scripts/build.sh asserts the two agree.
echo
echo "Embed these in project.yml's Frameworks copy phase:"
(cd "$PREFIX/lib" && ls -d lib*.[0-9]*.dylib)
