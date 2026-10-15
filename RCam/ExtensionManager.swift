import Foundation
import SystemExtensions
import os.log

/// Submits activation and deactivation requests for the CMIO extension and
/// reports progress.
///
/// Both directions share one `OSSystemExtensionRequestDelegate`, and the
/// request object itself does not say which kind it was — so `pendingKinds`
/// remembers, keyed by the request. Without it a deactivation that finishes
/// would report itself as "Activated".
final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    /// project.yml names the extension `<app bundle ID>.extension`, so derive
    /// it rather than repeat the prefix a contributor's Local.xcconfig changes.
    static let extensionIdentifier = Bundle.main.bundleIdentifier! + ".extension"

    enum State: Equatable {
        case unknown
        case activating
        case needsApproval
        case activated
        case activatedAfterReboot
        case removing
        case removedAfterReboot
        case removed
        case failed(String)
    }

    @Published private(set) var state: State = .unknown

    /// The one-line description the menu bar and Settings both show.
    var status: String {
        switch state {
        case .unknown: return "Not installed"
        case .activating: return "Installing…"
        case .needsApproval: return "Needs approval in System Settings › Privacy & Security"
        case .activated: return "Activated"
        case .activatedAfterReboot: return "Will activate after restart"
        case .removing: return "Removing…"
        case .removedAfterReboot: return "Removed — restart to finish"
        case .removed: return "Removed"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    /// Whether the menu bar should offer the install action. Hidden once the
    /// extension is live: an "Install Extension" button under an "Activated"
    /// status reads as if something did not take.
    var canInstall: Bool {
        switch state {
        case .activated, .activating, .removing, .activatedAfterReboot: return false
        case .unknown, .needsApproval, .removed, .removedAfterReboot, .failed: return true
        }
    }

    /// Whether removal is worth offering. Requesting deactivation of something
    /// already gone just returns an error the user can do nothing about.
    var canRemove: Bool {
        switch state {
        case .activated, .activatedAfterReboot, .needsApproval, .unknown, .failed: return true
        case .activating, .removing, .removed, .removedAfterReboot: return false
        }
    }

    private enum Kind: Equatable {
        case activate
        case deactivate
    }

    private var pendingKinds: [ObjectIdentifier: Kind] = [:]
    private let log = Logger(subsystem: "com.strawdynamics.rcam", category: "ExtensionManager")

    override init() {
        super.init()
        // Activate on every launch: no-op when already current, triggers the
        // .replace path when the installed extension version is older.
        // Checked first because activating from a DMG, ~/Downloads or a
        // translocated mount can only fail, and the failure sysextd reports
        // tells the user nothing about the drag they need to do.
        DispatchQueue.main.async { [weak self] in
            let location = InstallLocation.classify(bundleURL: Bundle.main.bundleURL)
            guard location == .ok else {
                InstallLocationAlert.presentAndQuit(location)
                return
            }
            self?.activate()
        }
    }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        submit(request, kind: .activate)
        state = .activating
        log.info("Submitted activation request for \(Self.extensionIdentifier, privacy: .public)")
    }

    /// Ask macOS to remove the extension.
    ///
    /// Expect `.willCompleteAfterReboot`, not `.completed`: on this OS a CMIO
    /// extension's teardown is always deferred to the next boot, even with no
    /// client attached. Measured 2026-08-22 via `systemextensionsctl uninstall`
    /// (this `deactivationRequest` path wasn't tested separately): with RCam
    /// quit, no extension process and `references: []` in
    /// `/Library/SystemExtensions/db.plist`, sysextd still went
    /// `activated_enabled -> terminating_for_uninstall ->
    /// terminated_waiting_to_uninstall_on_reboot`, and `gc` can't shortcut it
    /// (`sysextd.InternalError Code=5`). The extension process is killed and the
    /// device disappears immediately; only the staged bundle in
    /// `/Library/SystemExtensions/<uuid>/` and the db record survive to be
    /// drained at boot. Reporting that honestly is the difference between a
    /// user rebooting once and a user concluding the removal silently failed.
    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        submit(request, kind: .deactivate)
        state = .removing
        log.info("Submitted deactivation request for \(Self.extensionIdentifier, privacy: .public)")
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: Kind) {
        pendingKinds[ObjectIdentifier(request)] = kind
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func take(_ request: OSSystemExtensionRequest) -> Kind {
        pendingKinds.removeValue(forKey: ObjectIdentifier(request)) ?? .activate
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        log.info("Replacing extension \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // Fires for removal too, where the wording above would be wrong: there
        // is nothing to approve under Privacy & Security for a deactivation.
        switch pendingKinds[ObjectIdentifier(request)] ?? .activate {
        case .activate:
            state = .needsApproval
            log.info("Activation needs user approval")
        case .deactivate:
            state = .removing
            log.info("Deactivation needs user approval")
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let kind = take(request)
        switch (kind, result) {
        case (.activate, .completed):
            state = .activated
        case (.activate, .willCompleteAfterReboot):
            state = .activatedAfterReboot
        case (.deactivate, .completed):
            state = .removed
        case (.deactivate, .willCompleteAfterReboot):
            state = .removedAfterReboot
        @unknown default:
            state = .failed("finished with result \(result.rawValue)")
        }
        log.info("\(String(describing: kind), privacy: .public) finished with result \(result.rawValue)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let kind = take(request)
        // Removing something that was never installed is not a failure worth
        // showing as one — it is the state the user asked for.
        if kind == .deactivate,
           (error as? OSSystemExtensionError)?.code == .extensionNotFound {
            state = .removed
            log.info("Deactivation: extension was not installed")
            return
        }
        // The path check at launch is a prediction; this is sysextd's verdict.
        // Same remedy, so the same window rather than a "Failed:" status.
        if kind == .activate,
           (error as? OSSystemExtensionError)?.code == .unsupportedParentBundleLocation {
            state = .failed(error.localizedDescription)
            log.error("Activation refused: unsupported parent bundle location")
            InstallLocationAlert.presentAndQuit(.notInApplications)
            return
        }
        state = .failed(error.localizedDescription)
        log.error("\(String(describing: kind), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
}
