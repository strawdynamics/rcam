import Foundation

/// Pure stream-health helpers, kept Foundation-only so the test target can
/// compile them without FFmpeg headers or a linked libav.
enum StreamHealth {
    /// Counts consecutive decode failures and fires once when the run reaches
    /// the threshold, so a stream that keeps demuxing but never decodes is
    /// reported as `.failed` instead of stalling silently.
    struct DecodeFailureCounter {
        let threshold: Int
        private var consecutiveFailures = 0
        private var hasFired = false

        init(threshold: Int) {
            self.threshold = max(1, threshold)
        }

        /// Returns `true` exactly once per run of failures — on the record that
        /// brings the run to `threshold`. A success resets both the run and the
        /// fired latch, so a later run can fire again.
        mutating func record(success: Bool) -> Bool {
            if success {
                consecutiveFailures = 0
                hasFired = false
                return false
            }
            consecutiveFailures += 1
            guard !hasFired, consecutiveFailures >= threshold else { return false }
            hasFired = true
            return true
        }
    }

    /// A thread-name / log-safe label for a stream URL: `host:port/path`, with
    /// the userinfo and query stripped. Thread names surface in crash reports,
    /// `sample` output, and Instruments, so a camera password must never be
    /// able to survive this function — including via the unparseable fallback.
    static func streamLabel(forURL urlString: String) -> String {
        // An empty host is possible (`rtsp://`), so check for it explicitly —
        // `components.host` is non-nil there.
        if let components = URLComponents(string: urlString), let host = components.host, !host.isEmpty {
            var label = host
            if let port = components.port { label += ":\(port)" }
            let path = components.path
            if !path.isEmpty, path != "/" { label += path }
            return label
        }
        return redactedFallback(urlString)
    }

    // MARK: - Local Network privacy

    /// `AVERROR(EHOSTUNREACH)`. macOS gates outbound LAN connections behind
    /// Local Network privacy, and a denial is not surfaced as a permission
    /// error: the connect is blackholed and FFmpeg reports "No route to host",
    /// which reads like a routing fault. This is the signature of that denial.
    private static let hostUnreachable: Int32 = -65

    /// A hint to show alongside a stream failure when it looks like Local
    /// Network privacy rather than a network problem, or nil when it does not.
    ///
    /// Deliberately narrow: only `EHOSTUNREACH`, and only for a host the user
    /// typed as a local address. A genuinely unreachable host on your own
    /// subnet is rare; sending someone into Privacy settings over a real
    /// routing fault is worse than saying nothing.
    static func localNetworkHint(forURL urlString: String, message: String) -> String? {
        guard errorCode(inMessage: message) == hostUnreachable,
              let host = host(forURL: urlString),
              isLocalNetworkHost(host) else { return nil }
        return "RCam may be blocked from reaching your local network. "
             + "Check System Settings › Privacy & Security › Local Network."
    }

    /// Reads the trailing `(-65)` that `RTSPSource.errorString` appends. Only
    /// the last one counts: the prose ahead of it can contain parentheses.
    static func errorCode(inMessage message: String) -> Int32? {
        guard let close = message.lastIndex(of: ")"),
              let open = message[..<close].lastIndex(of: "(") else { return nil }
        return Int32(message[message.index(after: open)..<close])
    }

    /// Whether an address, as written in the URL, names something on the user's
    /// own network. Loopback is excluded on purpose — Local Network privacy
    /// does not gate it, and the local test rig runs on 127.0.0.1.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        // A zone id (`fe80::1%en0`) and the brackets from an IPv6 URL authority
        // both survive into `URLComponents.host` depending on the input.
        var host = host.lowercased()
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }

        if let octets = ipv4Octets(host) {
            switch (octets[0], octets[1]) {
            case (10, _): return true                      // 10/8
            case (172, 16...31): return true               // 172.16/12
            case (192, 168): return true                   // 192.168/16
            case (169, 254): return true                   // 169.254/16 link-local
            default: return false                          // includes 127/8
            }
        }

        if host.contains(":") { return isLocalIPv6(host) }

        // Bonjour. Local Network privacy gates mDNS too, so a camera addressed
        // by `.local` name hits exactly the same wall.
        return host.hasSuffix(".local")
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 ? octets : nil
    }

    /// `fc00::/7` (unique local) and `fe80::/10` (link-local). `::1` is
    /// loopback and falls through to false, as it must.
    private static func isLocalIPv6(_ host: String) -> Bool {
        let first = host.split(separator: ":", omittingEmptySubsequences: false)[0]
        guard let hextet = UInt16(first, radix: 16) else { return false }
        return (0xfc00...0xfdff).contains(hextet) || (0xfe80...0xfebf).contains(hextet)
    }

    /// The host alone, by the same two-path parse `streamLabel` uses.
    private static func host(forURL urlString: String) -> String? {
        if let components = URLComponents(string: urlString),
           let host = components.host, !host.isEmpty {
            return host
        }
        // Fall back to the label, which is already host-first and credential-free,
        // and drop the port and path it appends.
        let label = redactedFallback(urlString)
        guard label != "stream" else { return nil }
        var host = Substring(label)
        if let slash = host.firstIndex(of: "/") { host = host[..<slash] }
        // rfind, so an IPv6 literal's own colons are not mistaken for the port.
        if let colon = host.lastIndex(of: ":"), !host[host.index(after: colon)...].contains(":") {
            let port = host[host.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) { host = host[..<colon] }
        }
        return host.isEmpty ? nil : String(host)
    }

    /// URLComponents rejects some URLs real cameras produce (an unescaped `@`
    /// or `:` inside a password, for one). Rather than fall back to the raw
    /// string, rebuild the label by hand with the same guarantees.
    private static func redactedFallback(_ urlString: String) -> String {
        var rest = Substring(urlString)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }

        let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        var remainder = rest[authorityEnd...]

        // lastIndex, not firstIndex: a password may itself contain an `@`.
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if let query = remainder.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            remainder = remainder[..<query]
        }

        let label = authority + remainder
        return label.isEmpty ? "stream" : String(label)
    }
}
