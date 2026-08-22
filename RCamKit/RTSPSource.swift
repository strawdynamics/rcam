import Foundation
import CFFmpeg
import CoreMedia
import CoreVideo
import VideoToolbox

/// RTSP H.264 source: libavformat demux (TCP, low-latency) →
/// VTDecompressionSession (hardware decode) → VTPixelTransferSession
/// (scale + letterbox to 1280x720 NV12).
public final class RTSPSource: FrameSource {
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

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var transferSession: VTPixelTransferSession?
    private var outputPool: CVPixelBufferPool?
    private var decodeCounter: Int64 = 0

    /// `fill: true` crops to fill the 16:9 output instead of letterboxing.
    public init(url: String, fill: Bool = false) {
        self.url = url
        self.fill = fill
        RTSPSource.initializeFFmpegOnce
    }

    deinit {
        stop()
    }

    public func start() {
        guard thread == nil else { return }
        stopFlag.stopped = 0
        let thread = Thread { [weak self] in
            self?.runLoop()
            self?.finished.signal()
        }
        thread.name = "RTSPSource(\(url))"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    public func stop() {
        guard thread != nil else { return }
        stopFlag.stopped = 1
        _ = finished.wait(timeout: .now() + 3)
        thread = nil
        teardownVideoToolbox()
    }

    // MARK: - Demux loop

    private static let initializeFFmpegOnce: Void = {
        av_log_set_level(AV_LOG_WARNING)
        avformat_network_init()
    }()

    private final class StopFlag {
        var stopped: Int32 = 0
    }

    private let interruptCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 0 }
        let flag = Unmanaged<StopFlag>.fromOpaque(opaque).takeUnretainedValue()
        return flag.stopped != 0 ? 1 : 0
    }

    private func runLoop() {
        onStateChange?(.connecting)

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

        while stopFlag.stopped == 0 {
            ret = av_read_frame(formatContext, packet)
            if ret < 0 {
                if stopFlag.stopped == 0 {
                    onStateChange?(.failed("read failed: \(Self.errorString(ret))"))
                }
                break
            }
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex,
                  let packetData = packet.pointee.data else { continue }
            let packetSize = Int(packet.pointee.size)

            // In-band SPS/PPS (annex-B) — needed if the SDP had none, and
            // keeps us current if the camera re-sends them.
            if parameterSets == nil {
                parameterSets = H264Bitstream.parseAnnexBParameterSets(data: packetData, size: packetSize)
            }
            guard let sets = parameterSets else { continue }

            if formatDescription == nil {
                guard setupDecoder(sps: sets.sps, pps: sets.pps) else {
                    onStateChange?(.failed("decoder setup failed"))
                    return
                }
            }

            if !sawKeyframe {
                guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { continue }
                sawKeyframe = true
            }

            if let output = decodePacket(data: packetData, size: packetSize) {
                if !deliveredFirstFrame {
                    deliveredFirstFrame = true
                    onStateChange?(.streaming)
                }
                onFrame?(output, Self.now())
            }
        }
    }

    // MARK: - VideoToolbox

    private func setupDecoder(sps: [UInt8], pps: [UInt8]) -> Bool {
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

    private func teardownVideoToolbox() {
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

    /// Annex-B packet → length-prefixed sample buffer → decode → letterboxed
    /// 720p NV12 buffer (or nil for non-displayable/failed frames).
    private func decodePacket(data: UnsafePointer<UInt8>, size: Int) -> CVPixelBuffer? {
        guard let session = decompressionSession,
              let formatDescription,
              let converted = H264Bitstream.annexBToLengthPrefixed(data: data, size: size),
              !converted.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: converted.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: converted.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        status = converted.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: converted.count)
        }
        guard status == noErr else { return nil }

        decodeCounter += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: decodeCounter, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleSize = converted.count
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
