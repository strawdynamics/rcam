import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import os.log

// Fixed output format (locked): 1280x720, 30fps, NV12.
let kOutputWidth: Int32 = 1280
let kOutputHeight: Int32 = 720
let kFrameRate: Int32 = 30

let extensionLog = Logger(subsystem: "com.paulstraw.rcam.extension", category: "Provider")

// MARK: - Provider

final class RCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: RCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = RCamDeviceSource(localizedName: "RTSP Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
        extensionLog.info("Provider initialized, device added")
    }

    func connect(to client: CMIOExtensionClient) throws {
        extensionLog.info("Client connected: \(client.clientID, privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        extensionLog.info("Client disconnected: \(client.clientID, privacy: .public)")
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "paulstraw"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties.
    }
}

// MARK: - Device (owns the single 30Hz clock)

final class RCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStreamSource: RCamSourceStreamSource!
    private var sinkStreamSource: RCamSinkStreamSource!

    private let stateLock = NSLock()
    private var streamingCounter = 0

    private let timerQueue = DispatchQueue(label: "com.paulstraw.rcam.extension.emit",
                                           qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let frameDuration = CMTime(value: 1, timescale: kFrameRate)
    private var baseHostTime = CMTime.invalid
    private var frameIndex: UInt64 = 0

    private let testPattern = TestPatternGenerator()

    // Sink-side state for the priority chain. Fed by the sink stream in M3;
    // declared now so the chain shape is final.
    private var pendingSinkFrame: CVPixelBuffer?
    private var lastGoodFrame: CVPixelBuffer?
    private var lastSinkArrival: CFTimeInterval = 0
    private let sinkStaleThreshold: CFTimeInterval = 1.0

    init(localizedName: String) {
        super.init()
        // Stable IDs so the device identity survives reinstalls.
        let deviceID = UUID(uuidString: "7E5F9C1A-3B2D-4E6F-8A90-C1D2E3F4A5B6")!
        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: kOutputWidth,
            height: kOutputHeight,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        let streamFormat = CMIOExtensionStreamFormat(
            formatDescription: formatDescription!,
            maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration,
            validFrameDurations: nil
        )

        let sourceStreamID = UUID(uuidString: "A1B2C3D4-E5F6-4A7B-9C8D-0E1F2A3B4C5D")!
        sourceStreamSource = RCamSourceStreamSource(
            localizedName: "RTSP Camera Video",
            streamID: sourceStreamID,
            streamFormat: streamFormat,
            device: device
        )
        let sinkStreamID = UUID(uuidString: "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E")!
        sinkStreamSource = RCamSinkStreamSource(
            localizedName: "RTSP Camera Sink",
            streamID: sinkStreamID,
            streamFormat: streamFormat,
            device: device
        )
        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' — virtual device transport.
            deviceProperties.transportType = Int(0x7669_7274)
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "RCam Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // No settable device properties.
    }

    // MARK: 30Hz emit loop

    func startStreaming() {
        stateLock.lock()
        defer { stateLock.unlock() }
        streamingCounter += 1
        extensionLog.info("startStreaming — clients now \(self.streamingCounter)")
        guard timer == nil else { return }

        baseHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        frameIndex = 0
        let newTimer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        newTimer.schedule(deadline: .now(),
                          repeating: 1.0 / Double(kFrameRate),
                          leeway: .milliseconds(2))
        newTimer.setEventHandler { [weak self] in
            self?.emitFrame()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stopStreaming() {
        stateLock.lock()
        defer { stateLock.unlock() }
        streamingCounter = max(0, streamingCounter - 1)
        extensionLog.info("stopStreaming — clients now \(self.streamingCounter)")
        if streamingCounter == 0, let activeTimer = timer {
            activeTimer.cancel()
            timer = nil
        }
    }

    /// One tick: emit exactly one frame. Priority: fresh sink frame → last-good
    /// (sink merely stale) → placeholder. Timestamps are derived from the tick
    /// index — monotonic, evenly spaced, never a source PTS.
    private func emitFrame() {
        let pixelBuffer = nextOutputBuffer()
        guard let pixelBuffer else {
            extensionLog.error("emitFrame: no buffer available this tick")
            return
        }

        let pts = CMTimeAdd(baseHostTime,
                            CMTime(value: CMTimeValue(frameIndex), timescale: kFrameRate))
        frameIndex &+= 1

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }

        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(pts.seconds * Double(NSEC_PER_SEC))
        )
    }

    private func nextOutputBuffer() -> CVPixelBuffer? {
        stateLock.lock()
        let fresh = pendingSinkFrame
        pendingSinkFrame = nil
        let lastGood = lastGoodFrame
        let sinkAge = monotonicNow() - lastSinkArrival
        stateLock.unlock()

        if let fresh {
            return fresh
        }
        if let lastGood, sinkAge < sinkStaleThreshold {
            return lastGood
        }
        // M1: animated test pattern is the placeholder; the "Open RCam…" text
        // frame replaces it in M3 (bars stay behind a debug flag).
        return testPattern.nextFrame()
    }

    /// Sink stream hands decoded frames in here (wired up in M3).
    func sinkFrameArrived(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        pendingSinkFrame = pixelBuffer
        lastGoodFrame = pixelBuffer
        lastSinkArrival = monotonicNow()
        stateLock.unlock()
    }

    private func monotonicNow() -> CFTimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / Double(NSEC_PER_SEC)
    }
}

// MARK: - Source stream (clients read from this)

final class RCamSourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [streamFormat]
    }

    var activeFormatIndex = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                extensionLog.error("Invalid activeFormatIndex \(self.activeFormatIndex)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // No settable stream properties.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? RCamDeviceSource else {
            fatalError("Unexpected device source type")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? RCamDeviceSource else {
            fatalError("Unexpected device source type")
        }
        deviceSource.stopStreaming()
    }
}

// MARK: - Sink stream (the app writes decoded frames here; consumed in M3)

final class RCamSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(
        localizedName: String,
        streamID: UUID,
        streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [streamFormat]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize]
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(value: 1, timescale: kFrameRate)
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 4
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        // No settable stream properties.
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        extensionLog.info("Sink stream started (consumption wired in M3)")
    }

    func stopStream() throws {
        extensionLog.info("Sink stream stopped")
    }
}
