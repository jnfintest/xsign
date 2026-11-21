import Foundation

/// A configuration profile (`.mobileconfig`) that installs one root
/// certificate on the device. XSign's local install server uses a certificate
/// signed by that root, and iOS only talks to it once the root is installed
/// and turned on under Certificate Trust Settings.
public enum TrustProfile {
    public static let contentType = "application/x-apple-aspen-config"

    public static func mobileconfig(rootDER: Data, name: String, identifier: String,
                                    profileUUID: UUID = UUID(), payloadUUID: UUID = UUID()) throws -> Data {
        let certificate: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).root",
            "PayloadUUID": payloadUUID.uuidString,
            "PayloadDisplayName": name,
            "PayloadCertificateFileName": "\(name).cer",
            "PayloadContent": rootDER,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": profileUUID.uuidString,
            "PayloadDisplayName": name,
            "PayloadDescription": "Lets XSign hand apps to the iOS installer from this iPhone. It is only used for the names localhost and local.backloop.dev.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [certificate],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// DER bytes of each certificate in a PEM string, in order.
    public static func derCertificates(fromPEM pem: String) -> [Data] {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var result: [Data] = []
        var rest = Substring(pem)
        while let start = rest.range(of: begin), let stop = rest.range(of: end, range: start.upperBound..<rest.endIndex) {
            let body = rest[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            if let data = Data(base64Encoded: String(body)) { result.append(data) }
            rest = rest[stop.upperBound...]
        }
        return result
    }
}
