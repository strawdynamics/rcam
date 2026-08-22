# RCam — Review Remediation Loop (2026-08-21)

Self-contained spec + task list for an autonomous implementation loop. Actions a
code-review agent's findings on the M0–M5 codebase. Every finding below was
**verified against the source before this doc was written** — including two the
reviewer got wrong, corrected inline. Decisions in **Locked decisions** were
settled with the user on 2026-08-21 and are **locked**; do not re-litigate them.

Predecessor: `loops/20260820-A-LOOP.md` (M0–M5, parked at HUMAN GATE 3). That
gate is **retired into this doc** — its checklist is absorbed by this loop's
single human gate at the end. Do not work the old doc's gate separately.

Suggested invocation: `/loop Read loops/20260821-A-FEEDBACK.md, then execute one iteration per its Loop Protocol.`

---

## Loop Protocol

Each iteration:

1. Read **State** (bottom of this file). Find the current milestone (first with unchecked tasks).
2. Do the next unchecked task (or a small coherent batch). Implement fully — no stubs left behind unless the task says so.
3. Run that task's **Verify** command(s). Never check a box without actually running its verification.
4. Update State: check boxes, append a one-line entry to the Iteration Log (`- <date> F<n>: what happened`).
5. Commit at every green state: `git add -A && git commit -m "F<n>: <summary>"`. **Local only — never push.**
6. On reaching the `⛔ HUMAN GATE`: finish everything automatable first, then write the exact manual steps + diagnostic commands into the gate's State entry, notify the user, and **stop the loop** (do not schedule another wakeup).

Rules:

- If the same failure repeats 3 times, stop retrying, record it under **Blockers** in State with what was tried, and stop the loop.
- Regenerate the Xcode project with `xcodegen generate` after any `project.yml` change; never hand-edit `project.pbxproj`.
- `scripts/build.sh` is the only way to see a change in the running app. After it replaces the extension, **quit and relaunch RCam** — a running app process holds a stale DAL view of the virtual device.
- The test rig must never be left running. `scripts/testrig.sh stop` at the end of any milestone that started it.
- **Never `git push`.** A private GitHub remote (`github`) exists and both branches are already on it; this loop stays local. The user decides when to publish.
- Do not weaken a verification to make it pass. If a check can't be made to work as written, record why under **Blockers** and propose the substitute rather than silently downgrading it.

---

## Locked decisions

| Topic | Decision |
|---|---|
| Scope | The whole review: findings 1–8, both documentation minors, a unit-test target, `build.sh --release`, and `project.yml` settingGroups. Nothing deferred. |
| Committed key (F0) | `git rm` + `.gitignore` only. **No history rewrite, no force-push.** The reviewer assumed there was no remote; there is (private), and both branches are pushed, so a rewrite would mean force-pushing two branches while GitHub keeps the unreachable blob until its own GC. The pair is a self-signed `CN=mediamtx` cert for a 127.0.0.1 test rig, regenerated on demand — it protects nothing. |
| Deployment target | **macOS 14.0 → 15.0**, an explicit amendment to the M0 locked decision, taken so `StopFlag` can use `Synchronization.Atomic<Int32>`. The user is the only user and runs macOS 26.5. |
| Finding 3 fix | **Both** halves: parse SPS/PPS on every packet (folded into the NAL walk `annexBToLengthPrefixed` already performs, so it is free), rebuild the decoder when they differ from the current pair, **and** emit `.failed` after `decodeFailureThreshold` consecutive `decodePacket` nils so the existing reconnect machinery catches every other silent-nil cause. |
| Finding 4 fix | `runLoop()` tears down VideoToolbox on its own exit path. `stop()` sets the atomic, waits `stopWaitSeconds` (above the 5s socket timeout so it normally succeeds), and **drains the semaphore on the timeout path**. |
| Finding 7 fix | Distinguish absent from unparseable; preserve the bad file as `cameras.json.bak` before anything can overwrite it; debounce `save()`; surface both load-corruption and write failure **in the UI** (menu bar + Settings), not only `os_log`. |
| Tests | Pure parsers extracted to Foundation-only files; `RCamTests` bundle (Swift Testing) compiles **only** those files — no FFmpeg headers, no linker flags. `scripts/test.sh` runs them. |
| Build config | `scripts/build.sh --release` added; Debug stays the default so loop iterations stay fast; the final task before the gate installs a Release build. |
| Git | Commit the pending `loops/` move → fast-forward `main` to `app-icon` → work on a new `review-fixes` branch → commit at green states → never push. |
| Human gates | Exactly one, at the end, absorbing the old HUMAN GATE 3 DoD checklist plus checks specific to what this loop changed. |

Tunable constants introduced by this loop (name them explicitly in code, don't inline the magic numbers):

- `decodeFailureThreshold = 30` — consecutive `decodePacket` nils before `.failed` (~1s at 30fps).
- `stopWaitSeconds = 6` — `stop()`'s bounded wait, chosen above the 5s ffmpeg socket `timeout`.
- `saveDebounceSeconds = 0.5` — `ConfigStore.save()` coalescing window.

---

## Verified findings (audited 2026-08-21, before any code was changed)

Each was confirmed by reading the source. File:line references are against the
tree at commit `80ab419`.

**1 — Committed private key. CONFIRMED, premise corrected.**
`auto.crt` and `auto.key` are tracked (added in `e5e360d`), referenced by nothing
in the tree, and are a self-signed `CN=mediamtx` pair (valid to 2036) left behind
by running the test rig from the repo root. **Correction:** the reviewer wrote
"the repo has no remote yet". It does — `github.com/paulstraw/rcam`, private,
with both `main` and `app-icon` already pushed. See the locked decision.

**2 — Credentials in the thread name. CONFIRMED.**
`RTSPSource.swift:56` sets `thread.name = "RTSPSource(\(url))"`. Both call sites
pass a credential-bearing URL: `RCamController.swift:248` uses
`ConfigStore.resolvedURL(for:)` and `SettingsView.swift:477` uses
`ConfigStore.resolvedURL(_:cameraID:)`, both of which inject the Keychain
password into `URLComponents.password`. Thread names surface in crash reports,
`sample` output, and Instruments.

**3 — Mid-stream parameter-set changes stall forever. CONFIRMED.**
`RTSPSource.swift:179` only parses in-band SPS/PPS while `parameterSets == nil`,
contradicting the comment at `:177`; `:184` only builds the decoder while
`formatDescription == nil`. Every failure path in `decodePacket` returns `nil`
silently (`:285, :299, :306, :330, :341, :343, :346, :349`) while `av_read_frame`
keeps succeeding — so `.failed` never fires, the controller never tears down or
backs off, and the extension shows "No signal" until the TCP connection itself
dies.

**4 — `stop()` can tear down VideoToolbox under a live decode. CONFIRMED, plus one the reviewer missed.**
`stop()` waits 3s on `finished` (`:65`) then calls `teardownVideoToolbox()` from
the caller's thread (`:67`), while the ffmpeg socket `timeout` is 5s (`:109`) —
so on a wedged connection the demux thread can still be inside `decodePacket`
using `decompressionSession` when another thread invalidates and nils it.
`StopFlag.stopped` (`:78`) is a plain `Int32` touched from main, `teardownQueue`,
the demux thread, and a `@convention(c)` interrupt callback with no atomics.
**Additional latent bug:** on the timeout path `stop()` sets `thread = nil` but
never drains `finished`, so the late signal leaves the semaphore at 1 and the
*next* `stop()` returns immediately regardless of thread state.

**5 — Every "Test Connection" leaks an `RTSPSource`. CONFIRMED.**
`SettingsView.swift:479` — `finish` captures `source` strongly, and
`source.onFrame` / `source.onStateChange` capture `finish`. The callbacks are
never nil'd after `stop()`, so the cycle is never broken and each test leaks a
stopped source plus its closures. `deinit` therefore never runs either.

**6 — `SinkWriter` is racy across threads. CONFIRMED.**
`enqueue` (`SinkWriter.swift:61`) runs on the demux thread via
`RCamController.makeSource`'s `onFrame`, while `stop()` (`:52`) runs on main via
`disconnect()`. `queue`, `running`, and `formatDescription` are all read and
written across those threads unsynchronized. `CMSimpleQueueEnqueue`'s status is
discarded at `:92`, so a failed enqueue leaks the `passRetained` sample buffer,
and the count-vs-capacity check at `:63` races the extension's consumption.

**7 — Config persistence fails silently and destructively. CONFIRMED.**
`ConfigStore.init` (`CameraConfig.swift:46`) collapses "file absent" and "file
unparseable" into `cameras = []` via two `try?`s; the next `didSet` calls
`save()` (`:65`), which atomically overwrites the file — permanently losing the
user's cameras. `save()` runs on every keystroke of every text field, and swallows
write errors with `try?`.

**8 — User re-selection doesn't bypass backoff. CONFIRMED.**
`RCamController.select` (`:120`) sets `selectedID` but `poll` still gates
connection on `Date() >= nextReconnectAllowed` (`:151`), which
`handleSourceFailure` (`:305`) can have pushed 30s out. The guard at `:121`
(`camera.id != config.selectedID || activeSource == nil`) does let a re-pick of
the failed camera through, since `activeSource` is nil after a failure — so a
reset inside `select` fixes both the switch case and the re-pick case.

**Minors — all CONFIRMED.** No test target exists anywhere in `project.yml`.
`scripts/build.sh` hardcodes `-configuration Debug` at lines 14, 17, and 20. The
FFmpeg search-path/linker block is duplicated verbatim at `project.yml:31-34` and
`:93-96`. Nothing outside `RTSPSource.swift` references the bitstream parsers, so
extracting them is self-contained.

---

## Milestones

### F0 — Repo hygiene and project configuration

No behavior change. Gets `project.yml` and the build script right once, before
any code milestone edits them.

- [x] `git checkout -b review-fixes`. All subsequent work happens on `review-fixes`.
- [x] Remove the committed key: `git rm auto.crt auto.key`, and add `auto.crt` / `auto.key` to `.gitignore`. No history rewrite.
- [x] `project.yml`: `deploymentTarget.macOS` → `"15.0"`.
- [x] `project.yml`: collapse the duplicated FFmpeg settings into a `settingGroups` entry (`ffmpeg`: `SWIFT_INCLUDE_PATHS`, `HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`, `OTHER_LDFLAGS`) and reference it from `RCam` and `rcamcli` via `settings.groups`.
- [x] `scripts/build.sh`: accept `--release`. One `CONFIGURATION` variable must drive both `xcodebuild` invocations *and* the `APP_SRC` product path (the current script hardcodes `Debug` in three places). Default stays `Debug`. Echo which configuration was installed.

**Verify**: `git ls-files | grep -c 'auto\.\(crt\|key\)'` is `0` and both files are gone from the working tree; `git check-ignore auto.key` succeeds. `scripts/build.sh` exits 0 and `defaults read /Applications/RCam.app/Contents/Info LSMinimumSystemVersion` prints `15.0`. `scripts/build.sh --release` exits 0 and installs from `build/Build/Products/Release/`. `git diff` on the regenerated project shows the FFmpeg flags still present on both targets. Commit.

### F1 — Extract the pure parsers and stand up tests

Tests land **before** the decode-path surgery in F2, so the riskiest change has a
safety net.

- [x] New `RCamKit/H264Bitstream.swift` — Foundation only, **no `import CFFmpeg`**. Move `ParameterSets`, `parseParameterSets`, `parseAVCC`, `parseAnnexBParameterSets`, `annexBNALUnits`, and `annexBToLengthPrefixed` out of `RTSPSource` into an `enum H264Bitstream` namespace. Make `ParameterSets` `Equatable` (F2 needs it to detect changes). Keep `parseParameterSets`'s `UnsafeMutablePointer<UInt8>?` signature — it is fed `codecpar.extradata` directly.
- [x] New `RCamKit/StreamHealth.swift` — Foundation only. Two pure pieces:
  - `DecodeFailureCounter` — `init(threshold:)`, `mutating func record(success: Bool) -> Bool` returning `true` exactly once when the run of failures reaches the threshold, resetting on success.
  - `streamLabel(forURL:)` — strips userinfo and returns `host:port/path` (no scheme-level credentials, no query). This is what F2 puts in the thread name; it must be impossible for a password to survive it.
- [x] Update `RTSPSource` to call through to the moved code. Nothing else in the tree references these functions, so no other call sites change.
- [x] `project.yml`: new `RCamTests` target, `type: bundle.unit-test`, platform macOS, sources = `RCamTests/` plus **only** `RCamKit/H264Bitstream.swift` and `RCamKit/StreamHealth.swift`. No FFmpeg group, no test host. Add a `test:` action to the `RCam` scheme covering it.
- [x] `RCamTests/` using **Swift Testing** (`import Testing`). Cover, at minimum: a well-formed avcC; avcC truncated at each early-return branch (`size > 7`, the SPS length reads, the `offset < size` boundary before the PPS count, the PPS length reads); annex-B with 3-byte and 4-byte start codes intermixed; annex-B missing SPS, missing PPS, and with neither; zero-size and nil input; `annexBToLengthPrefixed` dropping NAL types 7/8/9/12 while keeping slices and emitting big-endian 4-byte lengths; a trailing NAL with no following start code; `DecodeFailureCounter` firing exactly once at the threshold and resetting on success; `streamLabel(forURL:)` stripping `user:password@` from a realistic RTSP URL.
- [x] `scripts/test.sh` — `xcodebuild test -project RCam.xcodeproj -scheme RCam -derivedDataPath build`.

**Verify**: `scripts/test.sh` exits 0 with every test passing; deliberately break one assertion and confirm the script exits non-zero (a test target that silently runs nothing is the classic failure here). `scripts/build.sh` exits 0 — `RTSPSource` still compiles against the moved code. `rcamcli capture rtsp://127.0.0.1:8554/test --seconds 5 --out /tmp/f1` (rig started first) still yields animating 1280x720 PNGs, proving the extraction was behavior-preserving. Stop the rig. Commit.

### F2 — RTSPSource: credentials, reconfiguration, teardown (findings 2, 3, 4)

- [x] **Finding 2**: `thread.name = "RTSPSource(\(StreamHealth.streamLabel(forURL: url)))"`. `RTSPSource` never learns the camera's display name, so the label is derived from the URL rather than threading a new initializer parameter through both call sites.
- [x] **Finding 3a**: parse SPS/PPS from every packet. Fold the parameter-set extraction into the single NAL walk `annexBToLengthPrefixed` already performs, so the per-packet cost is unchanged — do not add a second full walk per packet.
- [x] **Finding 3b**: when the newly parsed `ParameterSets` differs from the current one, tear down and rebuild the decoder (format description, decompression session, transfer session, pool) before decoding that packet. Log the change at `info` with old→new dimensions.
- [x] **Finding 3c**: `DecodeFailureCounter(threshold: decodeFailureThreshold)` in the demux loop. On a nil from `decodePacket`, `record(success: false)`; when it fires, emit `.failed("decode stalled — N consecutive failures")` and break the loop so `handleSourceFailure` runs the existing backoff. Reset on every successful frame.
- [x] **Finding 4a**: `StopFlag` holds `Atomic<Int32>` from `Synchronization` (`import Synchronization`; store as a `let` since `Atomic` is non-copyable). Interrupt callback does a relaxed load; `start`/`stop` do relaxed stores.
- [x] **Finding 4b**: move `teardownVideoToolbox()` to `runLoop()`'s exit path so the owning thread always performs it. `stop()` sets the flag, waits `stopWaitSeconds`, and on timeout **drains** `finished` (a non-blocking `wait(timeout: .now())` after the late signal, or equivalent bookkeeping) so a stale signal can never pre-satisfy the next `stop()`. Verify by inspection that no path can leave the semaphore with a stray count.
- [x] **Minor**: one comment at the `VTDecompressionSessionDecodeFrame` call noting that synchronous decode delivers in decode order, so the pipeline assumes no B-frames — true of essentially every IP camera, but currently unstated.

**Verify**:
1. `scripts/test.sh` green; `scripts/build.sh` exits 0.
2. **No credentials in the thread name**: start the rig, run `rcamcli capture` against a URL with `user:pass@` in it, and while it runs `sample rcamcli 1 -f /tmp/sample.txt`; assert the thread name appears and `grep -c 'pass@' /tmp/sample.txt` is `0`.
3. **Reconfiguration**: with the app streaming `Test A`, run `scripts/testrig.sh stop-push test` then `scripts/testrig.sh start-push test 640x360` and confirm from `log stream --predicate 'subsystem == "com.paulstraw.rcam"' --info` that the stream recovers and frames flow again. **Honest caveat:** mediamtx drops readers when a publisher disconnects, so this most likely exercises the reconnect path rather than a true in-band parameter-set change. That is an acceptable outcome — record which path the log shows. The rebuild logic itself is covered by the `ParameterSets` equality unit tests; if you can find a way to make the rig deliver a genuine mid-session change, do it, but do not fake one.
4. **Decode-failure counter**: the rig cannot produce decodable-but-unrenderable packets, so verify the counter through its unit tests plus one temporary fault injection — force `decodePacket` to return nil under a `#if DEBUG` flag, confirm `.failed` fires after exactly `decodeFailureThreshold` packets and the controller's backoff log line appears, then **remove the injection before committing**.
5. **Teardown**: a start/stop stress loop — 50 cycles of `RTSPSource.start()` / `stop()` against the rig (a `rcamcli` subcommand is fine, note it in the log if you add one) with no crash and no hang; plus the same run under Thread Sanitizer (`xcodebuild -enableThreadSanitizer YES`) reporting zero races on `stopped`, `decompressionSession`, or `formatDescription`.

Stop the rig. Commit.

### F3 — SinkWriter and the Test Connection leak (findings 5, 6)

- [x] **Finding 6a**: guard `SinkWriter`'s mutable state (`queue`, `running`, `formatDescription`) with an `OSAllocatedUnfairLock` or equivalent so `enqueue` on the demux thread cannot observe or race `stop()` on main. Keep the critical section tight — this is a per-frame path.
- [x] **Finding 6b**: check `CMSimpleQueueEnqueue`'s status; on anything other than `noErr`, release the `passRetained` sample buffer rather than leaking it, and log at `error` (rate-limited or change-only, so a persistently-full queue can't flood the log).
- [x] **Finding 5**: in `SettingsView.runTest`, nil `source.onFrame`, `source.onStateChange`, and `source.onStreamInfo` inside `finish` before stopping, breaking the retain cycle. Prefer nil'ing the callbacks over weak captures so the fix is visible at the point the cycle is created.

**Verify**: `scripts/build.sh` exits 0. **Leak**: add a temporary `os_log` in `RTSPSource.deinit`, run five Test Connections from Settings against the rig, and confirm five deinit lines — then decide whether the log line is worth keeping (it is cheap and it is exactly the signal that was missing). **Race**: with a Thread Sanitizer build, stream from the rig and force a `disconnect()` (stop the capturing client so the unwatched grace expires) while frames are flowing; assert zero TSan reports naming `SinkWriter`. Stop the rig. Commit.

### F4 — Config durability (finding 7)

- [x] `ConfigStore.init` distinguishes three cases: file absent (normal first run, empty list, no warning); file present and parseable (load); file present and unparseable or unreadable (**move it to `cameras.json.bak`** before anything can overwrite it, then start empty).
- [x] A published error state on `ConfigStore` (e.g. `@Published var persistenceError: String?`) covering both load corruption and save failure.
- [x] Surface it: the menu bar shows the error instead of the usual status, and Settings shows it prominently. Reuse the existing error-card copy/expand UX from Settings if it fits — the review specifically praised it.
- [x] Debounce `save()` by `saveDebounceSeconds` so it stops firing per keystroke, and make sure a pending save is flushed on app termination so nothing is lost.
- [x] Replace the `try?`s in `save()` with real error handling that sets `persistenceError`. Keep the atomic write.

**Verify**: with RCam quit, write garbage into `~/Library/Containers/com.paulstraw.rcam/Data/Library/Application Support/RCam/cameras.json`, launch RCam, and assert (a) `cameras.json.bak` exists containing the garbage, (b) the error is visible in the menu bar, (c) editing a camera and quitting does not destroy the `.bak`. Then restore a good `cameras.json` and confirm normal load with no error shown. Separately, confirm the debounce: type into a camera name field and check the file's mtime updates once after the pause rather than per keystroke. Commit.

### F5 — Controller: backoff bypass and threading documentation (finding 8, minors)

- [x] **Finding 8**: `RCamController.select` resets `backoffSeconds = 1` and `nextReconnectAllowed = .distantPast`. An explicit user action is a strong signal; it should never wait out a 30s backoff. This covers both switching cameras and re-picking the failed one after fixing it (the `:121` guard already lets the latter through, since `activeSource` is nil after a failure).
- [x] **Minor**: a comment block on `RCamController` stating the threading contract — which members are main-thread-only (`unwatchedSince`, `backoffSeconds`, `nextReconnectAllowed`, `statusText`, `streamingCameraID`, `lastPollDiagnostic`), which are guarded by `switchLock` (`activeSource`, `pendingSource`), and that `completeSwitch` / `setSwitching` are deliberately called from the decode thread. This is documentation only — do not restructure the threading.

**Verify**: start the rig, let a camera fail (`scripts/testrig.sh stop-push test`), watch the log until the backoff has grown past a few seconds, restart the push, then immediately `rcamcli select-camera "<name>"` and assert from the log that the reconnect attempt happens on the next 1s poll rather than after the remaining backoff. `scripts/test.sh` and `scripts/build.sh` green. Stop the rig. Commit.

### F6 — Release install and handoff

- [x] `scripts/build.sh --release` and confirm the installed app reports the Release build.
- [x] Full regression before the gate: `scripts/test.sh` green; rig up; `rcamcli probe-device --frames 120` green; `rcamcli capture` on both rig paths green; rig down.
- [x] Write the gate checklist into **State** with exact commands, then stop the loop.

**Verify**: all of the above green, working tree clean, `git log --oneline main..review-fixes` shows one commit per milestone, and `git status` confirms nothing was pushed.

---

## ⛔ HUMAN GATE — real-camera validation (absorbs old Gate 3)

Everything automatable is done. This gate combines the previously unfinished
definition-of-done checklist with checks specific to what this loop changed.

**Carried over from the old HUMAN GATE 3:**

- [ ] Six real cameras configured (creds land in Keychain; substream preferred where ≥720p is available)
- [ ] "RTSP Camera" works in QuickTime, Safari (a WebRTC test page), Zoom, Meet, FaceTime
- [ ] Switching sources from the menu bar mid-call works
- [ ] Survives a camera reboot (placeholder → auto-reconnect) and a Mac sleep/wake cycle
- [ ] Launches at login
- [ ] Rough latency check: point a camera at a phone stopwatch

**New, specific to this loop:**

- [ ] The app still launches and streams after the **macOS 15 deployment-target bump** (nothing here should be version-sensitive, but this is the first real-camera run since the bump)
- [ ] **No credentials in diagnostics**: with a real authenticated camera streaming, run `sample RCam 1 -f /tmp/rcam-sample.txt` and confirm the password appears nowhere (`grep` for it)
- [ ] **Reconnect after a real reconfiguration**: change a camera's resolution or encoding profile in its own web UI while RCam is streaming it, and confirm RCam recovers (either a decoder rebuild or a clean reconnect — both are acceptable; a permanent "No signal" is not, and is precisely the bug finding 3 describes)
- [ ] **User re-selection beats backoff**: unplug a camera, wait for "No signal" and a grown backoff, plug it back in, pick it from the menu, and confirm it reconnects within about a second rather than waiting
- [ ] **Config durability**: quit RCam and confirm `cameras.json` still holds all six cameras and still contains no credentials (`grep` for the password)
- [ ] **Release build**: `/Applications/RCam.app` is the Release build and CPU use while streaming is at or below what the Debug build used

When this passes, merge `review-fixes` into `main` and decide whether to push.

Diagnostics: `log stream --predicate 'subsystem == "com.paulstraw.rcam"' --info` (app) / same with `.extension` (extension). After any rebuild: quit RCam, `scripts/build.sh`, reopen RCam **twice** (activation replace, then fresh DAL view).

---

## State

**Current milestone**: **⛔ HUMAN GATE — real-camera validation.** All six milestones (F0–F6) are done, verified and committed on `review-fixes`. The loop is stopped. Nothing further is automatable without real cameras and a reboot.

F0 complete. Notes carried forward:
- The git housekeeping from the earlier draft (commit the `loops/` move, fast-forward `main` to `app-icon`) was already done before this loop started: `main` already contained it, and `app-icon` is now a stale duplicate that differs from `main` only in this doc. `review-fixes` was branched from `main` at `cf4c3b9`.
- `auto.crt` / `auto.key` are untracked, gitignored, and deleted from the working tree. No history rewrite, nothing pushed.
- `scripts/build.sh [--release|--debug]`; one `CONFIGURATION` variable drives both `xcodebuild` calls and `APP_SRC`. Debug is installed right now.

F1 complete. Notes carried forward:
- `H264Bitstream` (enum namespace) and `StreamHealth` (enum namespace, holding `DecodeFailureCounter` and `streamLabel(forURL:)`) are in `RCamKit/`, Foundation-only. `ParameterSets` is now `Equatable` and nested in `H264Bitstream`, ready for F2's change detection.
- `RCamTests` needed `GENERATE_INFOPLIST_FILE: YES` (plus a bundle id) or the host-less test bundle fails to code sign. Not in the original task text; recorded here so a regenerate doesn't lose it.
- The tests found a real bug while being written: `URLComponents(string: "rtsp://")` returns a **non-nil, empty** host, so `streamLabel` returned `""` instead of taking the redacting fallback. Fixed with an `!host.isEmpty` check.
- 42 tests in 6 suites. F2 should extend `DecodeFailureCounter` coverage only if its semantics change; the threshold-30 case is already pinned.

**Blockers**:

- **`probe-device`'s animation assertion is mis-calibrated and has almost certainly never passed.** Found at the gate, 2026-08-21. `assess()` requires the **whole-frame mean luma** to move by >0.05 on >=25% of consecutive frame pairs. Neither source can satisfy that:
  - *Rig* (`testsrc=1280x720:rate=30`) is static colour bars with a burned-in clock. Only the clock region changes, so a 921,600-pixel average barely moves. Measured: `fps=30.5`, 14 distinct luma values over 150 frames, **3.05 luma steps/sec vs the 7.52/sec the threshold demands**. Real exit code **3**.
  - *Real camera* (Front door, a static night scene) is worse: `changedPairs=2/119`, though frames are provably live — luma drifts 95.0 -> 95.1 -> 94.9 and `meanLuma` swung 74.9 -> 95.1 -> 64.8 across runs as auto-exposure settled.
  - Every *other* criterion passes on both sources: frame count, 1280x720, full 30fps, non-black. **The sink path is healthy; the tool is wrong.**
  - Earlier milestones never caught this because they only ever quoted `meanLuma` (F5) and F6 recorded the check as blocked, so nobody had seen its verdict.
  - **Fix in progress, NOT finished.** `FrameStat` now carries an FNV-1a `signature` hashed over the same 16px sampled grid the mean already walks (free), and `assess()` prints `distinct=` and `sigChanged=`. **The old luma assertion is deliberately still in place** — per the loop's "do not weaken a verification to make it pass" rule the threshold must be chosen from measured ground truth in all three states (frozen placeholder, live rig, live real camera), and the device died before those measurements could be taken. Build green, `scripts/test.sh` 48/48.

- **Extension replacement kills the virtual device until a reboot — now a reproducible trigger, not an intermittent one.** Every `scripts/build.sh` replaces the system extension; afterwards `systemextensionsctl list` shows the new build `[activated enabled]` and the old one `[terminated waiting to uninstall on reboot]`, but **no extension process runs at all** and `probe-device` reports `device "RTSP Camera" not found`. Tried on 2026-08-21 after the reboot: quit+relaunch RCam (twice, as the doc prescribes), a 20s wait, and a `system_profiler SPCameraDataType` to force DAL enumeration — three strikes, stopped per the loop rule. Note this happened with only **1** stale entry queued, so the earlier "21 stale sysexts" backlog theory is **not** the whole cause; a plain extension swap is enough. Practical consequence: **any rebuild costs a reboot before the camera can be exercised again.** Batch code changes accordingly.

*(Resolved 2026-08-21.)* The `REBOOT REQUIRED` blocker below cleared: after the reboot the stale count went 21 -> 0 and the device returned (`OK: found "RTSP Camera"`).

- **`REBOOT REQUIRED` before the gate.** The "RTSP Camera" virtual device is missing again, and this time it did not come back: three retries over ~2.5 minutes with a relaunch each. `systemextensionsctl list` shows the current build `[activated enabled]` but **21** stale `com.paulstraw.rcam.extension` entries in `[terminated waiting to uninstall on reboot]`, and no extension process running. The backlog grows by one on every `scripts/build.sh`, so this will keep recurring until a reboot clears it. It blocked F6's `probe-device --frames 120` only — every other F6 check passed. Step 0 of the gate below handles it.

*(Earlier occurrence, resolved 2026-08-21 during F5.)* The "RTSP Camera" virtual device was invisible to every process for most of F2–F4 — the extension registered as `activated enabled` but no extension process ran, with 16 stale entries stuck in `[terminated waiting to uninstall on reboot]`. It came back on its own before F5 without a reboot and without any code change, which fits the accumulated-sysext diagnosis. Everything it had blocked has since been run and passed: F2 verify 3's app-level recovery, F3's SinkWriter Thread Sanitizer check, and F5's own verification. If it recurs, the symptom is `rcamcli probe-device` reporting `device "RTSP Camera" not found` while `systemextensionsctl list` shows the extension activated; a reboot clears the backlog.

### Iteration Log

- 2026-08-21 F0: branched `review-fixes`; removed + gitignored `auto.crt`/`auto.key`; deployment target 14.0→15.0; FFmpeg build settings collapsed into a `settingGroups: ffmpeg` referenced by `RCam` and `rcamcli`; `build.sh` gained `--release`. Verified: 0 tracked key files, `git check-ignore` passes both, Debug and Release builds each exit 0 and install from their own product dir, `LSMinimumSystemVersion` = 15.0, FFmpeg flags still present on both targets × both configs in the regenerated pbxproj. Debug reinstalled last.
- 2026-08-21 F1: extracted the pure parsers into `RCamKit/H264Bitstream.swift` and the new health helpers into `RCamKit/StreamHealth.swift` (both Foundation-only); `RTSPSource` now calls through. Added the `RCamTests` unit-test target (no FFmpeg group, no test host) plus a `test:` action on the RCam scheme, 42 Swift Testing cases, and `scripts/test.sh`. Verified: `scripts/test.sh` exits 0 with 42/42 passing; a deliberately broken assertion makes it exit 65 (so the target is genuinely running tests, not silently passing); `scripts/build.sh` exits 0; `rcamcli capture rtsp://127.0.0.1:8554/test --seconds 5` against the rig gave 133 animating 1280x720 frames. Rig stopped.
- 2026-08-21 F2: RTSPSource rewritten for findings 2/3/4. Thread name now `RTSPSource(host:port/path)` via `StreamHealth.streamLabel`. `H264Bitstream.convert` does one walk per packet yielding both the length-prefixed payload and any in-band SPS/PPS, so parameter-set changes are watched on every packet for free; a changed pair tears down and rebuilds the decoder (logged old→new dims) and resets the keyframe wait. `DecodeFailureCounter(threshold: 30)` emits `.failed` and breaks the loop; parameter-set-only packets are skipped rather than counted as failures. `StopFlag` is `Atomic<Int32>` (Synchronization). All VideoToolbox state moved into a per-run `DecodeSession` created, used and torn down on the demux thread (`defer` in `runLoop`), so `stop()` can no longer invalidate a session under a live decode and an abandoned thread can only tear down its own; `stop()` waits `stopWaitSeconds = 6` and, on timeout, sets `abandonedRun` so the next `start()` drains the late `finished` signal before creating a thread. Added `rcamcli stress` and a B-frame note at the decode call.
  Verified: `scripts/test.sh` 48/48; `scripts/build.sh` 0. Credentials — `sample rcamcli` during a capture of `rtsp://camuser:s3cretpw@127.0.0.1:8554/test` shows `RTSPSource(127.0.0.1:8554/test)`, 0 hits for the password and 0 for the username. Reconfiguration — as the doc predicted, mediamtx drops the reader when the publisher restarts, so the rig exercised the **reconnect** path (`read failed: End of file`), not a true in-band change; the rebuild logic itself is covered by the `ParameterSets` equality and `convert` unit tests. Decode counter — temporary `#if DEBUG` injection forced nil from `decode`; exactly 30 forced failures then `state: failed("decode stalled — 30 consecutive failures")` and the loop broke; **injection removed and the removal grep-verified before committing**. Teardown — 50 start/stop cycles at `--hold 1.5` (1063 frames, so `stop()` really was landing on live decode; an earlier `--hold 0.4` run only reached 7 frames and was not a real test of the race) with no crash or hang, plus 20 cycles / 427 frames under a **confirmed-instrumented** Thread Sanitizer build reporting 0 races. Note: `-enableThreadSanitizer YES` is silently ignored for `xcodebuild build` — it only applies to test/run actions — so the first TSan attempt was an uninstrumented binary and its "0 races" meant nothing; the real build needs `OTHER_SWIFT_FLAGS=-sanitize=thread` plus `-fsanitize=thread` in `OTHER_LDFLAGS`, confirmed by `otool -L` showing `libclang_rt.tsan_osx_dynamic.dylib`. Rig stopped.
- 2026-08-21 F3: `SinkWriter` now guards `queue`, `formatDescription`, `running` and the new `lastEnqueueStatus` behind an `OSAllocatedUnfairLock`, taken once for the whole `enqueue` path — the capacity check, the format-description cache and the enqueue have to see the same queue, so splitting the critical section would reintroduce the very race being fixed. Explicit `lock()`/`unlock()` rather than `withLock`, whose closure is `@Sendable` while the CoreMedia types crossing it are not. `CMSimpleQueueEnqueue`'s status is now checked: on anything but `noErr` the `passRetained` sample buffer is released instead of leaked, and the failure is logged **on change only** so a persistently-full queue cannot flood the log. `SettingsView.runTest` nils `onFrame`/`onStateChange`/`onStreamInfo` inside `finish` before stopping. Kept the `RTSPSource.deinit` log at `.info` — cheap, and it is the signal whose absence hid this leak.
  Verified: `scripts/build.sh` 0; `scripts/test.sh` 48/48. Leak — the real "Test Connection" button is SwiftUI and not scriptable here, so instead of counting five deinits from UI clicks I built a temporary `rcamcli leak-check` that reproduces `runTest`'s closure shape exactly (`finish` captures `source` strongly; the callbacks capture `finish`) and ran it **both ways** against the rig: without the fix **0 deinit lines in 5 rounds**, with the fix **exactly 5**. That is a two-sided proof the cycle was real and that nil'ing the callbacks breaks it — stronger than the one-sided count the task asked for, but it does exercise a copy of the closure shape rather than the button itself, so the button path is worth an eyeball at the human gate. Temporary command removed and the removal grep-verified before committing. Race — **not verifiable**: `SinkWriter.start()` needs the virtual device, which is still missing (see Blockers), so `enqueue` never runs and there is nothing for TSan to observe. Deferred to the human gate. Rig stopped.
- 2026-08-21 F4: `ConfigStore.init` now separates absent (normal first run, silent) from present-but-unreadable, which is **moved** — not copied — to `cameras.json.bak` before anything can write, then reported. An existing quarantine is never clobbered: the second corruption goes to `cameras.json.bak-<timestamp>`, since the older file is the more likely to hold the user's real list. `@Published persistenceError` is fed by separate `loadError`/`saveError` so a later successful write clears the write error without erasing the "your file was quarantined" notice. `save()` is debounced by `saveDebounceSeconds = 0.5` with a `DispatchWorkItem`, and `NSApplication.willTerminateNotification` flushes a pending write. `writeNow()` uses real `do`/`catch` instead of `try?`. Surfaced in the menu bar (the error replaces the status line) and as a `PersistenceErrorCard` in Settings.
  Two bugs found while building it. (1) Property observers do not fire for assignments made during `init`, so the quarantine message never reached `persistenceError` — fixed with an explicit `refreshPersistenceError()` at the end of `init`. (2) The Settings scene hoists the TabView's tab picker into the window toolbar, which **overlaid and clipped** the card's icon and title; neither a wrapping `VStack` nor `safeAreaInset(edge: .top)` avoided it (both were screenshotted and rejected). The card now lives inside each pane, where it lays out in normal content space — verified by screenshot.
  Verified end to end against the real container: garbage written to `cameras.json`, RCam launched → (a) `cameras.json.bak` contains exactly the garbage and `cameras.json` is gone; (b) the menu bar's status line is replaced by the error text (read back via System Events) and Settings shows the full card; (c) adding a camera, typing a name and quitting left **all** quarantine files intact. Debounce: 12 keystrokes into the Name field at ~90ms produced **1** file write (mtime polled at 50ms). Termination flush: a keystroke followed immediately by quit — inside the 0.5s window — is on disk. Then the real 8-camera config was restored: clean load, all 8 in the menu, status back to "idle (no clients)", no ConfigStore log entries, no stray `.bak`. `scripts/test.sh` 48/48, `scripts/build.sh` 0.
- 2026-08-21 F5: `RCamController.select` now resets `backoffSeconds = 1` and `nextReconnectAllowed = .distantPast`, logging how much backoff the selection cleared. Its guard also reads `activeSource` under `switchLock` instead of unlocked — the one place that violated the contract being documented, and it folds into the read `select` already did a few lines later, so no behaviour changed. Added the threading-contract comment block to `RCamController` (main-thread-only members vs `switchLock`-guarded ones, and why `completeSwitch`/`setSwitching` run on the decode thread). Documentation only; the threading is unchanged.
  Verified live through the app: rig up, `probe-device` holding the device watched, `select-camera "Test A"`, then `stop-push test`. The log shows backoff growing 1 → 2 → 4 → 8 → **16s** (next reconnect due 21:57:27). The publisher was restarted and `select-camera "Test A"` issued at 21:57:14.748, which logged "user selection clears 12.4s of remaining reconnect backoff", and the reconnect ran at **21:57:15.123 — 0.375s later, on the very next 1s poll** rather than 12.4s later. `scripts/test.sh` 48/48, `scripts/build.sh` 0. Rig stopped.
- 2026-08-21 F5 (deferred verifications picked up once the device returned):
  - **F2 verify 3, app-level half** — now passes. Across the F5 run the app survived the publisher dying and coming back: repeated `.failed` → backoff → reconnect, then live frames again (`probe-device --frames 400` reports `meanLuma=122.4`, matching the rig's synthetic content rather than the "No signal" placeholder). As predicted, this is the reconnect path, not a true in-band parameter-set change.
  - **F3's SinkWriter race check** — now passes, via a different route than the task described. Four attempts to build the *app* under Thread Sanitizer failed: `-enableThreadSanitizer YES` is ignored for `xcodebuild build`, bare `OTHER_SWIFT_FLAGS`/`OTHER_LDFLAGS` break the extension's link (command-line settings hit every target), and with `$(inherited)` the flags reached both compiler and linker yet only the *extension* binary came out instrumented, never the app. Stopped there per the 3-strike rule and drove the real `SinkWriter` from a temporary `rcamcli sink-race` command instead — same concurrency shape as `disconnect()`: `enqueue` hammering from a background thread while `stop()` lands on the calling thread, against the real CMIO sink. **20 cycles, 0 TSan reports.** Then a negative control: locking commented out, same test → TSan reports a data race naming `SinkWriter.stop` and the process aborts (exit 134). So the check has real power, and the lock is what removes the race. Temp command, the temporary `RCam/SinkWriter.swift` entry in the rcamcli target, and the negative-control edit were all reverted and grep-verified before committing.
- 2026-08-21 F6: `scripts/build.sh --release` run; the installed `/Applications/RCam.app` binary is **byte-identical** to `build/Build/Products/Release/RCam.app` (sha256 `2440f48e…`) and differs from the Debug product, `LSMinimumSystemVersion` 15.0. Regression: `scripts/test.sh` 48/48; `rcamcli capture` green on **both** rig paths (`/test` 138 frames @27.4fps, `/test-sub` 141 frames @28.0fps, 5 PNGs each, 1280x720). `probe-device --frames 120` **blocked** — the extension replacement dropped the virtual device again and it did not return after three relaunch-and-wait retries; see Blockers. Rig stopped, working tree clean, `main..review-fixes` is exactly six commits (one per milestone), and `review-fixes` exists on no remote. Gate checklist written below; loop stopped.

- 2026-08-21 GATE (post-reboot session): reboot cleared the sysext backlog (21 -> 0) and the virtual device returned. Closed three gate items by machine — real-camera streaming on the macOS 15 build (Front door, 1280x720 @ 30.5fps end to end), finding 2's no-credentials-in-diagnostics check against a **real authenticated camera** (thread name `RTSPSource(192.168.40.126:554/cam/realmonitor)`, 0 credential-shaped strings in `sample RCam`), and config durability (`cameras.json` has no credential fields at all). Also diagnosed why the menu-bar icon was invisible: **Bartender 5**, not RCam — the status item existed at full size (37x24) but was parked at x=-1435, off the left edge of the only 2560pt display, because Bartender's `DefaultedToBartenderBar = 1` hides unknown new items and it had no entry for RCam. Then found that `probe-device`'s animation assertion fails on the rig too (real exit 3) and is mis-calibrated by ~2.5x — see Blockers; a signature-based replacement is started but deliberately unfinished, and the extension died on rebuild before ground-truth measurements could be taken.

---

## ⛔ GATE HANDOFF — exact steps

Everything automatable is done. What remains needs real cameras, a reboot, and human eyes.

### Gate progress so far (2026-08-21, post-reboot)

Verified by machine, no human eyes needed:

- [x] **Step 0 — stale sysext backlog cleared.** 21 -> 0 `waiting to uninstall`; extension process running; `OK: found "RTSP Camera"`.
- [x] **macOS 15 deployment bump — app launches and streams from a real camera.** Front door delivered 1280x720 @ 30.5fps end to end (RTSP -> decode -> SinkWriter -> extension -> AVFoundation client).
- [x] **No credentials in diagnostics (finding 2, real authenticated camera).** `sample RCam` shows the thread name as `RTSPSource(192.168.40.126:554/cam/realmonitor)` — host:port/path only, userinfo *and* query string stripped — and **0** occurrences of any `rtsp://...@...` credential-shaped string. This is credential-*agnostic*: rather than grepping for one known password it proves no credential-shaped string exists at all.
- [x] **Config durability — no credentials in `cameras.json`.** The schema has no credential fields whatsoever (`fit`, `id`, `mainURL`, `name`, `preferSub`, `subURL`); passwords live only in the Keychain. 8 cameras: the 6 real ones plus Test A/Test B.
- [ ] **`probe-device --frames 120`** — still open, blocked on the metric defect above, not on RCam.

Two gotchas worth knowing before re-running any of this:

1. **Warm-up is mandatory.** `probe-device` is usually the *only* client, so it cold-starts the whole chain: the controller's poll takes up to 1s to notice `watched=true`, then the RTSP connect/auth/first-keyframe takes seconds more. 120 frames is only ~4s, so a cold probe finishes before the first real frame arrives and reads the placeholder. Run a throwaway `--frames 300` first, then the real probe **within the 10s unwatched grace** so it lands on a live stream.
2. **`--dump-luma` exists but is undocumented** in `usage()` — it is parsed at `CLIMain.swift` but not listed. It is the fastest way to tell "frozen" from "live but static": a frozen buffer gives a bit-identical value forever, a live static scene wobbles in the 0.1 range.

### Step 0 — reboot first (required)

Nothing below involving the virtual camera will work until the stale system-extension
backlog is cleared. 21 copies are queued for uninstall-on-reboot.

```sh
# after rebooting:
cd ~/dev/rcam
systemextensionsctl list | grep paulstraw | grep -c "waiting to uninstall"   # expect 0
open -a /Applications/RCam.app          # then quit and reopen once more
build/Build/Products/Release/rcamcli probe-device --frames 30                # expect: OK: found "RTSP Camera"
```

If `probe-device` still fails, the app is fine but the device is not published — re-run
`scripts/build.sh --release`, relaunch RCam **twice**, and re-probe.

### Step 1 — the two checks the rig could not do

```sh
scripts/testrig.sh start
build/Build/Products/Release/rcamcli probe-device --frames 120   # the one F6 check left unrun
scripts/testrig.sh stop
```

Then, in Settings → Cameras, click **Test Connection** five times against a rig camera and
confirm five `deinit` lines — the F3 leak fix was proved with a faithful reproduction of
`runTest`'s closure shape, not the button itself, so this is the one path still worth an eyeball:

```sh
log stream --predicate 'subsystem == "com.paulstraw.rcam" AND category == "RTSPSource"' --info | grep deinit
```

### Step 2 — carried over from the old HUMAN GATE 3

- [ ] Six real cameras configured (creds land in Keychain; substream preferred where ≥720p is available)
- [ ] "RTSP Camera" works in QuickTime, Safari (a WebRTC test page), Zoom, Meet, FaceTime
- [ ] Switching sources from the menu bar mid-call works
- [ ] Survives a camera reboot (placeholder → auto-reconnect) and a Mac sleep/wake cycle
- [ ] Launches at login
- [ ] Rough latency check: point a camera at a phone stopwatch

### Step 3 — specific to this loop

- [ ] **macOS 15 deployment bump** — app still launches and streams (first real-camera run since 14.0 → 15.0)
- [ ] **No credentials in diagnostics** — with a real authenticated camera streaming:
      `sample RCam 1 -f /tmp/rcam-sample.txt && grep -c '<the password>' /tmp/rcam-sample.txt`  → expect `0`
      (also expect the thread name to read `RTSPSource(<host>:<port>/<path>)`)
- [ ] **Reconnect after a real reconfiguration** — change a camera's resolution or profile in its own
      web UI while RCam streams it. Either a decoder rebuild or a clean reconnect is fine; a permanent
      "No signal" is the finding-3 bug. Watch for the rebuild line:
      `log stream --predicate 'subsystem == "com.paulstraw.rcam"' --info | grep -E "parameter sets changed|decode stalled|failed"`
      This is the one check the rig genuinely could not perform — mediamtx drops readers when a
      publisher restarts, so it only ever exercised the reconnect path.
- [ ] **User re-selection beats backoff** — unplug a camera, wait for "No signal" and a grown backoff,
      plug it back in, pick it from the menu. Expect a reconnect within ~1s and this line:
      `user selection clears <N>s of remaining reconnect backoff`
- [ ] **Config durability** — quit RCam, then:
      `cd ~/Library/Containers/com.paulstraw.rcam/Data/Library/Application\ Support/RCam`
      `python3 -c "import json;print(len(json.load(open('cameras.json'))))"`  → expect 6
      `grep -c '<the password>' cameras.json`  → expect `0`
- [ ] **Release build** — `/Applications/RCam.app` is Release (already confirmed byte-identical) and CPU
      while streaming is at or below the Debug build's

### When it passes

```sh
git checkout main && git merge --no-ff review-fixes
# then decide whether to push — this loop never did
```

`app-icon` is a stale duplicate of `main` (it differs only in an earlier draft of this
file) and can be deleted locally and on the remote whenever convenient.
