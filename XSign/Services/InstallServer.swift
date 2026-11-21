import Foundation
import UIKit
import Vapor
import NIOSSL
import XSignCore

/// TLS material for the local install server. `itms-services` only accepts
/// HTTPS manifests with a publicly trusted certificate, so (like Feather) we
/// use a certificate for a public hostname that resolves to 127.0.0.1.
struct SSLPack: Codable {
    var certificatePEM: String
    var privateKeyPEM: String
    var hostname: String

    static let defaultSourceURL = URL(string: "https://backloop.dev/pack.json")!
    private static var fileURL: URL { AppPaths.ssl.appendingPathComponent("pack.json") }

    static func load() -> SSLPack? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(SSLPack.self, from: data)
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
    }

    static func remove() { try? FileManager.default.removeItem(at: fileURL) }

    /// backloop.dev format: `{ cert, ca, key1, key2, info: { domains: { commonName } } }`.
    private struct RemotePack: Decodable {
        struct Info: Decodable {
            struct Domains: Decodable { let commonName: String }
            let domains: Domains
        }
        let cert: String
        let ca: String?
        let key1: String
        let key2: String
        let info: Info
    }

    static func download(from url: URL = defaultSourceURL) async throws -> SSLPack {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.http(http.statusCode)
        }
        let remote = try JSONDecoder().decode(RemotePack.self, from: data)
        let chain = [remote.cert, remote.ca].compactMap { $0 }.joined(separator: "\n")
        var host = remote.info.domains.commonName
        // A wildcard CN (e.g. *.example.dev) needs a concrete label.
        if host.hasPrefix("*.") { host = "local" + host.dropFirst(1) }
        let pack = SSLPack(certificatePEM: chain, privateKeyPEM: remote.key1 + remote.key2, hostname: host)
        try pack.save()
        return pack
    }

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
    private let hostname: String
    private var running = false
    private var didShutdown = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(ipa: URL, bundleIdentifier: String, version: String, title: String, icon: UIImage?,
         ssl: SSLPack, onEvent: @escaping (Event) -> Void) throws {
        hostname = ssl.hostname

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

        let base = Self.baseURL(host: ssl.hostname, port: port, token: token)
        let manifest = try InstallManifest.data(
            bundleIdentifier: bundleIdentifier,
            version: version,
            title: title,
            packageURL: base.appendingPathComponent("app.ipa"),
            displayImageURL: base.appendingPathComponent("icon-57.png"),
            fullSizeImageURL: base.appendingPathComponent("icon-512.png")
        )
        let smallIcon = Self.png(icon, size: 57)
        let largeIcon = Self.png(icon, size: 512)
        let tokenPath = PathComponent.constant(token)

        app.get(tokenPath, "manifest.plist") { req -> Response in
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

    var manifestURL: URL {
        Self.baseURL(host: hostname, port: port, token: token).appendingPathComponent("manifest.plist")
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
    func openInstaller() async -> Bool {
        guard let url = InstallManifest.installURL(manifestURL: manifestURL) else { return false }
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
