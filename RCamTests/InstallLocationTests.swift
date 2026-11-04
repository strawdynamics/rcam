import Testing
import Foundation

@Suite("InstallLocation.classify")
struct InstallLocationTests {
    private func classify(_ path: String) -> InstallLocation {
        InstallLocation.classify(bundleURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    @Test("the normal install in /Applications is ok")
    func applications() {
        #expect(classify("/Applications/RCam.app") == .ok)
    }

    @Test("a subfolder of /Applications is ok")
    func applicationsSubfolder() {
        #expect(classify("/Applications/Utilities/RCam.app") == .ok)
    }

    @Test("launched straight from the mounted DMG")
    func mountedDMG() {
        #expect(classify("/Volumes/RCam/RCam.app") == .notInApplications)
    }

    @Test("launched from Downloads")
    func downloads() {
        #expect(classify("/Users/someone/Downloads/RCam.app") == .notInApplications)
    }

    // sysextd only accepts the system /Applications, so the per-user one has
    // to be rejected here rather than failing later at activation.
    @Test("~/Applications is not good enough")
    func userApplications() {
        #expect(classify("/Users/someone/Applications/RCam.app") == .notInApplications)
    }

    @Test("a Gatekeeper-translocated launch is reported as such")
    func translocated() {
        let path = "/private/var/folders/xy/abc123/T/AppTranslocation/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/d/RCam.app"
        #expect(classify(path) == .translocated)
    }

    @Test("a lookalike prefix does not count as /Applications")
    func lookalikePrefix() {
        #expect(classify("/ApplicationsOld/RCam.app") == .notInApplications)
        #expect(classify("/Applications") == .notInApplications)
    }

    @Test("dot-dot can't escape into /Applications")
    func dotDot() {
        #expect(classify("/Applications/../Users/someone/Downloads/RCam.app") == .notInApplications)
    }
}
