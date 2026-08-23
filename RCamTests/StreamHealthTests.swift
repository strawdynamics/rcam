import Testing
import Foundation

@Suite("DecodeFailureCounter")
struct DecodeFailureCounterTests {
    @Test("fires exactly once, on the record that reaches the threshold")
    func firesOnceAtThreshold() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 3)
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: true) == false)   // resets the run
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == true)   // third in a row
        // Latched: further failures in the same run must not re-fire.
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == false)
    }

    @Test("a success resets the latch so a later run can fire again")
    func refiresAfterSuccess() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 2)
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == true)
        #expect(counter.record(success: false) == false)  // latched
        #expect(counter.record(success: true) == false)   // clears the latch
        #expect(counter.record(success: false) == false)
        #expect(counter.record(success: false) == true)
    }

    @Test("a run of successes never fires")
    func successesNeverFire() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 2)
        for _ in 0..<100 {
            #expect(counter.record(success: true) == false)
        }
    }

    @Test("alternating success and failure never reaches the threshold")
    func alternatingNeverFires() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 2)
        for index in 0..<100 {
            #expect(counter.record(success: index.isMultiple(of: 2)) == false)
        }
    }

    @Test("the production threshold fires on exactly the 30th consecutive failure")
    func productionThreshold() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 30)
        var firedAt: Int?
        for index in 1...60 where counter.record(success: false) {
            if firedAt == nil { firedAt = index }
        }
        #expect(firedAt == 30)
    }

    @Test("a threshold below 1 is clamped so it cannot fire on construction")
    func clampsDegenerateThreshold() {
        var counter = StreamHealth.DecodeFailureCounter(threshold: 0)
        #expect(counter.threshold == 1)
        #expect(counter.record(success: true) == false)
        #expect(counter.record(success: false) == true)
    }
}

@Suite("streamLabel(forURL:)")
struct StreamLabelTests {
    /// The whole point of the function: no credential may survive it.
    private func assertNoCredentials(_ label: String, secrets: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in secrets {
            #expect(!label.contains(secret), "label \"\(label)\" leaked \"\(secret)\"", sourceLocation: sourceLocation)
        }
        #expect(!label.contains("@"), "label \"\(label)\" still has userinfo", sourceLocation: sourceLocation)
    }

    @Test("strips user:password from a realistic camera URL")
    func stripsUserinfo() {
        let label = StreamHealth.streamLabel(
            forURL: "rtsp://admin:hunter2@192.168.1.50:554/cam/realmonitor?channel=1&subtype=1")
        #expect(label == "192.168.1.50:554/cam/realmonitor")
        assertNoCredentials(label, secrets: ["admin", "hunter2", "channel=1"])
    }

    @Test("keeps host, port and path for a URL with no credentials")
    func noCredentials() {
        #expect(StreamHealth.streamLabel(forURL: "rtsp://127.0.0.1:8554/test") == "127.0.0.1:8554/test")
    }

    @Test("omits an absent port and an empty path")
    func minimalURL() {
        #expect(StreamHealth.streamLabel(forURL: "rtsp://camera.local") == "camera.local")
        #expect(StreamHealth.streamLabel(forURL: "rtsp://camera.local/") == "camera.local")
    }

    @Test("strips a username with no password")
    func usernameOnly() {
        let label = StreamHealth.streamLabel(forURL: "rtsp://admin@10.0.0.7:554/stream1")
        #expect(label == "10.0.0.7:554/stream1")
        assertNoCredentials(label, secrets: ["admin"])
    }

    @Test("strips credentials even when the password contains an @ or a colon")
    func unescapedPassword() {
        // URLComponents rejects these; the hand-rolled fallback must still redact.
        for url in ["rtsp://admin:p@ssw0rd@192.168.1.50:554/stream",
                    "rtsp://admin:a:b@c@cam.local/live?token=secret"] {
            let label = StreamHealth.streamLabel(forURL: url)
            assertNoCredentials(label, secrets: ["admin", "p@ssw0rd", "ssw0rd", "a:b", "token", "secret"])
        }
    }

    @Test("a password appears nowhere in the label for any of these shapes",
          arguments: ["rtsp://u:sup3rsecret@host/path",
                      "rtsp://u:sup3rsecret@host:554/path?q=1",
                      "rtsps://u:sup3rsecret@host:322/a/b/c",
                      "u:sup3rsecret@host/path",
                      "rtsp://u:sup3rsecret@host"])
    func passwordNeverSurvives(url: String) {
        assertNoCredentials(StreamHealth.streamLabel(forURL: url), secrets: ["sup3rsecret"])
    }

    @Test("an unparseable string still produces a non-empty label")
    func degenerateInput() {
        #expect(!StreamHealth.streamLabel(forURL: "").isEmpty)
        #expect(!StreamHealth.streamLabel(forURL: "rtsp://").isEmpty)
        #expect(!StreamHealth.streamLabel(forURL: "not a url").isEmpty)
    }
}

@Suite("localNetworkHint")
struct LocalNetworkHintTests {
    /// The message shape RTSPSource.errorString produces for EHOSTUNREACH.
    static let unreachable = "open failed: No route to host (-65)"

    @Test("fires for a camera on a private subnet")
    func firesOnPrivateHost() {
        for host in ["192.168.1.12", "10.0.0.5", "172.16.3.1", "172.31.255.254",
                     "169.254.1.1", "camera.local", "[fe80::1]", "[fd00::abcd]"] {
            let hint = StreamHealth.localNetworkHint(forURL: "rtsp://\(host):554/stream",
                                                     message: Self.unreachable)
            #expect(hint != nil, "expected a hint for \(host)")
        }
    }

    /// The local test rig runs on 127.0.0.1 and Local Network privacy does not
    /// gate loopback, so a hint there would be wrong every single day.
    @Test("stays quiet for loopback, public, and near-miss addresses")
    func silentOnNonLocalHost() {
        for host in ["127.0.0.1", "[::1]", "8.8.8.8", "172.15.0.1", "172.32.0.1",
                     "192.169.0.1", "example.com", "[2001:db8::1]"] {
            let hint = StreamHealth.localNetworkHint(forURL: "rtsp://\(host):554/stream",
                                                     message: Self.unreachable)
            #expect(hint == nil, "expected no hint for \(host)")
        }
    }

    /// Deliberately narrow: a private host that fails any other way is a real
    /// network or stream problem, and pointing at Privacy settings would send
    /// the user somewhere useless.
    @Test("only EHOSTUNREACH qualifies")
    func silentOnOtherErrors() {
        let url = "rtsp://192.168.1.12:554/stream"
        #expect(StreamHealth.localNetworkHint(forURL: url,
                                              message: "open failed: Connection refused (-61)") == nil)
        #expect(StreamHealth.localNetworkHint(forURL: url,
                                              message: "no video stream") == nil)
        #expect(StreamHealth.localNetworkHint(forURL: url,
                                              message: "unsupported codec (only H.264 in v1)") == nil)
    }

    @Test("reads the code past prose that itself contains parentheses")
    func parsesTrailingCode() {
        #expect(StreamHealth.errorCode(inMessage: "open failed: No route to host (-65)") == -65)
        #expect(StreamHealth.errorCode(inMessage: "decode stalled (30 in a row) (-1094995529)")
                == -1094995529)
        #expect(StreamHealth.errorCode(inMessage: "no video stream") == nil)
        #expect(StreamHealth.errorCode(inMessage: "unsupported codec (only H.264 in v1)") == nil)
    }

    /// Credentials and unparseable URLs must not cost the hint: those are
    /// exactly the URLs real cameras produce.
    @Test("classifies hosts URLComponents cannot parse")
    func handlesAwkwardURLs() {
        #expect(StreamHealth.localNetworkHint(forURL: "rtsp://admin:p@ss:word@192.168.1.12:554/h264",
                                              message: Self.unreachable) != nil)
        #expect(StreamHealth.localNetworkHint(forURL: "rtsp://192.168.1.12", message: Self.unreachable) != nil)
        #expect(StreamHealth.localNetworkHint(forURL: "", message: Self.unreachable) == nil)
        #expect(StreamHealth.localNetworkHint(forURL: "not a url", message: Self.unreachable) == nil)
    }
}
