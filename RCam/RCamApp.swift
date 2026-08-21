import SwiftUI
import CoreMediaIO

@main
struct RCamApp: App {
    @StateObject private var extensionManager = ExtensionManager()
    @StateObject private var controller: RCamController

    init() {
        let controller = RCamController()
        _controller = StateObject(wrappedValue: controller)
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra("RCam", systemImage: "video.fill") {
            Text("Extension: \(extensionManager.status)")
            Text("Stream: \(controller.statusText)")
            Button("Install Extension") {
                extensionManager.activate()
            }
            Divider()
            Button("Quit RCam") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
