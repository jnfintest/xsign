import Foundation

/// Builds the manifest plist that `itms-services://` installs read.
public enum InstallManifest {
    public static func data(
        bundleIdentifier: String,
        version: String,
        title: String,
        packageURL: URL,
        displayImageURL: URL? = nil,
        fullSizeImageURL: URL? = nil
    ) throws -> Data {
        var assets: [[String: Any]] = [["kind": "software-package", "url": packageURL.absoluteString]]
        if let displayImageURL { assets.append(["kind": "display-image", "url": displayImageURL.absoluteString]) }
        if let fullSizeImageURL { assets.append(["kind": "full-size-image", "url": fullSizeImageURL.absoluteString]) }

        let manifest: [String: Any] = [
            "items": [[
                "assets": assets,
                "metadata": [
                    "bundle-identifier": bundleIdentifier,
                    "bundle-version": version,
                    "kind": "software",
                    "title": title,
                ],
            ]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }

    /// `itms-services` URL pointing at a manifest.
    public static func installURL(manifestURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifestURL.absoluteString),
        ]
        // URLComponents yields "itms-services:?action=…"; iOS expects "itms-services://?…".
        guard let query = components.percentEncodedQuery else { return nil }
        return URL(string: "itms-services://?\(query)")
    }
}
