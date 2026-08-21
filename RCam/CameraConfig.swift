import Foundation
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
    @Published var cameras: [CameraConfig] {
        didSet { save() }
    }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedCameraID") }
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cameras.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode([CameraConfig].self, from: data) {
            cameras = loaded
        } else {
            cameras = []
        }
        if let raw = UserDefaults.standard.string(forKey: "selectedCameraID"),
           let uuid = UUID(uuidString: raw) {
            selectedID = uuid
        }
        if selectedID == nil || !cameras.contains(where: { $0.id == selectedID }) {
            selectedID = cameras.first?.id
        }
    }

    var selectedCamera: CameraConfig? {
        cameras.first { $0.id == selectedID }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cameras) {
            try? data.write(to: Self.fileURL, options: .atomic)
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
