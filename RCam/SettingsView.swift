import SwiftUI
import AppKit
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
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch RCam at login")
                    Text("The virtual camera is only available while RCam is running.")
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    if !controller.setLaunchAtLogin(newValue) {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

                LabeledContent {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directoryURL])
                    }
                } label: {
                    Text("Configuration & logs")
                    Text((ConfigStore.directoryURL.path as NSString).abbreviatingWithTildeInPath)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } footer: {
                Text("Connection status and extension install stay in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}

struct CamerasPane: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var controller: RCamController

    @State private var editingID: UUID?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 232, maxWidth: 280)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { editingID = config.selectedID ?? config.cameras.first?.id }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if config.cameras.isEmpty {
                Text("No cameras")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $editingID) {
                    Section("Cameras") {
                        ForEach(config.cameras) { camera in
                            CameraRow(camera: camera,
                                      isLive: controller.streamingCameraID == camera.id)
                                .tag(camera.id)
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack(spacing: 2) {
                Button(action: addCamera) {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 16)
                }
                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 20, height: 16)
                }
                .disabled(editingID == nil)
                Spacer()
                Text("^[\(config.cameras.count) camera](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if config.cameras.isEmpty {
            EmptyCamerasView(addCamera: addCamera)
        } else if let id = editingID,
                  let index = config.cameras.firstIndex(where: { $0.id == id }) {
            CameraEditor(config: config,
                         index: index,
                         isLive: controller.streamingCameraID == id,
                         isSelected: config.selectedID == id)
                .id(id)
        } else {
            Text("Select or add a camera")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addCamera() {
        let camera = CameraConfig()
        config.cameras.append(camera)
        editingID = camera.id
    }

    private func removeSelected() {
        guard let id = editingID else { return }
        KeychainStore.delete(cameraID: id)
        config.cameras.removeAll { $0.id == id }
        editingID = config.cameras.first?.id
    }
}

struct CameraRow: View {
    let camera: CameraConfig
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isLive ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                if camera.name.isEmpty {
                    Text("Untitled").italic().foregroundStyle(.secondary)
                } else {
                    Text(camera.name)
                }
                Text(hostText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if isLive {
                Text("LIVE")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 1)
    }

    private var hostText: String {
        if camera.mainURL.isEmpty { return "no URL yet" }
        return URLComponents(string: camera.mainURL)?.host ?? camera.mainURL
    }
}

struct EmptyCamerasView: View {
    let addCamera: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "video")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.quaternary)
            Text("Add your first camera")
                .font(.headline)
            Text("Paste an RTSP URL from your NVR or camera. RCam turns it into the “RTSP Camera” device your apps can pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button("Add Camera", action: addCamera)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            Text("rtsp://user@host:554/stream")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CameraEditor: View {
    @ObservedObject var config: ConfigStore
    let index: Int
    let isLive: Bool
    let isSelected: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var credsLoaded = false
    @State private var credsSavedAt: Date?
    @State private var mainTest = StreamTest()
    @State private var subTest = StreamTest()
    @State private var lastTested: Date?

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
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                cameraSection
                credentialsSection
                previewSection
            }
            .formStyle(.grouped)
        }
        .onAppear {
            guard !credsLoaded else { return }
            credsLoaded = true
            if let creds = KeychainStore.read(cameraID: config.cameras[index].id) {
                username = creds.username
                password = creds.password
            }
            credsSavedAt = KeychainStore.savedAt(cameraID: config.cameras[index].id)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "video")
                        .foregroundStyle(Color.accentColor)
                }
            VStack(alignment: .leading, spacing: 2) {
                if config.cameras[index].name.isEmpty {
                    Text("Untitled").font(.headline).italic().foregroundStyle(.secondary)
                } else {
                    Text(config.cameras[index].name).font(.headline)
                }
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLive {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Streaming")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        if isLive {
            return "Currently feeding the RTSP Camera virtual device"
        } else if isSelected {
            return "Selected — streams when an app uses the RTSP Camera device"
        } else {
            return "Not selected — choose it from the menu bar to go live"
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section("Camera") {
            TextField("Name", text: $config.cameras[index].name,
                      prompt: Text("Untitled"))

            LabeledContent("Main stream") {
                TextField("Main stream", text: $config.cameras[index].mainURL,
                          prompt: Text("rtsp://host:554/stream"))
                    .labelsHidden()
                    .fontDesign(.monospaced)
            }

            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Substream", text: $config.cameras[index].subURL,
                              prompt: Text("rtsp://host:554/substream"))
                        .labelsHidden()
                        .fontDesign(.monospaced)
                    Text("Optional. A lighter stream RCam can fall back to.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("Substream")
            }

            Picker("Use", selection: $config.cameras[index].preferSub) {
                Text("Main").tag(false)
                Text("Substream").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!hasSubstream)

            LabeledContent("Aspect") {
                HStack(spacing: 10) {
                    AspectGlyph(fit: config.cameras[index].fit)
                    Text(config.cameras[index].fit == .fit
                         ? "bars top & bottom" : "edges cropped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect", selection: $config.cameras[index].fit) {
                        Text("Fit (letterbox)").tag(FitMode.fit)
                        Text("Fill (crop)").tag(FitMode.fill)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Credentials

    private var credentialsSection: some View {
        Section {
            TextField("Username", text: $username)
            SecureField("Password", text: $password)
            HStack(spacing: 8) {
                if let savedAt = credsSavedAt {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Last saved \(Self.savedFormatter.string(from: savedAt)) · used for both streams")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save") {
                    KeychainStore.write(cameraID: config.cameras[index].id,
                                        username: username, password: password)
                    credsSavedAt = username.isEmpty && password.isEmpty ? nil : .now
                }
            }
        } header: {
            HStack {
                Text("Credentials")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.caption2)
                    Text("Stored in Keychain")
                        .font(.caption)
                }
                .foregroundStyle(.green)
            }
        }
    }

    /// "Today at 9:41 AM"-style date for the credentials footer.
    private static let savedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                StreamPreviewCard(title: "Main",
                                  pathSuffix: pathSuffix(of: config.cameras[index].mainURL),
                                  isActive: !usesSubstream,
                                  test: mainTest)
                if hasSubstream {
                    StreamPreviewCard(title: "Sub",
                                      pathSuffix: pathSuffix(of: config.cameras[index].subURL),
                                      isActive: usesSubstream,
                                      test: subTest)
                }
            }
        } header: {
            HStack {
                Text("Preview")
                Spacer()
                if let lastTested {
                    Text("Tested \(lastTested.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Test Connection") { testConnection() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(mainTest.phase == .testing || subTest.phase == .testing)
            }
        }
    }

    private func pathSuffix(of url: String) -> String? {
        guard let path = URLComponents(string: url)?.path, !path.isEmpty else { return nil }
        return path
    }

    private var hasSubstream: Bool {
        !config.cameras[index].subURL.isEmpty
    }

    private var usesSubstream: Bool {
        config.cameras[index].preferSub && hasSubstream
    }

    private func testConnection() {
        let camera = config.cameras[index]
        lastTested = .now
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
            finish(.error("Timed out after 10s"))
        }
    }
}

/// Tiny letterbox/crop illustration next to the Aspect picker.
struct AspectGlyph: View {
    let fit: FitMode

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.85))
            // Opaque base plus a gray wash so the band reads against both
            // the dark bars and the window background.
            Rectangle()
                .fill(.background)
                .overlay(.quaternary)
                .frame(height: fit == .fit ? 12 : 18)
        }
        .frame(width: 30, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct StreamPreviewCard: View {
    let title: String
    let pathSuffix: String?
    let isActive: Bool
    let test: CameraEditor.StreamTest

    @State private var showFullError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            snapshot
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            statusLine
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isError ? Color.red.opacity(0.05) : Color.primary.opacity(0.03))
            RoundedRectangle(cornerRadius: 8)
                .stroke(isError ? Color.red.opacity(0.35) : Color.primary.opacity(0.10),
                        lineWidth: 1)
        }
    }

    private var isError: Bool {
        if case .error = test.phase { return true }
        return false
    }

    private var cardHeader: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let badge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badge.color.opacity(0.15), in: Capsule())
                    .foregroundStyle(badge.color)
            }
            Spacer()
            if let pathSuffix {
                Text(pathSuffix)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// One badge per card: an active test outcome wins; otherwise mark the
    /// stream RCam is configured to use.
    private var badge: (text: String, color: Color)? {
        switch test.phase {
        case .testing: return ("TESTING", .secondary)
        case .error: return ("FAILED", .red)
        case .ok: return isActive ? ("IN USE", .accentColor) : ("OK", .green)
        case .idle: return isActive ? ("IN USE", .accentColor) : nil
        }
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
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                case .error:
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                case .ok:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch test.phase {
        case .idle:
            Text("Not tested yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .testing:
            Text("Connecting… times out in 10s")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ok:
            if let details = detailsText {
                Text(details)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(showFullError ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if message.count > 90 {
                        Button(showFullError ? "Hide full log" : "Show full log") {
                            showFullError.toggle()
                        }
                    }
                    Button("Copy details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
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
