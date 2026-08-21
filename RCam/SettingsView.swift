import SwiftUI
import CoreVideo
import CoreImage
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var config: ConfigStore
    let controller: RCamController

    var body: some View {
        TabView {
            CamerasPane(config: config, controller: controller)
                .tabItem { Label("Cameras", systemImage: "video") }
            GeneralPane(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

struct GeneralPane: View {
    let controller: RCamController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("Launch RCam at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    if !controller.setLaunchAtLogin(newValue) {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .padding()
    }
}

struct CamerasPane: View {
    @ObservedObject var config: ConfigStore
    let controller: RCamController

    @State private var editingID: UUID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $editingID) {
                    ForEach(config.cameras) { camera in
                        Text(camera.name.isEmpty ? "Untitled" : camera.name)
                            .tag(camera.id)
                    }
                }
                HStack {
                    Button {
                        var camera = CameraConfig()
                        camera.name = "New Camera"
                        config.cameras.append(camera)
                        editingID = camera.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let id = editingID {
                            KeychainStore.delete(cameraID: id)
                            config.cameras.removeAll { $0.id == id }
                            editingID = config.cameras.first?.id
                        }
                    } label: { Image(systemName: "minus") }
                    .disabled(editingID == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 240)

            if let id = editingID,
               let index = config.cameras.firstIndex(where: { $0.id == id }) {
                CameraEditor(config: config, index: index)
                    .id(id)
            } else {
                Text("Select or add a camera")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { editingID = config.selectedID ?? config.cameras.first?.id }
    }
}

struct CameraEditor: View {
    @ObservedObject var config: ConfigStore
    let index: Int

    @State private var username = ""
    @State private var password = ""
    @State private var credsLoaded = false
    @State private var testResult: TestResult = .none

    enum TestResult {
        case none
        case testing
        case ok(NSImage)
        case error(String)
    }

    var body: some View {
        Form {
            TextField("Name", text: $config.cameras[index].name)
            TextField("Main URL (rtsp://…)", text: $config.cameras[index].mainURL)
            TextField("Sub URL (optional)", text: $config.cameras[index].subURL)
            Toggle("Prefer substream", isOn: $config.cameras[index].preferSub)
            Picker("Aspect", selection: $config.cameras[index].fit) {
                Text("Fit (letterbox)").tag(FitMode.fit)
                Text("Fill (crop)").tag(FitMode.fill)
            }

            Section("Credentials (stored in Keychain)") {
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
                Button("Save Credentials") {
                    KeychainStore.write(cameraID: config.cameras[index].id,
                                        username: username, password: password)
                }
            }

            Section {
                HStack(alignment: .top) {
                    Button("Test Connection") { testConnection() }
                        .disabled({ if case .testing = testResult { true } else { false } }())
                    switch testResult {
                    case .none:
                        EmptyView()
                    case .testing:
                        ProgressView().controlSize(.small)
                    case .ok(let image):
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 192, height: 108)
                            .border(Color.secondary)
                    case .error(let message):
                        Text(message)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding()
        .onAppear {
            guard !credsLoaded else { return }
            credsLoaded = true
            if let creds = KeychainStore.read(cameraID: config.cameras[index].id) {
                username = creds.username
                password = creds.password
            }
        }
    }

    private func testConnection() {
        testResult = .testing
        let camera = config.cameras[index]
        let source = RTSPSource(url: ConfigStore.resolvedURL(for: camera),
                                fill: camera.fit == .fill)
        var finished = false
        let finish: (TestResult) -> Void = { result in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                testResult = result
                DispatchQueue.global().async { source.stop() }
            }
        }
        source.onFrame = { pixelBuffer, _ in
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            finish(.ok(image))
        }
        source.onStateChange = { state in
            if case .failed(let message) = state {
                finish(.error(message))
            }
        }
        source.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            finish(.error("timed out after 10s"))
        }
    }
}
