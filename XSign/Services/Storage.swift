import Foundation
import Security
import XSignCore

/// On-disk layout inside Application Support/XSign.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("XSign", isDirectory: true)
    }()

    static var stateFile: URL { root.appendingPathComponent("state.json") }
    static var catalogFile: URL { root.appendingPathComponent("catalogs.json") }
    static var certificates: URL { directory("Certificates") }
    static var library: URL { directory("Library") }
    static var icons: URL { directory("Icons") }
    static var ssl: URL { directory("SSL") }
    static var work: URL { directory("Work") }

    static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fresh scratch directory for one signing job.
    static func newWorkDirectory() -> URL {
        let url = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clearWork() {
        try? FileManager.default.removeItem(at: work)
    }
}

// MARK: - Persisted records

struct CertificateRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var teamName: String?
    var teamIdentifier: String?
    var applicationIdentifier: String?
    var expirationDate: Date?
    var deviceCount: Int
    var importedAt: Date

    var directory: URL { AppPaths.certificates.appendingPathComponent(id.uuidString, isDirectory: true) }
    var p12URL: URL { directory.appendingPathComponent("certificate.p12") }
    var profileURL: URL { directory.appendingPathComponent("profile.mobileprovision") }
    var passwordKey: String { "certificate.\(id.uuidString)" }

    var isExpired: Bool { expirationDate.map { $0 <= Date() } ?? false }

    var profile: ProvisioningProfile? {
        (try? Data(contentsOf: profileURL)).flatMap { try? ProvisioningProfile.parse($0) }
    }
}

/// An app XSign holds: the original (unsigned) IPA, plus the last signed copy.
/// Apps got from a source carry `catalogKey`, which links them to updates.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id: UUID
    /// "<source id>|<catalog app id>" for apps from a source; nil for imports.
    var catalogKey: String?
    var sourceName: String?
    var name: String
    var bundleIdentifier: String
    var version: String
    var build: String?
    var fileSize: Int64?
    var iconFileName: String?
    var addedAt: Date
    /// Release the stored original came from (source apps only).
    var originalRelease: ReleaseInfo?
    /// Last release installed through XSign; drives update detection.
    var installed: InstalledRecord?
    var signedBundleIdentifier: String?
    var signedCertificateID: UUID?
    var signedCertificateName: String?
    var signedAt: Date?

    var directory: URL { AppPaths.library.appendingPathComponent(id.uuidString, isDirectory: true) }
    var originalURL: URL { directory.appendingPathComponent("original.ipa") }
    var signedURL: URL { directory.appendingPathComponent("\(fileStem)-signed.ipa") }
    var hasSignedCopy: Bool { signedAt != nil && FileManager.default.fileExists(atPath: signedURL.path) }

    /// Phases are tracked per catalog app when there is one, so the Apps tab and
    /// the Library show the same progress.
    var jobKey: String { catalogKey ?? id.uuidString }

    var displayVersion: String {
        if let build, !build.isEmpty, build != version { return "\(version) (\(build))" }
        return version
    }

    private var fileStem: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return "\(String(cleaned))-\(version)"
    }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct AppSettings: Codable, Hashable {
    /// Whether betas (GitHub pre-releases, beta feed apps) count as updates.
    var includeBetaUpdates = false
    var appearance: Appearance = .dark

    init() {}

    // Missing keys fall back to defaults, so adding settings never wipes state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        includeBetaUpdates = try c.decodeIfPresent(Bool.self, forKey: .includeBetaUpdates) ?? false
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .dark
    }
}

struct PersistedState: Codable {
    var sources: [SourceRecord] = []
    var library: [LibraryItem] = []
    var certificates: [CertificateRecord] = []
    var activeCertificateID: UUID?
    var settings = AppSettings()
    var rateLimit: RateLimit?

    init() {}

    init(sources: [SourceRecord], library: [LibraryItem], certificates: [CertificateRecord],
         activeCertificateID: UUID?, settings: AppSettings, rateLimit: RateLimit?) {
        self.sources = sources
        self.library = library
        self.certificates = certificates
        self.activeCertificateID = activeCertificateID
        self.settings = settings
        self.rateLimit = rateLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([SourceRecord].self, forKey: .sources) ?? []
        library = try c.decodeIfPresent([LibraryItem].self, forKey: .library) ?? []
        certificates = try c.decodeIfPresent([CertificateRecord].self, forKey: .certificates) ?? []
        activeCertificateID = try c.decodeIfPresent(UUID.self, forKey: .activeCertificateID)
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        rateLimit = try c.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
    }
}

enum StateStore {
    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: AppPaths.stateFile) else { return PersistedState() }
        return (try? decoder.decode(PersistedState.self, from: data)) ?? PersistedState()
    }

    static func save(_ state: PersistedState) {
        write(state, to: AppPaths.stateFile)
    }

    /// Catalogs are a cache: rebuilt from the sources on every refresh.
    static func loadCatalogs() -> [UUID: SourceCatalog] {
        guard let data = try? Data(contentsOf: AppPaths.catalogFile),
              let list = try? decoder.decode([String: SourceCatalog].self, from: data) else { return [:] }
        var result: [UUID: SourceCatalog] = [:]
        for (key, value) in list { if let id = UUID(uuidString: key) { result[id] = value } }
        return result
    }

    static func saveCatalogs(_ catalogs: [UUID: SourceCatalog]) {
        write(Dictionary(uniqueKeysWithValues: catalogs.map { ($0.key.uuidString, $0.value) }), to: AppPaths.catalogFile)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: - Keychain

/// Secrets (GitHub token, feed token, .p12 passwords) live in the keychain,
/// never in state.json.
enum Keychain {
    private static let service = "com.jnfintest.xsign"

    static let githubTokenKey = "github.token"
    static let feedTokenKey = "feed.token"

    static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        // Readable after first unlock so background refresh can use the token.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
