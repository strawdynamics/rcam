import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import os.log

// Fixed output format (locked): 1280x720, 30fps, NV12.
let kOutputWidth: Int32 = 1280
let kOutputHeight: Int32 = 720
let kFrameRate: Int32 = 30

let extensionLog = Logger(subsystem: "com.strawdynamics.rcam.extension", category: "Provider")

// MARK: - Provider

final class RCamProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: RCamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = RCamDeviceSource(localizedName: "RCam")
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
            providerProperties.manufacturer = "Straw Dynamics"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties.
    }
}

// MARK: - Device (owns the single 30Hz clock)

final class RCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // Custom properties (device scope). Format: 4cc_<fourcc>_glob_0000.
    // Both are strings: watched is "0"/"1" so the app-side read path is uniform.
    static let watchedProperty = CMIOExtensionProperty(rawValue: "4cc_rwch_glob_0000")
    static let cameraNameProperty = CMIOExtensionProperty(rawValue: "4cc_rnam_glob_0000")
    static let switchingProperty = CMIOExtensionProperty(rawValue: "4cc_rswt_glob_0000")

    private(set) var device: CMIOExtensionDevice!
    private var sourceStreamSource: RCamSourceStreamSource!
    private var sinkStreamSource: RCamSinkStreamSource!

    private let stateLock = NSLock()
    private var streamingCounter = 0
    private var sinkConnected = false
    private var activeCameraName = ""
    private var switching = false
    private let debugBars = ProcessInfo.processInfo.environment["RCAM_TEST_BARS"] != nil

    private let timerQueue = DispatchQueue(label: "com.strawdynamics.rcam.extension.emit",
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
    /// How long to re-emit the last-good frame during a sink stall before
    /// declaring the stream dead ("No signal" placeholder).
    private let sinkStaleThreshold: CFTimeInterval = 3.0

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
        [.deviceTransportType, .deviceModel,
         Self.watchedProperty, Self.cameraNameProperty, Self.switchingProperty]
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
        stateLock.lock()
        let watched = streamingCounter > 0
        let name = activeCameraName
        stateLock.unlock()
        if properties.contains(Self.watchedProperty) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: (watched ? "1" : "0") as NSString),
                forProperty: Self.watchedProperty
            )
        }
        if properties.contains(Self.cameraNameProperty) {
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: name as NSString),
                forProperty: Self.cameraNameProperty
            )
        }
        if properties.contains(Self.switchingProperty) {
            stateLock.lock()
            let switchingNow = switching
            stateLock.unlock()
            deviceProperties.setPropertyState(
                CMIOExtensionPropertyState(value: (switchingNow ? "1" : "0") as NSString),
                forProperty: Self.switchingProperty
            )
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if let state = deviceProperties.propertiesDictionary[Self.cameraNameProperty],
           let name = state.value as? String {
            stateLock.lock()
            activeCameraName = name
            stateLock.unlock()
            extensionLog.info("activeCameraName set to \(name, privacy: .public)")
        }
        if let state = deviceProperties.propertiesDictionary[Self.switchingProperty],
           let raw = state.value as? String {
            stateLock.lock()
            switching = raw == "1"
            stateLock.unlock()
            extensionLog.info("switching set to \(raw, privacy: .public)")
        }
    }

    private func notifyWatchedChanged() {
        stateLock.lock()
        let watched = streamingCounter > 0
        stateLock.unlock()
        let state = CMIOExtensionPropertyState<AnyObject>(value: (watched ? "1" : "0") as NSString)
        device.notifyPropertiesChanged([Self.watchedProperty: state])
    }

    // MARK: 30Hz emit loop

    func startStreaming() {
        stateLock.lock()
        streamingCounter += 1
        extensionLog.info("startStreaming — clients now \(self.streamingCounter)")
        if timer == nil {
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
        stateLock.unlock()
        notifyWatchedChanged()
    }

    func stopStreaming() {
        stateLock.lock()
        streamingCounter = max(0, streamingCounter - 1)
        extensionLog.info("stopStreaming — clients now \(self.streamingCounter)")
        if streamingCounter == 0, let activeTimer = timer {
            activeTimer.cancel()
            timer = nil
        }
        stateLock.unlock()
        notifyWatchedChanged()
    }

    /// One tick: emit exactly one frame. Priority: fresh sink frame → last-good
    /// (sink merely stale) → placeholder. Timestamps are derived from the tick
    /// index — monotonic, evenly spaced, never a source PTS.
    private func emitFrame() {
        var pixelBuffer = nextOutputBuffer()
        stateLock.lock()
        let switchingNow = switching
        stateLock.unlock()
        if switchingNow, let base = pixelBuffer, let badged = withConnectingBadge(base) {
            pixelBuffer = badged
        }
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
        let connected = sinkConnected
        let name = activeCameraName
        stateLock.unlock()

        if let fresh {
            return fresh
        }
        if connected {
            // RTSP stalls are normal — hold the last-good frame while merely
            // stale, drop to "No signal" only when the stream looks dead.
            if let lastGood, sinkAge < sinkStaleThreshold {
                return lastGood
            }
            let label = name.isEmpty ? "camera" : name
            return PlaceholderRenderer.textFrame(lines: ["No signal — \(label)"])
        }
        if debugBars {
            return testPattern.nextFrame()
        }
        return PlaceholderRenderer.textFrame(lines: ["Open RCam to select a source"])
    }

    /// Sink stream hands decoded frames in here.
    func sinkFrameArrived(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        pendingSinkFrame = pixelBuffer
        lastGoodFrame = pixelBuffer
        lastSinkArrival = monotonicNow()
        stateLock.unlock()
    }

    func setSinkConnected(_ connected: Bool) {
        stateLock.lock()
        sinkConnected = connected
        if !connected {
            // Client is gone — fall straight to the placeholder, don't replay
            // its stale frames.
            pendingSinkFrame = nil
            lastGoodFrame = nil
        }
        stateLock.unlock()
        extensionLog.info("sinkConnected = \(connected)")
    }

    private func monotonicNow() -> CFTimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / Double(NSEC_PER_SEC)
    }

    // MARK: "Connecting…" badge overlay

    private lazy var overlayPool: CVPixelBufferPool? = {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Int(kOutputWidth),
            kCVPixelBufferHeightKey: Int(kOutputHeight),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }()

    /// Copy the frame (never mutate a sink buffer in place — the writer may
    /// still hold it) and blit the cached badge bottom-center.
    private func withConnectingBadge(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        guard let overlayPool,
              let badge = PlaceholderRenderer.badge(text: "Connecting…") else { return nil }
        var copyOpt: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, overlayPool, &copyOpt)
        guard let copy = copyOpt else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let srcY = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let srcC = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let dstY = CVPixelBufferGetBaseAddressOfPlane(copy, 0),
              let dstC = CVPixelBufferGetBaseAddressOfPlane(copy, 1) else { return nil }
        let width = Int(kOutputWidth)
        let height = Int(kOutputHeight)
        let srcYStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let srcCStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(copy, 0)
        let dstCStride = CVPixelBufferGetBytesPerRowOfPlane(copy, 1)
        for row in 0..<height {
            memcpy(dstY + row * dstYStride, srcY + row * srcYStride, width)
        }
        for row in 0..<(height / 2) {
            memcpy(dstC + row * dstCStride, srcC + row * srcCStride, width)
        }

        // Badge bottom-center; neutralize chroma underneath so it reads white.
        let originX = (width - badge.width) / 2
        let originY = height - badge.height - 48
        let yPlane = dstY.assumingMemoryBound(to: UInt8.self)
        badge.pixels.withUnsafeBufferPointer { src in
            for row in 0..<badge.height {
                memcpy(yPlane + (originY + row) * dstYStride + originX,
                       src.baseAddress! + row * badge.width, badge.width)
            }
        }
        let chromaX = originX & ~1
        for row in (originY / 2)..<((originY + badge.height) / 2) {
            memset(dstC + row * dstCStride + chromaX, 128, badge.width & ~1)
        }
        return copy
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
    private var client: CMIOExtensionClient?
    private var sinkStarted = false

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
        self.client = client
        return true
    }

    func startStream() throws {
        extensionLog.info("Sink stream started")
        sinkStarted = true
        deviceSource?.setSinkConnected(true)
        consumeNext()
    }

    func stopStream() throws {
        extensionLog.info("Sink stream stopped")
        sinkStarted = false
        deviceSource?.setSinkConnected(false)
    }

    private var deviceSource: RCamDeviceSource? {
        device.source as? RCamDeviceSource
    }

    private func consumeNext() {
        guard sinkStarted, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, _, _, _, error in
            guard let self else { return }
            if let sampleBuffer, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                self.deviceSource?.sinkFrameArrived(pixelBuffer)
            }
            if let error {
                extensionLog.error("consumeSampleBuffer: \(error.localizedDescription, privacy: .public)")
            }
            if self.sinkStarted {
                self.consumeNext()
            }
        }
    }
}
