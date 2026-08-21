import Foundation
import CoreImage
import CoreVideo

/// `rcamcli capture <rtsp-url> --seconds N --out <dir>`: decode via RTSPSource,
/// save every 30th frame as PNG, print per-frame stats + fps/latency summary.
enum CaptureCommand {
    static func run(url: String, seconds: Int, outDir: String?) -> Int32 {
        if let outDir {
            try? FileManager.default.createDirectory(atPath: outDir,
                                                     withIntermediateDirectories: true)
        }

        let collector = StatsCollector(outDir: outDir)
        let source = RTSPSource(url: url)
        let startTime = RTSPSource.now()
        var firstFrameLatency: Double?

        source.onStateChange = { state in
            print("state: \(state)")
        }
        source.onFrame = { buffer, arrival in
            if firstFrameLatency == nil {
                firstFrameLatency = arrival - startTime
            }
            collector.ingest(buffer)
        }

        source.start()
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        source.stop()

        let elapsed = RTSPSource.now() - startTime
        let frameCount = collector.frameCount
        print(String(format: "captured %d frames in %.1fs (%.1f fps), first frame after %.2fs, saved %d PNGs",
                     frameCount, elapsed, Double(frameCount) / elapsed,
                     firstFrameLatency ?? -1, collector.savedCount))

        guard frameCount > 0 else {
            fputs("FAIL: no frames decoded\n", stderr)
            return 1
        }
        return 0
    }
}

/// Per-frame luma stats; saves every 30th frame as PNG.
private final class StatsCollector {
    private let outDir: String?
    private let ciContext = CIContext()
    private var previousLumaSamples: [Double]?
    private(set) var frameCount = 0
    private(set) var savedCount = 0

    init(outDir: String?) {
        self.outDir = outDir
    }

    func ingest(_ buffer: CVPixelBuffer) {
        frameCount += 1
        let index = frameCount - 1
        guard index % 30 == 0 else { return }

        let stats = analyze(buffer)
        let diff: Double
        if let previous = previousLumaSamples {
            diff = zip(stats.samples, previous).map { abs($0 - $1) }.reduce(0, +)
                / Double(max(stats.samples.count, 1))
        } else {
            diff = -1
        }
        previousLumaSamples = stats.samples

        print(String(format: "frame %d: %dx%d meanY=%.1f topBand=%.1f bottomBand=%.1f leftBand=%.1f rightBand=%.1f centerY=%.1f diffPrevSaved=%.2f",
                     index, stats.width, stats.height, stats.mean, stats.top, stats.bottom,
                     stats.left, stats.right, stats.center, diff))

        if let outDir {
            let path = "\(outDir)/frame-\(String(format: "%05d", index)).png"
            if savePNG(buffer, to: path) { savedCount += 1 }
        }
    }

    private struct LumaStats {
        let width: Int
        let height: Int
        let mean: Double
        let top: Double
        let bottom: Double
        let left: Double
        let right: Double
        let center: Double
        let samples: [Double]
    }

    private func analyze(_ buffer: CVPixelBuffer) -> LumaStats {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
            return LumaStats(width: width, height: height, mean: 0, top: 0, bottom: 0,
                             left: 0, right: 0, center: 0, samples: [])
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let plane = base.assumingMemoryBound(to: UInt8.self)

        func regionMean(rows: Range<Int>, cols: Range<Int>, step: Int = 4) -> Double {
            var sum = 0.0
            var count = 0
            for row in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: step) {
                for col in Swift.stride(from: cols.lowerBound, to: cols.upperBound, by: step) {
                    sum += Double(plane[row * stride + col])
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0
        }

        var samples = [Double]()
        for row in Swift.stride(from: 0, to: height, by: 32) {
            for col in Swift.stride(from: 0, to: width, by: 32) {
                samples.append(Double(plane[row * stride + col]))
            }
        }

        return LumaStats(
            width: width,
            height: height,
            mean: regionMean(rows: 0..<height, cols: 0..<width, step: 16),
            top: regionMean(rows: 0..<12, cols: 0..<width),
            bottom: regionMean(rows: (height - 12)..<height, cols: 0..<width),
            left: regionMean(rows: 0..<height, cols: 0..<12),
            right: regionMean(rows: 0..<height, cols: (width - 12)..<width),
            center: regionMean(rows: (height / 2 - 60)..<(height / 2 + 60),
                               cols: (width / 2 - 60)..<(width / 2 + 60)),
            samples: samples
        )
    }

    private func savePNG(_ buffer: CVPixelBuffer, to path: String) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = try? ciContext.pngRepresentation(
                of: image, format: .BGRA8, colorSpace: colorSpace) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }
}
