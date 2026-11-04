# Contributing to RCam

Thanks for helping out. RCam is two halves: a menu bar app and a CoreMediaIO camera system extension. You can work on most of the app without an Apple Developer account. Only the extension and the full installed app need a paid team. Start with the path that fits what you're changing.

## Prerequisites

- An Apple Silicon Mac. RCam is **arm64 only**, and the vendored FFmpeg in `vendor/ffmpeg/` is built for arm64 only.
- macOS 15 or later.
- Xcode 26 or later. The app icon is an `.icon` bundle, which older Xcodes can't compile. CI uses Xcode 26.3.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). `RCam.xcodeproj` is generated from `project.yml`. Edit `project.yml`, never the project file.
- For the test rig: `brew install mediamtx ffmpeg`.

## Zero-signing path (no Apple account)

`rcamcli`, the `RCamTests` unit tests and the test rig all run unsigned. This is exactly what CI runs on every pull request (`.github/workflows/ci.yml`):

```sh
xcodegen generate
scripts/preflight.sh

xcodebuild build -project RCam.xcodeproj -scheme RCam    -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild build -project RCam.xcodeproj -scheme rcamcli -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild test  -project RCam.xcodeproj -scheme RCam    -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

`CODE_SIGNING_ALLOWED=NO` skips team signing. The linker still ad hoc signs arm64 binaries, which is all the test bundle and `rcamcli` need. (`scripts/test.sh` is the same test command, but signed. Use the line above if you have no team.)

To exercise the real RTSP → FFmpeg → VideoToolbox decode path:

```sh
scripts/testrig.sh start     # mediamtx + synthetic H.264 at rtsp://127.0.0.1:8554/{test,test-sub}
build/Build/Products/Debug/rcamcli capture rtsp://127.0.0.1:8554/test --seconds 4 --out "$TMPDIR/frames"
scripts/testrig.sh stop
```

Right after `start`, mediamtx can return 404 for a moment. Wait until `.testrig/mediamtx.log` shows `[path test] stream is available`. `capture` prints per-frame stats and saves every 30th frame as a PNG. Run `rcamcli` with no arguments to see the other commands.

The unsigned RCam app builds, but it can't install its camera extension. System extensions need a team-signed, provisioned app running from `/Applications`.

## Full path (paid Apple Developer team)

You need this to run the app end to end, with the virtual camera showing up in Zoom, Photo Booth and so on.

1. Create `Configs/Local.xcconfig` (gitignored). `Configs/Signing.xcconfig` includes it last, so it overrides the defaults:

   ```
   DEVELOPMENT_TEAM = <your team ID>
   RCAM_BUNDLE_ID_PREFIX = com.example
   ```

   Every bundle ID (`<prefix>.rcam`, `.rcam.extension`, `.rcam.cli`, `.rcam.tests`) and the app group (`<team>.<prefix>.rcam`) derive from these two lines. That keeps the extension's CMIO mach service inside the app group, which the system requires. Xcode's automatic signing creates the matching profiles. Don't edit `Signing.xcconfig` or hardcode identifiers in code or scripts. They read the identity from build settings.

2. Build and install:

   ```sh
   scripts/build.sh
   ```

   This stamps `CFBundleVersion`, runs `xcodegen generate` and `scripts/preflight.sh`, builds the RCam and rcamcli schemes, and installs the app to `/Applications/RCam.app`. A bare `xcodebuild` compiles, but it does **not** update the installed app.

3. Launch `/Applications/RCam.app`. On first launch, approve the extension in System Settings › General › Login Items & Extensions › Camera Extensions. Allow Local Network access when asked. The permission is keyed on the bundle ID. If you change `RCAM_BUNDLE_ID_PREFIX` and LAN cameras start failing with `No route to host` while `127.0.0.1` still works, re-enable RCam in Privacy & Security › Local Network.

4. Verify headlessly with `build/Build/Products/Debug/rcamcli probe-device`, which checks that the "RCam" camera exists and animates.

### Extension changes and reboots

`scripts/build.sh` gives the extension a new version only when its inputs change, and it prints an UPGRADE warning when it does. macOS replaces a camera extension in two stages, so the order matters:

1. After a build that touched `RCamExtension/`, **launch RCam first**. That's what submits the new extension version.
2. Confirm that `systemextensionsctl list` shows the new version `[activated enabled]`, with no sibling left in `terminated waiting to uninstall on reboot`.
3. Only then reboot, if the camera is missing or stale.

If you reboot straight after the build, the reboot drains the wrong generation, and you pay for a second one. `systemextensionsctl list` alone looks healthy in the broken case, so check the version.

Removing the extension (Settings › General › **Remove…**) takes the camera away immediately. sysextd still keeps the record until the next boot, and `systemextensionsctl gc` can't shortcut that.

`systemextensionsctl developer on` lets you activate extensions without the `/Applications` requirement, which can speed up iteration. It only works with **System Integrity Protection disabled**, which lowers your Mac's security. Turn it back off (`developer off`, then re-enable SIP) when you're done. Nothing in the repo needs it.

### Logs

zsh shadows `log` with a builtin, so use the full path:

```sh
/usr/bin/log stream --predicate 'subsystem BEGINSWITH "com.strawdynamics.rcam"'
```

The log subsystems stay `com.strawdynamics.rcam` and `.rcam.extension` even under your own prefix, so this predicate keeps working.

## FFmpeg

`vendor/ffmpeg/` holds prebuilt, demux-only FFmpeg shared libraries, committed so you don't have to build them. `scripts/build-ffmpeg.sh` rebuilds them from the checksum-pinned upstream tarball. Release builds always rebuild from source. Don't commit rebuilt dylibs unless your change is an FFmpeg update. If you bump the version, update `ffmpegVersion` in `RCam/Acknowledgements.swift` too (`scripts/preflight.sh` checks that they match).

## Style

- Match the code around you. Comments are dense and explain *why* (the constraint, the measurement, the macOS behavior), not what the next line does.
- Keep logic you can test in small, Foundation-only types (see `InstallLocation.swift` and `ScheduledUpdateGate.swift`), add them to the `RCamTests` sources in `project.yml`, and cover them with Swift Testing tests.
- Shell scripts use `#!/bin/bash` and `set -euo pipefail`, and fail loudly with a specific `error:` message that says what to do next.
- Put new cross-file invariants that the compiler can't check in `scripts/preflight.sh`.
- Put scratch output in `$TMPDIR` or `build/`, never in the tree.

## Pull requests

- Open an issue first for anything bigger than a small fix, so we can agree on the approach.
- Keep each PR to one focused change, with commit messages in the repo's style (an imperative summary, and a body explaining why).
- CI must pass: preflight, unsigned builds of both schemes, and `RCamTests`. Run the zero-signing commands above locally first.
- In the PR description, say what you tested and how: unit tests, `rcamcli capture` against the rig, or the full app with the extension. Reviewers can't see your camera, so include details (macOS version, camera model) for stream-handling changes.
- User-visible changes get a line under `## [Unreleased]` in `CHANGELOG.md`, written for users.
- Report security issues privately, as described in `SECURITY.md`. Don't open a public issue for them.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
