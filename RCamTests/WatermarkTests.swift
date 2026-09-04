import CoreVideo
import XCTest

final class WatermarkTests: XCTestCase {
    // MARK: blend()

    private func blend(_ pixel: UInt8, coverage: UInt8, toward target: UInt8, opacity: Double) -> UInt8 {
        var plane = [pixel]
        plane.withUnsafeMutableBufferPointer { buf in
            Watermark.blend(luma: buf.baseAddress!, stride: 1, originX: 0, originY: 0,
                            coverage: [coverage], width: 1, height: 1,
                            toward: target, opacity: opacity)
        }
        return plane[0]
    }

    func testFullCoverageAtFullOpacityReachesTarget() {
        XCTAssertEqual(blend(100, coverage: 255, toward: 235, opacity: 1.0), 235)
        XCTAssertEqual(blend(200, coverage: 255, toward: 16, opacity: 1.0), 16)
    }

    func testZeroCoverageLeavesPixelUntouched() {
        XCTAssertEqual(blend(77, coverage: 0, toward: 235, opacity: 1.0), 77)
    }

    func testOpacityScalesTheMove() {
        // 100 → 235 is +135; at half opacity and full coverage, about +67.
        let out = Int(blend(100, coverage: 255, toward: 235, opacity: 0.5))
        XCTAssertEqual(out, 167, accuracy: 1)
    }

    func testBlendHonoursStrideAndOrigin() {
        // 4×3 plane with a 5-byte stride; mark is 2×2 at (1,1).
        var plane = [UInt8](repeating: 50, count: 5 * 3)
        plane.withUnsafeMutableBufferPointer { buf in
            Watermark.blend(luma: buf.baseAddress!, stride: 5, originX: 1, originY: 1,
                            coverage: [255, 255, 255, 255], width: 2, height: 2,
                            toward: 250, opacity: 1.0)
        }
        let expected: [UInt8] = [
            50, 50, 50, 50, 50,
            50, 250, 250, 50, 50,
            50, 250, 250, 50, 50,
        ]
        XCTAssertEqual(plane, expected)
    }

    // MARK: apply(to:)

    private func makeNV12(width: Int, height: Int, luma: UInt8 = 100) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 0), Int32(luma),
               CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * height)
        memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1), 128,
               CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * (height / 2))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// (rows, cols) bounding box of luma pixels that differ from `original`.
    private func changedBounds(_ pb: CVPixelBuffer, original: UInt8) -> (rows: ClosedRange<Int>, cols: ClosedRange<Int>)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        var minR = Int.max, maxR = -1, minC = Int.max, maxC = -1
        for r in 0..<h {
            for c in 0..<w where base[r * stride + c] != original {
                minR = min(minR, r); maxR = max(maxR, r)
                minC = min(minC, c); maxC = max(maxC, c)
            }
        }
        return maxR < 0 ? nil : (minR...maxR, minC...maxC)
    }

    func testMarkIsCentredAndLeavesTheRestAlone() {
        let mark = Watermark.shared
        let pb = makeNV12(width: 1920, height: 1080)
        mark.apply(to: pb)

        guard let box = changedBounds(pb, original: 100) else {
            return XCTFail("watermark changed no pixels")
        }
        // Everything touched lies inside the mark's rectangle…
        let x0 = (1920 - mark.width) / 2, y0 = (1080 - mark.height) / 2
        XCTAssertGreaterThanOrEqual(box.rows.lowerBound, y0)
        XCTAssertLessThan(box.rows.upperBound, y0 + mark.height)
        XCTAssertGreaterThanOrEqual(box.cols.lowerBound, x0)
        XCTAssertLessThan(box.cols.upperBound, x0 + mark.width)
        // …and is roughly centred: the bounding box's centre within 4px of frame centre.
        let cx = (box.cols.lowerBound + box.cols.upperBound) / 2
        let cy = (box.rows.lowerBound + box.rows.upperBound) / 2
        XCTAssertEqual(cx, 960, accuracy: 4)
        XCTAssertEqual(cy, 540, accuracy: 4)
    }

    func testChromaIsNeverTouched() {
        let pb = makeNV12(width: 1920, height: 1080)
        Watermark.shared.apply(to: pb)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for r in 0..<540 {
            for c in 0..<1920 where base[r * stride + c] != 128 {
                return XCTFail("chroma modified at row \(r) byte \(c)")
            }
        }
    }

    func testTextReadsOverBothDarkAndBrightFrames() {
        // Some pixel must move toward white on a dark frame and some toward
        // black on a bright one -- the stroke/fill pair, not a single tint.
        let dark = makeNV12(width: 1920, height: 1080, luma: 20)
        Watermark.shared.apply(to: dark)
        XCTAssertNotNil(changedBounds(dark, original: 20))
        let bright = makeNV12(width: 1920, height: 1080, luma: 230)
        Watermark.shared.apply(to: bright)
        XCTAssertNotNil(changedBounds(bright, original: 230))
    }

    func testFramesSmallerThanTheMarkAreLeftAlone() {
        let pb = makeNV12(width: 64, height: 64)
        Watermark.shared.apply(to: pb)
        XCTAssertNil(changedBounds(pb, original: 100))
    }
}
