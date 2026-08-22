import Foundation
import CFFmpeg
import CoreMedia
import CoreVideo
import OSLog
import Synchronization
import VideoToolbox

/// RTSP H.264 source: libavformat demux (TCP, low-latency) →
/// VTDecompressionSession (hardware decode) → VTPixelTransferSession
/// (scale + letterbox to 1280x720 NV12).
///
/// Threading: every piece of decode state lives in a `DecodeSession` created
/// and owned by the demux thread inside `runLoop()`, so nothing outside that
/// thread can invalidate a session under a live decode. `stop()` only sets the
/// atomic stop flag and waits.
public final class RTSPSource: FrameSource {
    /// Consecutive `decodePacket` failures before the source gives up and
    /// reports `.failed` (~1s at 30fps). Without this a stream that keeps
    /// demuxing but never decodes stalls forever: `av_read_frame` succeeds, so
    /// nothing else notices, and the extension shows "No signal" until the TCP
    /// connection itself dies.
    static let decodeFailureThreshold = 30

    /// How long `stop()` waits for the demux thread. Deliberately above the 5s
    /// ffmpeg socket `timeout` below, so a thread blocked in I/O normally
    /// unblocks and exits within the window.
    static let stopWaitSeconds: TimeInterval = 6

    /// Native properties of the connected stream, as reported by the demuxer
    /// (before any scaling to the 720p output format).
    public struct StreamInfo: Equatable {
        public let width: Int
        public let height: Int
        public let codec: String
        public let frameRate: Double?
    }

    public var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    public var onStateChange: ((FrameSourceState) -> Void)?
    /// Fires once per connection, after stream info is probed — including for
    /// streams that then fail the codec check.
    public var onStreamInfo: ((StreamInfo) -> Void)?

    private let url: String
    private let fill: Bool
    private let stopFlag = StopFlag()
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    /// Set when a `stop()` gave up waiting and left its demux thread running.
    /// The next `start()` uses this to drain that thread's late `finished`
    /// signal — see `start()`.
    private var abandonedRun = false

    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "RTSPSource")

    /// `fill: true` crops to fill the 16:9 output instead of letterboxing.
    public init(url: String, fill: Bool = false) {
        self.url = url
        self.fill = fill
        RTSPSource.initializeFFmpegOnce
    }

    deinit {
        stop()
        // Cheap, and exactly the signal that was missing when Test Connection
        // was leaking a source per run (finding 5).
        log.info("deinit \(StreamHealth.streamLabel(forURL: self.url), privacy: .public)")
    }

    public func start() {
        guard thread == nil else { return }

        // A previous stop() may have timed out and abandoned its demux thread.
        // That thread signals `finished` on its way out; if we left the signal
        // sitting in the semaphore it would pre-satisfy the *next* stop(),
        // which would then return while a thread was still running. Wait it
        // out here instead — before a new thread exists, any signal in flight
        // can only belong to the abandoned run.
        if abandonedRun {
            if finished.wait(timeout: .now() + Self.stopWaitSeconds) == .timedOut {
                log.error("previous demux thread still running after \(Self.stopWaitSeconds, format: .fixed(precision: 0))s — starting anyway")
            }
            abandonedRun = false
        }

        stopFlag.stopped.store(0, ordering: .relaxed)
        let thread = Thread { [weak self] in
            self?.runLoop()
            self?.finished.signal()
        }
        // Finding 2: the URL carries the Keychain password, and thread names
        // surface in crash reports, `sample` output, and Instruments.
        thread.name = "RTSPSource(\(StreamHealth.streamLabel(forURL: url)))"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    public func stop() {
        guard thread != nil else { return }
        stopFlag.stopped.store(1, ordering: .relaxed)
        if finished.wait(timeout: .now() + Self.stopWaitSeconds) == .timedOut {
            // Wedged past the socket timeout. The thread still owns its
            // DecodeSession and tears it down on its own exit path, so it is
            // safe to walk away — but record that its signal is still coming.
            abandonedRun = true
            log.error("stop() timed out after \(Self.stopWaitSeconds, format: .fixed(precision: 0))s — demux thread abandoned")
        }
        thread = nil
    }

    // MARK: - Demux loop

    private static let initializeFFmpegOnce: Void = {
        av_log_set_level(AV_LOG_WARNING)
        avformat_network_init()
    }()

    /// Read from the demux thread, the interrupt callback, `start()` and
    /// `stop()`, so it has to be atomic. Relaxed ordering is enough: the flag
    /// is the only thing shared across those threads, and it is a one-way
    /// latch per run.
    private final class StopFlag {
        let stopped = Atomic<Int32>(0)
    }

    private let interruptCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 0 }
        let flag = Unmanaged<StopFlag>.fromOpaque(opaque).takeUnretainedValue()
        return flag.stopped.load(ordering: .relaxed) != 0 ? 1 : 0
    }

    private var shouldStop: Bool { stopFlag.stopped.load(ordering: .relaxed) != 0 }

    private func runLoop() {
        onStateChange?(.connecting)

        // Owned entirely by this thread, and torn down on every exit path
        // below — including the early returns. Nothing else can reach it.
        let decoder = DecodeSession(fill: fill)
        defer { decoder.teardown() }

        var formatContext = avformat_alloc_context()
        guard formatContext != nil else {
            onStateChange?(.failed("avformat_alloc_context failed"))
            return
        }
        formatContext!.pointee.interrupt_callback.callback = interruptCallback
        formatContext!.pointee.interrupt_callback.opaque =
            Unmanaged.passUnretained(stopFlag).toOpaque()

        var options: OpaquePointer?
        av_dict_set(&options, "rtsp_transport", "tcp", 0)
        // Low-latency tuning (M5): RTSP delivers SPS/PPS via the SDP, so tiny
        // probe windows are safe; TCP transport can't reorder, so no queue.
        av_dict_set(&options, "probesize", "100000", 0)
        av_dict_set(&options, "analyzeduration", "200000", 0)
        av_dict_set(&options, "fflags", "nobuffer", 0)
        av_dict_set(&options, "flags", "low_delay", 0)
        av_dict_set(&options, "reorder_queue_size", "0", 0)
        av_dict_set(&options, "max_delay", "500000", 0)
        av_dict_set(&options, "timeout", "5000000", 0) // socket I/O timeout, µs

        var ret = avformat_open_input(&formatContext, url, nil, &options)
        av_dict_free(&options)
        guard ret >= 0, formatContext != nil else {
            onStateChange?(.failed("open failed: \(Self.errorString(ret))"))
            return
        }
        defer { avformat_close_input(&formatContext) }

        ret = avformat_find_stream_info(formatContext, nil)
        guard ret >= 0 else {
            onStateChange?(.failed("find_stream_info failed: \(Self.errorString(ret))"))
            return
        }

        let streamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        guard streamIndex >= 0,
              let stream = formatContext!.pointee.streams[Int(streamIndex)] else {
            onStateChange?(.failed("no video stream"))
            return
        }
        let codecParameters = stream.pointee.codecpar!

        let avgFrameRate = stream.pointee.avg_frame_rate
        let frameRate: Double? = avgFrameRate.num > 0 && avgFrameRate.den > 0
            ? Double(avgFrameRate.num) / Double(avgFrameRate.den) : nil
        onStreamInfo?(StreamInfo(
            width: Int(codecParameters.pointee.width),
            height: Int(codecParameters.pointee.height),
            codec: String(cString: avcodec_get_name(codecParameters.pointee.codec_id)),
            frameRate: frameRate
        ))

        guard codecParameters.pointee.codec_id == AV_CODEC_ID_H264 else {
            onStateChange?(.failed("unsupported codec (only H.264 in v1)"))
            return
        }

        // SPS/PPS: usually in extradata for RTSP (from the SDP).
        var parameterSets = H264Bitstream.parseParameterSets(
            data: codecParameters.pointee.extradata,
            size: Int(codecParameters.pointee.extradata_size)
        )

        guard let packet = av_packet_alloc() else {
            onStateChange?(.failed("av_packet_alloc failed"))
            return
        }
        var packetOpt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&packetOpt) }

        var sawKeyframe = false
        var deliveredFirstFrame = false
        var decodeFailures = StreamHealth.DecodeFailureCounter(threshold: Self.decodeFailureThreshold)
        /// Dimensions of the decoder we are replacing, so the rebuild can be
        /// logged as old→new once the new one exists.
        var rebuildingFrom: CMVideoDimensions?

        while !shouldStop {
            ret = av_read_frame(formatContext, packet)
            if ret < 0 {
                if !shouldStop {
                    onStateChange?(.failed("read failed: \(Self.errorString(ret))"))
                }
                break
            }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex,
                  let packetData = packet.pointee.data else { continue }

            // One walk: length-prefixed slices out, in-band SPS/PPS out.
            guard let converted = H264Bitstream.convert(data: packetData,
                                                        size: Int(packet.pointee.size)) else { continue }

            // Finding 3: watch every packet, not just until the first pair
            // arrives. A camera that changes resolution or profile mid-stream
            // re-sends its parameter sets; decoding new slices against the old
            // decoder produces nothing but silent nils.
            if let sps = converted.sps ?? parameterSets?.sps,
               let pps = converted.pps ?? parameterSets?.pps {
                let candidate = H264Bitstream.ParameterSets(sps: sps, pps: pps)
                if candidate != parameterSets {
                    if parameterSets != nil {
                        rebuildingFrom = decoder.dimensions
                    }
                    parameterSets = candidate
                    decoder.teardown()
                }
            }
            guard let sets = parameterSets else { continue }

            if !decoder.isReady {
                guard decoder.setup(sps: sets.sps, pps: sets.pps) else {
                    onStateChange?(.failed("decoder setup failed"))
                    return
                }
                if let from = rebuildingFrom, let to = decoder.dimensions {
                    log.info("parameter sets changed — rebuilt decoder (\(from.width)x\(from.height) → \(to.width)x\(to.height))")
                    rebuildingFrom = nil
                }
                // A fresh decoder cannot start mid-GOP.
                sawKeyframe = false
            }

            if !sawKeyframe {
                guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
                sawKeyframe = true
            }

            // A packet of pure parameter sets has nothing to decode; it is not
            // a decode failure, so it must not feed the counter.
            guard !converted.lengthPrefixed.isEmpty else { continue }

            if let output = decoder.decode(converted.lengthPrefixed) {
                _ = decodeFailures.record(success: true)
                if !deliveredFirstFrame {
                    deliveredFirstFrame = true
                    onStateChange?(.streaming)
                }
                onFrame?(output, Self.now())
            } else if decodeFailures.record(success: false) {
                // Finding 3c: every failure path inside decode() returns nil
                // silently. Surfacing the run as `.failed` is what lets the
                // controller tear down and back off instead of stalling.
                onStateChange?(.failed("decode stalled — \(Self.decodeFailureThreshold) consecutive failures"))
                break
            }
        }
    }

    // MARK: - Decode session

    /// All VideoToolbox state for one run of `runLoop()`. Created, used and
    /// torn down on the demux thread and never published anywhere else, so a
    /// `stop()` on another thread cannot invalidate a session mid-decode
    /// (finding 4) and an abandoned thread can only tear down its own.
    private final class DecodeSession {
        private let fill: Bool
        private var decompressionSession: VTDecompressionSession?
        private var formatDescription: CMFormatDescription?
        private var transferSession: VTPixelTransferSession?
        private var outputPool: CVPixelBufferPool?
        private var decodeCounter: Int64 = 0

        init(fill: Bool) {
            self.fill = fill
        }

        var isReady: Bool { formatDescription != nil }

        var dimensions: CMVideoDimensions? {
            formatDescription.map { CMVideoFormatDescriptionGetDimensions($0) }
        }

        func setup(sps: [UInt8], pps: [UInt8]) -> Bool {
            var formatDesc: CMFormatDescription?
            let status: OSStatus = sps.withUnsafeBufferPointer { spsBuf in
                pps.withUnsafeBufferPointer { ppsBuf in
                    let pointers: [UnsafePointer<UInt8>] = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                    let sizes: [Int] = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: pointers,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
            guard status == noErr, let formatDesc else { return false }
            formatDescription = formatDesc

            let destinationAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var session: VTDecompressionSession?
            let createStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDesc,
                decoderSpecification: nil,
                imageBufferAttributes: destinationAttributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session
            )
            guard createStatus == noErr, let session else { return false }
            decompressionSession = session

            var transfer: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault,
                                               pixelTransferSessionOut: &transfer) == noErr,
                  let transfer else { return false }
            VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: fill ? kVTScalingMode_CropSourceToCleanAperture
                                             : kVTScalingMode_Letterbox)
            transferSession = transfer

            let poolAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: 1280,
                kCVPixelBufferHeightKey: 720,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                    poolAttributes as CFDictionary, &pool)
            guard let pool else { return false }
            outputPool = pool
            return true
        }

        func teardown() {
            if let session = decompressionSession {
                VTDecompressionSessionInvalidate(session)
                decompressionSession = nil
            }
            if let transfer = transferSession {
                VTPixelTransferSessionInvalidate(transfer)
                transferSession = nil
            }
            formatDescription = nil
            outputPool = nil
        }

        /// Length-prefixed slices → decode → letterboxed 720p NV12 buffer (or
        /// nil for non-displayable/failed frames — the caller counts those).
        func decode(_ lengthPrefixed: [UInt8]) -> CVPixelBuffer? {
            guard let session = decompressionSession,
                  let formatDescription,
                  !lengthPrefixed.isEmpty else { return nil }

            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: lengthPrefixed.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: lengthPrefixed.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr, let blockBuffer else { return nil }
            status = lengthPrefixed.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                                              blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0,
                                              dataLength: lengthPrefixed.count)
            }
            guard status == noErr else { return nil }

            decodeCounter += 1
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMTime(value: decodeCounter, timescale: 30),
                decodeTimeStamp: .invalid
            )
            var sampleSize = lengthPrefixed.count
            var sampleBuffer: CMSampleBuffer?
            status = CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: formatDescription,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else { return nil }

            var decoded: CVPixelBuffer?
            // Synchronous decode (no kVTDecodeFrame_EnableAsynchronousDecompression):
            // the handler runs before this call returns and delivers frames in
            // *decode* order, so the pipeline assumes no B-frames. True of
            // essentially every IP camera's baseline/main-profile stream; a
            // stream with B-frames would present out of order.
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: nil
            ) { _, _, imageBuffer, _, _ in
                decoded = imageBuffer
            }
            guard decodeStatus == noErr, let decoded else { return nil }

            guard let transferSession, let outputPool else { return nil }
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &output)
            guard let output else { return nil }
            guard VTPixelTransferSessionTransferImage(transferSession,
                                                      from: decoded,
                                                      to: output) == noErr else { return nil }
            return output
        }
    }

    // MARK: - Misc

    static func errorString(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / Double(NSEC_PER_SEC)
    }
}
