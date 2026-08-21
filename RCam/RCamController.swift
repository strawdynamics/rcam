import AVFoundation
import Foundation
import CoreMediaIO
import CoreVideo
import os.log

/// Decode-only-when-watched: polls the extension's `watched` custom property
/// (~1s), connects the RTSP source while a client is attached, disconnects
/// after a grace period when the last client leaves.
final class RCamController: ObservableObject {
    // M3: the test rig is the hardcoded "camera"; real config lands in M4.
    static let cameraName = "Test Rig"
    static let cameraURL = "rtsp://127.0.0.1:8554/test"
    static let unwatchedGrace: TimeInterval = 10

    @Published var statusText = "starting…"

    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "Controller")
    private let sinkWriter = SinkWriter()
    private var source: RTSPSource?
    private var pollTimer: Timer?
    private var unwatchedSince: Date?

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
    }

    private var lastPollDiagnostic = ""

    private func poll() {
        guard let device = CMIOHelpers.findDevice(uid: SinkWriter.deviceUID) else {
            statusText = "virtual camera not installed"
            diagnose("device not found; visible UIDs: \(CMIOHelpers.allDeviceUIDs())")
            return
        }
        let rawWatched = CMIOHelpers.readCustomString(device: device, code: "rwch")
        diagnose("device \(device), rwch=\(rawWatched ?? "<missing>")")
        let watched = rawWatched == "1"

        if watched {
            unwatchedSince = nil
            if source == nil {
                connect(device: device)
            }
        } else if source != nil {
            if let since = unwatchedSince {
                if Date().timeIntervalSince(since) > Self.unwatchedGrace {
                    disconnect()
                }
            } else {
                unwatchedSince = Date()
                log.info("unwatched — disconnecting in \(Self.unwatchedGrace)s unless a client returns")
            }
        } else {
            statusText = "idle (no clients)"
        }
    }

    private func connect(device: CMIOObjectID) {
        log.info("watched — attaching sink and connecting RTSP")
        guard sinkWriter.start() else {
            statusText = "sink attach failed"
            return
        }
        CMIOHelpers.writeCustomString(device: device, code: "rnam", value: Self.cameraName)

        let source = RTSPSource(url: Self.cameraURL)
        source.onFrame = { [weak self] pixelBuffer, _ in
            self?.sinkWriter.enqueue(pixelBuffer)
        }
        source.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .idle: self?.statusText = "idle"
                case .connecting: self?.statusText = "connecting to \(Self.cameraName)…"
                case .streaming: self?.statusText = "streaming \(Self.cameraName)"
                case .failed(let message): self?.statusText = "failed: \(message)"
                }
            }
        }
        self.source = source
        source.start()
    }

    /// Log poll findings only when they change, so the log stays readable.
    private func diagnose(_ message: String) {
        guard message != lastPollDiagnostic else { return }
        lastPollDiagnostic = message
        log.info("poll: \(message, privacy: .public)")
    }

    private func disconnect() {
        log.info("unwatched for \(Self.unwatchedGrace)s — disconnecting RTSP")
        source?.stop()
        source = nil
        sinkWriter.stop()
        unwatchedSince = nil
        statusText = "idle (no clients)"
    }
}
