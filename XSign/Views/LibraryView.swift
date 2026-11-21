import SwiftUI
import UniformTypeIdentifiers
import XSignCore

extension UTType {
    static let ipa = UTType(importedAs: "com.apple.itunes.ipa", conformingTo: .data)
    static let mobileProvision = UTType(importedAs: "com.apple.mobileprovision", conformingTo: .data)
}

/// Apps XSign holds: signed copies ready to install, re-sign or share,
/// plus IPAs imported from Files.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    @State private var importError: String?
    @State private var busyImporting = false
    @State private var showingURLImport = false

    private var signed: [LibraryItem] { model.library.filter(\.hasSignedCopy) }
    private var unsigned: [LibraryItem] { model.library.filter { !$0.hasSignedCopy } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "Library", trailing: {
                        if busyImporting {
                            ProgressView().frame(width: 46, height: 46)
                        } else {
                            Menu {
                                Button { model.selectedTab = .repos } label: {
                                    Label("From a Repo or Source", systemImage: "folder.badge.plus")
                                }
                                Button { importing = true } label: { Label("Import from Files", systemImage: "doc") }
                                Button { showingURLImport = true } label: { Label("Download from URL", systemImage: "link") }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 46, height: 46)
                                    .background(Theme.card, in: Circle())
                                    .overlay(Circle().stroke(Theme.stroke))
                            }
                        }
                    })

                    if model.library.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(Theme.accent)
                                Text("Library is empty").font(.title3.bold())
                                Text("Apps you get from a repo or source land here, signed and ready to reinstall or share. You can also add an .ipa from Files or a direct link with +.")
                                    .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !signed.isEmpty {
                        SectionLabel("Signed apps")
                        ForEach(signed) { LibraryCard(item: $0) }
                    }
                    if !unsigned.isEmpty {
                        SectionLabel("Not signed yet")
                        ForEach(unsigned) { LibraryCard(item: $0) }
                    }
                    if let name = model.activeCertificate?.name {
                        Text("Signing with \(name).").font(Theme.mono(.caption)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                // .data as well: some iOS versions don't map .ipa to a type, which
                // would grey the file out. Non-IPAs are rejected on import.
                .documentPicker(isPresented: $importing, contentTypes: [.ipa, .zip, .data]) { urls in
                    Task {
                        busyImporting = true
                        defer { busyImporting = false }
                        for url in urls {
                            do { try await model.importIPA(from: url) } catch { importError = error.localizedDescription }
                            try? FileManager.default.removeItem(at: url) // our private copy
                        }
                    }
                }
            }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingURLImport) { URLImportView() }
            .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }
}

struct LibraryCard: View {
    @EnvironmentObject private var model: AppModel
    let item: LibraryItem
    @State private var confirmDelete = false

    var body: some View {
        let phase = model.phase(for: item.jobKey)
        let entry = item.catalogKey.flatMap(model.entry(forKey:))
        Card(padding: 14) {
            HStack(spacing: 12) {
                AppIconView(name: item.name, iconFileName: item.iconFileName, iconURL: entry?.app.iconURL,
                            tintHex: entry?.app.tintHex, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Text("v\(item.displayVersion)").font(Theme.mono(.caption)).foregroundStyle(.secondary)
                    Text(item.signedBundleIdentifier ?? item.bundleIdentifier)
                        .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if let phase {
                        PhaseText(phase: phase) { model.dismissPhase(item.jobKey) }
                    } else if let certificate = item.signedCertificateName {
                        Label(certificate, systemImage: "checkmark.seal")
                            .font(Theme.mono(.caption)).foregroundStyle(Theme.beta).lineLimit(1)
                    } else if let source = item.sourceName {
                        Label(source, systemImage: "shippingbox")
                            .font(Theme.mono(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let phase, phase.isBusy {
                    Button { model.cancel(item.jobKey) } label: {
                        ZStack {
                            ProgressRing(progress: phase.progress)
                            Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                        .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        SquareIconButton(systemImage: "arrow.down.app", prominent: true) { model.install(item.id) }
                            .accessibilityLabel("Install")
                        SquareIconButton(systemImage: "arrow.triangle.2.circlepath") { model.resign(item.id) }
                            .accessibilityLabel("Re-sign and install")
                        if let url = model.shareURL(for: item) {
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 44, height: 44)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.stroke))
                            }
                            .accessibilityLabel("Share IPA")
                        }
                    }
                }
            }
        }
        .contextMenu {
            Button { model.install(item.id) } label: { Label("Install", systemImage: "arrow.down.app") }
            Button { model.resign(item.id) } label: { Label("Re-sign & Install", systemImage: "arrow.triangle.2.circlepath") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
        }
        .confirmationDialog("Delete \(item.name) from XSign?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteLibraryItem(item.id) }
        } message: {
            Text("Removes XSign's copies of the IPA. The app on your Home Screen is not touched.")
        }
    }
}

/// Download an .ipa from a direct link into the Library.
struct URLImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var progress: Double?
    @State private var error: String?

    private var url: URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/App.ipa", text: $input, axis: .vertical)
                        .font(Theme.mono(.body))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { input = first }
                    }
                } footer: {
                    Text("For a one-off .ipa link. To keep an app updated, add its GitHub repo or source on the Repos tab instead.")
                }
                if let progress {
                    Section {
                        ProgressView(value: progress) { Text("Downloading \(Int(progress * 100))%").font(Theme.mono(.caption)) }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                }
            }
            .font(Theme.mono(.body))
            .navigationTitle("Download IPA")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") { Task { await download() } }
                        .disabled(url == nil || progress != nil)
                }
            }
        }
    }

    private func download() async {
        guard let url else { return }
        error = nil
        progress = 0
        do {
            try await model.importIPA(fromRemote: url) { progress = $0 }
            Haptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            progress = nil
        }
    }
}
