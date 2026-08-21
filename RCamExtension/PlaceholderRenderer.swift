import Foundation
import CoreGraphics
import CoreText
import CoreVideo

struct DigitGlyph {
    let width: Int
    let height: Int
    let pixels: [UInt8] // grayscale, row 0 = top
}

/// Core Graphics rendering for placeholder content. Everything here is rendered
/// once and cached — never per frame.
enum PlaceholderRenderer {
    private static var textFrameCache = [String: CVPixelBuffer]()
    private static var digitCache = [CGFloat: [DigitGlyph]]()
    private static let lock = NSLock()

    /// Full-size NV12 frame: centered white text on a dark background. Cached by content.
    static func textFrame(lines: [String]) -> CVPixelBuffer? {
        let key = lines.joined(separator: "\n")
        lock.lock()
        defer { lock.unlock() }
        if let cached = textFrameCache[key] { return cached }

        let width = Int(kOutputWidth)
        let height = Int(kOutputHeight)
        guard let buffer = makeNV12Buffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        memset(yBase, 28, yStride * height) // dark gray
        memset(cBase, 128, cStride * (height / 2)) // neutral chroma

        if let context = CGContext(
            data: yBase,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: yStride,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
            let lineHeight: CGFloat = 60
            let blockHeight = lineHeight * CGFloat(lines.count)
            for (index, text) in lines.enumerated() {
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.92, alpha: 1.0),
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let baselineY = (CGFloat(height) + blockHeight) / 2
                    - lineHeight * CGFloat(index + 1) + lineHeight * 0.28
                context.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: baselineY)
                CTLineDraw(line, context)
            }
        }

        textFrameCache[key] = buffer
        return buffer
    }

    /// Small luma bitmap of a text badge (white on dark), rendered once and
    /// cached — blitted onto outgoing frames by the emit loop.
    static func badge(text: String, pointSize: CGFloat = 28) -> DigitGlyph? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = badgeCache[text] { return cached }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1.0),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let padding: CGFloat = 14
        let width = Int(ceil(textWidth + padding * 2))
        let height = Int(ceil(pointSize * 1.4 + padding))
        var pixels = [UInt8](repeating: 22, count: width * height) // dark backdrop
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.textPosition = CGPoint(x: padding, y: pointSize * 0.42)
            CTLineDraw(line, context)
        }
        let glyph = DigitGlyph(width: width, height: height, pixels: pixels)
        badgeCache[text] = glyph
        return glyph
    }

    private static var badgeCache = [String: DigitGlyph]()

    /// Grayscale bitmaps for digits 0–9, rendered once per point size.
    static func digitGlyphs(pointSize: CGFloat) -> [DigitGlyph] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = digitCache[pointSize] { return cached }

        let cellWidth = Int(ceil(pointSize * 0.72))
        let cellHeight = Int(ceil(pointSize * 1.05))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, pointSize, nil)

        let glyphs: [DigitGlyph] = (0...9).map { digit in
            var pixels = [UInt8](repeating: 0, count: cellWidth * cellHeight)
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: cellWidth,
                    height: cellHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: cellWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return }
                let attributed = NSAttributedString(string: String(digit), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1.0, alpha: 1.0),
                ])
                let line = CTLineCreateWithAttributedString(attributed)
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                context.textPosition = CGPoint(
                    x: (CGFloat(cellWidth) - lineWidth) / 2,
                    y: pointSize * 0.16
                )
                CTLineDraw(line, context)
            }
            return DigitGlyph(width: cellWidth, height: cellHeight, pixels: pixels)
        }

        digitCache[pointSize] = glyphs
        return glyphs
    }
}

/// IOSurface-backed NV12 buffer (IOSurface backing is required for zero-copy
/// hand-off to CMIO clients).
func makeNV12Buffer(width: Int, height: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        attributes as CFDictionary, &buffer)
    return buffer
}
