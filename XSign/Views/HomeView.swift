import SwiftUI
import XSignCore

/// Overview: what needs updating, signing status, what's new in sources.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    private var recent: [CatalogEntry] {
        model.allEntries
            .filter { $0.app.versions.first?.publishedAt != nil }
            .sorted { ($0.app.versions.first?.publishedAt ?? .distantPast) > ($1.app.versions.first?.publishedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Home", trailing: {
                        if model.isRefreshing {
                            ProgressView().frame(width: 46, height: 46)
                        } else {
                            CircleButton(systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        }
                    })
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(Theme.mono(.footnote, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                        .padding(.top, -12)

                    setupCard
                    updatesSection
                    stats
                    if !recent.isEmpty {
                        SectionLabel("Latest from your sources")
                        VStack(spacing: 10) {
                            ForEach(recent) { entry in
                                NavigationLink(value: entry) { CatalogRow(entry: entry) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .refreshable { await model.refreshAll() }
            .screen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CatalogEntry.self) { CatalogAppDetailView(entryKey: $0.key) }
        }
    }

    // MARK: Setup / certificate

    @ViewBuilder
    private var setupCard: some View {
        if model.sources.isEmpty || model.activeCertificate == nil || model.installTrusted == false {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Get set up").font(.title3.bold())
                    step(done: !model.sources.isEmpty, title: "Add a source",
                         detail: "A GitHub repo or source URL, on the Repos tab.") { model.selectedTab = .repos }
                    step(done: model.activeCertificate != nil, title: "Import a certificate",
                         detail: ".p12 + .mobileprovision, in Settings.") { model.selectedTab = .settings }
                    step(done: model.hasGitHubToken, title: "Add a GitHub token (private repos)",
                         detail: "Settings › GitHub.") { model.selectedTab = .settings }
                    step(done: model.installTrusted == true, title: "Trust the install certificate",
                         detail: "Once, in Settings › Installer.") { model.selectedTab = .settings }
                }
            }
        } else if let certificate = model.activeCertificate {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(certificate.expiryTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(certificate.teamName ?? certificate.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(certificate.expiryText).font(Theme.mono(.caption)).foregroundStyle(certificate.expiryTint)
                    }
                    Spacer()
                    Button("Change") { model.selectedTab = .settings }
                        .font(Theme.mono(.caption, weight: .semibold))
                }
            }
        }
    }

    private func step(done: Bool, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(Theme.mono(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if !done { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .buttonStyle(.plain)
        .disabled(done)
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesSection: some View {
        let updates = model.pendingUpdates
        SectionLabel("Updates", trailing: updates.count > 1
                     ? AnyView(Button("Update All") { model.updateAll() }.font(Theme.mono(.caption, weight: .bold)))
                     : nil)
        if updates.isEmpty {
            Card(padding: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text(model.library.contains { $0.catalogKey != nil } ? "Everything is up to date." : "Apps you get from a source show their updates here.")
                        .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(updates) { update in
                    UpdateRow(update: update)
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            stat("\(model.sources.count)", "sources") { model.selectedTab = .repos }
            stat("\(model.allEntries.count)", "apps") { model.selectedTab = .apps }
            stat("\(model.library.filter(\.hasSignedCopy).count)", "signed") { model.selectedTab = .library }
        }
    }

    private func stat(_ value: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(label.uppercased()).font(Theme.mono(.caption2, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
    }
}

struct UpdateRow: View {
    @EnvironmentObject private var model: AppModel
    let update: PendingUpdate

    var body: some View {
        let phase = model.phase(for: update.entry.key)
        NavigationLink(value: update.entry) {
            Card(padding: 14) {
                HStack(spacing: 14) {
                    AppIconView(name: update.item.name, iconFileName: update.item.iconFileName,
                                iconURL: update.entry.app.iconURL, tintHex: update.entry.app.tintHex, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(update.item.name).font(.headline).lineLimit(1)
                        if let phase {
                            PhaseText(phase: phase) { model.dismissPhase(update.entry.key) }
                        } else {
                            HStack(spacing: 4) {
                                Text(update.item.installed?.displayVersion ?? "?").foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                Text(update.release.displayVersion).foregroundStyle(Theme.accent).fontWeight(.semibold)
                                if update.release.isPrerelease { Chip(text: "beta", tint: Theme.beta) }
                            }
                            .font(Theme.mono(.caption))
                        }
                    }
                    Spacer(minLength: 6)
                    ActionPill(title: "Update", phase: phase,
                               action: { model.update(update) }, cancel: { model.cancel(update.entry.key) })
                }
            }
        }
        .buttonStyle(.plain)
    }
}
