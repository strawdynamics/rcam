import Testing
import Foundation

// MARK: - Fixtures and helpers

/// Realistic-looking NAL payloads (start codes are added by the builders).
private let spsNAL: [UInt8] = [0x67, 0x42, 0x00, 0x1E]
private let ppsNAL: [UInt8] = [0x68, 0xCE, 0x38, 0x80]
private let sliceNAL: [UInt8] = [0x65, 0xB8, 0x00, 0x04, 0x11]  // type 5, IDR slice
private let audNAL: [UInt8] = [0x09, 0x10]                      // type 9
private let fillerNAL: [UInt8] = [0x0C, 0xFF, 0xFF]             // type 12

private let startCode3: [UInt8] = [0x00, 0x00, 0x01]
private let startCode4: [UInt8] = [0x00, 0x00, 0x00, 0x01]

/// Runs `body` with a pointer to `bytes`, valid even when `bytes` is empty.
private func withBytes<R>(_ bytes: [UInt8], _ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    defer { buffer.deallocate() }
    _ = buffer.initialize(fromContentsOf: bytes)
    return body(UnsafePointer(buffer.baseAddress!), bytes.count)
}

private func withMutableBytes<R>(_ bytes: [UInt8], _ body: (UnsafeMutablePointer<UInt8>?, Int) -> R) -> R {
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
    defer { buffer.deallocate() }
    _ = buffer.initialize(fromContentsOf: bytes)
    return body(buffer.baseAddress, bytes.count)
}

/// Builds an avcC record. `spsCount`/`ppsCount` default to the real counts but
/// can be overstated to exercise the truncation guards.
private func avcC(
    spsUnits: [[UInt8]] = [spsNAL],
    ppsUnits: [[UInt8]] = [ppsNAL],
    declaredSPSCount: Int? = nil,
    declaredPPSCount: Int? = nil,
    includePPSSection: Bool = true
) -> [UInt8] {
    var out: [UInt8] = [0x01, 0x42, 0x00, 0x1E, 0xFF]
    out.append(0xE0 | UInt8(declaredSPSCount ?? spsUnits.count))
    for unit in spsUnits {
        out.append(UInt8(unit.count >> 8))
        out.append(UInt8(unit.count & 0xFF))
        out.append(contentsOf: unit)
    }
    guard includePPSSection else { return out }
    out.append(UInt8(declaredPPSCount ?? ppsUnits.count))
    for unit in ppsUnits {
        out.append(UInt8(unit.count >> 8))
        out.append(UInt8(unit.count & 0xFF))
        out.append(contentsOf: unit)
    }
    return out
}

private func bigEndianLength(_ bytes: ArraySlice<UInt8>) -> Int {
    bytes.reduce(0) { $0 << 8 | Int($1) }
}

// MARK: - parseAVCC

@Suite("parseAVCC")
struct ParseAVCCTests {
    @Test("well-formed avcC yields both parameter sets")
    func wellFormed() {
        let data = avcC()
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL))
    }

    @Test("multiple SPS/PPS entries keep the first of each")
    func multipleEntries() {
        let secondSPS: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0x99]
        let secondPPS: [UInt8] = [0x68, 0xEE, 0x3C, 0xB0, 0x00]
        let data = avcC(spsUnits: [spsNAL, secondSPS], ppsUnits: [ppsNAL, secondPPS])
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets?.sps == spsNAL)
        #expect(sets?.pps == ppsNAL)
    }

    @Test("rejects a record of 7 bytes or fewer", arguments: [0, 1, 5, 6, 7])
    func tooShort(size: Int) {
        let data = Array(avcC().prefix(size))
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a truncated SPS length field")
    func truncatedSPSLengthField() {
        // Two declared SPS entries, but the buffer ends one byte into the
        // second entry's 2-byte length — the `offset + 2 <= size` guard.
        var data = avcC(spsUnits: [spsNAL], declaredSPSCount: 2, includePPSSection: false)
        data.append(0x00)
        #expect(data.count > 7)
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects an SPS whose declared length runs past the buffer")
    func truncatedSPSPayload() {
        var data: [UInt8] = [0x01, 0x42, 0x00, 0x1E, 0xFF, 0xE1]
        data.append(contentsOf: [0x00, 0x20])   // claims 32 bytes
        data.append(contentsOf: spsNAL)          // supplies 4
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a record that ends before the PPS count")
    func missingPPSCount() {
        let data = avcC(includePPSSection: false)
        #expect(data.count > 7)
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a truncated PPS length field")
    func truncatedPPSLengthField() {
        var data = avcC(declaredPPSCount: 2)
        data.append(0x00)  // one byte of the second PPS's length
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a PPS whose declared length runs past the buffer")
    func truncatedPPSPayload() {
        var data = avcC(includePPSSection: false)
        data.append(0x01)
        data.append(contentsOf: [0x00, 0x20])   // claims 32 bytes
        data.append(contentsOf: ppsNAL)          // supplies 4
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a record with zero SPS entries")
    func zeroSPSCount() {
        let data = avcC(spsUnits: [], ppsUnits: [ppsNAL])
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("rejects a record with zero PPS entries")
    func zeroPPSCount() {
        let data = avcC(spsUnits: [spsNAL], ppsUnits: [])
        let sets = withBytes(data) { H264Bitstream.parseAVCC(data: $0, size: $1) }
        #expect(sets == nil)
    }
}

// MARK: - parseParameterSets dispatch

@Suite("parseParameterSets")
struct ParseParameterSetsTests {
    @Test("nil extradata yields nil")
    func nilInput() {
        #expect(H264Bitstream.parseParameterSets(data: nil, size: 32) == nil)
    }

    @Test("zero size yields nil")
    func zeroSize() {
        let sets = withMutableBytes(avcC()) { data, _ in
            H264Bitstream.parseParameterSets(data: data, size: 0)
        }
        #expect(sets == nil)
    }

    @Test("a leading 0x01 routes to the avcC parser")
    func routesToAVCC() {
        let sets = withMutableBytes(avcC()) { H264Bitstream.parseParameterSets(data: $0, size: $1) }
        #expect(sets == H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL))
    }

    @Test("anything else routes to the annex-B parser")
    func routesToAnnexB() {
        let data = startCode4 + spsNAL + startCode3 + ppsNAL + startCode4 + sliceNAL
        #expect(data[0] != 0x01)
        let sets = withMutableBytes(data) { H264Bitstream.parseParameterSets(data: $0, size: $1) }
        #expect(sets == H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL))
    }
}

// MARK: - annex-B

@Suite("annexBNALUnits / parseAnnexBParameterSets")
struct AnnexBTests {
    @Test("splits 3-byte and 4-byte start codes intermixed")
    func mixedStartCodes() {
        let data = startCode4 + spsNAL + startCode3 + ppsNAL + startCode4 + audNAL + startCode3 + sliceNAL
        let units = withBytes(data) { H264Bitstream.annexBNALUnits(data: $0, size: $1) }
        #expect(units == [spsNAL, ppsNAL, audNAL, sliceNAL])
    }

    @Test("keeps a trailing NAL that has no following start code")
    func trailingNAL() {
        let data = startCode4 + spsNAL + startCode4 + sliceNAL
        let units = withBytes(data) { H264Bitstream.annexBNALUnits(data: $0, size: $1) }
        #expect(units.count == 2)
        #expect(units.last == sliceNAL)
    }

    @Test("an empty buffer produces no units")
    func emptyBuffer() {
        let units = withBytes([]) { H264Bitstream.annexBNALUnits(data: $0, size: $1) }
        #expect(units.isEmpty)
    }

    @Test("a buffer with no start code at all produces no units")
    func noStartCode() {
        let units = withBytes([0xAA, 0xBB, 0xCC, 0xDD]) { H264Bitstream.annexBNALUnits(data: $0, size: $1) }
        #expect(units.isEmpty)
    }

    @Test("annex-B with SPS and PPS yields both")
    func bothPresent() {
        let data = startCode4 + spsNAL + startCode4 + ppsNAL + startCode4 + sliceNAL
        let sets = withBytes(data) { H264Bitstream.parseAnnexBParameterSets(data: $0, size: $1) }
        #expect(sets == H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL))
    }

    @Test("annex-B missing the SPS yields nil")
    func missingSPS() {
        let data = startCode4 + ppsNAL + startCode4 + sliceNAL
        let sets = withBytes(data) { H264Bitstream.parseAnnexBParameterSets(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("annex-B missing the PPS yields nil")
    func missingPPS() {
        let data = startCode4 + spsNAL + startCode4 + sliceNAL
        let sets = withBytes(data) { H264Bitstream.parseAnnexBParameterSets(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("annex-B with neither yields nil")
    func missingBoth() {
        let data = startCode4 + sliceNAL + startCode4 + audNAL
        let sets = withBytes(data) { H264Bitstream.parseAnnexBParameterSets(data: $0, size: $1) }
        #expect(sets == nil)
    }

    @Test("the first SPS and PPS win when a unit repeats")
    func firstOfEachWins() {
        let laterSPS: [UInt8] = [0x67, 0x4D, 0x00, 0x28, 0x77]
        let data = startCode4 + spsNAL + startCode4 + ppsNAL + startCode4 + laterSPS
        let sets = withBytes(data) { H264Bitstream.parseAnnexBParameterSets(data: $0, size: $1) }
        #expect(sets?.sps == spsNAL)
    }
}

// MARK: - annexBToLengthPrefixed

@Suite("annexBToLengthPrefixed")
struct LengthPrefixTests {
    @Test("drops NAL types 7, 8, 9 and 12 while keeping slices")
    func dropsParameterAndFillerUnits() {
        let data = startCode4 + audNAL       // 9
            + startCode4 + spsNAL            // 7
            + startCode3 + ppsNAL            // 8
            + startCode4 + fillerNAL         // 12
            + startCode4 + sliceNAL          // 5 — the only survivor
        let out = withBytes(data) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) }
        let expected = [0x00, 0x00, 0x00, UInt8(sliceNAL.count)] + sliceNAL
        #expect(out == expected)
    }

    @Test("emits a big-endian 4-byte length before each kept unit")
    func bigEndianLengths() throws {
        let secondSlice: [UInt8] = [0x41, 0x9A, 0x00, 0x11, 0x22, 0x33, 0x44]  // type 1
        let data = startCode4 + spsNAL + startCode4 + sliceNAL + startCode4 + secondSlice
        let out = try #require(withBytes(data) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) })

        #expect(out.count == 4 + sliceNAL.count + 4 + secondSlice.count)
        #expect(bigEndianLength(out[0..<4]) == sliceNAL.count)
        #expect(Array(out[4..<(4 + sliceNAL.count)]) == sliceNAL)

        let secondStart = 4 + sliceNAL.count
        #expect(bigEndianLength(out[secondStart..<(secondStart + 4)]) == secondSlice.count)
        #expect(Array(out[(secondStart + 4)...]) == secondSlice)
    }

    @Test("a length prefix is big-endian for a unit longer than 255 bytes")
    func multiByteLength() throws {
        let bigSlice: [UInt8] = [0x65] + Array(repeating: 0x42, count: 299)
        let data = startCode4 + bigSlice
        let out = try #require(withBytes(data) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) })
        #expect(Array(out[0..<4]) == [0x00, 0x00, 0x01, 0x2C])  // 300, big-endian
        #expect(bigEndianLength(out[0..<4]) == bigSlice.count)
    }

    @Test("a buffer with no NAL units yields nil")
    func noUnits() {
        let out = withBytes([0xAA, 0xBB, 0xCC]) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) }
        #expect(out == nil)
    }

    @Test("an empty buffer yields nil")
    func emptyBuffer() {
        let out = withBytes([]) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) }
        #expect(out == nil)
    }

    @Test("a packet of only parameter sets yields an empty (not nil) result")
    func onlyParameterSets() {
        // The caller treats empty as undecodable; this pins the distinction.
        let data = startCode4 + spsNAL + startCode4 + ppsNAL
        let out = withBytes(data) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) }
        #expect(out == [])
    }
}

// MARK: - convert (the single-walk primitive)

@Suite("convert")
struct ConvertTests {
    @Test("picks out in-band SPS and PPS in the same walk that builds the payload")
    func extractsParameterSetsAndPayload() throws {
        let data = startCode4 + spsNAL + startCode4 + ppsNAL + startCode4 + sliceNAL
        let converted = try #require(withBytes(data) { H264Bitstream.convert(data: $0, size: $1) })
        #expect(converted.sps == spsNAL)
        #expect(converted.pps == ppsNAL)
        #expect(converted.lengthPrefixed == [0x00, 0x00, 0x00, UInt8(sliceNAL.count)] + sliceNAL)
    }

    @Test("reports SPS and PPS independently when a packet carries only one")
    func splitAcrossPackets() throws {
        let spsOnly = try #require(withBytes(startCode4 + spsNAL) { H264Bitstream.convert(data: $0, size: $1) })
        #expect(spsOnly.sps == spsNAL)
        #expect(spsOnly.pps == nil)
        #expect(spsOnly.lengthPrefixed.isEmpty)

        let ppsOnly = try #require(withBytes(startCode4 + ppsNAL) { H264Bitstream.convert(data: $0, size: $1) })
        #expect(ppsOnly.sps == nil)
        #expect(ppsOnly.pps == ppsNAL)
        #expect(ppsOnly.lengthPrefixed.isEmpty)
    }

    @Test("a slice-only packet reports no parameter sets")
    func sliceOnly() throws {
        let converted = try #require(withBytes(startCode4 + sliceNAL) { H264Bitstream.convert(data: $0, size: $1) })
        #expect(converted.sps == nil)
        #expect(converted.pps == nil)
        #expect(!converted.lengthPrefixed.isEmpty)
    }

    @Test("a buffer with no NAL units yields nil")
    func noUnits() {
        #expect(withBytes([0xAA, 0xBB, 0xCC]) { H264Bitstream.convert(data: $0, size: $1) } == nil)
    }

    @Test("agrees with annexBToLengthPrefixed, which delegates to it")
    func agreesWithLegacyEntryPoint() {
        let data = startCode4 + audNAL + startCode4 + spsNAL + startCode3 + ppsNAL
            + startCode4 + fillerNAL + startCode4 + sliceNAL
        let viaConvert = withBytes(data) { H264Bitstream.convert(data: $0, size: $1)?.lengthPrefixed }
        let direct = withBytes(data) { H264Bitstream.annexBToLengthPrefixed(data: $0, size: $1) }
        #expect(viaConvert == direct)
    }

    @Test("a changed SPS makes the ParameterSets pair compare unequal")
    func parameterSetsEquality() {
        // This is what the mid-stream rebuild check in runLoop() depends on.
        let original = H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL)
        let resized = H264Bitstream.ParameterSets(sps: [0x67, 0x42, 0x00, 0x1F], pps: ppsNAL)
        #expect(original != resized)
        #expect(original == H264Bitstream.ParameterSets(sps: spsNAL, pps: ppsNAL))
        #expect(original != H264Bitstream.ParameterSets(sps: spsNAL, pps: [0x68, 0xCE, 0x38, 0x81]))
    }
}
