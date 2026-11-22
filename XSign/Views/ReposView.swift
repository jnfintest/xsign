import SwiftUI
import XSignCore

/// The sources XSign pulls apps from: GitHub repos and JSON sources.
struct ReposView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false
    @State private var addInput = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Repos", leading: {
                        CircleButton(systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                            .opacity(model.sources.isEmpty ? 0 : 1)
                    }, trailing: {
                        CircleButton(systemImage: "plus") { addInput = ""; showingAdd = true }
                    })

                    if model.sources.isEmpty {
                        emptyState
                    } else {
                        SectionLabel("\(model.sources.count) source\(model.sources.count == 1 ? "" : "s")",
                                     trailing: model.isRefreshing ? AnyView(ProgressView()) : nil)
                        ForEach(model.sources) { source in
                            NavigationLink(value: source.id) { SourceCard(source: source) }
                                .buttonStyle(.plain)
                                .contextMenu { menu(for: source) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .refreshable { await model.refreshAll() }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { SourceDetailView(sourceID: $0) }
            .navigationDestination(for: CatalogEntry.self) { CatalogAppDetailView(entryKey: $0.key) }
            .sheet(isPresented: $showingAdd) { AddSourceView(initialInput: addInput) }
            .onChange(of: model.pendingSourceInput) { input in
                guard let input else { return }
                addInput = input
                model.pendingSourceInput = nil
                showingAdd = true
            }
        }
    }

    private var emptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(Theme.accent)
                Text("No sources yet").font(.title3.bold())
                Text("Add a GitHub repository that publishes an .ipa in its releases, or any AltStore / Feather-style source URL. Browse and search their apps under Apps.")
                    .font(Theme.mono(.subheadline))
                    .foregroundStyle(.secondary)
                Button { showingAdd = true } label: {
                    Label("Add Source", systemImage: "plus")
                        .font(Theme.mono(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func menu(for source: SourceRecord) -> some View {
        Button { Task { await model.refresh(source.id) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        Button { UIPasteboard.general.string = source.kind.address } label: { Label("Copy Address", systemImage: "doc.on.doc") }
        Button(role: .destructive) { model.removeSource(source.id) } label: { Label("Remove", systemImage: "trash") }
    }
}

struct SourceCard: View {
    @EnvironmentObject private var model: AppModel
    let source: SourceRecord

    var body: some View {
        let appCount = model.appCount(in: source.id)
        Card {
            HStack(spacing: 14) {
                AppIconView(name: source.name, iconURL: source.iconURL, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.headline).lineLimit(1)
                        if case .github = source.kind { Chip(text: "GitHub", tint: .secondary) }
                    }
                    Text(source.kind.address)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if model.refreshingSources.contains(source.id) {
                        Text("Refreshing…").font(Theme.mono(.caption)).foregroundStyle(Theme.accent)
                    } else if let error = source.lastError {
                        Text(error).font(Theme.mono(.caption)).foregroundStyle(.orange).lineLimit(2)
                    } else if !model.catalogsLoaded {
                        Text("Loading…").font(Theme.mono(.caption)).foregroundStyle(.secondary)
                    } else {
                        Text("\(appCount) app\(appCount == 1 ? "" : "s")\(source.lastRefreshed.map { " · \($0.relative)" } ?? "")")
                            .font(Theme.mono(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Apps offered by one source, searchable and loaded a page at a time.
struct SourceDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var confirmRemove = false
    @State private var search = ""

    var body: some View {
        ScrollView {
            if let source = model.sources.first(where: { $0.id == sourceID }) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        AppIconView(name: source.name, iconURL: source.iconURL, size: 64)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.title2.bold())
                            Text(source.kind.address).font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if model.refreshingSources.contains(sourceID) {
                                Text("Refreshing…").font(Theme.mono(.caption)).foregroundStyle(Theme.accent)
                            } else if let refreshed = source.lastRefreshed {
                                Text("Updated \(refreshed.relative)").font(Theme.mono(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error = source.lastError {
                        Card { Label(error, systemImage: "exclamationmark.triangle.fill").font(Theme.mono(.footnote)).foregroundStyle(.orange) }
                    }
                    if case .github = source.kind {
                        Card {
                            Text("XSign reads this repository's releases. The newest release with an .ipa is the current version. Pre-releases are listed as betas and only count as updates if Settings › Updates allows betas.")
                                .font(Theme.mono(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    if model.appCount(in: sourceID) > 1 {
                        SearchField(prompt: "Search \(source.name)", text: $search)
                    }
                    if model.catalogsLoaded {
                        CatalogResultsList(query: search.trimmingCharacters(in: .whitespaces), sourceID: sourceID)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 16)
                    }
                }
                .padding(16)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await model.refresh(sourceID) }
        .screen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await model.refresh(sourceID) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    if let source = model.sources.first(where: { $0.id == sourceID }) {
                        Button { UIPasteboard.general.string = source.kind.address } label: {
                            Label("Copy Address", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { confirmRemove = true } label: { Label("Remove Source", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Remove this source?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.removeSource(sourceID)
                dismiss()
            }
        } message: {
            Text("Apps you already got stay in your Library, but stop getting updates.")
        }
    }
}

/// Paste an address, preview what it offers, add it.
struct AddSourceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var input: String
    @State private var checking = false
    @State private var preview: SourceCatalog?
    @State private var previewKind: SourceKind?
    @State private var error: String?
    @State private var useFeedToken = false
    /// Catalog keys of apps started from this sheet, to show their progress.
    @State private var startedKeys: [String: String] = [:]

    private static let previewLimit = 10

    init(initialInput: String = "") {
        _input = State(initialValue: initialInput)
    }

    private var parsed: SourceKind? {
        guard var kind = SourceKind.parse(input) else { return nil }
        if case .feed(var feed) = kind {
            feed.useToken = useFeedToken
            kind = .feed(feed)
        }
        return kind
    }

    private var isFeed: Bool {
        if case .feed = parsed { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paste the address of a GitHub repository, or of an AltStore / Feather-style source, and XSign reads its apps. A repo that publishes an .ipa in its releases updates like any other source.")
                                .font(Theme.mono(.subheadline))
                            Text("Private repos need a GitHub token (Settings › GitHub). Pre-releases are included and marked as betas.")
                                .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                        }
                    }

                    SectionLabel("Address")
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("github.com/owner/repo or https://…/source.json", text: $input, axis: .vertical)
                                .font(Theme.mono(.body))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .padding(12)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onChange(of: input) { _ in preview = nil; error = nil }
                            HStack {
                                PasteButton(payloadType: String.self) { strings in
                                    if let first = strings.first { input = first }
                                }
                                .labelStyle(.titleAndIcon)
                                .buttonBorderShape(.capsule)
                                Spacer()
                                if let parsed {
                                    Chip(text: parsed.kindLabel, systemImage: "checkmark", tint: .green)
                                } else if !input.isEmpty {
                                    Chip(text: "Not an address", tint: .orange)
                                }
                            }
                            if isFeed {
                                Toggle("Send homelab token", isOn: $useFeedToken)
                                    .font(Theme.mono(.subheadline))
                                    .onChange(of: useFeedToken) { _ in preview = nil; error = nil }
                            }
                        }
                    }

                    if let error {
                        Card { Label(error, systemImage: "xmark.octagon.fill").font(Theme.mono(.footnote)).foregroundStyle(.red) }
                    }

                    if let preview {
                        SectionLabel("Preview")
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 12) {
                                    AppIconView(name: preview.name, iconURL: preview.iconURL, size: 44)
                                    VStack(alignment: .leading) {
                                        Text(preview.name).font(.headline)
                                        Text("\(preview.apps.count) app\(preview.apps.count == 1 ? "" : "s")")
                                            .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                    }
                                }
                                ForEach(preview.apps.prefix(Self.previewLimit)) { app in
                                    previewRow(app)
                                }
                                if preview.apps.count > Self.previewLimit {
                                    Text("+ \(preview.apps.count - Self.previewLimit) more. Add the source to browse and search them all.")
                                        .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                                }
                                Text("Get adds this source and installs the app straight away. Add only adds the source.")
                                    .font(Theme.mono(.caption2)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(GridBackground())
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else if preview != nil {
                        Button(startedKeys.isEmpty ? "Add" : "Done") { add() }.fontWeight(.bold)
                    } else {
                        Button("Check") { Task { await check() } }.disabled(parsed == nil)
                    }
                }
            }
            .task { if parsed != nil { await check() } }
        }
    }

    @ViewBuilder
    private func previewRow(_ app: CatalogApp) -> some View {
        let key = startedKeys[app.id]
        let phase = key.flatMap { model.phase(for: $0) }
        let latest = app.latest(includeBetas: model.settings.includeBetaUpdates) ?? app.versions.first
        HStack(spacing: 10) {
            AppIconView(name: app.name, iconURL: app.iconURL, tintHex: app.tintHex, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let phase {
                    PhaseText(phase: phase) { if let key { model.dismissPhase(key) } }
                } else {
                    HStack(spacing: 4) {
                        Text(latest.map { "v\($0.displayVersion)" } ?? "no .ipa")
                        if latest?.isPrerelease == true { Chip(text: "beta", tint: Theme.beta) }
                    }
                    .font(Theme.mono(.caption)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if latest != nil {
                ActionPill(title: "Get", phase: phase, action: { getNow(app) },
                           cancel: { if let key { model.cancel(key) } })
            }
        }
    }

    private func getNow(_ app: CatalogApp) {
        guard let kind = previewKind ?? parsed, let preview else { return }
        if let key = model.addSourceAndGet(kind, catalog: preview, appID: app.id) {
            startedKeys[app.id] = key
        }
    }

    private func check() async {
        guard let kind = parsed else { return }
        checking = true
        defer { checking = false }
        do {
            preview = try await model.fetchCatalog(kind)
            previewKind = kind
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        guard let kind = previewKind ?? parsed else { return }
        model.addSource(kind, catalog: preview)
        Haptics.success()
        dismiss()
    }
}
