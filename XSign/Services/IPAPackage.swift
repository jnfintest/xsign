import Foundation
import UIKit
import ZIPFoundation

enum IPAError: LocalizedError {
    case noAppBundle
    case unreadableInfoPlist
    case missingBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .noAppBundle: return "The IPA has no Payload/*.app bundle."
        case .unreadableInfoPlist: return "The app's Info.plist could not be read."
        case .missingBundleIdentifier: return "The app has no bundle identifier."
        }
    }
}

/// An IPA unpacked into a working directory (`<dir>/Payload/<Name>.app`).
struct IPAPackage {
    let workDirectory: URL
    let appBundle: URL
    private(set) var info: [String: Any]

    var bundleIdentifier: String { info["CFBundleIdentifier"] as? String ?? "" }
    var version: String { info["CFBundleShortVersionString"] as? String ?? "1.0" }
    var build: String? { info["CFBundleVersion"] as? String }
    var displayName: String {
        (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? appBundle.deletingPathExtension().lastPathComponent
    }

    static func extract(ipa: URL, into directory: URL) throws -> IPAPackage {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.unzipItem(at: ipa, to: directory)
        return try open(workDirectory: directory)
    }

    static func open(workDirectory: URL) throws -> IPAPackage {
        let payload = workDirectory.appendingPathComponent("Payload", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw IPAError.noAppBundle
        }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw IPAError.unreadableInfoPlist }
        guard (info["CFBundleIdentifier"] as? String)?.isEmpty == false else { throw IPAError.missingBundleIdentifier }
        return IPAPackage(workDirectory: workDirectory, appBundle: app, info: info)
    }

    /// Re-reads Info.plist (zsign rewrites it when the bundle ID changes).
    mutating func reloadInfo() {
        if let reopened = try? IPAPackage.open(workDirectory: workDirectory) { info = reopened.info }
    }

    /// Zips `Payload/` back into an .ipa.
    func repackage(to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.zipItem(at: workDirectory.appendingPathComponent("Payload", isDirectory: true),
                       to: destination, shouldKeepParent: true, compressionMethod: .deflate)
    }

    /// Best-effort icon: the largest loose PNG named in CFBundleIcons.
    /// (Icons compiled only into Assets.car are not extracted.)
    func iconImage() -> UIImage? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
               let files = primary["CFBundleIconFiles"] as? [String] {
                names += files
            }
        }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files }
        if names.isEmpty { names = ["AppIcon"] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: appBundle, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let candidates = contents.filter { url in
            url.pathExtension.lowercased() == "png" && names.contains { url.lastPathComponent.hasPrefix($0) }
        }
        let best = candidates.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
        return best.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// Saves the icon as PNG into the icon cache, returning the file name.
    func cacheIcon(named name: String) -> String? {
        guard let image = iconImage(), let png = image.pngData() else { return nil }
        let fileName = "\(name).png"
        try? png.write(to: AppPaths.icons.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }
}
