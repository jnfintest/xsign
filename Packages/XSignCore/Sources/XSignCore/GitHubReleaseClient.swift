import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Turns a GitHub repository into a one-app catalog from its releases.
/// Private repositories need a token (fine-grained, Contents: Read-only).
public struct GitHubReleaseClient: Sendable {
    public var token: String?
    public var http: HTTPClient
    public var apiBase: URL

    public init(token: String?, http: HTTPClient = URLSessionHTTPClient(),
                apiBase: URL = URL(string: "https://api.github.com")!) {
        self.token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.http = http
        self.apiBase = apiBase
    }

    struct Repository: Decodable {
        struct Owner: Decodable {
            let login: String
            let avatarUrl: URL?
        }
        let name: String
        let description: String?
        let owner: Owner
    }

    struct Release: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let htmlUrl: URL?
        let assets: [Asset]
    }

    struct Asset: Decodable {
        let id: Int
        let name: String
        let size: Int64?
        let url: URL
        let browserDownloadUrl: URL?
        /// e.g. "sha256:9f2c…" (GitHub fills this in for newer uploads).
        let digest: String?

        var sha256: String? {
            guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
            return String(digest.dropFirst("sha256:".count))
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func authorized(_ url: URL, accept: String = "application/vnd.github+json") -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("XSign", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func repoURL(_ source: GitHubSource) -> URL {
        apiBase.appendingPathComponent("repos").appendingPathComponent(source.owner).appendingPathComponent(source.repo)
    }

    /// Repository metadata + releases as a catalog, and the API quota left.
    public func catalog(for source: GitHubSource, limit: Int = 30) async throws -> (SourceCatalog, RateLimit?) {
        let resource = "Repository \(source.owner)/\(source.repo)"
        let (repoData, repoResponse) = try await http.send(authorized(repoURL(source)))
        try repoResponse.ensureSuccess(data: repoData, resource: resource)
        let repository = try Self.decoder.decode(Repository.self, from: repoData)

        var components = URLComponents(url: repoURL(source).appendingPathComponent("releases"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "per_page", value: String(limit))]
        let (data, response) = try await http.send(authorized(components.url!))
        try response.ensureSuccess(data: data, resource: resource)
        let releases = try Self.decoder.decode([Release].self, from: data)

        let versions = releases
            .filter { !$0.draft }
            .compactMap { Self.makeInfo($0, pattern: source.assetPattern) }

        let app = CatalogApp(
            id: "github:\(source.owner.lowercased())/\(source.repo.lowercased())",
            name: repository.name,
            developer: repository.owner.login,
            summary: repository.description,
            iconURL: repository.owner.avatarUrl,
            versions: versions
        )
        let catalog = SourceCatalog(name: repository.name, iconURL: repository.owner.avatarUrl, apps: [app])
        return (catalog, RateLimit(headers: response.headerStrings))
    }

    /// Current quota without spending any (the rate-limit endpoint is free).
    public func rateLimit() async throws -> RateLimit? {
        let (_, response) = try await http.send(authorized(apiBase.appendingPathComponent("rate_limit")))
        return RateLimit(headers: response.headerStrings)
    }

    /// Request that downloads the asset binary. For private repos the API asset
    /// URL must be used with `Accept: application/octet-stream`; GitHub then
    /// redirects to a pre-signed URL (drop the Authorization header on redirect).
    public func downloadRequest(for asset: ReleaseAsset) -> URLRequest {
        guard asset.isGitHubAPIAsset else {
            var request = URLRequest(url: asset.downloadURL)
            request.setValue("XSign", forHTTPHeaderField: "User-Agent")
            return request
        }
        return authorized(asset.downloadURL, accept: "application/octet-stream")
    }

    static func makeInfo(_ release: Release, pattern: String) -> ReleaseInfo? {
        guard let asset = release.assets.first(where: { globMatch(pattern, $0.name) }) else { return nil }
        let version = release.tagName.hasPrefix("v") || release.tagName.hasPrefix("V")
            ? String(release.tagName.dropFirst())
            : release.tagName
        let title = release.name.flatMap { $0.isEmpty ? nil : $0 }
        return ReleaseInfo(
            id: release.tagName,
            version: version,
            title: title,
            notes: release.body,
            publishedAt: release.publishedAt,
            pageURL: release.htmlUrl,
            isPrerelease: release.prerelease,
            asset: ReleaseAsset(name: asset.name, size: asset.size, downloadURL: asset.url,
                                isGitHubAPIAsset: true, sha256: asset.sha256)
        )
    }
}

extension HTTPURLResponse {
    var headerStrings: [String: String] {
        var result: [String: String] = [:]
        for (key, value) in allHeaderFields {
            if let key = key as? String { result[key] = "\(value)" }
        }
        return result
    }
}
