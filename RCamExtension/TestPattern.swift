import Foundation
import CoreVideo

/// Animated 720p NV12 test pattern: horizontally scrolling color bars with a
/// frame counter. Serves as the M1 "no sink" placeholder source.
final class TestPatternGenerator {
    private let width = Int(kOutputWidth)
    private let height = Int(kOutputHeight)
    private let barWidth = 160
    private let shiftPerFrame = 4 // must stay even so chroma pairs stay aligned

    // BT.601-ish YCbCr for SMPTE-style bars.
    private static let bars: [(y: UInt8, cb: UInt8, cr: UInt8)] = [
        (180, 128, 128), // white
        (162, 44, 142),  // yellow
        (131, 156, 44),  // cyan
        (112, 72, 58),   // green
        (84, 184, 198),  // magenta
        (65, 100, 212),  // red
        (35, 212, 114),  // blue
        (16, 128, 128),  // black
    ]

    private var period: Int { barWidth * Self.bars.count }

    private var pool: CVPixelBufferPool?
    private var frameCount: UInt64 = 0
    private var yTemplate: [UInt8]
    private var cTemplate: [UInt8]
    private let digits: [DigitGlyph]

    init() {
        let templateWidth = width + barWidth * Self.bars.count
        yTemplate = [UInt8](repeating: 0, count: templateWidth)
        cTemplate = [UInt8](repeating: 0, count: templateWidth)
        for x in 0..<templateWidth {
            yTemplate[x] = Self.bars[(x / barWidth) % Self.bars.count].y
        }
        for pair in 0..<(templateWidth / 2) {
            let bar = Self.bars[(pair * 2 / barWidth) % Self.bars.count]
            cTemplate[pair * 2] = bar.cb
            cTemplate[pair * 2 + 1] = bar.cr
        }
        digits = PlaceholderRenderer.digitGlyphs(pointSize: 64)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }

    func nextFrame() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let offset = Int((frameCount &* UInt64(shiftPerFrame)) % UInt64(period))
        yTemplate.withUnsafeBytes { src in
            let srcBase = src.baseAddress!.advanced(by: offset)
            for row in 0..<height {
                memcpy(yBase.advanced(by: row * yStride), srcBase, width)
            }
        }
        // Chroma rows: one interleaved CbCr byte pair per 2 pixels → `width` bytes per row.
        cTemplate.withUnsafeBytes { src in
            let srcBase = src.baseAddress!.advanced(by: offset)
            for row in 0..<(height / 2) {
                memcpy(cBase.advanced(by: row * cStride), srcBase, width)
            }
        }

        drawCounter(yBase: yBase, yStride: yStride, cBase: cBase, cStride: cStride)

        frameCount &+= 1
        return buffer
    }

    private func drawCounter(yBase: UnsafeMutableRawPointer, yStride: Int,
                             cBase: UnsafeMutableRawPointer, cStride: Int) {
        let text = String(frameCount)
        guard let glyphHeight = digits.first?.height, let glyphWidth = digits.first?.width else { return }
        let padding = 16
        let originX = 24
        let originY = 24
        let boxWidth = glyphWidth * text.count + padding * 2
        let boxHeight = glyphHeight + padding * 2

        // Dark backdrop with neutral chroma so the counter stays legible over the bars.
        for row in originY..<(originY + boxHeight) {
            memset(yBase.advanced(by: row * yStride + originX), 16, boxWidth)
        }
        let chromaX = originX & ~1
        for row in (originY / 2)..<((originY + boxHeight) / 2) {
            memset(cBase.advanced(by: row * cStride + chromaX), 128, boxWidth & ~1)
        }

        var penX = originX + padding
        let penY = originY + padding
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        for character in text {
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { continue }
            let glyph = digits[value]
            glyph.pixels.withUnsafeBufferPointer { src in
                for row in 0..<glyph.height {
                    let dstRow = yPlane.advanced(by: (penY + row) * yStride + penX)
                    let srcRow = src.baseAddress!.advanced(by: row * glyph.width)
                    for col in 0..<glyph.width {
                        let v = srcRow[col]
                        if v > 16 { dstRow[col] = v }
                    }
                }
            }
            penX += glyph.width
        }
    }
}
