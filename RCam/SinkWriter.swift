import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import os.log

/// Pushes decoded frames into the extension's sink stream via the
/// CoreMediaIO C API: find device → find sink stream → copy buffer queue →
/// enqueue CMSampleBuffers → start the stream.
///
/// Threading: `enqueue` runs on the demux thread (via `RTSPSource.onFrame`)
/// while `start()`/`stop()` run on main, so `queue`, `formatDescription` and
/// `running` are all guarded by `lock` (finding 6). `deviceID` and
/// `sinkStreamID` are main-thread only — written by `start()`, read by
/// `stop()` — and stay outside it.
final class SinkWriter {
    static let deviceUID = "7E5F9C1A-3B2D-4E6F-8A90-C1D2E3F4A5B6"
    static let sinkStreamName = "RTSP Camera Sink"

    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "SinkWriter")
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0

    /// Explicit lock/unlock rather than `withLock`: its closure is `@Sendable`,
    /// and the CoreMedia types crossing this boundary are not.
    private let lock = OSAllocatedUnfairLock()
    private var queue: CMSimpleQueue?
    private var formatDescription: CMVideoFormatDescription?
    private var isRunning = false
    /// Last `CMSimpleQueueEnqueue` status, so a persistently-full queue logs
    /// once per change rather than once per dropped frame.
    private var lastEnqueueStatus: OSStatus = noErr

    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

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
        let copiedQueue = queueRef.takeRetainedValue()

        let startStatus = CMIODeviceStartStream(device, sink)
        guard startStatus == noErr else {
            log.error("CMIODeviceStartStream failed: \(startStatus)")
            return false
        }

        lock.lock()
        queue = copiedQueue
        lastEnqueueStatus = noErr
        isRunning = true
        lock.unlock()

        log.info("sink stream attached and started")
        return true
    }

    func stop() {
        lock.lock()
        let wasRunning = isRunning
        queue = nil
        formatDescription = nil
        isRunning = false
        lock.unlock()

        guard wasRunning else { return }
        CMIODeviceStopStream(deviceID, sinkStreamID)
        log.info("sink stream stopped")
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        // One critical section for the whole path, not several: the capacity
        // check, the format-description cache and the enqueue all have to see
        // the same queue. Splitting them would let a concurrent stop() drop
        // the queue between the check and the enqueue. Uncontended this is a
        // single atomic op per frame — stop() is the only other caller.
        lock.lock()

        guard isRunning, let queue else {
            lock.unlock()
            return
        }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else {
            lock.unlock()
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
        guard let formatDescription else {
            lock.unlock()
            return
        }

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
        guard let sampleBuffer else {
            lock.unlock()
            return
        }

        // Receiver takes over the +1 retain — but only if the enqueue
        // succeeds. On failure the retain is ours to undo, or the sample
        // buffer (and the pixel buffer it holds) leaks.
        let retained = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        let previousStatus = lastEnqueueStatus
        lastEnqueueStatus = status
        if status != noErr { retained.release() }
        lock.unlock()

        // Log on change only, so a wedged queue can't flood the log.
        if status != noErr, status != previousStatus {
            log.error("CMSimpleQueueEnqueue failed: \(status) — frame dropped")
        }
    }
}
