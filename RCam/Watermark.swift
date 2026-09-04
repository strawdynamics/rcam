import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// The free-tier watermark: one line of text, blended into the centre of every
/// frame the app pushes into the sink while RCam is not unlocked.
///
/// Drawn in the app rather than the extension on purpose. The app owns the
/// StoreKit state, so the unlock never has to cross a process boundary; a
/// change here is a plain `scripts/build.sh` with no extension version bump
/// and no reboot; and the extension's placeholders ("No signal", "Open RCam…")
/// stay clean, which is right -- they are not the product. The extension has
/// its own text renderer in `PlaceholderRenderer`; the two are deliberately not
/// shared, because linking RCamKit into the extension would put its inputs
/// outside the version hash `build.sh` computes.
///
/// Rendering happens once. Core Text draws the line twice into small grayscale
/// coverage maps: a fill pass and a wider stroke pass. Per frame, the stroke
/// coverage pulls the luma under the letters toward black and the fill
/// coverage pulls it toward white, so the text reads over a bright window and a
/// dark room alike. Chroma is never touched: the letters take on the colour of
/// whatever is behind them, which is what keeps the mark from looking like a
/// cut-out over someone's face.
///
/// `apply` modifies the frame in place. That is safe only because of where it
/// is called: `RTSPSource` hands the controller a buffer it has just pulled
/// from its own pool and finished writing, and nothing else holds it until the
/// sink writer wraps it. Never call this on a buffer that came back from the
/// extension or that a client may already be reading.
struct Watermark {
    let width: Int
    let height: Int
    /// 0…255 coverage of the filled glyphs, row 0 = top.
    let fill: [UInt8]
    /// 0…255 coverage of the stroked glyphs -- a superset of `fill`.
    let stroke: [UInt8]

    static let text = "RCam · free version"
    static let fillOpacity = 0.62
    static let strokeOpacity = 0.55
    /// Video-range white and black -- the buffers are `…VideoRange` NV12.
    static let fillLuma: UInt8 = 235
    static let strokeLuma: UInt8 = 16

    static let shared = Watermark(text: text, pointSize: 72)

    init(text: String, pointSize: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil)
        let white = CGColor(gray: 1.0, alpha: 1.0)
        // Negative stroke width = stroke *and* fill, as a percentage of the
        // point size. 5% at 72pt is a 3.6px outline -- enough to separate the
        // letters from a light background without reading as an outline font.
        let strokeAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): white,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -5.0,
        ]
        let fillAttributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
        ]
        let strokeLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: strokeAttributes))
        let fillLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: fillAttributes))

        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(fillLine, &ascent, &descent, nil))
        // Generous canvas -- the stroke spills past the glyph bounds -- then
        // crop to the ink. Centring the typographic box would sit the text
        // visibly high: this line has no descenders, so the box reserves
        // space below the letters that nothing ever paints.
        let padding: CGFloat = 16
        let canvasWidth = Int(ceil(textWidth + padding * 2))
        let canvasHeight = Int(ceil(ascent + descent + padding * 2))
        let origin = CGPoint(x: padding, y: padding + descent)
        let strokeCanvas = Self.render(strokeLine, width: canvasWidth, height: canvasHeight, origin: origin)
        let fillCanvas = Self.render(fillLine, width: canvasWidth, height: canvasHeight, origin: origin)

        // The stroke coverage is a superset of the fill, so its ink bounds
        // (plus a pixel of breathing room) bound both.
        let box = Self.inkBounds(strokeCanvas, width: canvasWidth, height: canvasHeight, margin: 1)
        // Even dimensions keep the mark aligned to the chroma grid should this
        // ever grow a chroma pass; harmless for the luma-only blend.
        let width = (box.width + 1) & ~1
        let height = (box.height + 1) & ~1
        self.width = width
        self.height = height
        self.stroke = Self.crop(strokeCanvas, canvasWidth: canvasWidth, to: box, width: width, height: height)
        self.fill = Self.crop(fillCanvas, canvasWidth: canvasWidth, to: box, width: width, height: height)
    }

    /// Bounding box of the nonzero pixels, widened by `margin` and clamped to
    /// the canvas. An empty canvas yields a 1×1 box rather than a crash.
    private static func inkBounds(_ pixels: [UInt8], width: Int, height: Int, margin: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where pixels[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return (0, 0, 1, 1) }
        let x0 = max(0, minX - margin), y0 = max(0, minY - margin)
        let x1 = min(width - 1, maxX + margin), y1 = min(height - 1, maxY + margin)
        return (x0, y0, x1 - x0 + 1, y1 - y0 + 1)
    }

    /// Copy `box` out of the canvas into a `width`×`height` bitmap (zero-padded
    /// on the right/bottom when the even-rounding made it a pixel larger).
    private static func crop(_ pixels: [UInt8], canvasWidth: Int, to box: (x: Int, y: Int, width: Int, height: Int),
                             width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<box.height {
            let src = (box.y + y) * canvasWidth + box.x
            out.replaceSubrange(y * width ..< y * width + box.width, with: pixels[src ..< src + box.width])
        }
        return out
    }

    /// Draw one line, white on black, into a fresh grayscale bitmap. The pixel
    /// value *is* the coverage. Memory row 0 is the top of the image; Core
    /// Graphics' y axis points up from the last row, so text drawn near y = 0
    /// lands upright at the bottom of the bitmap.
    private static func render(_ line: CTLine, width: Int, height: Int, origin: CGPoint) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
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
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.textPosition = origin
            CTLineDraw(line, context)
        }
        return pixels
    }

    // MARK: - Per-frame blend

    /// Blend the mark into the centre of an NV12 frame's luma plane. Frames
    /// smaller than the mark are left alone rather than clipped.
    func apply(to buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return }
        let frameWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let frameHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard frameWidth >= width, frameHeight >= height else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let originX = (frameWidth - width) / 2
        let originY = (frameHeight - height) / 2

        Self.blend(luma: luma, stride: stride, originX: originX, originY: originY,
                   coverage: stroke, width: width, height: height,
                   toward: Self.strokeLuma, opacity: Self.strokeOpacity)
        Self.blend(luma: luma, stride: stride, originX: originX, originY: originY,
                   coverage: fill, width: width, height: height,
                   toward: Self.fillLuma, opacity: Self.fillOpacity)
    }

    /// `luma[p] += (target - luma[p]) * coverage[p] * opacity` for every pixel
    /// of the mark, placed at (`originX`, `originY`) in a plane `stride` bytes
    /// wide. The caller guarantees the mark fits. Pure, so it is unit-tested
    /// without a pixel buffer.
    static func blend(luma: UnsafeMutablePointer<UInt8>, stride: Int, originX: Int, originY: Int,
                      coverage: [UInt8], width: Int, height: Int,
                      toward target: UInt8, opacity: Double) {
        // Fold opacity into a 256-entry alpha table once per call rather than
        // multiplying a Double per pixel.
        let alpha = (0...255).map { Int32((Double($0) * opacity).rounded()) }
        let target = Int32(target)
        coverage.withUnsafeBufferPointer { cov in
            for row in 0..<height {
                let dst = luma + (originY + row) * stride + originX
                let src = cov.baseAddress! + row * width
                for x in 0..<width {
                    let a = alpha[Int(src[x])]
                    if a == 0 { continue }
                    let d = Int32(dst[x])
                    dst[x] = UInt8(d + ((target - d) * a) / 255)
                }
            }
        }
    }
}
