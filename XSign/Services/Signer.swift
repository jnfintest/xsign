import Foundation
import Security
import Zsign
import XSignCore

enum SigningError: LocalizedError {
    case noCertificate
    case certificateFilesMissing
    case wrongPassword
    case certificateExpired
    case signFailed

    var errorDescription: String? {
        switch self {
        case .noCertificate: return "Add a signing certificate in Settings first."
        case .certificateFilesMissing: return "The certificate files are missing. Re-import the certificate."
        case .wrongPassword: return "The .p12 password is incorrect."
        case .certificateExpired: return "The signing certificate / profile has expired."
        case .signFailed: return "Signing failed. Check that the profile matches the certificate."
        }
    }
}

/// Wraps zsign (MIT, github.com/zhlynn/zsign via khcrysalis/Zsign-Package).
enum Signer {
    struct Credentials {
        let p12: URL
        let profile: URL
        let password: String
        let parsedProfile: ProvisioningProfile?
    }

    static func credentials(for record: CertificateRecord) throws -> Credentials {
        let fm = FileManager.default
        guard fm.fileExists(atPath: record.p12URL.path), fm.fileExists(atPath: record.profileURL.path) else {
            throw SigningError.certificateFilesMissing
        }
        if record.isExpired { throw SigningError.certificateExpired }
        return Credentials(p12: record.p12URL, profile: record.profileURL,
                           password: Keychain.get(record.passwordKey) ?? "",
                           parsedProfile: record.profile)
    }

    /// Signs the unpacked app in place. Returns the bundle identifier used.
    ///
    /// The app keeps its own bundle ID unless an override is given, as Feather
    /// and FlareStore do: iOS ties an app's data to that ID. The profile's App
    /// ID doesn't have to match it; the signature carries the profile's
    /// entitlements, and certificates sold for sideloading usually have one
    /// fixed App ID that is used to sign every app.
    @discardableResult
    static func sign(_ package: inout IPAPackage, with credentials: Credentials,
                     bundleIdentifierOverride: String?) throws -> String {
        let original = package.bundleIdentifier
        let custom = bundleIdentifierOverride?.trimmingCharacters(in: .whitespaces) ?? ""
        let target = custom.isEmpty ? original : custom

        var succeeded = false
        let started = Zsign.sign(
            appPath: package.appBundle.path,
            provisionPath: credentials.profile.path,
            p12Path: credentials.p12.path,
            p12Password: credentials.password,
            entitlementsPath: "",
            customIdentifier: target == original ? "" : target,
            customName: "",
            customVersion: "",
            adhoc: false,
            // Despite the name, `true` makes zsign treat embedded.mobileprovision
            // as changed so the new profile is embedded and hashed (same default
            // as Feather).
            removeProvision: true,
            completion: { succeeded = $0 }
        )
        guard started, succeeded else { throw SigningError.signFailed }
        package.reloadInfo()
        return target
    }

    /// Validates a .p12 + password pair; returns the certificate's common name.
    static func validateP12(_ data: Data, password: String) throws -> String? {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            guard
                let first = (items as? [[String: Any]])?.first,
                let identityRef = first[kSecImportItemIdentity as String]
            else { return nil }
            // swiftlint:disable:next force_cast
            let identity = identityRef as! SecIdentity
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        case errSecAuthFailed:
            throw SigningError.wrongPassword
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "The .p12 file could not be read (\(status))."])
        }
    }
}
