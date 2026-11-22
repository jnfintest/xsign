import Foundation
import Security
import UIKit
import CryptoKit
import Vapor
import NIOSSL
import X509
import XSignCore

/// TLS material for the local install server.
///
/// `itms-services` only fetches manifests over HTTPS that iOS trusts. XSign
/// makes its own root certificate on the device, signs a server certificate
/// for the loopback names with it, and then throws the root's private key
/// away: the root can't vouch for anything else, even if this app's files
/// leaked. The user installs the root once (a configuration profile) and turns
/// it on under Certificate Trust Settings.
struct SSLPack: Codable {
    /// Server certificate followed by the root, PEM.
    var certificatePEM: String
    var privateKeyPEM: String
    /// The root certificate, DER, for the configuration profile.
    var rootDER: Data
    var rootName: String
    var createdAt: Date
    var expiresAt: Date

    /// Names the server certificate covers, tried in this order. Every
    /// subdomain of backloop.dev still resolves to 127.0.0.1, and iOS's
    /// installer reaches it there; with "localhost" it can't connect (likely
    /// because it tries ::1 while the server listens on 127.0.0.1), so that
    /// name is only the fallback.
    static let hostnames = ["local.backloop.dev", "localhost"]
    static let profileIdentifier = "app.xsign.local-install"

    private static var fileURL: URL { AppPaths.ssl.appendingPathComponent("local-install.json") }

    static func load() -> SSLPack? {
        // Packs from backloop.dev (discontinued, revoked) are no longer used.
        try? FileManager.default.removeItem(at: AppPaths.ssl.appendingPathComponent("pack.json"))
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SSLPack.self, from: data)
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var isExpired: Bool { expiresAt.timeIntervalSinceNow < 24 * 3600 }

    func mobileconfig() throws -> Data {
        try TrustProfile.mobileconfig(rootDER: rootDER, name: rootName, identifier: Self.profileIdentifier)
    }

    /// Whether iOS trusts the server certificate, i.e. the root is installed
    /// and turned on. Evaluating trust can block; call it off the main thread.
    func isTrusted() -> Bool {
        let certificates = TrustProfile.derCertificates(fromPEM: certificatePEM)
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return false }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, Self.hostnames[0] as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Makes a new root and server certificate and saves them.
    static func generate(now: Date = Date()) throws -> SSLPack {
        let tag = String(UUID().uuidString.prefix(4))
        let rootName = "XSign Local Install \(tag)"
        let start = now.addingTimeInterval(-3600)
        // iOS rejects server certificates valid for more than 825 days.
        let end = now.addingTimeInterval(800 * 24 * 3600)

        let rootKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let rootSubject = try DistinguishedName {
            CommonName(rootName)
            OrganizationName("XSign")
        }
        let root = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: rootKey.publicKey,
            notValidBefore: start,
            notValidAfter: end.addingTimeInterval(24 * 3600),
            issuer: rootSubject,
            subject: rootSubject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: rootKey
        )

        let serverKey = P256.Signing.PrivateKey()
        let server = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PrivateKey(serverKey).publicKey,
            notValidBefore: start,
            notValidAfter: end,
            issuer: rootSubject,
            subject: try DistinguishedName { CommonName(hostnames[0]) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(hostnames.map { GeneralName.dnsName($0) })
            },
            issuerPrivateKey: rootKey
        )
        // rootKey goes out of scope here and is never stored.

        let rootPEM = try root.serializeAsPEM().pemString
        let chain = try server.serializeAsPEM().pemString + "\n" + rootPEM
        guard let rootDER = TrustProfile.derCertificates(fromPEM: rootPEM).first else {
            throw InstallError.noSSL("The certificate could not be encoded.")
        }
        let pack = SSLPack(certificatePEM: chain, privateKeyPEM: serverKey.pemRepresentation,
                           rootDER: rootDER, rootName: rootName, createdAt: now, expiresAt: end)
        try pack.save()
        return pack
    }
}

/// A thread-safe flag set from the server's event loop.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Serves one signed IPA over HTTPS on loopback and triggers the iOS
/// installer through an `itms-services://` link.
final class InstallServer {
    enum Event {
        case manifestRequested
        case payloadStarted
        case payloadSent
        case failed(Error)
    }

    private let app: Application
    private let token = UUID().uuidString.lowercased()
    private let port = Int.random(in: 40000...60000)
    private var running = false
    private var didShutdown = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Set once iOS fetches a manifest, i.e. the install prompt is coming.
    let manifestFetched = OnceFlag()

    init(ipa: URL, bundleIdentifier: String, version: String, title: String, icon: UIImage?,
         ssl: SSLPack, onEvent: @escaping (Event) -> Void) throws {
        // Do not let Vapor parse the host app's launch arguments.
        let environment = Environment(name: "production", arguments: ["xsign"])
        app = Application(environment)

        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(ssl.certificatePEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(ssl.privateKeyPEM.utf8), format: .pem)
        app.http.server.configuration.tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        // Loopback only: the IPA is never exposed to the local network.
        app.http.server.configuration.address = .hostname("127.0.0.1", port: port)
        app.http.server.configuration.tcpNoDelay = true

        // One manifest per hostname, so the IPA is fetched from the same name.
        var manifests: [String: Data] = [:]
        for (index, host) in SSLPack.hostnames.enumerated() {
            let base = Self.baseURL(host: host, port: port, token: token)
            manifests[String(index)] = try InstallManifest.data(
                bundleIdentifier: bundleIdentifier,
                version: version,
                title: title,
                packageURL: base.appendingPathComponent("app.ipa"),
                displayImageURL: base.appendingPathComponent("icon-57.png"),
                fullSizeImageURL: base.appendingPathComponent("icon-512.png")
            )
        }
        let smallIcon = Self.png(icon, size: 57)
        let largeIcon = Self.png(icon, size: 512)
        let tokenPath = PathComponent.constant(token)
        let fetched = manifestFetched

        app.get(tokenPath, ":host", "manifest.plist") { req -> Response in
            guard let manifest = req.parameters.get("host").flatMap({ manifests[$0] }) else {
                return Response(status: .notFound)
            }
            fetched.set()
            onEvent(.manifestRequested)
            return Response(status: .ok, headers: ["Content-Type": "text/xml"], body: .init(data: manifest))
        }
        app.get(tokenPath, "icon-57.png") { _ -> Response in
            Response(status: .ok, headers: ["Content-Type": "image/png"], body: .init(data: smallIcon))
        }
        app.get(tokenPath, "icon-512.png") { _ -> Response in
            Response(status: .ok, headers: ["Content-Type": "image/png"], body: .init(data: largeIcon))
        }
        app.get(tokenPath, "app.ipa") { req -> Response in
            onEvent(.payloadStarted)
            let response = req.fileio.streamFile(at: ipa.path) { result in
                switch result {
                case .success: onEvent(.payloadSent)
                case .failure(let error): onEvent(.failed(error))
                }
            }
            response.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
            return response
        }
    }

    deinit { stop() }

    func manifestURL(hostIndex: Int) -> URL {
        Self.baseURL(host: SSLPack.hostnames[hostIndex], port: port, token: token)
            .appendingPathComponent(String(hostIndex))
            .appendingPathComponent("manifest.plist")
    }

    func start() throws {
        guard !running else { return }
        try app.server.start()
        running = true
        // Keep serving for a while if the user leaves XSign during install.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "xsign.install") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    @MainActor
    func openInstaller(hostIndex: Int) async -> Bool {
        guard let url = InstallManifest.installURL(manifestURL: manifestURL(hostIndex: hostIndex)) else { return false }
        return await UIApplication.shared.open(url)
    }

    func stop() {
        if running {
            running = false
            app.server.shutdown()
        }
        if !didShutdown {
            didShutdown = true
            app.shutdown()
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
    }

    private static func baseURL(host: String, port: Int, token: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        components.path = "/\(token)"
        return components.url!
    }

    private static func png(_ image: UIImage?, size: CGFloat) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.pngData { context in
            if let image {
                image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
            } else {
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
    }
}

/// Serves the trust profile over plain HTTP on loopback, so Safari can hand
/// it to iOS (profiles can't be installed from inside an app).
final class ProfileServer {
    private let app: Application
    private let port = Int.random(in: 40000...60000)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var running = false
    private var didShutdown = false

    init(profile: Data) {
        app = Application(Environment(name: "production", arguments: ["xsign"]))
        app.http.server.configuration.address = .hostname("127.0.0.1", port: port)
        app.get("xsign-install.mobileconfig") { _ -> Response in
            Response(status: .ok,
                     headers: ["Content-Type": TrustProfile.contentType,
                               "Content-Disposition": "attachment; filename=xsign-install.mobileconfig"],
                     body: .init(data: profile))
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/xsign-install.mobileconfig")! }

    deinit { stop() }

    func start() throws {
        try app.server.start()
        running = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "xsign.profile") { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        if running {
            running = false
            app.server.shutdown()
        }
        if !didShutdown {
            didShutdown = true
            app.shutdown()
        }
        let task = backgroundTask
        backgroundTask = .invalid
        if task != .invalid { DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) } }
    }
}
