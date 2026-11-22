import SwiftUI
import XSignCore

/// Overview of what you have: signing status, pending updates and your own
/// apps. Browsing what sources offer happens on the Apps and Repos tabs, so
/// a source with thousands of apps doesn't flood this screen.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    private static let yourAppsLimit = 8

    /// Apps you have through XSign, most recently installed first.
    private var yourApps: [LibraryItem] {
        model.library.sorted { Self.lastUsed($0) > Self.lastUsed($1) }
    }

    private static func lastUsed(_ item: LibraryItem) -> Date {
        item.installed?.installedAt ?? item.signedAt ?? item.addedAt
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
                    yourAppsSection
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
            stat("\(model.library.filter { $0.installed != nil }.count)", "installed") { model.selectedTab = .library }
            stat("\(model.library.filter(\.hasSignedCopy).count)", "signed") { model.selectedTab = .library }
        }
    }

    // MARK: Your apps

    @ViewBuilder
    private var yourAppsSection: some View {
        let apps = yourApps
        SectionLabel("Your apps", trailing: apps.count > Self.yourAppsLimit
                     ? AnyView(Button("See All") { model.selectedTab = .library }.font(Theme.mono(.caption, weight: .bold)))
                     : nil)
        if apps.isEmpty {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Apps you get show up here, so you can see what you have and what needs updating.")
                        .font(Theme.mono(.subheadline)).foregroundStyle(.secondary)
                    Button("Browse Apps") { model.selectedTab = .apps }
                        .font(Theme.mono(.subheadline, weight: .semibold))
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(apps.prefix(Self.yourAppsLimit)) { item in
                    YourAppRow(item: item)
                    if item.id != apps.prefix(Self.yourAppsLimit).last?.id {
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .background(Theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
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

/// Compact row for one of your apps: what's installed and whether it's current.
struct YourAppRow: View {
    @EnvironmentObject private var model: AppModel
    let item: LibraryItem

    var body: some View {
        let entry = item.catalogKey.flatMap(model.entry(forKey:))
        if let entry {
            NavigationLink(value: entry) { content(entry) }.buttonStyle(.plain)
        } else {
            Button { model.selectedTab = .library } label: { content(nil) }.buttonStyle(.plain)
        }
    }

    private func content(_ entry: CatalogEntry?) -> some View {
        let phase = model.phase(for: item.jobKey)
        return HStack(spacing: 12) {
            AppIconView(name: item.name, iconFileName: item.iconFileName, iconURL: entry?.app.iconURL,
                        tintHex: entry?.app.tintHex, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let phase {
                    PhaseText(phase: phase) { model.dismissPhase(item.jobKey) }
                } else {
                    Text(subtitle(entry)).font(Theme.mono(.caption)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            status(entry)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func subtitle(_ entry: CatalogEntry?) -> String {
        let version = "v\(item.installed?.displayVersion ?? item.displayVersion)"
        guard let source = entry?.source.name ?? item.sourceName else { return "\(version) · imported" }
        return "\(version) · \(source)"
    }

    @ViewBuilder
    private func status(_ entry: CatalogEntry?) -> some View {
        if let entry, model.hasUpdate(entry) {
            Chip(text: "update", tint: Theme.accent)
        } else if item.installed == nil {
            Chip(text: "not installed", tint: .secondary)
        } else if item.catalogKey != nil && entry == nil && model.catalogsLoaded {
            Chip(text: "no source", tint: .orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
