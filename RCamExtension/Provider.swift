import Foundation
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

// MARK: - Device

final class RCamDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStreamSource: RCamSourceStreamSource!

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
        let frameDuration = CMTime(value: 1, timescale: kFrameRate)
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
        do {
            try device.addStream(sourceStreamSource.stream)
        } catch {
            fatalError("Failed to add source stream: \(error.localizedDescription)")
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

    // Real 30Hz emit loop lands in M1; the skeleton only tracks client interest.
    func startStreaming() {
        extensionLog.info("startStreaming (skeleton — frames come in M1)")
    }

    func stopStreaming() {
        extensionLog.info("stopStreaming (skeleton)")
    }
}

// MARK: - Source stream

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
