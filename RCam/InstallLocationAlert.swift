import AppKit
import os.log

/// The "move me to Applications" window, and the reveal that follows it.
///
/// Kept apart from `InstallLocation` so that file stays Foundation-only for
/// the tests. Shown from two places: at launch, when `InstallLocation` already
/// knows activation can't succeed, and from `ExtensionManager` when sysextd
/// rejects the location anyway (`unsupportedParentBundleLocation`) — a case
/// the path check can't fully predict.
enum InstallLocationAlert {
    private static let log = Logger(subsystem: "com.strawdynamics.rcam", category: "InstallLocation")
    private static var isShowing = false

    /// Shows the window, reveals the app in Finder, then quits. Never returns
    /// control to the caller in a useful state: the sandbox forbids moving
    /// ourselves, so there is nothing RCam can do from here but point at the
    /// bundle the user needs to drag.
    static func presentAndQuit(_ location: InstallLocation) {
        // A launch-time check and an activation failure can both land here.
        guard !isShowing else { return }
        isShowing = true
        log.error("Refusing to run from \(Bundle.main.bundleURL.path, privacy: .public): \(String(describing: location), privacy: .public)")

        // An NSAlert rather than a SwiftUI window: it is modal and has no
        // close button, so the only way out is the button that quits — RCam
        // can't be left half-running from a DMG with no camera.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "RCam needs to be in your Applications folder to install its camera."
        alert.informativeText = "Drag RCam into Applications, then open it from there."
        alert.addButton(withTitle: "Show in Finder")
        // LSUIElement apps don't come forward on their own, and an alert
        // behind the user's other windows looks like RCam silently did nothing.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        NSWorkspace.shared.activateFileViewerSelecting([revealTarget(for: location)])
        NSApp.terminate(nil)
    }

    /// What to select in Finder: the copy the user can actually drag.
    ///
    /// Launched from a DMG, the bundle *is* that copy. Translocated, the bundle
    /// is a randomized read-only mount the user has never seen, and the real
    /// path is only available through private `SecTranslocate` API — so look
    /// for a mounted volume carrying an `RCam.app` with our bundle ID. If the
    /// sandbox denies the lookup or nothing matches (e.g. translocated from
    /// ~/Downloads), fall back to the bundle itself: Finder still opens, which
    /// beats revealing nothing.
    private static func revealTarget(for location: InstallLocation) -> URL {
        let bundleURL = Bundle.main.bundleURL
        guard location == .translocated else { return bundleURL }

        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) ?? []
        let ownID = Bundle.main.bundleIdentifier
        for volume in volumes where volume.path.hasPrefix("/Volumes/") {
            let candidate = volume.appendingPathComponent(bundleURL.lastPathComponent)
            if Bundle(url: candidate)?.bundleIdentifier == ownID {
                return candidate
            }
        }
        return bundleURL
    }
}
