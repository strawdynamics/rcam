import Foundation
import AVFoundation
import CoreVideo

/// `rcamcli probe-device`: assert the "RTSP Camera" virtual device exists,
/// capture frames from it, and assert 1280x720 with live (animating) content.
enum ProbeDevice {
    static let deviceName = "RTSP Camera"

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
        let done = collector.wait(timeout: .now() + 15)
        session.stopRunning()

        guard done else {
            fputs("FAIL: timed out after collecting \(collector.stats.count) of \(frameTarget) frames\n", stderr)
            return 2
        }
        if dumpLuma {
            for (index, stat) in collector.stats.enumerated() {
                print(String(format: "luma[%d]=%.1f", index, stat.luma))
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
        let diffs = zip(stats.dropFirst(), stats).map { abs($0.luma - $1.luma) }
        let changed = diffs.filter { $0 > 0.05 }.count
        let meanLuma = stats.map(\.luma).reduce(0, +) / Double(max(stats.count, 1))
        print(String(format: "frames=%d meanLuma=%.1f changedPairs=%d/%d",
                     stats.count, meanLuma, changed, max(diffs.count, 1)))
        if meanLuma < 17 {
            failures.append("frames are essentially black (mean luma \(meanLuma))")
        }
        if changed < max(1, diffs.count / 4) {
            failures.append("content not animating (only \(changed)/\(diffs.count) frame pairs differ)")
        }
        if failures.isEmpty {
            print("OK: \(stats.count) frames, 1280x720, animating")
            return 0
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        return 3
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
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let plane = yBase.assumingMemoryBound(to: UInt8.self)
            for row in Swift.stride(from: 0, to: height, by: 16) {
                for col in Swift.stride(from: 0, to: width, by: 16) {
                    sum += Double(plane[row * stride + col])
                    samples += 1
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        stats.append(FrameStat(width: width, height: height,
                               luma: samples > 0 ? sum / Double(samples) : 0))
        if stats.count >= target {
            semaphore.signal()
        }
    }
}
