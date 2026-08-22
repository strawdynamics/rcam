import AppKit
import Foundation
import OSLog
import Security

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fit   // letterbox
    case fill  // crop to fill
    var id: String { rawValue }
}

/// One camera. URLs are stored WITHOUT credentials — those live in the
/// Keychain, keyed by the camera id, and are merged only in memory at
/// connect time.
struct CameraConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var mainURL = ""
    var subURL = ""
    var preferSub = false
    var fit = FitMode.fit
}

/// JSON persistence in the sandboxed app's Application Support container.
final class ConfigStore: ObservableObject {
    /// How long `save()` coalesces edits. Without it every keystroke in every
    /// text field rewrites the file.
    static let saveDebounceSeconds: TimeInterval = 0.5

    @Published var cameras: [CameraConfig] {
        didSet { save() }
    }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedCameraID") }
    }

    /// Non-nil when the config could not be read or could not be written.
    /// Surfaced in the menu bar and at the top of Settings — a silent failure
    /// here costs the user their whole camera list.
    @Published private(set) var persistenceError: String?

    /// Tracked separately so a later successful write clears the write error
    /// without also clearing the "your old file was quarantined" notice.
    private var loadError: String? { didSet { refreshPersistenceError() } }
    private var saveError: String? { didSet { refreshPersistenceError() } }

    private var pendingSave: DispatchWorkItem?
    private var terminationObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "com.paulstraw.rcam", category: "ConfigStore")

    /// Application Support directory holding the config (and, from the
    /// user's point of view, "where RCam keeps its files").
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("cameras.json")
    }

    private static var quarantineURL: URL {
        directoryURL.appendingPathComponent("cameras.json.bak")
    }

    init() {
        // Three cases, deliberately distinguished. Collapsing "absent" and
        // "unparseable" into an empty list is what made a corrupt file
        // silently fatal: the next edit's save() would overwrite it.
        let fileURL = Self.fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            cameras = []                                   // normal first run
        } else {
            do {
                let data = try Data(contentsOf: fileURL)
                cameras = try JSONDecoder().decode([CameraConfig].self, from: data)
            } catch {
                cameras = []
                loadError = Self.quarantine(fileURL, reason: error, log: log)
            }
        }

        if let raw = UserDefaults.standard.string(forKey: "selectedCameraID"),
           let uuid = UUID(uuidString: raw) {
            selectedID = uuid
        }
        if selectedID == nil || !cameras.contains(where: { $0.id == selectedID }) {
            selectedID = cameras.first?.id
        }

        // didSet does not fire for assignments made during init, so a load
        // error set above has not reached `persistenceError` yet.
        refreshPersistenceError()

        // A debounced save must not be lost on quit.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flushPendingSave()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Move an unreadable/unparseable config aside before anything can
    /// overwrite it, and return the message to show the user.
    private static func quarantine(_ fileURL: URL, reason: Error, log: Logger) -> String {
        // Never clobber an existing quarantine — the older one is the more
        // likely to still hold the user's real camera list.
        var destination = quarantineURL
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            destination = directoryURL.appendingPathComponent("cameras.json.bak-\(stamp)")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            log.error("cameras.json unreadable (\(reason.localizedDescription, privacy: .public)) — moved to \(destination.lastPathComponent, privacy: .public)")
            return "Couldn\u{2019}t read cameras.json, so RCam started with no cameras. The file was kept as \(destination.lastPathComponent) — recover it before adding cameras."
        } catch {
            log.error("cameras.json unreadable and could not be moved aside: \(error.localizedDescription, privacy: .public)")
            return "Couldn\u{2019}t read cameras.json (\(reason.localizedDescription)), and it could not be moved aside either. RCam started with no cameras; do not add any until you have copied the file somewhere safe."
        }
    }

    private func refreshPersistenceError() {
        // A failed write is the more urgent of the two.
        persistenceError = saveError ?? loadError
    }

    var selectedCamera: CameraConfig? {
        cameras.first { $0.id == selectedID }
    }

    /// Debounced: `cameras.didSet` fires on every keystroke of every field.
    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceSeconds, execute: work)
    }

    /// Write any coalesced edit immediately — on quit, so nothing is lost.
    func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        writeNow()
    }

    private func writeNow() {
        pendingSave = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cameras)
            try data.write(to: Self.fileURL, options: .atomic)
            saveError = nil
        } catch {
            log.error("saving cameras.json failed: \(error.localizedDescription, privacy: .public)")
            saveError = "Couldn\u{2019}t save cameras.json: \(error.localizedDescription). Recent changes are not on disk."
        }
    }

    /// The URL to actually connect: sub if preferred and present, with
    /// Keychain credentials injected in memory only.
    static func resolvedURL(for camera: CameraConfig) -> String {
        let base = (camera.preferSub && !camera.subURL.isEmpty) ? camera.subURL : camera.mainURL
        return resolvedURL(base, cameraID: camera.id)
    }

    /// A specific URL with that camera's Keychain credentials injected.
    static func resolvedURL(_ base: String, cameraID: UUID) -> String {
        guard let creds = KeychainStore.read(cameraID: cameraID),
              var components = URLComponents(string: base) else { return base }
        components.user = creds.username
        components.password = creds.password
        return components.string ?? base
    }
}

/// Per-camera credentials. service = bundle id, account = camera id.
enum KeychainStore {
    struct Credentials: Codable {
        var username: String
        var password: String
    }

    private static let service = "com.paulstraw.rcam"

    static func read(cameraID: UUID) -> Credentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: cameraID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(Credentials.self, from: data) else {
            return nil
        }
        return creds
    }

    /// When the credentials item was last written, from the Keychain's own
    /// modification-date attribute.
    static func savedAt(cameraID: UUID) -> Date? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: cameraID.uuidString,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attrs = result as? [CFString: Any] else {
            return nil
        }
        return attrs[kSecAttrModificationDate] as? Date
    }

    @discardableResult
    static func write(cameraID: UUID, username: String, password: String) -> Bool {
        guard !username.isEmpty || !password.isEmpty else {
            delete(cameraID: cameraID)
            return true
        }
        guard let data = try? JSONEncoder().encode(
            Credentials(username: username, password: password)) else { return false }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: cameraID.uuidString,
        ]
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(cameraID: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: cameraID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
