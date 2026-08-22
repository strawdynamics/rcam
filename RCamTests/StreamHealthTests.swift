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
