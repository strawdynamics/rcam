import Foundation
import SystemExtensions
import os.log

/// Submits activation requests for the CMIO extension and reports progress.
final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "com.strawdynamics.rcam.extension"

    @Published var status = "Not installed"

    private let log = Logger(subsystem: "com.strawdynamics.rcam", category: "ExtensionManager")

    override init() {
        super.init()
        // Activate on every launch: no-op when already current, triggers the
        // .replace path when the installed extension version is older.
        DispatchQueue.main.async { [weak self] in
            self?.activate()
        }
    }

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        status = "Activation requested…"
        log.info("Submitted activation request for \(Self.extensionIdentifier, privacy: .public)")
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
        status = "Needs approval in System Settings → Privacy & Security"
        log.info("Activation needs user approval")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        switch result {
        case .completed:
            status = "Activated"
        case .willCompleteAfterReboot:
            status = "Will activate after reboot"
        @unknown default:
            status = "Finished (result \(result.rawValue))"
        }
        log.info("Activation finished with result \(result.rawValue)")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "Failed: \(error.localizedDescription)"
        log.error("Activation failed: \(error.localizedDescription, privacy: .public)")
    }
}
