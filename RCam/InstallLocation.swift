import Foundation

/// Where the running app bundle lives, as far as installing the camera
/// extension is concerned.
///
/// `OSSystemExtensionRequest` refuses to activate an extension whose parent
/// app is outside `/Applications`, and the sandbox forbids moving ourselves
/// there, so the app checks this at launch and asks the user to do the drag.
/// Foundation-only and path-based so it is unit-testable without a bundle.
enum InstallLocation: Equatable {
    case ok
    /// Anywhere else: a mounted DMG, `~/Downloads`, and also
    /// `~/Applications` — sysextd only accepts the system `/Applications`.
    case notInApplications
    /// Gatekeeper App Translocation: a quarantined app launched from where it
    /// was unpacked runs from a randomized read-only mount, so even a copy
    /// that *looks* installed can't host the extension until it is moved.
    case translocated

    static func classify(bundleURL: URL) -> InstallLocation {
        // `standardizedFileURL` folds `..` so `/Applications/../Users/…`
        // can't pass the prefix test below.
        let url = bundleURL.standardizedFileURL
        let path = url.path
        // Checked first: the translocated mount is under /private/var/folders,
        // never /Applications, but the reason to give the user differs.
        // SecTranslocateIsTranslocatedURL is private API, so the path is the
        // only public signal.
        if path.contains("/AppTranslocation/") {
            return .translocated
        }
        // Component-wise, so `/ApplicationsOld/RCam.app` doesn't match.
        // Subfolders (`/Applications/Utilities/RCam.app`) are accepted, as
        // sysextd accepts them; anything it rejects anyway surfaces as
        // `unsupportedParentBundleLocation` at activation.
        let components = url.pathComponents
        if components.count > 2, components[0] == "/", components[1] == "Applications" {
            return .ok
        }
        return .notInApplications
    }
}
