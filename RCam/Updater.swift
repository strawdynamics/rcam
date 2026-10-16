import AppKit
import Combine
import Sparkle

/// The app's one Sparkle updater, plus the two bits of its state the UI binds
/// to.
///
/// `SPUStandardUpdaterController` starts the updater as soon as it is created,
/// so this lives for the whole app (owned by `RCamApp`) and Sparkle's scheduled
/// checks run whether or not any window is open. Feed URL, key and the
/// automatic-check defaults all come from Info.plist (see project.yml).
final class Updater: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// False while a check or install is already in flight. Sparkle exposes it
    /// over KVO only, so it is mirrored here for SwiftUI.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors `SPUUpdater.automaticallyChecksForUpdates`. Sparkle persists the
    /// value in the app's defaults itself; it is republished from KVO rather
    /// than tracked locally so the toggle can't drift from what Sparkle will
    /// actually do.
    @Published private(set) var automaticallyChecksForUpdates: Bool

    private var observations: Set<AnyCancellable> = []

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
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
