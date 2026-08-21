import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import os.log

/// Pushes decoded frames into the extension's sink stream via the
/// CoreMediaIO C API: find device → find sink stream → copy buffer queue →
/// enqueue CMSampleBuffers → start the stream.
final class SinkWriter {
    static let deviceUID = "7E5F9C1A-3B2D-4E6F-8A90-C1D2E3F4A5B6"
    static let sinkStreamName = "RTSP Camera Sink"

    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "SinkWriter")
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private(set) var running = false

    func start() -> Bool {
        guard let device = CMIOHelpers.findDevice(uid: Self.deviceUID) else {
            log.error("virtual camera device not found")
            return false
        }
        deviceID = device
        guard let sink = CMIOHelpers.findStream(device: device, named: Self.sinkStreamName) else {
            log.error("sink stream not found")
            return false
        }
        sinkStreamID = sink

        var queueRef: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueRef)
        guard copyStatus == noErr, let queueRef else {
            log.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return false
        }
        queue = queueRef.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            log.error("CMIODeviceStartStream failed: \(startStatus)")
            queue = nil
            return false
        }
        running = true
        log.info("sink stream attached and started")
        return true
    }

    func stop() {
        guard running else { return }
        CMIODeviceStopStream(deviceID, sinkStreamID)
        queue = nil
        formatDescription = nil
        running = false
        log.info("sink stream stopped")
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard running, let queue else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            return // extension is behind; drop rather than block
        }

        if formatDescription == nil ||
            !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            )
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard let sampleBuffer else { return }
        // Receiver takes over the +1 retain.
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())
    }
}
