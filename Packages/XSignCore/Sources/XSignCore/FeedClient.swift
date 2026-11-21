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
        }
        let name: String?
        let iconURL: String?
        let apps: [App]
    }

    public static func parse(_ data: Data, baseURL: URL? = nil) throws -> SourceCatalog {
        let decoder = JSONDecoder()
        func url(_ string: String?) -> URL? {
            guard let string, !string.isEmpty else { return nil }
            return URL(string: string, relativeTo: baseURL)?.absoluteURL
        }
        let fallbackName = baseURL?.deletingPathExtension().lastPathComponent ?? "Source"

        if let feed = try? decoder.decode(XSignFeed.self, from: data) {
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
                versions: sortNewestFirst(versions)
            )
            return SourceCatalog(name: name, iconURL: url(feed.iconURL), apps: [app])
        }

        if let source = try? decoder.decode(AltSource.self, from: data) {
            var apps: [CatalogApp] = []
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
                apps.append(CatalogApp(
                    id: entry.bundleIdentifier ?? "feed:\(name.lowercased())",
                    name: name, bundleIdentifier: entry.bundleIdentifier, developer: entry.developerName,
                    subtitle: entry.subtitle, summary: entry.localizedDescription, iconURL: url(entry.iconURL),
                    tintHex: entry.tintColor.map { $0.hasPrefix("#") ? $0 : "#\($0)" },
                    versions: sortNewestFirst(versions)
                ))
            }
            return SourceCatalog(name: source.name ?? fallbackName, iconURL: url(source.iconURL), apps: apps)
        }

        throw SourceError.invalidFeed("not an AltStore-style source or XSign feed")
    }

    static func sortNewestFirst(_ releases: [ReleaseInfo]) -> [ReleaseInfo] {
        releases.sorted { lhs, rhs in
            let a = AppVersion(lhs.version), b = AppVersion(rhs.version)
            if a != b { return a > b }
            return (Int(lhs.build ?? "") ?? 0) > (Int(rhs.build ?? "") ?? 0)
        }
    }

    static func parseDate(_ string: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let d = full.date(from: string) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: string)
    }
}
