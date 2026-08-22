import SwiftUI
import CoreMediaIO

@main
struct RCamApp: App {
    @StateObject private var extensionManager = ExtensionManager()
    @StateObject private var controller: RCamController
    @StateObject private var config: ConfigStore

    init() {
        let controller = RCamController()
        _controller = StateObject(wrappedValue: controller)
        _config = StateObject(wrappedValue: controller.config)
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra("RCam", systemImage: "video.fill") {
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
            Button("Install Extension") {
                extensionManager.activate()
            }
            Divider()
            SettingsLink {
                Text("Settings…")
            }
            Button("Quit RCam") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            SettingsView(config: config, controller: controller)
        }
    }
}
