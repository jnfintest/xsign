import SwiftUI
import XSignCore

/// Every app from every source.
struct AppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    private var entries: [CatalogEntry] {
        let all = model.allEntries
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.app.name.localizedCaseInsensitiveContains(query)
                || ($0.app.developer?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.source.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "Apps")
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps", text: $search)
                            .font(Theme.mono(.body))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))

                    if model.sources.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nothing here yet").font(.headline)
                                Text("Apps come from your sources. Add a GitHub repo or a source URL on the Repos tab.")
                                    .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                                Button("Open Repos") { model.selectedTab = .repos }
                                    .font(Theme.mono(.subheadline, weight: .semibold))
                            }
                        }
                    } else if entries.isEmpty {
                        Text(search.isEmpty ? "Your sources don't offer any apps yet." : "No matches.")
                            .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        SectionLabel("\(entries.count) app\(entries.count == 1 ? "" : "s")")
                        VStack(spacing: 10) {
                            ForEach(entries) { entry in
                                NavigationLink(value: entry) { CatalogRow(entry: entry) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshAll() }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CatalogEntry.self) { CatalogAppDetailView(entryKey: $0.key) }
        }
    }
}

/// App card with GET / UPDATE / REINSTALL.
struct CatalogRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: CatalogEntry

    var body: some View {
        let item = model.libraryItem(for: entry)
        let phase = model.phase(for: entry.key)
        let latest = model.latestRelease(for: entry)
        Card(padding: 14) {
            HStack(spacing: 14) {
                AppIconView(name: entry.app.name, iconFileName: item?.iconFileName, iconURL: entry.app.iconURL,
                            tintHex: entry.app.tintHex, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.app.name).font(.headline).lineLimit(1)
                    if let phase {
                        PhaseText(phase: phase) { model.dismissPhase(entry.key) }
                    } else {
                        HStack(spacing: 6) {
                            Text(latest.map { "v\($0.displayVersion)" } ?? "no .ipa")
                                .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                            if latest?.isPrerelease == true { Chip(text: "beta", tint: Theme.beta) }
                        }
                        Label(entry.source.name, systemImage: "shippingbox")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(Theme.beta)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if latest != nil {
                    ActionPill(title: buttonTitle(item), prominent: item?.installed == nil || model.hasUpdate(entry), phase: phase,
                               action: { model.get(entry) }, cancel: { model.cancel(entry.key) })
                }
            }
        }
    }

    private func buttonTitle(_ item: LibraryItem?) -> String {
        guard let item, item.installed != nil else { return "Get" }
        return model.hasUpdate(entry) ? "Update" : "Reinstall"
    }
}

/// Store-style page for one app: what's new, versions, information.
struct CatalogAppDetailView: View {
    @EnvironmentObject private var model: AppModel
    let entryKey: String

    var body: some View {
        ScrollView {
            if let entry = model.entry(forKey: entryKey) {
                content(entry).padding(16)
            } else {
                Text("This app is no longer offered by its source.")
                    .font(Theme.mono(.subheadline)).foregroundStyle(.secondary).padding(32)
            }
        }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ entry: CatalogEntry) -> some View {
        let item = model.libraryItem(for: entry)
        let phase = model.phase(for: entry.key)
        let latest = model.latestRelease(for: entry)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                AppIconView(name: entry.app.name, iconFileName: item?.iconFileName, iconURL: entry.app.iconURL,
                            tintHex: entry.app.tintHex, size: 104)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.app.name).font(.title2.bold())
                    Text(entry.app.developer ?? entry.source.name)
                        .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if latest != nil {
                        ActionPill(title: item?.installed == nil ? "Get" : (model.hasUpdate(entry) ? "Update" : "Reinstall"),
                                   phase: phase, action: { model.get(entry) }, cancel: { model.cancel(entry.key) })
                    }
                }
            }

            if let phase { StatusBanner(phase: phase) { model.dismissPhase(entry.key) } }

            HStack(spacing: 0) {
                stat("INSTALLED", item?.installed?.displayVersion ?? "—")
                Divider().frame(height: 32)
                stat("LATEST", latest?.displayVersion ?? "—")
                Divider().frame(height: 32)
                stat("SIZE", latest?.asset.size?.byteString ?? "—")
            }
            .padding(.vertical, 12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            if let summary = entry.app.subtitle ?? entry.app.summary, !summary.isEmpty {
                Text(summary).font(Theme.mono(.subheadline))
            }

            if let latest {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("What's new")
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("v\(latest.displayVersion)").font(Theme.mono(.subheadline, weight: .semibold))
                                if latest.isPrerelease { Chip(text: "beta", tint: Theme.beta) }
                                Spacer()
                                if let date = latest.publishedAt {
                                    Text(date.relative).font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                }
                            }
                            if let notes = latest.notes, !notes.isEmpty {
                                Text(markdown(notes)).font(.subheadline)
                            } else if let title = latest.title {
                                Text(title).font(.subheadline)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Versions")
                VStack(spacing: 0) {
                    ForEach(entry.app.versions.prefix(15)) { release in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(release.displayVersion).font(Theme.mono(.subheadline, weight: .semibold))
                                    if release.isPrerelease { Chip(text: "beta", tint: Theme.beta) }
                                    if release.id == item?.installed?.releaseID { Chip(text: "installed", tint: .green) }
                                }
                                if let date = release.publishedAt {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                        .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Menu {
                                Button { model.get(entry, release: release) } label: {
                                    Label("Sign & Install This Version", systemImage: "arrow.down.circle")
                                }
                                Button { model.markInstalled(entry, release: release) } label: {
                                    Label("Mark as Installed", systemImage: "checkmark.circle")
                                }
                                if let page = release.pageURL {
                                    Link(destination: page) { Label("Open Release Page", systemImage: "safari") }
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.accent)
                            }
                            .disabled(phase?.isBusy == true)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        Divider().padding(.leading, 14)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Installed some other way? Use Mark as Installed on that version so XSign knows what's on the phone.")
                    .font(Theme.mono(.caption2)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Information")
                VStack(spacing: 0) {
                    infoRow("Source", entry.source.name)
                    infoRow("Address", entry.source.kind.address)
                    infoRow("Bundle ID", item?.bundleIdentifier.nilIfEmpty ?? entry.app.bundleIdentifier ?? "Read on first download")
                    if let signed = item?.signedCertificateName { infoRow("Signed with", signed) }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(Theme.mono(.caption2, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(Theme.mono(.subheadline, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .font(Theme.mono(.footnote))
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            Divider().padding(.leading, 14)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Progress / result banner on detail pages.
struct StatusBanner: View {
    let phase: JobPhase
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch phase {
            case .finished:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title2)
            default:
                ProgressRing(progress: phase.progress).frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phase.label).font(Theme.mono(.subheadline, weight: .semibold))
                if phase == .waitingForPrompt {
                    Text("Tap Install on the iOS prompt. The app lands on your Home Screen.")
                        .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !phase.isBusy {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
