import SwiftUI
import XSignCore

/// Browse what your sources offer. Like Feather, it doesn't list every app
/// at once: each source shows its newest few with See All, and search covers
/// everything, a page at a time.
struct AppsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    private static let previewCount = 4

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "Apps")
                    SearchField(prompt: "Search \(model.index.count) apps", text: $search)
                    content
                }
                .padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refreshAll() }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CatalogEntry.self) { CatalogAppDetailView(entryKey: $0.key) }
            .navigationDestination(for: UUID.self) { SourceDetailView(sourceID: $0) }
        }
    }

    @ViewBuilder
    private var content: some View {
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
        } else if !query.isEmpty {
            CatalogResultsList(query: query, sourceID: nil)
        } else if !model.catalogsLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.sources) { source in
                    sourceSection(source)
                }
            }
        }
    }

    @ViewBuilder
    private func sourceSection(_ source: SourceRecord) -> some View {
        let count = model.index.count(in: source.id)
        NavigationLink(value: source.id) {
            HStack(spacing: 10) {
                AppIconView(name: source.name, iconURL: source.iconURL, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.headline).lineLimit(1)
                    Text("\(count) app\(count == 1 ? "" : "s")")
                        .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if count > Self.previewCount {
                    Text("See All").font(Theme.mono(.caption, weight: .bold)).foregroundStyle(Theme.accent)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        let newest = model.index.newest(in: source.id, limit: Self.previewCount)
        if newest.isEmpty {
            Text(model.refreshingSources.contains(source.id) ? "Loading…" : (source.lastError ?? "No installable apps."))
                .font(Theme.mono(.caption)).foregroundStyle(.secondary).padding(.horizontal, 4)
        } else {
            ForEach(newest) { entry in
                NavigationLink(value: entry) { CatalogRow(entry: entry) }.buttonStyle(.plain)
            }
        }
    }
}

/// Search box used on the Apps tab and source pages.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .font(Theme.mono(.body))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

/// Apps matching a query (in one source or all), a page at a time. Matching
/// runs off the main thread, so typing stays smooth with huge sources. Put it
/// in a lazy stack inside a ScrollView.
struct CatalogResultsList: View {
    @EnvironmentObject private var model: AppModel
    let query: String
    let sourceID: UUID?

    /// Matches are positions in the index they were computed against, which
    /// is kept with them: after a refresh the old list stays on screen until
    /// the new one is ready, instead of collapsing.
    @State private var results: (index: CatalogIndex, matches: [Int], query: Query)?
    @State private var limit = Self.pageSize

    static let pageSize = 50

    private struct Query: Hashable, Sendable {
        let text: String
        let sourceID: UUID?
    }

    private struct SearchKey: Hashable {
        let query: Query
        let indexID: UUID
    }

    var body: some View {
        let current = Query(text: query, sourceID: sourceID)
        let index = model.index
        LazyVStack(alignment: .leading, spacing: 10) {
            if let results {
                let matches = results.matches
                if matches.isEmpty {
                    Text(query.isEmpty ? "No installable apps found yet." : "No matches.")
                        .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    SectionLabel(query.isEmpty
                                 ? "\(matches.count) app\(matches.count == 1 ? "" : "s")"
                                 : "\(matches.count) match\(matches.count == 1 ? "" : "es")")
                    ForEach(results.index.entries(at: matches.prefix(limit))) { entry in
                        NavigationLink(value: entry) { CatalogRow(entry: entry) }.buttonStyle(.plain)
                    }
                    if matches.count > limit {
                        // Reaching the end of the page loads the next one.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .onAppear { limit += Self.pageSize }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 16)
            }
        }
        .task(id: SearchKey(query: current, indexID: index.id)) {
            let queryChanged = results?.query != current
            // Wait for typing to pause before searching.
            if queryChanged && results != nil && !current.text.isEmpty {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
            }
            let found = await Task.detached(priority: .userInitiated) {
                index.search(current.text, in: current.sourceID)
            }.value
            guard !Task.isCancelled else { return }
            if queryChanged { limit = Self.pageSize }
            results = (index, found, current)
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
            } else if !model.catalogsLoaded {
                ProgressView().padding(32)
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
