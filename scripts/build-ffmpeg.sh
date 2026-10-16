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
# SHA-256 of ffmpeg-$FFMPEG_VERSION.tar.xz. These dylibs ship inside a signed,
# notarized app, so the tarball is part of the supply chain: pin it rather than
# trusting whatever ffmpeg.org (or anything between here and it) serves today.
# Taken from the tarball whose ffmpeg-7.1.1.tar.xz.asc verified against the
# FFmpeg release signing key (FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8,
# https://ffmpeg.org/ffmpeg-devel.asc). Bumping FFMPEG_VERSION means repeating
# that check, not just copying the new tarball's hash.
FFMPEG_SHA256="733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1"

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

# verify_tarball <file> <description>
verify_tarball() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$actual" != "$FFMPEG_SHA256" ]]; then
    echo "error: $1 ($2) has SHA-256" >&2
    echo "       $actual" >&2
    echo "       expected $FFMPEG_SHA256" >&2
    echo "       Not building from it. Delete it (and $TREE) to re-download, and if" >&2
    echo "       the fresh download mismatches too, find out why before changing the pin." >&2
    exit 1
  fi
}

mkdir -p "$SRC_DIR"
if [[ ! -f "$TARBALL" ]]; then
  # Download to a temp name so an interrupted or rejected download never
  # becomes the "cached" tarball the next run trusts.
  curl -fL --retry 3 -o "$TARBALL.part" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  verify_tarball "$TARBALL.part" "fresh download"
  mv -f "$TARBALL.part" "$TARBALL"
else
  # A cached tarball is checked too: it may predate the pin, or be a CI cache
  # restored from somewhere this run did not produce.
  verify_tarball "$TARBALL" "cached"
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
  `# FFmpeg strips with "strip -x" on install, which drops the debug map (the` \
  `# N_OSO/N_SO stabs pointing at the .o files) along with the local symbols.` \
  `# dsymutil reads exactly that map, so a stripped-on-install dylib yields a` \
  `# dSYM with the right UUID and no symbols in it, which symbolicates` \
  `# nothing. Keep the map, generate` \
  `# the dSYMs below, and strip afterwards, which is the order Xcode uses.` \
  --disable-stripping \
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

# Symbols. These are not optional extras: a release whose crash reports stop
# at the FFmpeg frontier is a release that cannot diagnose its own decode path.
#
# Order matters: dsymutil pulls the DWARF out of the .o files via the debug map
# in each dylib, so it has to run before the strip that removes that map. The
# strip is safe afterwards -- it does not touch LC_UUID, which is what ties the
# dSYM to the binary.
for lib in avformat avcodec avutil; do
  dylib="$PREFIX/lib/$(basename "$(readlink "$PREFIX/lib/lib$lib.dylib")")"
  rm -rf "$dylib.dSYM"
  dsymutil "$dylib" -o "$dylib.dSYM"
  strip -x "$dylib"
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

  # A dSYM whose UUID does not match its dylib is worse than none: the upload
  # warning goes away and the crash reports stay unsymbolicated. And a dSYM
  # built from a stripped binary has the right UUID and nothing in it, which is
  # exactly the shape this guard exists to catch.
  dsym="$dylib.dSYM"
  dsym_uuid="$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2; exit}')"
  dylib_uuid="$(dwarfdump --uuid "$dylib" 2>/dev/null | awk '{print $2; exit}')"
  if [[ -z "$dsym_uuid" || "$dsym_uuid" != "$dylib_uuid" ]]; then
    echo "error: $(basename "$dsym") UUID '$dsym_uuid' does not match the dylib's '$dylib_uuid'" >&2
    exit 1
  fi
  symbols="$(dwarfdump --debug-info "$dsym" 2>/dev/null | grep -c DW_TAG_subprogram || true)"
  if [[ "$symbols" -lt 100 ]]; then
    echo "error: $(basename "$dsym") carries only $symbols subprograms -- the debug map was" >&2
    echo "       stripped before dsymutil ran. Check --disable-stripping in ./configure." >&2
    exit 1
  fi

  lipo -info "$dylib"
done
echo "All libs stamped minos $MACOS_MIN with @rpath install names and matching dSYMs"

# project.yml names these files literally in the Frameworks copy phase, so a
# soname bump on an FFmpeg upgrade has to be noticed here rather than at the
# next launch on someone else's Mac. scripts/build.sh asserts the two agree.
echo
echo "Embed these in project.yml's Frameworks copy phase:"
(cd "$PREFIX/lib" && ls -d lib*.[0-9]*.dylib)
