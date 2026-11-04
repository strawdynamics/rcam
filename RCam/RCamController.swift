import AppKit
import AVFoundation
import Foundation
import CoreMediaIO
import CoreVideo
import ServiceManagement
import os.log

/// Multi-camera controller. Polls the extension's `watched` property (~1s),
/// decodes only the selected camera while a client is attached (10s grace on
/// disconnect), and performs overlap switching: the old source keeps feeding
/// the sink (with a "Connecting…" badge signaled to the extension) until the
/// new source delivers its first frame.
///
/// Every connect attempt is a switch. The initial connect (and each retry
/// after a failure) is a switch from nothing: the source sits in
/// `pendingSource` with the extension's `connecting` flag raised, so the
/// extension shows "Connecting — <name>…" rather than "No signal" until the
/// first frame promotes it. A failed pending source retires the old active
/// one too — the user picked the new camera, so the old feed must not linger.
///
/// **Threading contract.** Two disciplines, deliberately:
///
/// - *Main-thread only*: `unwatchedSince`, `backoffSeconds`,
///   `nextReconnectAllowed`, `asleep`, `statusText`, `streamingCameraID`,
///   `cameraInUse` and `lastPollDiagnostic`. They are touched by the poll
///   timer, by `select`, and by the `onStateChange` handler in `makeSource`,
///   all of which run on main — the handler hops there explicitly before
///   doing anything.
/// - *Guarded by `switchLock`*: `activeSource` and `pendingSource`, the only
///   two members the decode thread also reaches. Every read and write of them
///   takes the lock, including the identity checks in `onFrame`.
///
/// `completeSwitch` and `setConnecting` are called from the decode thread on
/// purpose: promoting the pending source has to happen on the frame that
/// proves it is alive, not a poll tick later. They confine themselves to
/// `switchLock`-guarded state and CMIO property writes, and hop to main for
/// anything published.
final class RCamController: ObservableObject {
    static let unwatchedGrace: TimeInterval = 10
    // Literal on purpose: rcamcli posts it (and setLaunchAtLogin below) under
    // its own bundle ID, so neither side can derive the other's. It is only a
    // namespaced name for a debug hook, not a signing identity.
    static let selectNotification = Notification.Name("com.strawdynamics.rcam.selectCamera")

    @Published var statusText = "Starting…"
    /// The camera currently delivering frames to the virtual device, if any.
    @Published private(set) var streamingCameraID: UUID?
    /// Whether a client has the virtual camera open, as of the last poll: the
    /// extension's `watched` flag, without the disconnect grace. The updater
    /// holds scheduled update prompts back while this is true.
    @Published private(set) var cameraInUse = false

    let config = ConfigStore()

    // Every subsystem stays literal, whatever the bundle ID prefix: the
    // documented `log show --predicate 'subsystem BEGINSWITH ...'` commands
    // depend on it, and RCamKit's logger is shared with rcamcli.
    private let log = Logger(subsystem: "com.strawdynamics.rcam", category: "Controller")
    private let sinkWriter = SinkWriter()
    private let switchLock = NSLock()
    private var activeSource: RTSPSource?      // feeding the sink
    private var pendingSource: RTSPSource?     // connecting during a switch
    private var pollTimer: Timer?
    private var unwatchedSince: Date?
    private var lastPollDiagnostic = ""
    private let teardownQueue = DispatchQueue(label: "com.strawdynamics.rcam.teardown")

    // Reconnect backoff (1s → 2s → 4s … capped at 30s), driven by the 1s poll.
    private var backoffSeconds: TimeInterval = 1
    private var nextReconnectAllowed = Date.distantPast
    private var asleep = false

    func start() {
        // Without camera authorization the DAL hides camera devices from this
        // process — the poll would never find our own virtual camera.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.statusText = "Camera access denied — enable in System Settings"
                    self.log.error("camera access denied; cannot reach the virtual device")
                    return
                }
                let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    self?.poll()
                }
                RunLoop.main.add(timer, forMode: .common)
                self.pollTimer = timer
                self.poll()
            }
        }

        // Scripted/test switching: rcamcli posts a distributed notification
        // with the camera name or id.
        //
        // Debug-only, deliberately. DistributedNotificationCenter is a system-
        // wide bus with no sender authentication: any process on the machine,
        // sandboxed or not, can post these. Switching someone's camera mid-call
        // is bad; silently flipping launch-at-login is worse. rcamcli only ever
        // drives a Debug build (scripts/build.sh defaults to Debug), so gating
        // here costs the test workflow nothing.
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: Self.selectNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let key = note.object as? String else { return }
            if let camera = self.config.cameras.first(where: {
                $0.id.uuidString == key || $0.name == key
            }) {
                self.select(camera)
            } else {
                self.log.error("selectCamera notification for unknown camera \(key, privacy: .public)")
            }
        }

        // Test hook for launch-at-login (the Settings toggle uses the same call).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.strawdynamics.rcam.setLaunchAtLogin"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.setLaunchAtLogin((note.object as? String) == "1")
        }
        #endif

        // Sleep/wake: tear down before sleep; reconnect immediately on wake
        // rather than waiting out dead TCP connections.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                              object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.info("system will sleep — tearing down")
            self.asleep = true
            self.disconnect()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log.info("system woke — reconnecting immediately")
            self.asleep = false
            self.backoffSeconds = 1
            self.nextReconnectAllowed = .distantPast
            self.poll()
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log.info("launch-at-login set \(enabled) — status now \(SMAppService.mainApp.status.rawValue)")
            return true
        } catch {
            log.error("launch-at-login change failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// User (or scripted) camera selection.
    func select(_ camera: CameraConfig) {
        switchLock.lock()
        let hasSource = activeSource != nil || pendingSource != nil
        switchLock.unlock()

        // Re-picking the camera that just failed is meaningful: it is nil'd
        // from both slots on failure, so `!hasSource` lets it through.
        guard camera.id != config.selectedID || !hasSource else { return }
        log.info("selecting camera \(camera.name, privacy: .public)")
        config.selectedID = camera.id

        // Finding 8: an explicit user action is a strong signal — it should
        // never wait out a backoff that may have grown to 30s. Reset it so the
        // next 1s poll reconnects immediately.
        let pendingBackoff = max(0, nextReconnectAllowed.timeIntervalSinceNow)
        if pendingBackoff > 0 {
            log.info("user selection clears \(pendingBackoff, format: .fixed(precision: 1))s of remaining reconnect backoff")
        }
        backoffSeconds = 1
        nextReconnectAllowed = .distantPast

        if hasSource {
            // Also covers a selection made while the initial connect is still
            // pending: `beginSwitch` supersedes the pending source.
            beginSwitch(to: camera)
        }
        // No source at all: the next watched poll connects to the new selection.
    }

    // MARK: - Watched polling

    private func poll() {
        guard let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) else {
            statusText = "Virtual camera not installed"
            if cameraInUse { cameraInUse = false }
            diagnose("device not found; visible UIDs: \(CMIOHelpers.allDeviceUIDs())")
            return
        }
        let watched = CMIOHelpers.readCustomString(device: device, code: "rwch") == "1"
        diagnose("device \(device), watched=\(watched)")
        if cameraInUse != watched { cameraInUse = watched }

        switchLock.lock()
        let hasSource = activeSource != nil || pendingSource != nil
        switchLock.unlock()

        if watched {
            unwatchedSince = nil
            if !hasSource, !asleep, Date() >= nextReconnectAllowed {
                connectSelected(device: device)
            }
        } else if hasSource {
            if let since = unwatchedSince {
                if Date().timeIntervalSince(since) > Self.unwatchedGrace {
                    disconnect()
                }
            } else {
                unwatchedSince = Date()
                log.info("unwatched — disconnecting in \(Self.unwatchedGrace)s unless a client returns")
            }
        } else {
            statusText = config.cameras.isEmpty ? "No cameras configured" : "Idle (no clients)"
        }
    }

    private func connectSelected(device: CMIOObjectID) {
        guard let camera = config.selectedCamera else {
            statusText = "No camera selected"
            return
        }
        log.info("watched — attaching sink, connecting \(camera.name, privacy: .public)")
        guard sinkWriter.start() else {
            statusText = "Sink attach failed"
            return
        }
        CMIOHelpers.writeCustomString(device: device, code: "rnam", value: camera.name)
        setConnecting(true)

        // Pending, not active: the first frame promotes it via `completeSwitch`,
        // which is also what clears the connecting flag. Until then the
        // extension has no video and shows the "Connecting" placeholder.
        let source = makeSource(for: camera)
        switchLock.lock()
        pendingSource = source
        switchLock.unlock()
        source.start()
    }

    private func disconnect() {
        log.info("unwatched for \(Self.unwatchedGrace)s — disconnecting RTSP")
        switchLock.lock()
        let oldActive = activeSource
        let oldPending = pendingSource
        activeSource = nil
        pendingSource = nil
        switchLock.unlock()
        teardownQueue.async {
            oldActive?.stop()
            oldPending?.stop()
        }
        sinkWriter.stop()
        setConnecting(false)
        streamingCameraID = nil
        unwatchedSince = nil
        backoffSeconds = 1
        nextReconnectAllowed = .distantPast
        statusText = "Idle (no clients)"
    }

    // MARK: - Overlap switching

    private func beginSwitch(to camera: CameraConfig) {
        log.info("switching to \(camera.name, privacy: .public) — overlap until first frame")
        setConnecting(true)
        if let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) {
            CMIOHelpers.writeCustomString(device: device, code: "rnam", value: camera.name)
        }

        let newSource = makeSource(for: camera)
        switchLock.lock()
        // A previous pending switch loses the race — tear it down.
        let superseded = pendingSource
        pendingSource = newSource
        switchLock.unlock()
        if let superseded {
            teardownQueue.async { superseded.stop() }
        }
        newSource.start()
    }

    /// Called from the pending source's first frame: promote it, retire the old.
    private func completeSwitch(from source: RTSPSource) {
        switchLock.lock()
        guard pendingSource === source else {
            switchLock.unlock()
            return
        }
        let old = activeSource
        activeSource = source
        pendingSource = nil
        switchLock.unlock()
        if let old {
            teardownQueue.async { old.stop() }
        }
        setConnecting(false)
        log.info("switch complete — new source live")
    }

    private func makeSource(for camera: CameraConfig) -> RTSPSource {
        let source = RTSPSource(url: ConfigStore.resolvedURL(for: camera),
                                fill: camera.fit == .fill)
        source.onFrame = { [weak self, weak source] pixelBuffer, _ in
            guard let self, let source else { return }
            self.switchLock.lock()
            let isActive = self.activeSource === source
            let isPendingNow = self.pendingSource === source
            self.switchLock.unlock()
            if isPendingNow {
                self.completeSwitch(from: source)
            }
            if isActive || isPendingNow {
                self.sinkWriter.enqueue(pixelBuffer)
            }
        }
        source.onStateChange = { [weak self, weak source] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .idle:
                    break
                case .connecting:
                    self.statusText = "Connecting to \(camera.name)…"
                case .streaming:
                    self.statusText = "Streaming \(camera.name)"
                    self.streamingCameraID = camera.id
                    self.backoffSeconds = 1
                case .failed(let message):
                    self.statusText = "\(camera.name): \(message)"
                    if self.streamingCameraID == camera.id {
                        self.streamingCameraID = nil
                    }
                    if let source {
                        self.handleSourceFailure(source, camera: camera)
                    }
                }
            }
        }
        return source
    }

    /// A source died (stream stall, camera reboot, network drop) or never came
    /// up. Keep the sink attached — the extension shows "No signal — <name>"
    /// while we wait — and let the poll retry with exponential backoff.
    ///
    /// A pending source that fails takes the active one down with it. The
    /// selection already points at the new camera; leaving the old feed
    /// running would show one camera's video under another's name, and the
    /// poll would never retry because it still saw a live source.
    private func handleSourceFailure(_ source: RTSPSource, camera: CameraConfig) {
        switchLock.lock()
        let wasActive = activeSource === source
        let wasPending = pendingSource === source
        let retiredActive = wasPending ? activeSource : nil
        if wasActive || wasPending { activeSource = nil }
        if wasPending { pendingSource = nil }
        switchLock.unlock()
        guard wasActive || wasPending else { return }

        teardownQueue.async {
            source.stop()
            retiredActive?.stop()
        }
        if wasPending {
            setConnecting(false)
            if retiredActive != nil {
                log.info("switch to \(camera.name, privacy: .public) failed — retiring the previous source")
                streamingCameraID = nil
            }
        }

        let delay = backoffSeconds
        nextReconnectAllowed = Date().addingTimeInterval(delay)
        backoffSeconds = min(backoffSeconds * 2, 30)
        log.info("source \(camera.name, privacy: .public) failed — reconnect allowed in \(delay, format: .fixed(precision: 0))s (backoff)")
    }

    /// Raise or clear the extension's "connect attempt in flight" flag. The
    /// fourcc predates the wider meaning (it began as switching-only).
    private func setConnecting(_ on: Bool) {
        guard let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) else { return }
        CMIOHelpers.writeCustomString(device: device, code: "rswt", value: on ? "1" : "0")
    }

    /// Log poll findings only when they change, so the log stays readable.
    private func diagnose(_ message: String) {
        guard message != lastPollDiagnostic else { return }
        lastPollDiagnostic = message
        log.info("poll: \(message, privacy: .public)")
    }
}
