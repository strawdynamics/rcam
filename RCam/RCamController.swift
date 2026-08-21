import AVFoundation
import Foundation
import CoreMediaIO
import CoreVideo
import os.log

/// Multi-camera controller. Polls the extension's `watched` property (~1s),
/// decodes only the selected camera while a client is attached (10s grace on
/// disconnect), and performs overlap switching: the old source keeps feeding
/// the sink (with a "Connecting…" badge signaled to the extension) until the
/// new source delivers its first frame.
final class RCamController: ObservableObject {
    static let unwatchedGrace: TimeInterval = 10
    static let selectNotification = Notification.Name("com.paulstraw.rcam.selectCamera")

    @Published var statusText = "starting…"

    let config = ConfigStore()

    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "Controller")
    private let sinkWriter = SinkWriter()
    private let switchLock = NSLock()
    private var activeSource: RTSPSource?      // feeding the sink
    private var pendingSource: RTSPSource?     // connecting during a switch
    private var pollTimer: Timer?
    private var unwatchedSince: Date?
    private var lastPollDiagnostic = ""
    private let teardownQueue = DispatchQueue(label: "com.paulstraw.rcam.teardown")

    func start() {
        // Without camera authorization the DAL hides camera devices from this
        // process — the poll would never find our own virtual camera.
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.statusText = "camera access denied — enable in System Settings"
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
    }

    /// User (or scripted) camera selection.
    func select(_ camera: CameraConfig) {
        guard camera.id != config.selectedID || activeSource == nil else { return }
        log.info("selecting camera \(camera.name, privacy: .public)")
        config.selectedID = camera.id

        switchLock.lock()
        let streamingNow = activeSource != nil
        switchLock.unlock()
        if streamingNow {
            beginSwitch(to: camera)
        }
        // Not streaming: the next watched poll connects to the new selection.
    }

    // MARK: - Watched polling

    private func poll() {
        guard let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) else {
            statusText = "virtual camera not installed"
            diagnose("device not found; visible UIDs: \(CMIOHelpers.allDeviceUIDs())")
            return
        }
        let watched = CMIOHelpers.readCustomString(device: device, code: "rwch") == "1"
        diagnose("device \(device), watched=\(watched)")

        switchLock.lock()
        let hasSource = activeSource != nil || pendingSource != nil
        switchLock.unlock()

        if watched {
            unwatchedSince = nil
            if !hasSource {
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
            statusText = config.cameras.isEmpty ? "no cameras configured" : "idle (no clients)"
        }
    }

    private func connectSelected(device: CMIOObjectID) {
        guard let camera = config.selectedCamera else {
            statusText = "no camera selected"
            return
        }
        log.info("watched — attaching sink, connecting \(camera.name, privacy: .public)")
        guard sinkWriter.start() else {
            statusText = "sink attach failed"
            return
        }
        CMIOHelpers.writeCustomString(device: device, code: "rnam", value: camera.name)

        let source = makeSource(for: camera, isPending: false)
        switchLock.lock()
        activeSource = source
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
        setSwitching(false)
        unwatchedSince = nil
        statusText = "idle (no clients)"
    }

    // MARK: - Overlap switching

    private func beginSwitch(to camera: CameraConfig) {
        log.info("switching to \(camera.name, privacy: .public) — overlap until first frame")
        setSwitching(true)
        if let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) {
            CMIOHelpers.writeCustomString(device: device, code: "rnam", value: camera.name)
        }

        let newSource = makeSource(for: camera, isPending: true)
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
        setSwitching(false)
        log.info("switch complete — new source live")
    }

    private func makeSource(for camera: CameraConfig, isPending: Bool) -> RTSPSource {
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
        source.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .idle: break
                case .connecting: self.statusText = "connecting to \(camera.name)…"
                case .streaming: self.statusText = "streaming \(camera.name)"
                case .failed(let message): self.statusText = "\(camera.name): \(message)"
                }
            }
        }
        return source
    }

    private func setSwitching(_ on: Bool) {
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
