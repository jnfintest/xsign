import Foundation

/// The parts of a `.mobileprovision` XSign cares about. The file is a CMS
/// envelope around an XML plist, so the plist is located by its markers.
public struct ProvisioningProfile: Hashable, Sendable {
    public var name: String
    public var uuid: String?
    public var teamName: String?
    public var teamIdentifier: String?
    /// e.g. `ABCDE12345.com.example.app` or `ABCDE12345.*`
    public var applicationIdentifier: String?
    public var creationDate: Date?
    public var expirationDate: Date?
    public var deviceCount: Int
    public var provisionsAllDevices: Bool
    public var getTaskAllow: Bool

    public enum ParseError: LocalizedError {
        case noPlist
        case invalidPlist

        public var errorDescription: String? {
            switch self {
            case .noPlist: return "That file does not look like a provisioning profile."
            case .invalidPlist: return "The provisioning profile could not be read."
            }
        }
    }

    public static func parse(_ data: Data) throws -> ProvisioningProfile {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { throw ParseError.noPlist }

        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let dict = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
            throw ParseError.invalidPlist
        }
        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfile(
            name: dict["Name"] as? String ?? "Provisioning Profile",
            uuid: dict["UUID"] as? String,
            teamName: dict["TeamName"] as? String,
            teamIdentifier: (dict["TeamIdentifier"] as? [String])?.first,
            applicationIdentifier: entitlements["application-identifier"] as? String,
            creationDate: dict["CreationDate"] as? Date,
            expirationDate: dict["ExpirationDate"] as? Date,
            deviceCount: (dict["ProvisionedDevices"] as? [String])?.count ?? 0,
            provisionsAllDevices: dict["ProvisionsAllDevices"] as? Bool ?? false,
            getTaskAllow: entitlements["get-task-allow"] as? Bool ?? false
        )
    }

    /// App ID without the team prefix (`com.example.app`, or `*`).
    public var bundleIdentifierPattern: String? {
        guard let id = applicationIdentifier else { return nil }
        guard let dot = id.firstIndex(of: ".") else { return id }
        return String(id[id.index(after: dot)...])
    }

    public var isWildcard: Bool {
        bundleIdentifierPattern?.hasSuffix("*") ?? false
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expirationDate else { return false }
        return expirationDate <= date
    }

    /// Whether this profile can sign an app with exactly `bundleIdentifier`.
    public func allows(bundleIdentifier: String) -> Bool {
        guard let pattern = bundleIdentifierPattern else { return true }
        guard isWildcard else { return pattern == bundleIdentifier }
        return bundleIdentifier.hasPrefix(String(pattern.dropLast()))
    }

    /// Bundle identifier the app must be signed with under this profile.
    /// Explicit profiles dictate it; wildcard profiles keep the app's own
    /// identifier when it matches the wildcard prefix.
    public func signingBundleIdentifier(for original: String) -> String {
        guard let pattern = bundleIdentifierPattern else { return original }
        guard isWildcard else { return pattern }
        let prefix = String(pattern.dropLast()) // drop "*"
        if prefix.isEmpty || original.hasPrefix(prefix) { return original }
        return prefix + original
    }
}
