import SwiftUI
import AppKit
import CoreVideo
import CoreImage
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var config: ConfigStore
    let controller: RCamController
    @ObservedObject var extensionManager: ExtensionManager

    var body: some View {
        // The card lives inside each pane rather than wrapped around the
        // TabView: the Settings scene hoists the tab picker into the window's
        // toolbar, which overlays and clips anything placed above the TabView
        // (whether by VStack or safeAreaInset).
        TabView {
            CamerasPane(config: config, controller: controller)
                .tabItem { Label("Cameras", systemImage: "video") }
            GeneralPane(config: config, controller: controller,
                        extensionManager: extensionManager, store: controller.store)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

/// Config load/save failure, in the same shape as the per-stream error card:
/// selectable red text plus copy and reveal actions.
struct PersistenceErrorCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Configuration problem")
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.directoryURL])
                    }
                    Button("Copy details") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.09))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct GeneralPane: View {
    @ObservedObject var config: ConfigStore
    let controller: RCamController
    @ObservedObject var extensionManager: ExtensionManager
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showAcknowledgements = false
    @State private var confirmRemoveExtension = false

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = config.persistenceError {
                PersistenceErrorCard(message: error)
            }
            generalForm
        }
    }

    private var generalForm: some View {
        Form {
            PurchaseSection(store: store)

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

                LabeledContent {
                    Text(OutputFormat.sizeDescription)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Output video size")
                    Text("Every camera is scaled to this size at \(OutputFormat.frameRate) fps.")
                }

                // Beta testers report bugs against a build, not a version, so
                // the build number has to be readable without digging into the
                // bundle. Copy button for the same reason.
                LabeledContent {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.versionString, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } label: {
                    Text("Version")
                    Text(Self.versionString)
                        .fontDesign(.monospaced)
                }

                // Sits with Version because together they are the about box
                // this app never got: RCam is LSUIElement, so there is no app
                // menu to hang a standard About panel off.
                LabeledContent {
                    Button("Show") { showAcknowledgements = true }
                        .buttonStyle(.link)
                        .font(.caption)
                } label: {
                    Text("Acknowledgements")
                    Text("FFmpeg \(Acknowledgements.ffmpegVersion), under the LGPL.")
                }
            }

            // The removal half of the install the app performs on first launch.
            // Deleting RCam.app does not take the extension with it, and
            // `systemextensionsctl uninstall` needs SIP off, so without this
            // there is no supported way off the machine at all.
            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        if extensionManager.canInstall {
                            Button("Install") { extensionManager.activate() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        if extensionManager.canRemove {
                            Button("Remove…") { confirmRemoveExtension = true }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                } label: {
                    Text("Virtual camera extension")
                    Text(extensionManager.status)
                }
            } footer: {
                Text("The RCam camera is provided by a system extension. Removing it takes the camera out of every app on this Mac.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsSheet()
        }
        .alert("Remove the RCam virtual camera?", isPresented: $confirmRemoveExtension) {
            Button("Remove", role: .destructive) { extensionManager.deactivate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Promising an immediate removal would be a lie: macOS defers a CMIO
            // extension's teardown to the next boot even with nothing attached.
            Text("""
                 RCam will stop appearing as a camera right away. macOS finishes \
                 removing the extension on your next restart.

                 You can install it again from this window at any time.
                 """)
        }
    }
}

/// The buy / restore row, or the thank-you once it has happened.
///
/// Sits at the top of General on purpose: it is the one screenshot App Review
/// asks for against the in-app purchase, and it is the first thing a free user
/// wondering about the watermark should find. There is deliberately no menu
/// bar item -- the watermark is already doing the asking.
struct PurchaseSection: View {
    @ObservedObject var store: Store

    var body: some View {
        Section {
            if store.isUnlocked {
                LabeledContent {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .imageScale(.large)
                } label: {
                    Text("RCam is unlocked")
                    if store.forceLockedActive {
                        Text("Debug override: forceLocked is set, so the watermark stays on.")
                    } else {
                        Text("Thank you for supporting RCam.")
                    }
                }
            } else {
                LabeledContent {
                    HStack(spacing: 12) {
                        Button("Restore Purchases") {
                            Task { await store.restore() }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(busy)

                        switch store.productState {
                        case .loading:
                            ProgressView().controlSize(.small)
                        case .failed:
                            Button("Retry") {
                                Task { await store.loadProduct() }
                            }
                        case .loaded(let product):
                            Button("Unlock for \(product.displayPrice)") {
                                Task { await store.purchase() }
                            }
                            .disabled(busy)
                        }
                    }
                } label: {
                    Text("Free version")
                    Text(detail)
                }
            }
        } footer: {
            if !store.isUnlocked {
                Text("The free version adds a small watermark to the video. A one-time purchase removes it on every Mac signed in to your Apple Account.")
            }
        }
    }

    private var busy: Bool {
        store.purchaseState == .inProgress
    }

    /// One line under the title. Purchase problems outrank product-load
    /// problems: the user just did something and deserves the answer to that.
    private var detail: String {
        switch store.purchaseState {
        case .inProgress:
            return "Contacting the App Store…"
        case .pending:
            return "Purchase pending approval. RCam unlocks when it is approved."
        case .failed(let message):
            return message
        case .idle:
            break
        }
        if case .failed = store.productState {
            return "Couldn't reach the App Store. Check your connection and retry."
        }
        return "Video from RCam carries a watermark."
    }
}

struct CamerasPane: View {
    @ObservedObject var config: ConfigStore
    @ObservedObject var controller: RCamController

    @State private var editingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let error = config.persistenceError {
                PersistenceErrorCard(message: error)
            }
            HSplitView {
                sidebar
                    .frame(minWidth: 200, idealWidth: 232, maxWidth: 280)
                detail
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
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
                  config.cameras.contains(where: { $0.id == id }) {
            CameraEditor(config: config,
                         cameraID: id,
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
            Text("Paste an RTSP URL from your NVR or camera. RCam turns it into a virtual camera your apps can pick.")
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
    let cameraID: UUID
    let isLive: Bool
    let isSelected: Bool

    @State private var username = ""
    @State private var password = ""
    @State private var credsLoaded = false
    @State private var credsSavedAt: Date?
    @State private var mainTest = StreamTest()
    @State private var subTest = StreamTest()
    @State private var lastTested: Date?
    @State private var showPresets = false

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

    /// The camera being edited, resolved by id on every access. An index
    /// into `config.cameras` cannot be trusted here: SwiftUI re-runs this
    /// body on the same `config` change that removed the camera, and a
    /// just-added camera is always the last element — so its index is out of
    /// bounds the moment it is deleted, and every other deletion shifts the
    /// editor onto the wrong camera.
    private var camera: CameraConfig {
        config.cameras.first { $0.id == cameraID } ?? CameraConfig()
    }

    /// A binding to one field of this camera, resolved by id at both ends.
    /// A write aimed at a camera that has since been deleted is dropped
    /// rather than landing on whatever took its place.
    private func field<V>(_ keyPath: WritableKeyPath<CameraConfig, V>) -> Binding<V> {
        Binding(
            get: { self.camera[keyPath: keyPath] },
            set: { newValue in
                guard let i = self.config.cameras.firstIndex(where: { $0.id == self.cameraID })
                else { return }
                self.config.cameras[i][keyPath: keyPath] = newValue
            }
        )
    }

    @ViewBuilder
    var body: some View {
        // Gone already: the parent drops this editor on the same update, but
        // this body can run first.
        if config.cameras.contains(where: { $0.id == cameraID }) {
            editor
        }
    }

    private var editor: some View {
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
            if let creds = KeychainStore.read(cameraID: cameraID) {
                username = creds.username
                password = creds.password
            }
            credsSavedAt = KeychainStore.savedAt(cameraID: cameraID)
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
                if camera.name.isEmpty {
                    Text("Untitled").font(.headline).italic().foregroundStyle(.secondary)
                } else {
                    Text(camera.name).font(.headline)
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
            return "Currently feeding the RCam virtual device"
        } else if isSelected {
            return "Selected — streams when an app uses the RCam device"
        } else {
            return "Not selected — choose it from the menu bar to go live"
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        Section {
            TextField("Name", text: field(\.name),
                      prompt: Text("Untitled"))

            LabeledContent("Main stream") {
                TextField("Main stream", text: field(\.mainURL),
                          prompt: Text("rtsp://host:554/stream"))
                    .labelsHidden()
                    .fontDesign(.monospaced)
            }

            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("Substream", text: field(\.subURL),
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

            Picker("Use", selection: field(\.preferSub)) {
                Text("Main").tag(false)
                Text("Substream").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(!hasSubstream)

            LabeledContent("Aspect") {
                HStack(spacing: 10) {
                    AspectGlyph(fit: camera.fit)
                    Text(camera.fit == .fit
                         ? "bars top & bottom" : "edges cropped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Aspect", selection: field(\.fit)) {
                        Text("Fit (letterbox)").tag(FitMode.fit)
                        Text("Fill (crop)").tag(FitMode.fill)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        } header: {
            HStack {
                Text("Camera")
                Spacer()
                // Sits in the section header, like Test Connection does in
                // Preview: this action rewrites both URL fields, so hanging it
                // off the Main stream row alone would understate its reach.
                Button("Fill from Preset…") { showPresets = true }
                    .controlSize(.small)
                    .popover(isPresented: $showPresets, arrowEdge: .bottom) {
                        PresetFillPopover(currentMainURL: camera.mainURL,
                                          onFill: applyPreset)
                    }
            }
        }
    }

    /// Writes both URLs at once. Half-applying a preset — a fresh main beside
    /// a stale sub from another platform — would leave the Use picker aimed at
    /// a camera that does not exist, so a preset with no substream clears the
    /// sub rather than leaving it behind. `name` is never touched.
    private func applyPreset(mainURL: String, subURL: String) {
        guard let i = config.cameras.firstIndex(where: { $0.id == cameraID })
        else { return }
        config.cameras[i].mainURL = mainURL
        config.cameras[i].subURL = subURL
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
                    KeychainStore.write(cameraID: cameraID,
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
                                  url: camera.mainURL,
                                  pathSuffix: pathSuffix(of: camera.mainURL),
                                  isActive: !usesSubstream,
                                  test: mainTest)
                if hasSubstream {
                    StreamPreviewCard(title: "Sub",
                                      url: camera.subURL,
                                      pathSuffix: pathSuffix(of: camera.subURL),
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
        !camera.subURL.isEmpty
    }

    private var usesSubstream: Bool {
        camera.preferSub && hasSubstream
    }

    private func testConnection() {
        let camera = camera
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
                // Finding 5: `finish` holds `source` strongly and the source's
                // callbacks hold `finish`, so the source can only be released
                // once those callbacks are cleared. Nil'ing them here — rather
                // than capturing weakly — keeps the fix next to the cycle.
                source.onFrame = nil
                source.onStateChange = nil
                source.onStreamInfo = nil
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
    /// Needed for `StreamHealth.localNetworkHint`, which classifies the host to
    /// decide whether a failure is worth blaming on Local Network privacy.
    let url: String
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
            let hint = StreamHealth.localNetworkHint(forURL: url, message: message)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(showFullError ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // The likeliest cause of this particular failure is a permission
                // RCam was never granted, which the error text actively
                // misdirects away from. Secondary styling, because it is a
                // guess -- the error above it is the fact.
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    if message.count > 90 {
                        Button(showFullError ? "Hide full log" : "Show full log") {
                            showFullError.toggle()
                        }
                    }
                    if hint != nil {
                        Button("Open Local Network Settings") {
                            NSWorkspace.shared.open(Self.localNetworkSettingsURL)
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

    /// Undocumented System Settings anchor. If Apple retires it, the pane still
    /// opens at Privacy & Security rather than failing to open at all, which is
    /// why this is one URL and not a resolve-then-fallback.
    private static let localNetworkSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

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
