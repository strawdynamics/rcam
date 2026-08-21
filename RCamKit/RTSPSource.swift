import Foundation
import CFFmpeg
import CoreMedia
import CoreVideo
import VideoToolbox

/// RTSP H.264 source: libavformat demux (TCP, low-latency) →
/// VTDecompressionSession (hardware decode) → VTPixelTransferSession
/// (scale + letterbox to 1280x720 NV12).
public final class RTSPSource: FrameSource {
    public var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    public var onStateChange: ((FrameSourceState) -> Void)?

    private let url: String
    private let stopFlag = StopFlag()
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var transferSession: VTPixelTransferSession?
    private var outputPool: CVPixelBufferPool?
    private var decodeCounter: Int64 = 0

    public init(url: String) {
        self.url = url
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
        av_dict_set(&options, "probesize", "500000", 0)
        av_dict_set(&options, "analyzeduration", "1000000", 0)
        av_dict_set(&options, "fflags", "nobuffer", 0)
        av_dict_set(&options, "flags", "low_delay", 0)
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
        guard codecParameters.pointee.codec_id == AV_CODEC_ID_H264 else {
            onStateChange?(.failed("unsupported codec (only H.264 in v1)"))
            return
        }

        // SPS/PPS: usually in extradata for RTSP (from the SDP).
        var parameterSets = Self.parseParameterSets(
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
                parameterSets = Self.parseAnnexBParameterSets(data: packetData, size: packetSize)
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
                             value: kVTScalingMode_Letterbox)
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
              let converted = Self.annexBToLengthPrefixed(data: data, size: size),
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

    // MARK: - H.264 bitstream helpers

    struct ParameterSets {
        let sps: [UInt8]
        let pps: [UInt8]
    }

    /// Extradata is either avcC (starts with 0x01) or annex-B.
    static func parseParameterSets(data: UnsafeMutablePointer<UInt8>?, size: Int) -> ParameterSets? {
        guard let data, size > 0 else { return nil }
        if data[0] == 1 {
            return parseAVCC(data: data, size: size)
        }
        return parseAnnexBParameterSets(data: data, size: size)
    }

    static func parseAVCC(data: UnsafePointer<UInt8>, size: Int) -> ParameterSets? {
        guard size > 7 else { return nil }
        var offset = 5
        var sps: [UInt8]?
        var pps: [UInt8]?

        let spsCount = Int(data[offset] & 0x1F)
        offset += 1
        for _ in 0..<spsCount {
            guard offset + 2 <= size else { return nil }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= size else { return nil }
            if sps == nil { sps = Array(UnsafeBufferPointer(start: data + offset, count: length)) }
            offset += length
        }
        guard offset < size else { return nil }
        let ppsCount = Int(data[offset])
        offset += 1
        for _ in 0..<ppsCount {
            guard offset + 2 <= size else { return nil }
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= size else { return nil }
            if pps == nil { pps = Array(UnsafeBufferPointer(start: data + offset, count: length)) }
            offset += length
        }
        guard let sps, let pps else { return nil }
        return ParameterSets(sps: sps, pps: pps)
    }

    static func parseAnnexBParameterSets(data: UnsafePointer<UInt8>, size: Int) -> ParameterSets? {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for unit in annexBNALUnits(data: data, size: size) {
            guard unit.count > 0 else { continue }
            switch unit[0] & 0x1F {
            case 7: if sps == nil { sps = unit }
            case 8: if pps == nil { pps = unit }
            default: break
            }
        }
        guard let sps, let pps else { return nil }
        return ParameterSets(sps: sps, pps: pps)
    }

    /// Split an annex-B buffer into NAL unit payloads (start codes stripped).
    static func annexBNALUnits(data: UnsafePointer<UInt8>, size: Int) -> [[UInt8]] {
        var units = [[UInt8]]()
        var nalStart: Int?
        var index = 0
        while index + 2 < size {
            if data[index] == 0, data[index + 1] == 0, data[index + 2] == 1 {
                if let start = nalStart {
                    var end = index
                    if end > start, data[end - 1] == 0 { end -= 1 } // 4-byte start code
                    units.append(Array(UnsafeBufferPointer(start: data + start, count: end - start)))
                }
                index += 3
                nalStart = index
            } else {
                index += 1
            }
        }
        if let start = nalStart, start < size {
            units.append(Array(UnsafeBufferPointer(start: data + start, count: size - start)))
        }
        return units
    }

    /// Annex-B → 4-byte-length-prefixed (AVCC) for VideoToolbox.
    static func annexBToLengthPrefixed(data: UnsafePointer<UInt8>, size: Int) -> [UInt8]? {
        let units = annexBNALUnits(data: data, size: size)
        guard !units.isEmpty else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(size + 8)
        for unit in units {
            // Skip parameter/filler units VT doesn't want mid-sample; keep slices.
            let type = unit.first.map { $0 & 0x1F } ?? 0
            guard type != 7, type != 8, type != 9, type != 12 else { continue }
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
            out.append(contentsOf: unit)
        }
        return out
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
