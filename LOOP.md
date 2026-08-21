# RCam — RTSP Virtual Camera for macOS: Loop Implementation Doc

Self-contained spec + task list for an autonomous implementation loop. The original
build brief has been superseded by this doc — decisions below were settled with the
user on 2026-08-20 and are **locked**; do not re-litigate them.

Suggested invocation: `/loop Read LOOP.md, then execute one iteration per its Loop Protocol.`

---

## Loop Protocol

Each iteration:

1. Read **State** (bottom of this file). Find the current milestone (first with unchecked tasks).
2. Do the next unchecked task (or a small coherent batch). Implement fully — no stubs left behind unless the task says so.
3. Run that task's **Verify** command(s). Never check a box without actually running its verification.
4. Update State: check boxes, append a one-line entry to the Iteration Log (`- <date> M<n>: what happened`).
5. Commit at every green state: `git add -A && git commit -m "M<n>: <summary>"`. Local only, never push.
6. On reaching a `⛔ HUMAN GATE`: finish everything automatable first, then write the exact manual steps + diagnostic commands into the gate's State entry, notify the user, and **stop the loop** (do not schedule another wakeup). The user resumes the loop after clearing the gate.

Rules:

- If the same failure repeats 3 times, stop retrying, record it under **Blockers** in State with what was tried, and stop the loop.
- Regenerate the Xcode project with `xcodegen generate` after any `project.yml` change; never hand-edit `project.pbxproj`.
- Keep the `FrameSource` protocol stable once defined — everything downstream depends on it.
- Research before guessing on CMIO extension APIs (sparsely documented). Apple's sample "Creating a camera extension with Core Media I/O" is the reference for the sink/source pattern.
- Do not start dev servers/streams and leave them orphaned; the test rig script must be idempotent (kill old instances on start).

---

## Locked decisions

| Topic | Decision |
|---|---|
| Signing | Apple Development, team **TK7EDP5B95**, Xcode-managed profiles. SIP stays ON; `systemextensionsctl developer` mode is unavailable. Dev loop = build → auto-bump extension version → copy app to `/Applications` → re-activate. |
| Sandbox | Container app **is sandboxed** (`com.apple.security.app-sandbox` + `com.apple.security.network.client` + `com.apple.developer.system-extension.install`). Extension: sandbox, no network entitlements. **Correction (verified 2026-08-20 against sysextd log + OBS's shipping extension):** the extension **must** carry `com.apple.security.application-groups: [TK7EDP5B95.com.paulstraw.rcam]` — the CMIO category validator requires `CMIOExtensionMachServiceName` to descend from an app group in the extension's entitlements; without it activation fails with "invalid mach service name". Team-ID-prefixed group works with Xcode-managed dev signing. |
| Decode path | **No ffmpeg subprocess, ever.** In-process: minimal **static FFmpeg** (demux only) + **VTDecompressionSession** (H.264 hardware decode) + **VTPixelTransferSession** (scale + letterbox to output format). |
| Project | **XcodeGen** `project.yml`; three targets: app `RCam`, extension `RCamExtension`, CLI `rcamcli`. |
| Frame pacing | The **extension owns the single 30Hz clock**. App just pushes frames when they arrive. |
| Test source | Local **mediamtx** rig fed by synthetic H.264 (Homebrew ffmpeg is fine *for the rig only* — it never ships). Real cameras only at human gates. |
| Git | Init up front; commit at green states; no remote. |
| Output format | Fixed forever: **1280×720, 30fps, NV12** (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`). Format can never change while a client holds the device open, so everything scales/letterboxes into this. |

Naming: app **RCam**, bundle id `com.paulstraw.rcam`, extension `com.paulstraw.rcam.extension`, virtual device display name **"RTSP Camera"**. App is `LSUIElement = true` (menu bar only), SwiftUI `MenuBarExtra`. Deployment target macOS 14.

## Environment facts (verified 2026-08-20)

- `~/dev/rcam` — project root. Xcode 26.6 (`/usr/bin/xcodebuild`), macOS 26.5, Apple Silicon (arm64 only — no universal builds needed).
- Homebrew ffmpeg at `/opt/homebrew/bin/ffmpeg` (test rig only). `xcodegen` and `mediamtx` need `brew install`.
- SIP enabled. No Developer ID cert; Apple Development identities exist, but sign with team `TK7EDP5B95` (Xcode-managed).
- The app **must run from `/Applications`** for extension activation — never DerivedData.

---

## Architecture (fixed)

Two halves, deliberately split — the extension runs in a restrictive sandbox and must hold no networking or camera config:

1. **App (RCam)**: menu bar UI, config, Keychain creds, RTSP connect + decode. Pushes decoded 720p NV12 `CVPixelBuffer`s into the extension's **sink stream** via the CoreMediaIO C API (find sink stream → `CMIOStreamCopyBufferQueue` → enqueue `CMSampleBuffer`s → `CMIODeviceStartStream`).
2. **Extension (RCamExtension)**: one `CMIOExtensionDevice`, one **source stream** (clients read) + one **sink stream** (app writes). Forwards sink → source under its own 30Hz clock.

**The 30Hz emit loop (extension)** — on every tick emit exactly one frame, priority order:
1. Fresh sink frame if one arrived since last tick.
2. Last-good frame, re-stamped, if sink is stale (RTSP stalls are normal).
3. Cached placeholder if no sink client is connected.

Timestamps must be monotonic and evenly spaced (derive from `mach_absolute_time`, step 1/30s) — never reuse a source PTS. Output must never stall; clients freeze or drop the device otherwise.

**Placeholders** (rendered in the extension, Core Graphics into a CVPixelBuffer, **cached** — never redrawn per frame, never plain black):
- App not running / no sink client: "Open RCam to select a source"
- App connected but stream dead: "No signal — \<camera name\>" (name passed via custom property)
- During source switch: last-good frame with a "Connecting…" badge overlay until the new source's first frame, then cut over (~2s black-ish transition is acceptable).

**Decode only when watched**: extension observes `startStream`/`stopStream` on the source stream and reflects "client count > 0" plus sink-side state through **CMIO custom properties**. App polls (~1s) or listens; connects RTSP only while a client is attached, disconnects after a ~10s grace period. Never hold six connections open.

**RTSP specifics**: TCP transport always (interleaved). Per-camera choice of substream (prefer it when ≥ output res — lower latency/CPU). Low-latency demux options: small `probesize`/`analyzeduration`, `nobuffer`, `low_delay` flags. First frame needs a keyframe; cameras use 2–4s GOPs — expect that delay on connect.

**Reconnect**: exponential backoff 1s → 2s → 4s … capped at 30s. On `NSWorkspace.willSleepNotification` tear down; on `didWakeNotification` reconnect immediately — never wait out TCP timeouts.

**Config**: JSON at the sandboxed app's Application Support container (`~/Library/Containers/com.paulstraw.rcam/Data/Library/Application Support/`): `[{id, name, mainURL, subURL, preferSub, fit}]` — URLs stored **without credentials**; credentials in **Keychain** (service = bundle id, account = camera id).

**Non-goals (v1)**: audio, ONVIF discovery, HEVC, recording/motion/PTZ, multi-camera mosaic, multiple virtual devices.

---

## Milestones

### M0 — Scaffold

- [x] `git init`; `.gitignore` (DerivedData, `build/`, `vendor/ffmpeg/src/`, `.DS_Store`)
- [x] `brew install xcodegen mediamtx` (skip if present)
- [x] `project.yml`: targets `RCam` (app, sandbox + network.client + system-extension.install entitlements, `LSUIElement`), `RCamExtension` (product type `com.apple.product-type.system-extension`, embedded into `RCam` at `Contents/Library/SystemExtensions`, sandbox-only entitlements), `rcamcli` (command-line tool, unsandboxed is fine — dev tool). Team `TK7EDP5B95`, Xcode-managed signing, deployment target macOS 14.
- [x] Extension Info.plist: `CMIOExtension` dict with `CMIOExtensionMachServiceName = $(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`. **Without this the extension silently never launches.**
- [x] `scripts/build.sh`: stamps `CFBundleVersion` = `date +%s` into an xcconfig (macOS won't pick up a re-installed extension without a version bump), runs `xcodegen generate` + `xcodebuild`, on success copies `RCam.app` into `/Applications` (replace old copy).
- [x] Minimal app: "Install Extension" button → `OSSystemExtensionManager` activation request, delegate logs result incl. `needsUserApproval`.
- [x] Minimal extension: provider/device/source-stream skeleton from the CMIO template pattern (real frames come in M1).

**Verify**: `scripts/build.sh` exits 0; `codesign -dv --entitlements - /Applications/RCam.app` and same for the embedded `.systemextension` show expected entitlements + team prefix; commit.

### M1 — Extension shows a test pattern

- [x] 30Hz clock-driven emit loop in the extension (the permanent one — priority chain above, monotonic timestamps).
- [x] Animated 720p30 NV12 test pattern (moving color bars + frame counter) as the initial "no sink" placeholder source.
- [x] Cached CG placeholder rendering utility (used now for the pattern text, later for "Open RCam…" / "No signal").
- [x] Sink stream added alongside source (wired in M3, declared now so the format never changes later).
- [x] App triggers activation; handle re-activation on version change.

**Verify (automated)**: build+install clean; then after the human gate, a tiny harness (`rcamcli probe-device`) enumerates `AVCaptureDevice`s (external/unknown types) and asserts "RTSP Camera" exists, captures 30 frames programmatically via `AVCaptureSession`, asserts 1280×720 and inter-frame pixel variance > 0 (pattern is animating, not frozen/black).

**⛔ HUMAN GATE 1**: user must (a) approve the extension in System Settings → Privacy & Security when prompted, (b) open QuickTime → New Movie Recording → camera menu → "RTSP Camera" and confirm moving bars. Prepare for the user:
- `systemextensionsctl list` output
- if activation fails: `log show --last 5m --predicate 'subsystem CONTAINS "com.apple.sysextd"' --info` — the generic "Invalid code signature or missing entitlements" error's real cause is only in this log
- extension runtime logs: `log stream --predicate 'subsystem == "com.paulstraw.rcam.extension"' --level debug`
- Known risk: development-signed sysext activation with SIP on may require this Mac in the provisioning profile (Xcode-managed usually handles it). If it hard-fails, surface the sysextd log verbatim; fallback options (register UDID, or SIP dev-mode) are the **user's** call.
- If things wedge: `systemextensionsctl reset` (needs user password), sometimes a reboot.

### M2 — Decode path proven in isolation (CLI)

- [x] `scripts/build-ffmpeg.sh`: fetch FFmpeg release source (pin a recent 7.x tag), configure minimal static demux-only build, arm64:
  `--disable-everything --disable-shared --enable-static --disable-programs --disable-doc --disable-autodetect --enable-network --enable-protocol=tcp,rtp,udp --enable-demuxer=rtsp,sdp --enable-parser=h264 --enable-bsf=h264_mp4toannexb,extract_extradata --disable-decoders --disable-encoders --disable-muxers --disable-filters --disable-swscale --disable-swresample --disable-avdevice`
  Install to `vendor/ffmpeg/` (headers + `.a`s: libavformat, libavcodec, libavutil). Commit the script, not the source tree; commit the built artifacts (small, and makes the loop reproducible).
- [x] `scripts/testrig.sh {start|stop}`: idempotently runs mediamtx + Homebrew-ffmpeg push of `testsrc2=size=1280x720:rate=30` with burned-in frame counter, H.264 `-tune zerolatency -g 30`, at `rtsp://127.0.0.1:8554/test`. Also a second 640×360 path to exercise upscale+letterbox. *(Note: Homebrew ffmpeg 8.0.1 has no drawtext — uses `testsrc`, whose built-in burned-in clock serves as the counter.)*
- [x] `RTSPSource` (app framework code, shared with CLI): C-interop wrapper over libavformat — open with TCP transport + low-latency opts, read H.264 packets, annex-B convert, build `CMVideoFormatDescription` from SPS/PPS, feed `VTDecompressionSession`, scale/letterbox via `VTPixelTransferSession` (`kVTPixelTransferPropertyKey_ScalingMode` letterbox) to 1280×720 NV12. *(Lives in `RCamKit/`, compiled into both app and CLI; CFFmpeg modulemap at `RCamKit/CFFmpeg`.)*
- [x] `FrameSource` protocol: `start/stop`, callback delivering `(CVPixelBuffer, arrival: TimeInterval)`, state (connecting/streaming/failed). Freeze it here. **FROZEN.**
- [x] `rcamcli capture <rtsp-url> --seconds N --out <dir>`: writes every 30th decoded frame as PNG + prints fps/latency stats.

**Verify (automated)**: `scripts/testrig.sh start`; `rcamcli capture rtsp://127.0.0.1:8554/test --seconds 5` produces ≥4 PNGs, each 1280×720, non-trivial pixel variance, and consecutive frames differ (stream is live, not stuck); same against the 640×360 path with letterbox bars detected (top/bottom rows near-black, center not). `testrig.sh stop`. Commit.

### M3 — Wire app → sink → source

- [ ] App-side sink writer: locate the device + sink stream via CoreMediaIO C API, `CMIOStreamCopyBufferQueue`, enqueue decoded frames as `CMSampleBuffer`s, start/stop the sink stream.
- [ ] Extension: consume sink queue; fresh sink frames take priority slot 1 in the emit loop; detect sink-stale (>1s) and fall back per the priority chain.
- [ ] Custom CMIO properties on the device: `sourceIsWatched` (extension → app: source-stream client count > 0), `activeCameraName` (app → extension, for the "No signal" placeholder). App polls watched-state ~1s.
- [ ] Decode-only-when-watched: app connects `RTSPSource` when watched, disconnects after 10s grace when unwatched. Hardcode the test-rig URL as the "camera" for this milestone (real config UI is M4).
- [ ] Placeholder text switches to "Open RCam to select a source" when no sink client (replaces color bars; keep bars behind a debug flag).

**Verify (automated)**: testrig up, RCam running from `/Applications`; `rcamcli probe-device --capture` frames now show the testrig's moving counter (inter-frame difference + not the placeholder); kill RCam mid-capture → captured frames keep flowing (placeholder takes over, no stall — assert continuous frame delivery and no `AVCaptureSession` error); check via logs that RTSP disconnects ~10s after capture stops. Commit.

**⛔ HUMAN GATE 2**: user opens QuickTime (and ideally a real call in Zoom/Meet/FaceTime) and confirms the live testrig feed; confirms feed continues (placeholder) when quitting RCam mid-call. Provide the log-stream commands again.

### M4 — Menu bar UI, config, multi-camera, switching

- [ ] Config store: JSON model above, in the app container's Application Support; Keychain read/write for per-camera credentials; URL+creds merged only in memory at connect time.
- [ ] `MenuBarExtra`: radio list of cameras (checkmark = active), "Settings…", "Quit". Selecting a camera switches the active source.
- [ ] Settings window: camera list CRUD, fields for name / main URL / sub URL / prefer-sub / fit-vs-fill, credentials fields (→ Keychain), manual entry only.
- [ ] "Test Connection" per camera: grab one frame via `FrameSource`, show thumbnail or error inline.
- [ ] Source switching: on switch, app keeps pushing last-good old-source frame while signaling "Connecting…" badge (custom property) until new source's first decoded frame, then cuts over. ~2s gap acceptable.
- [ ] Update watched-state plumbing to drive whichever camera is selected; still never more than one connection (+ brief overlap during switch).

**Verify (automated)**: run two testrig paths as two "cameras"; UI-test or scripted switch (`rcamcli` can flip selection via the app's config + a distributed notification, or `osascript`) while `probe-device --capture` runs — assert frames from path A, then after switch frames from path B, with no delivery stall during the gap. Config JSON on disk contains no credentials. Commit.

### M5 — Polish + definition of done

- [ ] Reconnect with exponential backoff (1→30s cap), status surfaced in menu (per-camera state).
- [ ] Sleep/wake: `NSWorkspace.willSleepNotification` teardown, `didWakeNotification` immediate reconnect.
- [ ] "No signal — \<camera name\>" placeholder path exercised (kill testrig push, verify text frame appears; restart push, verify recovery ≤ backoff cap + GOP).
- [ ] Launch at login via `SMAppService.mainApp` toggle in Settings.
- [ ] Low-latency demux opts tuned (`probesize`, `analyzeduration`, `nobuffer`, `low_delay`) — measure glass-to-glass with the burned-in testrig counter; target well under 1s on the rig.

**Verify (automated)**: kill/restart testrig mid-capture → placeholder then recovery, no frame stall throughout; backoff intervals visible in logs; `SMAppService` status registered. Commit.

**⛔ HUMAN GATE 3 — final DoD checklist (user, with real cameras)**:
- [ ] Six real cameras configured (creds land in Keychain; substream preferred where ≥720p is available)
- [ ] "RTSP Camera" works in QuickTime, Safari (webrtc test page), Zoom, Meet, FaceTime
- [ ] Switching sources from the menu bar mid-call works
- [ ] Survives a camera reboot (placeholder → auto-reconnect) and a Mac sleep/wake cycle
- [ ] Launches at login
- [ ] Rough latency check: point a camera at a phone stopwatch

---

## State

**Current milestone**: M3 (M0–M2 complete; Gate 1 cleared)

**Blockers**: none

### Iteration Log

(append one line per iteration)

- 2026-08-20 M2 (part 2): RTSPSource (libavformat→VTDecompression→VTPixelTransfer letterbox), FrameSource FROZEN, rcamcli capture. FFmpeg minimal-build fix: hevc parser added solely for aom_film_grain.o (h264's h2645_sei refs it). Testrig sub path changed 640x360→640x480 (360 is already 16:9, no bars to test). Verify: both paths 4 PNGs each 1280x720, animating (diff 5.7–8.1), pillarbox bars Y=16 vs center 125, ~30fps steady, first frame ≤1.5s. Testrig sub is 4:3 → bars are left/right, not top/bottom as M2 verify text assumed.
- 2026-08-20 M2 (part 1): Gate 1 cleared by user. build-ffmpeg.sh (7.1.1 static demux-only, arm64, 11MB libs committed to vendor/ffmpeg) + testrig.sh (mediamtx, testsrc→h264 720p30 + 360p30, idempotent start/stop verified via ffprobe). Next: RTSPSource + FrameSource + rcamcli capture.
- 2026-08-20 M1: Emit loop (30Hz DispatchSourceTimer, PTS = base host time + tick/30), scrolling-bars NV12 test pattern w/ frame counter, cached CG placeholder+digit renderer, sink stream declared, auto-activation on launch, rcamcli probe-device harness. Two activation fixes found via sysextd log: (1) extension Info.plist needs NSSystemExtensionUsageDescription for the cmio category, (2) extension entitlements need team-prefixed app group TK7EDP5B95.com.paulstraw.rcam (mach service name must descend from an app group — locked-decision table corrected). Extension now `[activated waiting for user]` → stopped at HUMAN GATE 1.
- 2026-08-20 M0: Full scaffold — git init, brew installed xcodegen+mediamtx, project.yml (3 targets, XcodeGen embeds sysext correctly), skeleton app/extension/CLI, scripts/build.sh. Verified: build.sh exit 0; app entitlements (sandbox, network.client, system-extension.install, team TK7EDP5B95); extension embedded at Contents/Library/SystemExtensions with sandbox-only entitlements, CMIOExtensionMachServiceName=TK7EDP5B95.com.paulstraw.rcam.extension, CFBundleVersion epoch-stamped.
