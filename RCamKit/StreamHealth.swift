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
