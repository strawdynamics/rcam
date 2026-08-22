import Foundation

/// A camera's network address, normalized to the two pieces a URL needs.
///
/// Kept separate from the raw text the user typed: the field is deliberately
/// forgiving (see `CameraPreset.parseAddress`), so "what they typed" and
/// "what we build URLs from" are different things.
struct StreamAddress: Equatable {
    /// Default RTSP port. Every preset URL spells the port out rather than
    /// relying on it, because that is how cameras and NVRs print their own
    /// URLs — matching them makes a filled URL comparable at a glance.
    static let defaultPort = 554

    var host: String
    var port: Int

    /// Bracketed when the host is a bare IPv6 literal, as RFC 3986 requires.
    var hostForURL: String {
        host.contains(":") ? "[\(host)]" : host
    }

    /// Round-trips back into the address field: `host` or `host:port`.
    var text: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }
}

/// One camera platform's RTSP URL shape.
///
/// Presets are keyed by *platform*, not brand: `Streaming/Channels/101` is
/// Hikvision's scheme, and the OEMs that rebrand Hikvision hardware inherit it
/// unchanged. Listing the rebrands under one entry is what makes three tested
/// cameras cover a dozen products.
struct CameraPreset: Identifiable, Hashable {
    /// How much the pattern can be trusted, surfaced in the picker. A preset
    /// that is wrong is worse than no preset — the user cannot tell a bad
    /// pattern from an unreachable camera or a bad password — so an untested
    /// entry says so rather than borrowing the tested ones' credibility.
    enum Provenance: Hashable {
        case tested
        case documented

        var isTested: Bool { self == .tested }

        var note: String {
            switch self {
            case .tested:
                return "Tested with RCam on real hardware."
            case .documented:
                return "From the vendor's documentation — not tested with RCam."
            }
        }
    }

    let id: String
    let name: String
    /// Hardware that rebrands this platform and speaks the same URL scheme.
    let alsoKnownAs: String?
    let mainPath: String
    /// Absent for cameras that expose only one stream.
    let subPath: String?
    let provenance: Provenance

    func mainURL(at address: StreamAddress) -> String {
        Self.url(path: mainPath, at: address)
    }

    /// Empty when the platform has no substream — `Fill` writes that empty
    /// string, because a preset's main URL beside a previous preset's
    /// substream is a camera that does not exist.
    func subURL(at address: StreamAddress) -> String {
        guard let subPath else { return "" }
        return Self.url(path: subPath, at: address)
    }

    private static func url(path: String, at address: StreamAddress) -> String {
        "rtsp://\(address.hostForURL):\(address.port)\(path)"
    }
}

extension CameraPreset {
    /// Ordered tested-first: the entries backed by hardware we have actually
    /// decoded lead, and cover the majority of consumer NVR gear besides.
    static let all: [CameraPreset] = [
        CameraPreset(
            id: "hikvision",
            name: "Hikvision / Annke",
            alsoKnownAs: "also LTS, Swann, older Lorex",
            mainPath: "/Streaming/Channels/101",
            subPath: "/Streaming/Channels/102",
            provenance: .tested
        ),
        CameraPreset(
            id: "dahua",
            name: "Dahua / Amcrest",
            alsoKnownAs: "also newer Lorex",
            mainPath: "/cam/realmonitor?channel=1&subtype=0",
            subPath: "/cam/realmonitor?channel=1&subtype=1",
            provenance: .tested
        ),
        CameraPreset(
            id: "hipcam",
            name: "Hipcam",
            alsoKnownAs: nil,
            mainPath: "/11",
            subPath: "/12",
            provenance: .tested
        ),
        CameraPreset(
            id: "reolink",
            name: "Reolink",
            alsoKnownAs: nil,
            mainPath: "/h264Preview_01_main",
            subPath: "/h264Preview_01_sub",
            provenance: .documented
        ),
        CameraPreset(
            id: "tapo",
            name: "TP-Link Tapo",
            alsoKnownAs: nil,
            mainPath: "/stream1",
            subPath: "/stream2",
            provenance: .documented
        ),
        CameraPreset(
            id: "foscam",
            name: "Foscam",
            alsoKnownAs: nil,
            mainPath: "/videoMain",
            subPath: "/videoSub",
            provenance: .documented
        ),
        CameraPreset(
            id: "axis",
            name: "Axis",
            alsoKnownAs: nil,
            mainPath: "/axis-media/media.amp",
            subPath: nil,
            provenance: .documented
        ),
        CameraPreset(
            id: "wyze",
            name: "Wyze (RTSP firmware)",
            alsoKnownAs: nil,
            mainPath: "/live",
            subPath: nil,
            provenance: .documented
        ),
    ]
}

extension CameraPreset {
    /// Pulls a host and port out of whatever the user has in the address
    /// field, and out of an existing `mainURL` when pre-filling it.
    ///
    /// Pasting a whole RTSP URL is the *common* case, not an edge case: that
    /// is the form a camera's own app hands you. Rejecting it would mean
    /// asking the user to hand-edit a string we can read perfectly well.
    ///
    /// Credentials are dropped rather than carried through. `CameraConfig`
    /// guarantees URLs are stored without them (they belong in the Keychain),
    /// so preserving a pasted `admin:hunter2@` would write a password into the
    /// config file — this strip is a correctness requirement, not a courtesy.
    ///
    /// Returns nil when no host survives.
    static func parseAddress(_ raw: String) -> StreamAddress? {
        var rest = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))

        // Scheme, if any. Matching on "://" rather than a scheme allowlist:
        // whatever they pasted, the authority is what follows.
        if let range = rest.range(of: "://") {
            rest = rest[range.upperBound...]
        }

        // Path / query / fragment: the authority ends at the first of them.
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[..<end]
        }

        // Userinfo. The last "@" wins, since a password may contain one.
        if let at = rest.lastIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
        }

        var host = rest
        var port = StreamAddress.defaultPort

        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            // Bracketed IPv6: the port separator is the colon after "]".
            let literal = host[host.index(after: host.startIndex)..<close]
            let after = host[host.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                let suffix = after.dropFirst()
                if !suffix.isEmpty {
                    guard let parsed = parsePort(suffix) else { return nil }
                    port = parsed
                }
            }
            host = literal
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":") {
            // Exactly one colon separates host from port. Several colons mean
            // an unbracketed IPv6 literal, which carries no port of its own.
            let suffix = host[host.index(after: colon)...]
            if !suffix.isEmpty {
                guard let parsed = parsePort(suffix) else { return nil }
                port = parsed
            }
            host = host[..<colon]
        }

        let trimmed = String(host)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace })
        else { return nil }

        return StreamAddress(host: trimmed, port: port)
    }

    private static func parsePort<S: StringProtocol>(_ text: S) -> Int? {
        guard text.allSatisfy(\.isNumber), let value = Int(text),
              (1...65535).contains(value)
        else { return nil }
        return value
    }
}
