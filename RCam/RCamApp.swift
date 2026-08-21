import SwiftUI

@main
struct RCamApp: App {
    @StateObject private var extensionManager = ExtensionManager()

    var body: some Scene {
        MenuBarExtra("RCam", systemImage: "video.fill") {
            Text("Extension: \(extensionManager.status)")
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
