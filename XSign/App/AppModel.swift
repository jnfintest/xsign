import Foundation
import SwiftUI
import UIKit
import XSignCore

/// Progress of a download/sign/install job, shown on buttons and rows.
enum JobPhase: Equatable {
    case downloading(Double)
    case preparing
    case signing
    case waitingForPrompt
    case installing
    case finished
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .finished, .failed: return false
        default: return true
        }
    }

    var label: String {
        switch self {
        case .downloading(let p): return p > 0 ? "Downloading \(Int(p * 100))%" : "Downloading…"
        case .preparing: return "Preparing…"
        case .signing: return "Signing…"
        case .waitingForPrompt: return "Confirm the install prompt"
        case .installing: return "Installing…"
        case .finished: return "Sent to iOS"
        case .failed(let message): return message
        }
    }

    var progress: Double? {
        switch self {
        case .downloading(let p): return p * 0.6
        case .preparing: return 0.65
        case .signing: return 0.75
        case .waitingForPrompt: return 0.85
        case .installing: return 0.95
        case .finished: return 1
        case .failed: return nil
        }
    }
}

enum InstallError: LocalizedError {
    case couldNotOpenInstaller
    case timedOut
    case noSSL(String)
    case missingOriginal

    var errorDescription: String? {
        switch self {
        case .couldNotOpenInstaller: return "iOS refused to open the installer."
        case .timedOut: return "The install wasn't confirmed in time. Try again."
        case .noSSL(let reason): return "Couldn't fetch the local install certificate: \(reason)"
        case .missingOriginal: return "The original IPA is missing. Get the app again from its source."
        }
    }
}

/// An app offered by one of the sources, with the source it came from.
struct CatalogEntry: Identifiable, Hashable {
    let source: SourceRecord
    let app: CatalogApp

    var key: String { "\(source.id.uuidString)|\(app.id)" }
    var id: String { key }
}

/// A library item with a newer release waiting in its source.
struct PendingUpdate: Identifiable, Hashable {
    let item: LibraryItem
    let entry: CatalogEntry
    let release: ReleaseInfo
    var id: UUID { item.id }
}

enum AppTab: String, CaseIterable, Hashable {
    case repos, apps, home, library, settings

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .repos: return "folder.fill"
        case .apps: return "square.grid.2x2.fill"
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sources: [SourceRecord] = []
    @Published private(set) var catalogs: [UUID: SourceCatalog] = [:]
    @Published var library: [LibraryItem] = []
    @Published var certificates: [CertificateRecord] = []
    @Published var activeCertificateID: UUID?
    @Published var settings = AppSettings() { didSet { persist() } }
    @Published private(set) var rateLimit: RateLimit?
    @Published private(set) var phases: [String: JobPhase] = [:]
    @Published private(set) var refreshingSources: Set<UUID> = []
    @Published var sslPack: SSLPack?
    @Published var selectedTab: AppTab = .home
    /// Set by deep links (`xsign://add?url=…`) to open the add-source sheet.
    @Published var pendingSourceInput: String?

    private var jobs: [String: Task<Void, Never>] = [:]
    private var servers: [String: InstallServer] = [:]
    /// Continuations waiting for iOS to fetch the IPA, tagged with a token so a
    /// stale timeout can't cancel a newer attempt.
    private var installWaiters: [String: (token: UUID, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var isLoading = true

    init() {
        let state = StateStore.load()
        sources = state.sources
        library = state.library
        certificates = state.certificates
        activeCertificateID = state.activeCertificateID
        settings = state.settings
        rateLimit = state.rateLimit
        catalogs = StateStore.loadCatalogs()
        sslPack = SSLPack.load()
        AppPaths.clearWork()
        isLoading = false
    }

    func persist() {
        guard !isLoading else { return }
        StateStore.save(PersistedState(sources: sources, library: library, certificates: certificates,
                                       activeCertificateID: activeCertificateID, settings: settings,
                                       rateLimit: rateLimit))
    }

    // MARK: - Derived data

    var activeCertificate: CertificateRecord? {
        certificates.first { $0.id == activeCertificateID } ?? certificates.first
    }

    var hasGitHubToken: Bool { !(Keychain.get(Keychain.githubTokenKey) ?? "").isEmpty }

    var isRefreshing: Bool { !refreshingSources.isEmpty }

    /// Every app from every source, sorted by name.
    var allEntries: [CatalogEntry] {
        sources.flatMap { source in
            (catalogs[source.id]?.apps ?? []).map { CatalogEntry(source: source, app: $0) }
        }
        .sorted { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
    }

    func entries(in sourceID: UUID) -> [CatalogEntry] {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return [] }
        return (catalogs[sourceID]?.apps ?? []).map { CatalogEntry(source: source, app: $0) }
    }

    func entry(forKey key: String) -> CatalogEntry? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let sourceID = UUID(uuidString: parts[0]),
              let source = sources.first(where: { $0.id == sourceID }),
              let app = catalogs[sourceID]?.apps.first(where: { $0.id == parts[1] }) else { return nil }
        return CatalogEntry(source: source, app: app)
    }

    func libraryItem(for entry: CatalogEntry) -> LibraryItem? {
        library.first { $0.catalogKey == entry.key }
    }

    func latestRelease(for entry: CatalogEntry) -> ReleaseInfo? {
        entry.app.latest(includeBetas: settings.includeBetaUpdates) ?? entry.app.versions.first
    }

    var pendingUpdates: [PendingUpdate] {
        library.compactMap { item in
            guard let key = item.catalogKey, let entry = entry(forKey: key),
                  let release = entry.app.latest(includeBetas: settings.includeBetaUpdates),
                  item.installed != nil, release.isUpdate(over: item.installed) else { return nil }
            return PendingUpdate(item: item, entry: entry, release: release)
        }
    }

    func hasUpdate(_ entry: CatalogEntry) -> Bool {
        pendingUpdates.contains { $0.entry.key == entry.key }
    }

    func phase(for key: String) -> JobPhase? { phases[key] }

    // MARK: - Sources

    /// Fetches a source without adding it (for the add-source preview).
    func fetchCatalog(_ kind: SourceKind) async throws -> SourceCatalog {
        switch kind {
        case .github(let github):
            let (catalog, rate) = try await GitHubReleaseClient(token: Keychain.get(Keychain.githubTokenKey))
                .catalog(for: github)
            if let rate { rateLimit = rate; persist() }
            return catalog
        case .feed(let feed):
            return try await FeedClient(token: Keychain.get(Keychain.feedTokenKey)).catalog(for: feed)
        }
    }

    func isAdded(_ kind: SourceKind) -> Bool { sources.contains { $0.kind == kind } }

    /// Adds a source (or finds the existing one) and returns its id.
    @discardableResult
    func addSource(_ kind: SourceKind, catalog: SourceCatalog?) -> UUID {
        if let existing = sources.first(where: { $0.kind == kind }) { return existing.id }
        var record = SourceRecord(kind: kind, name: catalog?.name ?? kind.address, iconURL: catalog?.iconURL)
        if let catalog {
            catalogs[record.id] = catalog
            record.lastRefreshed = Date()
            StateStore.saveCatalogs(catalogs)
        }
        sources.append(record)
        persist()
        if catalog == nil { Task { await refresh(record.id) } }
        return record.id
    }

    /// Paste-and-go: add the source if needed, then get one of its apps.
    func addSourceAndGet(_ kind: SourceKind, catalog: SourceCatalog, appID: String) -> String? {
        let sourceID = addSource(kind, catalog: catalog)
        guard let entry = entries(in: sourceID).first(where: { $0.app.id == appID }) else { return nil }
        get(entry)
        return entry.key
    }

    func removeSource(_ id: UUID) {
        sources.removeAll { $0.id == id }
        catalogs[id] = nil
        StateStore.saveCatalogs(catalogs)
        // Apps already in the library stay; they just stop getting updates.
        persist()
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    func refresh(_ id: UUID) async {
        guard let source = sources.first(where: { $0.id == id }), !refreshingSources.contains(id) else { return }
        refreshingSources.insert(id)
        defer { refreshingSources.remove(id) }
        do {
            let catalog = try await fetchCatalog(source.kind)
            catalogs[id] = catalog
            StateStore.saveCatalogs(catalogs)
            update(source: id) {
                $0.name = catalog.name
                $0.iconURL = catalog.iconURL ?? $0.iconURL
                $0.lastError = nil
                $0.lastRefreshed = Date()
            }
        } catch {
            update(source: id) {
                $0.lastError = error.localizedDescription
                $0.lastRefreshed = Date()
            }
        }
    }

    /// Refreshes every source. Returns updates that weren't pending before
    /// (used for notifications).
    @discardableResult
    func refreshAll() async -> [PendingUpdate] {
        let before = Set(pendingUpdates.map { "\($0.item.id)|\($0.release.id)" })
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.refresh(source.id) }
            }
        }
        return pendingUpdates.filter { !before.contains("\($0.item.id)|\($0.release.id)") }
    }

    func refreshRateLimit() async {
        if let rate = try? await GitHubReleaseClient(token: Keychain.get(Keychain.githubTokenKey)).rateLimit() {
            rateLimit = rate
            persist()
        }
    }

    private func update(source id: UUID, _ change: (inout SourceRecord) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[index])
        persist()
    }

    // MARK: - Jobs

    /// Download (a specific or the newest) release of a source app, sign it
    /// and install it. Also how updates run.
    func get(_ entry: CatalogEntry, release: ReleaseInfo? = nil) {
        let key = entry.key
        guard jobs[key] == nil, let release = release ?? latestRelease(for: entry) else { return }
        start(key) { model in try await model.runGet(entry: entry, release: release) }
    }

    func update(_ pending: PendingUpdate) { get(pending.entry, release: pending.release) }

    /// iOS shows one install prompt at a time, so updates run one after another.
    func updateAll() {
        let queue = pendingUpdates
        guard !queue.isEmpty else { return }
        Task { [weak self] in
            for pending in queue {
                guard let self else { return }
                self.update(pending)
                await self.jobs[pending.entry.key]?.value
            }
        }
    }

    /// Install the signed copy again (re-signing first if the certificate changed).
    func install(_ itemID: UUID) {
        guard let item = library.first(where: { $0.id == itemID }), jobs[item.jobKey] == nil else { return }
        let needsSigning = !item.hasSignedCopy || item.signedCertificateID != activeCertificate?.id
        start(item.jobKey) { model in
            if needsSigning {
                try await model.signAndInstall(itemID: itemID, release: item.originalRelease)
            } else {
                try await model.serve(itemID: itemID, release: item.originalRelease)
            }
        }
    }

    /// Sign the original IPA again with the active certificate, then install.
    func resign(_ itemID: UUID) {
        guard let item = library.first(where: { $0.id == itemID }), jobs[item.jobKey] == nil else { return }
        start(item.jobKey) { model in try await model.signAndInstall(itemID: itemID, release: item.originalRelease) }
    }

    func cancel(_ key: String) {
        jobs[key]?.cancel()
        jobs[key] = nil
        installWaiters.removeValue(forKey: key)?.continuation.resume(throwing: CancellationError())
        servers.removeValue(forKey: key)?.stop()
        phases[key] = nil
    }

    func dismissPhase(_ key: String) {
        if phases[key]?.isBusy == false { phases[key] = nil }
    }

    private func start(_ key: String, _ work: @escaping @MainActor (AppModel) async throws -> Void) {
        phases[key] = .preparing
        jobs[key] = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch is CancellationError {
                self.phases[key] = nil
            } catch {
                self.servers.removeValue(forKey: key)?.stop()
                self.phases[key] = .failed(error.localizedDescription)
                Haptics.error()
            }
            self.jobs[key] = nil
        }
    }

    private func runGet(entry: CatalogEntry, release: ReleaseInfo) async throws {
        let key = entry.key
        guard let certificate = activeCertificate else { throw SigningError.noCertificate }
        _ = try Signer.credentials(for: certificate)

        phases[key] = .downloading(0)
        let request: URLRequest
        switch entry.source.kind {
        case .github:
            request = GitHubReleaseClient(token: Keychain.get(Keychain.githubTokenKey)).downloadRequest(for: release.asset)
        case .feed(let feed):
            var r = URLRequest(url: release.asset.downloadURL)
            if feed.useToken, let token = Keychain.get(Keychain.feedTokenKey), !token.isEmpty {
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request = r
        }
        let work = AppPaths.newWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let downloaded = try await Downloader.download(
            request, to: work.appendingPathComponent("download.ipa"),
            expectedSize: release.asset.size, sha256: release.asset.sha256
        ) { [weak self] progress in
            Task { @MainActor in
                guard let self, case .downloading = self.phases[key] else { return }
                self.phases[key] = .downloading(progress)
            }
        }
        try Task.checkCancellation()

        // Store the original in the library (replacing an older one).
        phases[key] = .preparing
        let existing = libraryItem(for: entry)
        let itemID = existing?.id ?? UUID()
        let info = try await Task.detached(priority: .userInitiated) { () -> (IPAPackage, String?) in
            let package = try IPAPackage.extract(ipa: downloaded, into: work.appendingPathComponent("peek"))
            return (package, package.cacheIcon(named: itemID.uuidString))
        }.value

        var item = existing ?? LibraryItem(id: itemID, name: entry.app.name, bundleIdentifier: info.0.bundleIdentifier,
                                           version: info.0.version, addedAt: Date())
        try FileManager.default.createDirectory(at: item.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: item.signedURL.path) {
            try? FileManager.default.removeItem(at: item.signedURL)
        }
        if FileManager.default.fileExists(atPath: item.originalURL.path) {
            try FileManager.default.removeItem(at: item.originalURL)
        }
        try FileManager.default.moveItem(at: downloaded, to: item.originalURL)

        item.catalogKey = entry.key
        item.sourceName = entry.source.name
        item.name = entry.app.name
        item.bundleIdentifier = info.0.bundleIdentifier
        item.version = info.0.version
        item.build = info.0.build
        item.fileSize = (try? item.originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        item.iconFileName = info.1 ?? item.iconFileName
        item.originalRelease = release
        item.signedAt = nil
        upsert(item)

        try await signAndInstall(itemID: item.id, release: release)
    }

    /// Unpack the item's original IPA, sign it, keep the signed copy, install.
    private func signAndInstall(itemID: UUID, release: ReleaseInfo?) async throws {
        guard let item = library.first(where: { $0.id == itemID }) else { return }
        let key = item.jobKey
        guard let certificate = activeCertificate else { throw SigningError.noCertificate }
        let credentials = try Signer.credentials(for: certificate)
        guard FileManager.default.fileExists(atPath: item.originalURL.path) else { throw InstallError.missingOriginal }

        phases[key] = .preparing
        let work = AppPaths.newWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let original = item.originalURL
        let signedURL = item.signedURL
        // Apps from a source keep their bundle ID: iOS ties their data to it.
        let lock = item.catalogKey != nil
        let unpacked = try await Task.detached(priority: .userInitiated) {
            try IPAPackage.extract(ipa: original, into: work.appendingPathComponent("unpacked", isDirectory: true))
        }.value
        try Task.checkCancellation()

        phases[key] = .signing
        let bundleID = try await Task.detached(priority: .userInitiated) { () -> String in
            var package = unpacked
            let bundleID = try Signer.sign(&package, with: credentials, bundleIdentifierOverride: nil,
                                           lockBundleIdentifier: lock)
            try package.repackage(to: signedURL)
            return bundleID
        }.value
        try Task.checkCancellation()

        modify(itemID) {
            $0.signedBundleIdentifier = bundleID
            $0.signedCertificateID = certificate.id
            $0.signedCertificateName = certificate.name
            $0.signedAt = Date()
        }
        try await serve(itemID: itemID, release: release)
    }

    /// Serve the item's signed IPA to the iOS installer and wait for it.
    private func serve(itemID: UUID, release: ReleaseInfo?) async throws {
        guard let item = library.first(where: { $0.id == itemID }) else { return }
        let key = item.jobKey
        let ssl = try await ensureSSLPack()

        phases[key] = .waitingForPrompt
        let icon = item.iconFileName.flatMap { UIImage(contentsOfFile: AppPaths.icons.appendingPathComponent($0).path) }
        let server = try InstallServer(
            ipa: item.signedURL,
            bundleIdentifier: item.signedBundleIdentifier ?? item.bundleIdentifier,
            version: item.version,
            title: item.name,
            icon: icon,
            ssl: ssl
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event, key: key) }
        }
        try server.start()
        servers[key] = server

        guard await server.openInstaller() else {
            servers.removeValue(forKey: key)?.stop()
            throw InstallError.couldNotOpenInstaller
        }

        // Wait until iOS has pulled the IPA (or give up after 10 minutes).
        let token = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installWaiters[key] = (token, continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                guard let self, self.installWaiters[key]?.token == token else { return }
                self.installWaiters.removeValue(forKey: key)?.continuation.resume(throwing: InstallError.timedOut)
            }
        }

        modify(itemID) { item in
            if let release {
                item.installed = InstalledRecord(releaseID: release.id, releaseVersion: release.version,
                                                 bundleVersion: item.version, build: item.build ?? release.build)
            } else {
                item.installed = InstalledRecord(releaseID: "local:\(item.version)", releaseVersion: item.version,
                                                 bundleVersion: item.version, build: item.build)
            }
        }
        phases[key] = .finished
        Haptics.success()

        // Give iOS a moment before tearing the server down.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            self?.servers.removeValue(forKey: key)?.stop()
            if self?.phases[key] == .finished { self?.phases[key] = nil }
        }
    }

    private func handle(_ event: InstallServer.Event, key: String) {
        switch event {
        case .manifestRequested:
            break
        case .payloadStarted:
            phases[key] = .installing
        case .payloadSent:
            installWaiters.removeValue(forKey: key)?.continuation.resume()
        case .failed(let error):
            installWaiters.removeValue(forKey: key)?.continuation.resume(throwing: error)
        }
    }

    // MARK: - Library

    private func upsert(_ item: LibraryItem) {
        if let index = library.firstIndex(where: { $0.id == item.id }) {
            library[index] = item
        } else {
            library.insert(item, at: 0)
        }
        persist()
    }

    private func modify(_ id: UUID, _ change: (inout LibraryItem) -> Void) {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        change(&library[index])
        persist()
    }

    /// Mark what is on the phone when it was installed some other way.
    func markInstalled(_ entry: CatalogEntry, release: ReleaseInfo) {
        if let item = libraryItem(for: entry) {
            modify(item.id) {
                $0.installed = InstalledRecord(releaseID: release.id, releaseVersion: release.version, build: release.build)
            }
        } else {
            // Track it without an IPA yet; the next update downloads one.
            var item = LibraryItem(id: UUID(), name: entry.app.name,
                                   bundleIdentifier: entry.app.bundleIdentifier ?? "", version: release.version,
                                   addedAt: Date())
            item.catalogKey = entry.key
            item.sourceName = entry.source.name
            item.build = release.build
            item.installed = InstalledRecord(releaseID: release.id, releaseVersion: release.version, build: release.build)
            upsert(item)
        }
    }

    func importIPA(from url: URL) async throws {
        let id = UUID()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var item = LibraryItem(id: id, name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: "",
                               version: "", addedAt: Date())
        let directory = item.directory
        let original = item.originalURL
        let peek = try await Task.detached(priority: .userInitiated) { () -> (String, String, String, String?, String?, Int64?) in
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: original)
            let work = AppPaths.newWorkDirectory()
            defer { try? fm.removeItem(at: work) }
            let package = try IPAPackage.extract(ipa: original, into: work)
            let size = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return (package.displayName, package.bundleIdentifier, package.version, package.build,
                    package.cacheIcon(named: id.uuidString), size)
        }.value
        item.name = peek.0
        item.bundleIdentifier = peek.1
        item.version = peek.2
        item.build = peek.3
        item.iconFileName = peek.4
        item.fileSize = peek.5
        upsert(item)
    }

    /// Download an .ipa from a direct link into the Library (no source).
    func importIPA(fromRemote url: URL, onProgress: @escaping (Double) -> Void) async throws {
        let work = AppPaths.newWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var request = URLRequest(url: url)
        request.setValue("XSign", forHTTPHeaderField: "User-Agent")
        let name = url.pathExtension.lowercased() == "ipa" ? url.lastPathComponent : "download.ipa"
        let file = try await Downloader.download(request, to: work.appendingPathComponent(name)) { progress in
            Task { @MainActor in onProgress(progress) }
        }
        try await importIPA(from: file)
    }

    func deleteLibraryItem(_ id: UUID) {
        guard let item = library.first(where: { $0.id == id }) else { return }
        cancel(item.jobKey)
        try? FileManager.default.removeItem(at: item.directory)
        if let icon = item.iconFileName { try? FileManager.default.removeItem(at: AppPaths.icons.appendingPathComponent(icon)) }
        library.removeAll { $0.id == id }
        persist()
    }

    /// File to hand to the share sheet: the signed copy, else the original.
    func shareURL(for item: LibraryItem) -> URL? {
        let fm = FileManager.default
        if item.hasSignedCopy { return item.signedURL }
        return fm.fileExists(atPath: item.originalURL.path) ? item.originalURL : nil
    }

    // MARK: - SSL

    func ensureSSLPack() async throws -> SSLPack {
        if let sslPack { return sslPack }
        return try await refreshSSLPack()
    }

    @discardableResult
    func refreshSSLPack() async throws -> SSLPack {
        do {
            let pack = try await SSLPack.download()
            sslPack = pack
            return pack
        } catch {
            throw InstallError.noSSL(error.localizedDescription)
        }
    }

    // MARK: - Certificates

    func importCertificate(p12Data: Data, profileData: Data, password: String) throws {
        let commonName = try Signer.validateP12(p12Data, password: password)
        let profile = try ProvisioningProfile.parse(profileData)

        let record = CertificateRecord(
            id: UUID(),
            name: commonName ?? profile.name,
            teamName: profile.teamName,
            teamIdentifier: profile.teamIdentifier,
            applicationIdentifier: profile.applicationIdentifier,
            expirationDate: profile.expirationDate,
            deviceCount: profile.deviceCount,
            importedAt: Date()
        )
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        try p12Data.write(to: record.p12URL, options: .completeFileProtectionUntilFirstUserAuthentication)
        try profileData.write(to: record.profileURL, options: .completeFileProtectionUntilFirstUserAuthentication)
        Keychain.set(password, for: record.passwordKey)

        certificates.append(record)
        if activeCertificateID == nil { activeCertificateID = record.id }
        persist()
    }

    func selectCertificate(_ id: UUID) {
        activeCertificateID = id
        persist()
    }

    func deleteCertificate(_ id: UUID) {
        guard let record = certificates.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: record.directory)
        Keychain.set(nil, for: record.passwordKey)
        certificates.removeAll { $0.id == id }
        if activeCertificateID == id { activeCertificateID = certificates.first?.id }
        persist()
    }

    // MARK: - Deep links

    /// `xsign://add?url=<source>` opens the add-source sheet;
    /// `xsign://update?bundle=<id>` updates that app. Opened .ipa files are imported.
    func handle(url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "ipa" {
                selectedTab = .library
                Task { try? await importIPA(from: url) }
            }
            return
        }
        guard url.scheme == "xsign" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "add":
            if let source = items.first(where: { $0.name == "url" })?.value {
                selectedTab = .repos
                pendingSourceInput = source
            }
        case "update":
            selectedTab = .home
            let bundle = items.first { $0.name == "bundle" }?.value
            if let pending = pendingUpdates.first(where: {
                $0.item.bundleIdentifier == bundle || $0.item.signedBundleIdentifier == bundle
            }) {
                update(pending)
            }
        default:
            break
        }
    }

    private func readSecurityScoped(_ url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }
}

enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
