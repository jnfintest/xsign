import Foundation

// MARK: - Sources

/// What a source points at.
public enum SourceKind: Codable, Hashable, Sendable {
    /// A GitHub repository whose releases carry an .ipa (one app per repo).
    case github(GitHubSource)
    /// A JSON source over HTTP(S): AltStore/Feather format (many apps) or the
    /// XSign feed format (one app). Works for a homelab / NAS too.
    case feed(FeedSource)

    /// Human-readable address, e.g. `github.com/owner/repo`.
    public var address: String {
        switch self {
        case .github(let s): return "github.com/\(s.owner)/\(s.repo)"
        case .feed(let s):
            let text = s.url.absoluteString
            return text.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        }
    }

    public var kindLabel: String {
        switch self {
        case .github: return "GitHub"
        case .feed: return "Source"
        }
    }

    /// Parses what a user pastes: a GitHub repo URL / `owner/repo`, or any
    /// other http(s) URL as a JSON source.
    public static func parse(_ input: String) -> SourceKind? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        // Bare "owner/repo".
        let shorthand = text.split(separator: "/", omittingEmptySubsequences: false)
        if shorthand.count == 2, !text.contains(":"), !text.contains("."),
           !shorthand[0].isEmpty, !shorthand[1].isEmpty {
            return .github(GitHubSource(owner: String(shorthand[0]), repo: String(shorthand[1])))
        }

        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host?.lowercased() else { return nil }

        if host == "github.com" || host == "www.github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            return .github(GitHubSource(owner: parts[0], repo: repo))
        }
        guard host.contains(".") || host == "localhost" || url.port != nil else { return nil }
        return .feed(FeedSource(url: url))
    }
}

public struct GitHubSource: Codable, Hashable, Sendable {
    public var owner: String
    public var repo: String
    /// Glob matched against release asset names.
    public var assetPattern: String

    public init(owner: String, repo: String, assetPattern: String = "*.ipa") {
        self.owner = owner
        self.repo = repo
        self.assetPattern = assetPattern
    }
}

public struct FeedSource: Codable, Hashable, Sendable {
    public var url: URL
    /// Send the feed token (from the keychain) as a bearer token.
    public var useToken: Bool

    public init(url: URL, useToken: Bool = false) {
        self.url = url
        self.useToken = useToken
    }
}

/// A source the user added on the Repos tab.
public struct SourceRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SourceKind
    public var name: String
    public var iconURL: URL?
    public var addedAt: Date
    public var lastRefreshed: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), kind: SourceKind, name: String, iconURL: URL? = nil, addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.name = name
        self.iconURL = iconURL
        self.addedAt = addedAt
    }
}

// MARK: - Catalog

/// What a source currently offers.
public struct SourceCatalog: Codable, Hashable, Sendable {
    public var name: String
    public var iconURL: URL?
    public var apps: [CatalogApp]

    public init(name: String, iconURL: URL? = nil, apps: [CatalogApp]) {
        self.name = name
        self.iconURL = iconURL
        self.apps = apps
    }
}

/// One app offered by a source, with its versions (newest first).
public struct CatalogApp: Codable, Hashable, Identifiable, Sendable {
    /// Stable within its source: the bundle ID, or `github:owner/repo`.
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    public var developer: String?
    public var subtitle: String?
    public var summary: String?
    public var iconURL: URL?
    public var tintHex: String?
    public var versions: [ReleaseInfo]

    public init(id: String, name: String, bundleIdentifier: String? = nil, developer: String? = nil,
                subtitle: String? = nil, summary: String? = nil, iconURL: URL? = nil, tintHex: String? = nil,
                versions: [ReleaseInfo]) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.developer = developer
        self.subtitle = subtitle
        self.summary = summary
        self.iconURL = iconURL
        self.tintHex = tintHex
        self.versions = versions
    }

    /// Newest version, skipping betas unless asked for.
    public func latest(includeBetas: Bool) -> ReleaseInfo? {
        includeBetas ? versions.first : versions.first(where: { !$0.isPrerelease })
    }
}

// MARK: - Releases

public struct ReleaseAsset: Codable, Hashable, Sendable {
    public var name: String
    public var size: Int64?
    public var downloadURL: URL
    /// The download needs the GitHub token and `Accept: application/octet-stream`.
    public var isGitHubAPIAsset: Bool
    public var sha256: String?

    public init(name: String, size: Int64?, downloadURL: URL, isGitHubAPIAsset: Bool, sha256: String? = nil) {
        self.name = name
        self.size = size
        self.downloadURL = downloadURL
        self.isGitHubAPIAsset = isGitHubAPIAsset
        self.sha256 = sha256
    }
}

public struct ReleaseInfo: Codable, Hashable, Sendable, Identifiable {
    /// Stable identity of the release (tag, or version+build for feeds).
    public var id: String
    public var version: String
    public var build: String?
    public var title: String?
    public var notes: String?
    public var publishedAt: Date?
    public var pageURL: URL?
    /// GitHub pre-releases and feed betas. Shown, but skipped by updates
    /// unless the update rules include betas.
    public var isPrerelease: Bool
    public var asset: ReleaseAsset

    public init(id: String, version: String, build: String? = nil, title: String? = nil, notes: String? = nil,
                publishedAt: Date? = nil, pageURL: URL? = nil, isPrerelease: Bool = false, asset: ReleaseAsset) {
        self.id = id
        self.version = version
        self.build = build
        self.title = title
        self.notes = notes
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.isPrerelease = isPrerelease
        self.asset = asset
    }

    public var displayVersion: String {
        if let build, !build.isEmpty, build != version { return "\(version) (\(build))" }
        return version
    }

    /// Whether this release should replace what is installed.
    public func isUpdate(over installed: InstalledRecord?) -> Bool {
        guard let installed else { return true }
        if id == installed.releaseID { return false }

        let latest = AppVersion(version)
        let current = AppVersion(installed.releaseVersion)
        if latest.isNumeric && current.isNumeric {
            if latest != current { return latest > current }
            if let b1 = build.flatMap(Int.init), let b2 = installed.build.flatMap(Int.init) { return b1 > b2 }
            return false
        }
        if let publishedAt { return publishedAt > installed.installedAt }
        return true
    }
}

// MARK: - Installed state

/// What XSign last installed. iOS does not let one app read another app's
/// version, so XSign records this itself when an install is handed to iOS.
public struct InstalledRecord: Codable, Hashable, Sendable {
    public var releaseID: String
    /// Version from the release (tag / feed), used for update comparison.
    public var releaseVersion: String
    /// `CFBundleShortVersionString` read from the signed bundle.
    public var bundleVersion: String?
    public var build: String?
    public var installedAt: Date

    public init(releaseID: String, releaseVersion: String, bundleVersion: String? = nil, build: String? = nil,
                installedAt: Date = Date()) {
        self.releaseID = releaseID
        self.releaseVersion = releaseVersion
        self.bundleVersion = bundleVersion
        self.build = build
        self.installedAt = installedAt
    }

    public var displayVersion: String {
        let v = bundleVersion ?? releaseVersion
        if let build, !build.isEmpty, build != v { return "\(v) (\(build))" }
        return v
    }
}

// MARK: - Rate limit

/// GitHub API quota as reported in the last response's headers.
public struct RateLimit: Codable, Hashable, Sendable {
    public var limit: Int
    public var remaining: Int
    public var resetAt: Date
    public var measuredAt: Date

    public init(limit: Int, remaining: Int, resetAt: Date, measuredAt: Date = Date()) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.measuredAt = measuredAt
    }

    public init?(headers: [String: String], now: Date = Date()) {
        func value(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        guard
            let limit = value("X-RateLimit-Limit").flatMap(Int.init),
            let remaining = value("X-RateLimit-Remaining").flatMap(Int.init),
            let reset = value("X-RateLimit-Reset").flatMap(TimeInterval.init)
        else { return nil }
        self.init(limit: limit, remaining: remaining, resetAt: Date(timeIntervalSince1970: reset), measuredAt: now)
    }

    /// 60/hour means no (valid) token was sent.
    public var isAnonymous: Bool { limit <= 60 }
}
