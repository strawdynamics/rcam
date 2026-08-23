import Foundation
import AVFoundation
import CoreVideo

/// `rcamcli probe-device`: assert the "RCam" virtual device exists,
/// capture frames from it, and assert 1280x720 with live (animating) content.
enum ProbeDevice {
    static let deviceName = "RCam"

    static func run(frameTarget: Int, dumpLuma: Bool = false) -> Int32 {
        guard requestCameraAccess() else {
            fputs("FAIL: camera access denied (grant access in System Settings → Privacy & Security → Camera)\n", stderr)
            return 2
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )
        let names = discovery.devices.map(\.localizedName)
        print("external video devices: \(names)")
        guard let device = discovery.devices.first(where: { $0.localizedName == deviceName }) else {
            fputs("FAIL: device \"\(deviceName)\" not found\n", stderr)
            return 1
        }
        print("OK: found \"\(deviceName)\" (uniqueID \(device.uniqueID))")

        let collector = FrameCollector(target: frameTarget)
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                fputs("FAIL: cannot add device input\n", stderr)
                return 2
            }
            session.addInput(input)
        } catch {
            fputs("FAIL: cannot open device: \(error.localizedDescription)\n", stderr)
            return 2
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(collector, queue: DispatchQueue(label: "probe.frames"))
        guard session.canAddOutput(output) else {
            fputs("FAIL: cannot add video output\n", stderr)
            return 2
        }
        session.addOutput(output)

        session.startRunning()
        let done = collector.wait(timeout: .now() + .seconds(15 + frameTarget / 30))
        session.stopRunning()

        guard done else {
            fputs("FAIL: timed out after collecting \(collector.stats.count) of \(frameTarget) frames\n", stderr)
            return 2
        }
        if dumpLuma {
            for (index, stat) in collector.stats.enumerated() {
                print(String(format: "luma[%d]=%.1f sig=%016llx t=%.3f", index, stat.luma, stat.signature, stat.arrival))
            }
        }
        return assess(stats: collector.stats, frameTarget: frameTarget)
    }

    private static func assess(stats: [FrameStat], frameTarget: Int) -> Int32 {
        var failures = [String]()
        if stats.count < frameTarget {
            failures.append("collected \(stats.count) frames, wanted \(frameTarget)")
        }
        if let bad = stats.first(where: { $0.width != 1280 || $0.height != 720 }) {
            failures.append("unexpected dimensions \(bad.width)x\(bad.height), wanted 1280x720")
        }
        let pairCount = max(stats.count - 1, 1)
        let signatures = stats.map(\.signature)
        let meanLuma = stats.map(\.luma).reduce(0, +) / Double(max(stats.count, 1))
        let sigChanged = zip(signatures.dropFirst(), signatures).filter { $0 != $1 }.count
        let distinct = Set(signatures).count
        let longestStaticRun = longestRepeatRun(signatures)
        let span = (stats.last?.arrival ?? 0) - (stats.first?.arrival ?? 0)
        let fps = span > 0 ? Double(stats.count - 1) / span : 0
        let runLimit = staticRunLimit(frameCount: stats.count)
        let distinctFloor = max(2, stats.count / 10)
        print(String(format: "frames=%d fps=%.1f meanLuma=%.1f distinct=%d sigChanged=%d/%d longestStaticRun=%d (limits: run<%d distinct>=%d)",
                     stats.count, fps, meanLuma, distinct, sigChanged, pairCount,
                     longestStaticRun, runLimit, distinctFloor))
        if meanLuma < 17 {
            failures.append("frames are essentially black (mean luma \(meanLuma))")
        }
        if longestStaticRun >= runLimit {
            failures.append("content frozen: \(longestStaticRun) consecutive identical frames (limit \(runLimit)) — "
                            + "a frozen placeholder or a held last-good frame, not a live stream")
        }
        if distinct < distinctFloor {
            failures.append("only \(distinct) distinct frames in \(stats.count) (want >= \(distinctFloor)) — "
                            + "the device is cycling a few cached buffers, not streaming")
        }
        if failures.isEmpty {
            print("OK: \(stats.count) frames, 1280x720, live")
            return 0
        }
        if longestStaticRun >= runLimit || distinct < distinctFloor {
            fputs("note: probe-device is usually the device's only client, so it cold-starts the RTSP\n"
                  + "      connect and reads the placeholder for the first second or two. Run a throwaway\n"
                  + "      `probe-device --frames 300` first, then re-run this within the 10s unwatched grace.\n",
                  stderr)
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        return 3
    }

    /// Frames of unbroken repetition that count as "frozen".
    ///
    /// Measured ground truth at 1280x720/30fps (2026-08-22, 300-frame samples):
    ///
    ///   frozen "No signal" placeholder   distinct=1     longestStaticRun=300 (the whole sample)
    ///   live rig (testsrc, 30fps)        distinct=262   longestStaticRun=1-2
    ///   live real camera (~15fps source) distinct=140   longestStaticRun=7
    ///
    /// The real camera is the binding case: it feeds a 30fps output tick at
    /// about 15fps, so roughly every other emitted frame is a legitimate
    /// repeat. That is why this is a *run-length* test and not a fraction —
    /// a fraction test has to sit below the real camera's ~46% changed pairs,
    /// which leaves it nearly as blind as the mean-luma test it replaces.
    /// Run length is independent of the source frame rate: halving the source
    /// rate doubles the run length, it does not approach the sample size.
    ///
    /// 30 frames is 1s at 30fps — over 4x the worst live measurement and a
    /// tenth of the frozen one. Capped at half the sample so that a short
    /// probe (the 30-frame default) still fails when it is frozen throughout.
    private static func staticRunLimit(frameCount: Int) -> Int {
        min(30, max(2, frameCount / 2))
    }

    /// Longest run of consecutive frames carrying the same signature, in frames.
    /// A frozen source gives a run equal to the whole sample; a live source
    /// gives short runs from the occasional repeated tick.
    private static func longestRepeatRun(_ signatures: [UInt64]) -> Int {
        var longest = 0
        var current = 0
        var previous: UInt64?
        for signature in signatures {
            if signature == previous {
                current += 1
            } else {
                current = 1
                previous = signature
            }
            longest = max(longest, current)
        }
        return longest
    }

    private static func requestCameraAccess() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            return granted
        default:
            return false
        }
    }
}

struct FrameStat {
    let width: Int
    let height: Int
    let luma: Double // mean of sampled Y-plane pixels
    /// FNV-1a hash of the same sampled Y-plane grid the mean is taken from.
    /// Mean luma is nearly blind to motion confined to part of the frame (a
    /// burned-in clock, a person in a doorway) because it averages the change
    /// away across ~921k pixels. The hash changes if *any* sampled pixel does,
    /// which is what actually separates a live stream from a frozen one.
    let signature: UInt64
    let arrival: TimeInterval // epoch seconds
}

final class FrameCollector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private(set) var stats = [FrameStat]()
    private let target: Int
    private let semaphore = DispatchSemaphore(value: 0)

    init(target: Int) {
        self.target = target
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard stats.count < target,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var sum = 0.0
        var samples = 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let plane = yBase.assumingMemoryBound(to: UInt8.self)
            for row in Swift.stride(from: 0, to: height, by: 16) {
                for col in Swift.stride(from: 0, to: width, by: 16) {
                    let value = plane[row * stride + col]
                    sum += Double(value)
                    samples += 1
                    hash = (hash ^ UInt64(value)) &* 0x0000_0100_0000_01b3
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        stats.append(FrameStat(width: width, height: height,
                               luma: samples > 0 ? sum / Double(samples) : 0,
                               signature: hash,
                               arrival: Date().timeIntervalSince1970))
        if stats.count >= target {
            semaphore.signal()
        }
    }
}
