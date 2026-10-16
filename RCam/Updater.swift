import AppKit
import Combine
import Sparkle
import os.log

/// The app's one Sparkle updater, plus the two bits of its state the UI binds
/// to.
///
/// `SPUStandardUpdaterController` starts the updater as soon as it is created,
/// so this lives for the whole app (owned by `RCamApp`) and Sparkle's scheduled
/// checks run whether or not any window is open. Feed URL, key and the
/// automatic-check defaults all come from Info.plist (see project.yml).
///
/// Scheduled update prompts are held back while the virtual camera has a
/// client (see `ScheduledUpdateGate`); a manual check always shows at once.
final class Updater: ObservableObject {
    let controller: SPUStandardUpdaterController
    /// Sparkle holds its delegates weakly, so this keeps it alive.
    private let gentleReminders: GentleReminders

    /// False while a check or install is already in flight. Sparkle exposes it
    /// over KVO only, so it is mirrored here for SwiftUI.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Sparkle persists the
    /// value in the app's defaults itself; it is republished from KVO rather
    /// than tracked locally so the toggle can't drift from what Sparkle will
    /// actually do.
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private var observations: Set<AnyCancellable> = []

    /// `cameraInUse` must publish on main, where Sparkle calls its delegate.
    init(cameraInUse: some Publisher<Bool, Never>) {
        gentleReminders = GentleReminders()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: gentleReminders)
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        gentleReminders.showHeldUpdate = { [weak self] in
            // Async: one path here is from inside Sparkle's own "about to show"
            // callback, which must return before the update is brought forward.
            DispatchQueue.main.async { self?.checkForUpdates() }
        }
        cameraInUse
            .removeDuplicates()
            .sink { [weak self] in self?.gentleReminders.cameraInUseChanged($0) }
            .store(in: &observations)
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observations)
    }

    /// User-initiated, so Sparkle always shows the result — including "you're
    /// up to date" and errors, which a scheduled check keeps quiet about.
    func checkForUpdates() {
        // RCam is LSUIElement: without this Sparkle's window opens behind the
        // app the user clicked the menu bar from (see SettingsMenuButton).
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

/// Sparkle's gentle-reminder hooks, driving a `ScheduledUpdateGate`.
///
/// Holding an update means telling Sparkle we will show it ourselves and then
/// not doing so until the camera goes idle. Sparkle keeps the update session
/// open meanwhile, so `checkForUpdates` later brings that same update forward
/// rather than starting a new check.
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    var showHeldUpdate: () -> Void = {}
    private var cameraInUse = false
    private var gate = ScheduledUpdateGate()
    private let log = Logger(subsystem: "com.strawdynamics.rcam", category: "Updater")

    func cameraInUseChanged(_ inUse: Bool) {
        cameraInUse = inUse
        if gate.cameraInUseChanged(inUse) {
            log.info("camera idle — showing the held update")
            showHeldUpdate()
        }
    }

    // Also what keeps Sparkle from warning that a background (LSUIElement) app
    // without gentle reminders may have its scheduled alerts go unnoticed.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        ScheduledUpdateGate.sparkleShouldShowScheduledUpdate(cameraInUse: cameraInUse)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Sparkle showing it itself (idle, or a manual check) needs nothing.
        guard !handleShowingUpdate else { return }
        if gate.updateDeferred(cameraInUse: cameraInUse) {
            showHeldUpdate()
        } else {
            log.info("update \(update.displayVersionString, privacy: .public) found while the camera is in use — holding it until idle")
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        gate.updateHandled()
    }

    func standardUserDriverWillFinishUpdateSession() {
        gate.updateHandled()
    }
}
