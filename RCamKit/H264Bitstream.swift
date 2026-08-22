import Foundation

/// Pure H.264 bitstream parsing, split out of `RTSPSource` so it can be unit
/// tested without FFmpeg headers or a linked libav. Foundation only — do not
/// add an `import CFFmpeg` here, or the test target stops building.
enum H264Bitstream {
    struct ParameterSets: Equatable {
        let sps: [UInt8]
        let pps: [UInt8]
    }

    /// Extradata is either avcC (starts with 0x01) or annex-B.
    ///
    /// Takes an `UnsafeMutablePointer` because it is fed `codecpar.extradata`
    /// directly.
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
}
