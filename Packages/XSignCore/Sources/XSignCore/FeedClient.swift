import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a JSON source over HTTP(S): an AltStore/Feather-style source with
/// many apps, or the single-app XSign feed (handy for a homelab / NAS).
///
/// **XSign feed**
/// ```json
/// { "name": "MyApp", "bundleIdentifier": "com.example.myapp",
///   "iconURL": "https://nas.local/icon.png",
///   "releases": [ { "version": "1.4.0", "build": "42", "date": "2026-11-19T10:00:00Z",
///                   "notes": "…", "url": "builds/myapp-1.4.0.ipa",
///                   "size": 12345678, "sha256": "…", "prerelease": false } ] }
/// ```
public struct FeedClient: Sendable {
    public var token: String?
    public var http: HTTPClient

    public init(token: String?, http: HTTPClient = URLSessionHTTPClient()) {
        self.token = token
        self.http = http
    }

    public func catalog(for source: FeedSource) async throws -> SourceCatalog {
        var request = URLRequest(url: source.url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XSign", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if source.useToken, let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await http.send(request)
        try response.ensureSuccess(data: data, resource: "Source \(source.url.absoluteString)")
        return try Self.parse(data, baseURL: source.url)
    }

    // MARK: Parsing

    /// Versions kept per app. Big sources list dozens of builds per app; only
    /// the newest few are ever shown or installed, and keeping all of them
    /// makes the cached catalog many times larger.
    public static let maxVersionsPerApp = 15

    struct XSignFeed: Decodable {
        struct Release: Decodable {
            let version: String
            let build: String?
            let date: String?
            let notes: String?
            let url: String
            let size: Int64?
            let sha256: String?
            let prerelease: Bool?
        }
        let name: String?
        let bundleIdentifier: String?
        let iconURL: String?
        let developer: String?
        let subtitle: String?
        let description: String?
        let releases: [Release]
    }

    /// AltStore / Feather source. Large public sources are hand-edited and
    /// often have a few broken entries (a number where a string belongs, a
    /// missing URL). Those entries are skipped instead of failing the source.
    struct AltSource: Decodable {
        struct App: Decodable {
            struct Version: Decodable {
                let version: String
                let buildVersion: String?
                let date: String?
                let localizedDescription: String?
                let downloadURL: String
                let size: Int64?
                let sha256: String?

                init(version: String, buildVersion: String?, date: String?, localizedDescription: String?,
                     downloadURL: String, size: Int64?, sha256: String?) {
                    self.version = version
                    self.buildVersion = buildVersion
                    self.date = date
                    self.localizedDescription = localizedDescription
                    self.downloadURL = downloadURL
                    self.size = size
                    self.sha256 = sha256
                }

                private enum CodingKeys: String, CodingKey {
                    case version, buildVersion, date, localizedDescription, downloadURL, size, sha256
                }

                init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    guard let version = c.lossyString(.version),
                          let url = try? c.decodeIfPresent(String.self, forKey: .downloadURL) else {
                        throw SourceError.invalidFeed("version without version or downloadURL")
                    }
                    self.version = version
                    downloadURL = url
                    buildVersion = c.lossyString(.buildVersion)
                    date = c.lossyString(.date)
                    localizedDescription = c.lossyString(.localizedDescription)
                    size = c.lossyInt64(.size)
                    sha256 = c.lossyString(.sha256)
                }
            }
            let name: String?
            let bundleIdentifier: String?
            let developerName: String?
            let subtitle: String?
            let localizedDescription: String?
            let iconURL: String?
            let tintColor: String?
            let beta: Bool?
            let versions: [Version]?
            // Legacy single-version fields.
            let version: String?
            let versionDate: String?
            let versionDescription: String?
            let downloadURL: String?
            let size: Int64?

            private enum CodingKeys: String, CodingKey {
                case name, bundleIdentifier, developerName, subtitle, localizedDescription, iconURL, tintColor
                case beta, versions, version, versionDate, versionDescription, downloadURL, size
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = c.lossyString(.name)
                bundleIdentifier = c.lossyString(.bundleIdentifier)
                developerName = c.lossyString(.developerName)
                subtitle = c.lossyString(.subtitle)
                localizedDescription = c.lossyString(.localizedDescription)
                iconURL = c.lossyString(.iconURL)
                tintColor = c.lossyString(.tintColor)
                beta = c.lossyBool(.beta)
                versions = (try? c.decodeIfPresent([Lossy<Version>].self, forKey: .versions))?.compactMap(\.value)
                version = c.lossyString(.version)
                versionDate = c.lossyString(.versionDate)
                versionDescription = c.lossyString(.versionDescription)
                downloadURL = c.lossyString(.downloadURL)
                size = c.lossyInt64(.size)
            }
        }
        let name: String?
        let iconURL: String?
        let apps: [App]

        private enum CodingKeys: String, CodingKey { case name, iconURL, apps }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lossyString(.name)
            iconURL = c.lossyString(.iconURL)
            apps = try c.decode([Lossy<App>].self, forKey: .apps).compactMap(\.value)
        }
    }

    /// Decodes the document once, picking the format by its top-level keys.
    /// (Trying one format and then the other parses a large source twice.)
    enum AnyFeed: Decodable {
        case xsign(XSignFeed)
        case alt(AltSource)

        private enum Keys: String, CodingKey { case releases, apps }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if c.contains(.releases) {
                self = .xsign(try XSignFeed(from: decoder))
            } else if c.contains(.apps) {
                self = .alt(try AltSource(from: decoder))
            } else {
                throw SourceError.invalidFeed("not an AltStore-style source or XSign feed")
            }
        }
    }

    public static func parse(_ data: Data, baseURL: URL? = nil) throws -> SourceCatalog {
        func url(_ string: String?) -> URL? {
            guard let string, !string.isEmpty else { return nil }
            if let url = URL(string: string, relativeTo: baseURL) { return url.absoluteURL }
            // Some sources put spaces or other unescaped characters in URLs.
            guard let escaped = string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return nil }
            return URL(string: escaped, relativeTo: baseURL)?.absoluteURL
        }
        let fallbackName = baseURL?.deletingPathExtension().lastPathComponent ?? "Source"

        let feed: AnyFeed
        do {
            feed = try JSONDecoder().decode(AnyFeed.self, from: data)
        } catch let error as SourceError {
            throw error
        } catch {
            throw SourceError.invalidFeed("not an AltStore-style source or XSign feed")
        }

        switch feed {
        case .xsign(let feed):
            let versions = try feed.releases.map { r -> ReleaseInfo in
                guard let ipa = url(r.url) else { throw SourceError.invalidFeed("bad url \(r.url)") }
                return ReleaseInfo(
                    id: r.build.map { "\(r.version)+\($0)" } ?? r.version,
                    version: r.version, build: r.build, notes: r.notes,
                    publishedAt: r.date.flatMap(parseDate),
                    isPrerelease: r.prerelease ?? false,
                    asset: ReleaseAsset(name: ipa.lastPathComponent, size: r.size, downloadURL: ipa,
                                        isGitHubAPIAsset: false, sha256: r.sha256)
                )
            }
            let name = feed.name ?? fallbackName
            let app = CatalogApp(
                id: feed.bundleIdentifier ?? "feed:\(name.lowercased())",
                name: name, bundleIdentifier: feed.bundleIdentifier, developer: feed.developer,
                subtitle: feed.subtitle, summary: feed.description, iconURL: url(feed.iconURL),
                versions: Array(sortNewestFirst(versions).prefix(maxVersionsPerApp))
            )
            return SourceCatalog(name: name, iconURL: url(feed.iconURL), apps: [app])

        case .alt(let source):
            var apps: [CatalogApp] = []
            apps.reserveCapacity(source.apps.count)
            // App IDs must be unique within a source (they key the Library and
            // SwiftUI lists), but big sources repeat bundle IDs. The first app
            // keeps the plain ID so existing Library links stay valid.
            var seenIDs: [String: Int] = [:]
            for (index, entry) in source.apps.enumerated() {
                var rawVersions = entry.versions ?? []
                if rawVersions.isEmpty, let v = entry.version, let download = entry.downloadURL {
                    rawVersions = [.init(version: v, buildVersion: nil, date: entry.versionDate,
                                         localizedDescription: entry.versionDescription, downloadURL: download,
                                         size: entry.size, sha256: nil)]
                }
                let versions = rawVersions.compactMap { v -> ReleaseInfo? in
                    guard let ipa = url(v.downloadURL) else { return nil }
                    return ReleaseInfo(
                        id: v.buildVersion.map { "\(v.version)+\($0)" } ?? v.version,
                        version: v.version, build: v.buildVersion, notes: v.localizedDescription,
                        publishedAt: v.date.flatMap(parseDate),
                        isPrerelease: entry.beta ?? false,
                        asset: ReleaseAsset(name: ipa.lastPathComponent, size: v.size, downloadURL: ipa,
                                            isGitHubAPIAsset: false, sha256: v.sha256)
                    )
                }
                guard !versions.isEmpty else { continue }
                let name = entry.name ?? entry.bundleIdentifier ?? "App \(index + 1)"
                let baseID = entry.bundleIdentifier ?? "feed:\(name.lowercased())"
                var id = baseID
                if let count = seenIDs[baseID] {
                    seenIDs[baseID] = count + 1
                    id = "\(baseID)#\(count + 1)"
                } else {
                    seenIDs[baseID] = 1
                }
                apps.append(CatalogApp(
                    id: id,
                    name: name, bundleIdentifier: entry.bundleIdentifier, developer: entry.developerName,
                    subtitle: entry.subtitle, summary: entry.localizedDescription, iconURL: url(entry.iconURL),
                    tintHex: entry.tintColor.map { $0.hasPrefix("#") ? $0 : "#\($0)" },
                    versions: Array(sortNewestFirst(versions).prefix(maxVersionsPerApp))
                ))
            }
            return SourceCatalog(name: source.name ?? fallbackName, iconURL: url(source.iconURL), apps: apps)
        }
    }

    static func sortNewestFirst(_ releases: [ReleaseInfo]) -> [ReleaseInfo] {
        guard releases.count > 1 else { return releases }
        // Parse each version once instead of on every comparison.
        let keyed = releases.map { (release: $0, version: AppVersion($0.version), build: Int($0.build ?? "") ?? 0) }
        return keyed.sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version > rhs.version }
            return lhs.build > rhs.build
        }.map { $0.release }
    }

    // ISO8601DateFormatter is thread-safe and costly to create, so these are
    // made once instead of for every version of every app.
    private static let fullDate = ISO8601DateFormatter()
    private static let fractionalDate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func parseDate(_ string: String) -> Date? {
        fullDate.date(from: string) ?? fractionalDate.date(from: string) ?? dateOnly.date(from: string)
    }
}

/// Decodes a value if it can, else nil, so one bad element doesn't fail the array.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// A string, also accepting a number (`"buildVersion": 42`).
    func lossyString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(exactly: value.rounded()) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return ["true", "yes", "1"].contains(value.lowercased()) }
        return nil
    }
}
