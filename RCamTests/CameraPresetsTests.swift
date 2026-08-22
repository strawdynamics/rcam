import Testing
import Foundation

@Suite("CameraPreset.parseAddress")
struct ParseAddressTests {
    @Test("a bare host takes the default RTSP port")
    func bareHost() {
        let address = CameraPreset.parseAddress("192.168.1.82")
        #expect(address == StreamAddress(host: "192.168.1.82", port: 554))
    }

    @Test("an explicit port wins over the default")
    func explicitPort() {
        #expect(CameraPreset.parseAddress("192.168.1.82:8554")
                == StreamAddress(host: "192.168.1.82", port: 8554))
    }

    @Test("hostnames work as well as literals")
    func hostname() {
        #expect(CameraPreset.parseAddress("cam-shed.local")
                == StreamAddress(host: "cam-shed.local", port: 554))
    }

    @Test("a whole pasted RTSP URL reduces to its address")
    func pastedURL() {
        #expect(CameraPreset.parseAddress("rtsp://192.168.1.82:554/Streaming/Channels/101")
                == StreamAddress(host: "192.168.1.82", port: 554))
        #expect(CameraPreset.parseAddress("rtsp://192.168.1.122:8554/cam/realmonitor?channel=1&subtype=0")
                == StreamAddress(host: "192.168.1.122", port: 8554))
    }

    // The reason this is a correctness test and not a convenience one:
    // CameraConfig guarantees URLs are persisted without credentials, so a
    // pasted password must not survive into the field we write.
    @Test("credentials in a pasted URL are dropped, never carried into the fill")
    func stripsCredentials() {
        let address = CameraPreset.parseAddress("rtsp://admin:hunter2@192.168.1.82:554/11")
        #expect(address == StreamAddress(host: "192.168.1.82", port: 554))
    }

    @Test("an @ inside the password does not confuse the host")
    func passwordContainingAtSign() {
        #expect(CameraPreset.parseAddress("rtsp://admin:p@ss@192.168.1.92/x")
                == StreamAddress(host: "192.168.1.92", port: 554))
    }

    @Test("a query or fragment ends the address just like a path does")
    func queryAndFragment() {
        #expect(CameraPreset.parseAddress("192.168.1.5?channel=1")
                == StreamAddress(host: "192.168.1.5", port: 554))
        #expect(CameraPreset.parseAddress("192.168.1.5#frag")
                == StreamAddress(host: "192.168.1.5", port: 554))
    }

    @Test("surrounding whitespace is tolerated")
    func trimsWhitespace() {
        #expect(CameraPreset.parseAddress("  192.168.1.5  ")
                == StreamAddress(host: "192.168.1.5", port: 554))
    }

    @Test("a trailing colon means the default port, not a parse failure")
    func trailingColon() {
        #expect(CameraPreset.parseAddress("192.168.1.5:")
                == StreamAddress(host: "192.168.1.5", port: 554))
    }

    @Test("IPv6 literals keep their colons; only a bracketed one takes a port")
    func ipv6() {
        #expect(CameraPreset.parseAddress("fd00::1")
                == StreamAddress(host: "fd00::1", port: 554))
        #expect(CameraPreset.parseAddress("[fd00::1]:8554")
                == StreamAddress(host: "fd00::1", port: 8554))
        #expect(CameraPreset.parseAddress("rtsp://[fd00::1]:554/11")
                == StreamAddress(host: "fd00::1", port: 554))
    }

    @Test("nothing usable returns nil rather than a broken address")
    func rejectsUnusable() {
        #expect(CameraPreset.parseAddress("") == nil)
        #expect(CameraPreset.parseAddress("   ") == nil)
        #expect(CameraPreset.parseAddress("rtsp://") == nil)
        #expect(CameraPreset.parseAddress("/just/a/path") == nil)
        #expect(CameraPreset.parseAddress("host name") == nil)
    }

    @Test("a port outside the valid range is a failure, not a silent default")
    func rejectsBadPort() {
        #expect(CameraPreset.parseAddress("192.168.1.5:0") == nil)
        #expect(CameraPreset.parseAddress("192.168.1.5:70000") == nil)
        #expect(CameraPreset.parseAddress("192.168.1.5:abc") == nil)
    }
}

@Suite("CameraPreset URL construction")
struct PresetURLTests {
    private func preset(_ id: String) -> CameraPreset {
        CameraPreset.all.first { $0.id == id }!
    }

    @Test("the tested presets reproduce the URLs they were taken from")
    func testedPresets() {
        let annke = StreamAddress(host: "192.168.1.82", port: 554)
        #expect(preset("hikvision").mainURL(at: annke)
                == "rtsp://192.168.1.82:554/Streaming/Channels/101")
        #expect(preset("hikvision").subURL(at: annke)
                == "rtsp://192.168.1.82:554/Streaming/Channels/102")

        let amcrest = StreamAddress(host: "192.168.1.122", port: 554)
        #expect(preset("dahua").mainURL(at: amcrest)
                == "rtsp://192.168.1.122:554/cam/realmonitor?channel=1&subtype=0")
        #expect(preset("dahua").subURL(at: amcrest)
                == "rtsp://192.168.1.122:554/cam/realmonitor?channel=1&subtype=1")

        let hipcam = StreamAddress(host: "192.168.1.191", port: 554)
        #expect(preset("hipcam").mainURL(at: hipcam) == "rtsp://192.168.1.191:554/11")
        #expect(preset("hipcam").subURL(at: hipcam) == "rtsp://192.168.1.191:554/12")
    }

    @Test("the port is always spelled out, including a non-default one")
    func nonDefaultPort() {
        #expect(preset("reolink").mainURL(at: StreamAddress(host: "cam.local", port: 8554))
                == "rtsp://cam.local:8554/h264Preview_01_main")
    }

    // A single-stream platform must yield an empty sub, so Fill clears the
    // field rather than leaving another platform's substream beside it.
    @Test("a platform with no substream produces an empty sub URL")
    func noSubstream() {
        let address = StreamAddress(host: "192.168.1.5", port: 554)
        #expect(preset("wyze").subURL(at: address) == "")
        #expect(preset("axis").subURL(at: address) == "")
        #expect(preset("wyze").mainURL(at: address) == "rtsp://192.168.1.5:554/live")
    }

    @Test("IPv6 hosts are bracketed in the built URL")
    func ipv6Bracketed() {
        #expect(preset("hipcam").mainURL(at: StreamAddress(host: "fd00::1", port: 554))
                == "rtsp://[fd00::1]:554/11")
    }

    @Test("an address round-trips back through the field it came from")
    func roundTrip() {
        for preset in CameraPreset.all {
            let address = StreamAddress(host: "192.168.1.82", port: 8554)
            let built = preset.mainURL(at: address)
            #expect(CameraPreset.parseAddress(built) == address)
            #expect(CameraPreset.parseAddress(address.text) == address)
        }
    }

    @Test("preset ids are unique and exactly three are marked tested")
    func catalogIntegrity() {
        let ids = CameraPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CameraPreset.all.filter { $0.provenance.isTested }.count == 3)
        #expect(CameraPreset.all.allSatisfy { $0.mainPath.hasPrefix("/") })
    }
}
