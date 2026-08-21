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
    @State private var mainTest = StreamTest()
    @State private var subTest = StreamTest()

    struct StreamTest {
        enum Phase: Equatable {
            case idle
            case testing
            case ok
            case error(String)
        }
        var phase: Phase = .idle
        var image: NSImage?
        var info: RTSPSource.StreamInfo?
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

            Section("Preview") {
                HStack(alignment: .top, spacing: 12) {
                    StreamPreviewCard(title: "Main",
                                      isActive: !usesSubstream,
                                      test: mainTest)
                    if hasSubstream {
                        StreamPreviewCard(title: "Sub",
                                          isActive: usesSubstream,
                                          test: subTest)
                    }
                }
                Button("Test Connection") { testConnection() }
                    .disabled(mainTest.phase == .testing || subTest.phase == .testing)
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

    private var hasSubstream: Bool {
        !config.cameras[index].subURL.isEmpty
    }

    private var usesSubstream: Bool {
        config.cameras[index].preferSub && hasSubstream
    }

    private func testConnection() {
        let camera = config.cameras[index]
        mainTest = StreamTest(phase: .testing)
        runTest(base: camera.mainURL, camera: camera) { mutate in mutate(&mainTest) }
        if hasSubstream {
            subTest = StreamTest(phase: .testing)
            runTest(base: camera.subURL, camera: camera) { mutate in mutate(&subTest) }
        } else {
            subTest = StreamTest()
        }
    }

    /// Connects to one stream URL just long enough to capture a snapshot and
    /// its native properties. `update` applies a mutation to that stream's
    /// StreamTest state on the main thread.
    private func runTest(base: String, camera: CameraConfig,
                         update: @escaping ((inout StreamTest) -> Void) -> Void) {
        let source = RTSPSource(url: ConfigStore.resolvedURL(base, cameraID: camera.id),
                                fill: camera.fit == .fill)
        var finished = false
        let finish: (StreamTest.Phase) -> Void = { phase in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                update { $0.phase = phase }
                DispatchQueue.global().async { source.stop() }
            }
        }
        source.onStreamInfo = { info in
            DispatchQueue.main.async { update { $0.info = info } }
        }
        source.onFrame = { pixelBuffer, _ in
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            DispatchQueue.main.async { update { $0.image = image } }
            finish(.ok)
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

struct StreamPreviewCard: View {
    let title: String
    let isActive: Bool
    let test: CameraEditor.StreamTest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if isActive {
                    Text("In Use")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Spacer()
                if test.phase == .testing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            snapshot
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let details = detailsText {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .error(let message) = test.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var snapshot: some View {
        if let image = test.image {
            Image(nsImage: image)
                .resizable()
        } else {
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                switch test.phase {
                case .idle:
                    Image(systemName: "video")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                case .error:
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                case .testing, .ok:
                    EmptyView()
                }
            }
        }
    }

    private var detailsText: String? {
        guard let info = test.info else { return nil }
        var parts: [String] = []
        if info.width > 0 && info.height > 0 {
            parts.append("\(info.width)×\(info.height)")
        }
        parts.append(Self.displayName(codec: info.codec))
        if let frameRate = info.frameRate {
            parts.append(String(format: frameRate.truncatingRemainder(dividingBy: 1) == 0
                                    ? "%.0f fps" : "%.1f fps", frameRate))
        }
        return parts.joined(separator: " · ")
    }

    private static func displayName(codec: String) -> String {
        switch codec {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        default: return codec.uppercased()
        }
    }
}
