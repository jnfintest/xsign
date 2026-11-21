import SwiftUI
import UniformTypeIdentifiers
import XSignCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ScreenHeader(title: "Settings")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    row("Certificates", icon: "checkmark.seal.fill", tint: model.activeCertificate?.expiryTint ?? .gray,
                        value: model.activeCertificate?.expiryText ?? "None") { CertificatesView() }
                    row("GitHub", icon: "chevron.left.forwardslash.chevron.right", tint: .black,
                        value: model.hasGitHubToken ? "Token set" : "No token") { GitHubSettingsView() }
                    row("Updates", icon: "arrow.down.circle.fill", tint: Theme.accent,
                        value: model.settings.includeBetaUpdates ? "Incl. betas" : "Stable") { UpdateSettingsView() }
                    row("Installer", icon: "lock.shield.fill", tint: .blue,
                        value: model.sslPack == nil ? "Not set up" : "Ready") { InstallerSettingsView() }
                    row("Homelab", icon: "server.rack", tint: .gray, value: "") { HomelabSettingsView() }
                }
                Section {
                    Picker("Appearance", selection: $model.settings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("XSign \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .font(Theme.mono(.caption))
                }
            }
            .font(Theme.mono(.body))
            .screen()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func row<Destination: View>(_ title: String, icon: String, tint: Color, value: String,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                Spacer()
                Text(value).font(Theme.mono(.caption)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Certificates

struct CertificatesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingImport = false

    var body: some View {
        Form {
            Section {
                ForEach(model.certificates) { certificate in
                    Button { model.selectCertificate(certificate.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(certificate.expiryTint).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(certificate.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text([certificate.teamName, certificate.expiryText,
                                      certificate.deviceCount > 0 ? "\(certificate.deviceCount) devices" : nil]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                if let appID = certificate.applicationIdentifier {
                                    Text(appID).font(Theme.mono(.caption2)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if model.activeCertificate?.id == certificate.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.certificates[$0].id }.forEach(model.deleteCertificate)
                }
                Button { showingImport = true } label: { Label("Import Certificate", systemImage: "plus.circle.fill") }
            } footer: {
                Text("A .p12 identity and a .mobileprovision that includes this iPhone. The checked one signs everything. Passwords stay in the keychain.")
            }
        }
        .font(Theme.mono(.body))
        .screen()
        .navigationTitle("Certificates")
        .sheet(isPresented: $showingImport) { CertificateImportView() }
    }
}

// MARK: - GitHub

struct GitHubSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = Keychain.get(Keychain.githubTokenKey) ?? ""
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste the address of a GitHub repository on the Repos tab and XSign reads its releases, so a project that publishes an .ipa updates like any other source.")
                            .font(Theme.mono(.subheadline))
                        Text("Pre-releases are included and marked as betas, so the update rules can leave them alone.")
                            .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                    }
                }

                SectionLabel("Requests")
                Card {
                    if let rate = model.rateLimit {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(rate.remaining)").font(.system(size: 30, weight: .bold, design: .rounded))
                                Text("of \(rate.limit) left this hour").font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(rate.remaining), total: Double(max(rate.limit, 1)))
                                .tint(rate.remaining < rate.limit / 10 ? .orange : Theme.accent)
                            Text("Resets \(rate.resetAt.formatted(date: .omitted, time: .shortened)) · measured \(rate.measuredAt.relative)")
                                .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                            if rate.isAnonymous {
                                Text("No token in use: GitHub allows 60 requests an hour and private repos can't be read.")
                                    .font(Theme.mono(.caption)).foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("Nothing measured yet. Add a GitHub repository as a source and this fills in from the reply.")
                            .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                    }
                }

                SectionLabel("Token")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("ghp_… or github_pat_…", text: $token)
                            .font(Theme.mono(.body))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: token) { _ in saved = false }
                        HStack {
                            Button(saved ? "Saved" : "Save", action: save)
                                .font(Theme.mono(.body, weight: .semibold))
                                .disabled(token == (Keychain.get(Keychain.githubTokenKey) ?? ""))
                            Spacer()
                            if !token.isEmpty {
                                Button("Remove", role: .destructive) { token = ""; save() }
                                    .font(Theme.mono(.caption))
                            }
                        }
                        Text("Kept in the keychain, not in preferences.")
                            .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                    }
                }

                SectionLabel("Making a token")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("On github.com open Settings › Developer settings › Personal access tokens › Fine-grained tokens › Generate new token. Under Repository access pick the private repos XSign should read and give them Contents: Read-only. Public repos need no permissions at all. Copy the token it shows you once and paste it here.")
                            .font(Theme.mono(.subheadline))
                        Link(destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!) {
                            Label("Open the token page", systemImage: "arrow.up.right.square")
                                .font(Theme.mono(.subheadline, weight: .semibold))
                        }
                    }
                }
            }
            .padding(16)
        }
        .screen()
        .navigationTitle("GitHub")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.rateLimit == nil || model.rateLimit!.measuredAt.timeIntervalSinceNow < -300 { await model.refreshRateLimit() } }
    }

    private func save() {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.githubTokenKey)
        saved = true
        Haptics.success()
        Task {
            await model.refreshRateLimit()
            await model.refreshAll()
        }
    }
}

// MARK: - Updates

struct UpdateSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Include betas", isOn: $model.settings.includeBetaUpdates)
            } footer: {
                Text("Off: GitHub pre-releases and beta apps are listed but never offered as updates. On: the newest build wins, beta or not.")
            }
            Section {
                Button("Allow Update Notifications") { Task { await UpdateNotifier.requestAuthorization() } }
            } footer: {
                Text("XSign refreshes every source when opened and periodically in the background, and notifies you with a one-tap Update action.")
            }
        }
        .font(Theme.mono(.body))
        .screen()
        .navigationTitle("Updates")
    }
}

// MARK: - Installer

struct InstallerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Local HTTPS host")
                    Spacer()
                    Text(model.sslPack?.hostname ?? "Not downloaded").font(Theme.mono(.caption)).foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            let pack = try await model.refreshSSLPack()
                            message = "Updated certificate for \(pack.hostname)."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                } label: {
                    HStack {
                        Text(model.sslPack == nil ? "Download Certificate" : "Refresh Certificate")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                if let message { Text(message).font(Theme.mono(.caption)).foregroundStyle(.secondary) }
            } footer: {
                Text("iOS only installs from HTTPS. XSign serves the signed app from 127.0.0.1 with a public certificate for a loopback hostname (backloop.dev), then hands over to the iOS installer. Refresh it if installs start failing.")
            }
            Section {
                Button("Clear Temporary Files") { AppPaths.clearWork() }
            }
        }
        .font(Theme.mono(.body))
        .screen()
        .navigationTitle("Installer")
    }
}

// MARK: - Homelab

struct HomelabSettingsView: View {
    @State private var feedToken = Keychain.get(Keychain.feedTokenKey) ?? ""

    var body: some View {
        Form {
            Section {
                SecureField("Feed token (optional)", text: $feedToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save") {
                    Keychain.set(feedToken.trimmingCharacters(in: .whitespacesAndNewlines), for: Keychain.feedTokenKey)
                    Haptics.success()
                }
            } footer: {
                Text("Any source URL on your network works on the Repos tab, e.g. https://nas.local/apps/source.json in AltStore or XSign feed format. This token is sent as a Bearer header to sources set to use it.")
            }
        }
        .font(Theme.mono(.body))
        .screen()
        .navigationTitle("Homelab")
    }
}

/// Import a .p12 + .mobileprovision pair.
struct CertificateImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct PickedFile {
        let name: String
        let data: Data
    }

    @State private var p12: PickedFile?
    @State private var profile: PickedFile?
    @State private var password = ""
    @State private var showPicker = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileRow(title: "Certificate (.p12)", file: p12)
                    fileRow(title: "Provisioning Profile", file: profile)
                    SecureField("Certificate password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Tap each row and pick the file. A single tap on a file picks it. XSign tells the .p12 and the profile apart by themselves. Export the .p12 from Keychain Access (or your signing service), and get the profile from the Apple Developer portal.")
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Import Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: importFiles).disabled(p12 == nil || profile == nil)
                }
            }
            .documentPicker(isPresented: $showPicker, contentTypes: [.pkcs12, .mobileProvision, .data],
                            onPick: handlePicked)
        }
    }

    private func fileRow(title: String, file: PickedFile?) -> some View {
        Button { error = nil; showPicker = true } label: {
            HStack {
                Image(systemName: file == nil ? "doc.badge.plus" : "checkmark.circle.fill")
                    .foregroundStyle(file == nil ? Theme.accent : Color.green)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(file?.name ?? "Choose…")
                    .font(Theme.mono(.caption))
                    .foregroundStyle(file == nil ? Theme.accent : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func handlePicked(_ urls: [URL]) {
        var unknown: [String] = []
        for url in urls {
            defer { try? FileManager.default.removeItem(at: url) } // our private copy
            guard let data = try? Data(contentsOf: url) else {
                unknown.append(url.lastPathComponent)
                continue
            }
            let file = PickedFile(name: url.lastPathComponent, data: data)
            switch url.pathExtension.lowercased() {
            case "p12", "pfx":
                p12 = file
            case "mobileprovision", "provisionprofile":
                profile = file
            default:
                // No telling extension: a profile contains a plist, a .p12 doesn't.
                if (try? ProvisioningProfile.parse(data)) != nil { profile = file } else { p12 = file }
            }
        }
        error = unknown.isEmpty ? nil : "Couldn't read \(unknown.joined(separator: ", "))."
    }

    private func importFiles() {
        guard let p12, let profile else { return }
        do {
            try model.importCertificate(p12Data: p12.data, profileData: profile.data, password: password)
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
