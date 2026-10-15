# RCam

A macOS menu bar app that turns RTSP camera streams (security cams, IP cams) into a virtual camera — RCam — usable in QuickTime, Zoom, Meet, FaceTime, etc.

## How it works

Two halves:

- **RCam** (menu bar app): connects to the selected camera over RTSP (TCP), demuxes with a minimal FFmpeg build, hardware-decodes H.264 via VideoToolbox, and pushes 1920×1080@30 NV12 frames into the extension's sink stream via the CoreMediaIO C API. Camera config lives in JSON (no credentials); credentials live in the Keychain.
- **RCamExtension** (CMIO camera extension): owns a 30 Hz clock and always emits a frame — fresh sink frame, last-good frame, or a rendered placeholder — so clients never see a stall, even if the stream (or the app) dies mid-call.

The app only holds an RTSP connection while something is actually watching the virtual camera, and disconnects after a short grace period. Reconnects use exponential backoff and handle sleep/wake.

## Building

Requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an Apple Silicon Mac (arm64 only).

```sh
scripts/build.sh
```

This regenerates the Xcode project, bumps the extension version, builds, and installs `RCam.app` into `/Applications` (the extension can only activate from there). On first launch, approve the extension in System Settings → Privacy & Security.

The vendored FFmpeg libs (demux-only, no decoders) are prebuilt in `vendor/ffmpeg/`; rebuild them with `scripts/build-ffmpeg.sh` if needed. They are shared libraries, embedded in `RCam.app/Contents/Frameworks` and replaceable in place — LGPL-2.1 §6(b), which is what lets RCam ship FFmpeg in a signed app bundle at all.

## Development

- `scripts/testrig.sh {start|stop}` — local mediamtx + ffmpeg rig serving synthetic H.264 test streams at `rtsp://127.0.0.1:8554/{test,sub}`.
- `rcamcli` — dev CLI: `probe-device` verifies the virtual camera end-to-end, `capture` tests the RTSP decode path in isolation.

## Layout

| Path | Contents |
|---|---|
| `RCam/` | Menu bar app, settings UI, config/Keychain, sink writer |
| `RCamExtension/` | CMIO extension: device, streams, emit loop, placeholders |
| `RCamKit/` | Shared code: `FrameSource` protocol, `RTSPSource` decode pipeline |
| `rcamcli/` | Dev/test CLI |
| `scripts/` | Build, FFmpeg vendoring, test rig |
