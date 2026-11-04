import SwiftUI
import CoreMediaIO

@main
struct RCamApp: App {
    @StateObject private var extensionManager = ExtensionManager()
    @StateObject private var controller: RCamController
    @StateObject private var config: ConfigStore
    @StateObject private var updater: Updater

    init() {
        let controller = RCamController()
        _controller = StateObject(wrappedValue: controller)
        _config = StateObject(wrappedValue: controller.config)
        _updater = StateObject(wrappedValue: Updater(cameraInUse: controller.$cameraInUse))
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            if config.cameras.isEmpty {
                Text("No cameras — add one in Settings")
            } else {
                ForEach(config.cameras) { camera in
                    Button {
                        controller.select(camera)
                    } label: {
                        HStack {
                            Image(systemName: camera.id == config.selectedID
                                  ? "checkmark.circle.fill" : "circle")
                            Text(camera.name.isEmpty ? "Untitled" : camera.name)
                        }
                    }
                }
            }
            Divider()
            // A persistence failure outranks the connection status: losing the
            // camera list is worse than not streaming, and it is the one
            // problem the user must act on outside RCam.
            if let error = config.persistenceError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
            } else {
                Text(controller.statusText)
            }
            Text("Extension: \(extensionManager.status)")
            // Offered only while it could still help. Under an "Activated"
            // status an install button reads as if something did not take, and
            // removal is deliberately not here: it is destructive, needs a
            // confirmation, and belongs with the other rare actions in Settings.
            if extensionManager.canInstall {
                Button("Install Extension") {
                    extensionManager.activate()
                }
            }
            Divider()
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            SettingsMenuButton()
            Button("Quit RCam") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            // The filled variant is the "on air" state: RCam is loudest in the
            // menu bar exactly while it is feeding the virtual camera.
            Image(controller.streamingCameraID != nil
                  ? "rcam.connector.fill" : "rcam.connector")
                .accessibilityLabel("RCam")
        }

        Settings {
            SettingsView(config: config, controller: controller,
                         extensionManager: extensionManager, updater: updater)
        }
    }
}

/// Opening Settings from the menu bar.
///
/// RCam is an `LSUIElement` app, so clicking the menu bar item does not activate
/// it: SwiftUI orders the Settings window in while the app the user came from
/// keeps focus, leaving Settings open but buried. Activating RCam and making the
/// window key is what actually brings it forward.
struct SettingsMenuButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            openSettings()
            // `ignoringOtherApps` is required, deprecation notwithstanding: the
            // modern NSApp.activate() defers to the app that already has focus,
            // which is exactly the app we are trying to come forward over.
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
