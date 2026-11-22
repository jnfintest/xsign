import Foundation
import XSignCore

/// Lookup tables over every source's apps. A big source has tens of thousands
/// of apps, so this is built once per change, off the main thread, instead of
/// views sorting and filtering the raw catalogs on every redraw.
struct CatalogIndex: Sendable {
    /// Changes on every rebuild, so views can tell when results are stale.
    let id = UUID()
    /// Every app from every source, sorted by name.
    private(set) var all: [CatalogEntry] = []
    /// Catalog key → position in `all`.
    private var positions: [String: Int] = [:]
    /// Positions in `all` per source, in name order.
    private var bySource: [UUID: [Int]] = [:]
    /// Positions in `all` per source, most recently released first (only the
    /// first few, for previews).
    private var newestBySource: [UUID: [Int]] = [:]
    /// Folded (lowercase, no accents) name, parallel to `all`.
    private var names: [String] = []
    /// Folded name + developer + bundle ID + source name, parallel to `all`.
    private var haystacks: [String] = []

    static let previewCount = 12

    init() {}

    init(sources: [SourceRecord], catalogs: [UUID: SourceCatalog]) {
        var rows: [(entry: CatalogEntry, name: String, haystack: String)] = []
        rows.reserveCapacity(sources.reduce(0) { $0 + (catalogs[$1.id]?.apps.count ?? 0) })
        var seen = Set<String>()
        for source in sources {
            let sourceName = Self.fold(source.name)
            for app in catalogs[source.id]?.apps ?? [] {
                // Catalogs cached by older versions can repeat an app ID.
                guard seen.insert("\(source.id.uuidString)|\(app.id)").inserted else { continue }
                let name = Self.fold(app.name)
                var haystack = name
                if let developer = app.developer { haystack += " " + Self.fold(developer) }
                if let bundle = app.bundleIdentifier { haystack += " " + bundle.lowercased() }
                haystack += " " + sourceName
                rows.append((CatalogEntry(source: source, app: app), name, haystack))
            }
        }
        rows.sort { $0.name != $1.name ? $0.name < $1.name : $0.entry.key < $1.entry.key }

        all = rows.map { $0.entry }
        names = rows.map { $0.name }
        haystacks = rows.map { $0.haystack }
        positions.reserveCapacity(rows.count)
        for (position, entry) in all.enumerated() {
            positions[entry.key] = position
            bySource[entry.source.id, default: []].append(position)
        }
        for (sourceID, list) in bySource {
            let dated = list.compactMap { position -> (Int, Date)? in
                all[position].app.versions.first?.publishedAt.map { (position, $0) }
            }
            if dated.isEmpty {
                // No dates: keep the order the source lists its apps in.
                let order = Dictionary((catalogs[sourceID]?.apps ?? []).enumerated().map { ($1.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
                newestBySource[sourceID] = Array(list.sorted {
                    (order[all[$0].app.id] ?? .max) < (order[all[$1].app.id] ?? .max)
                }.prefix(Self.previewCount))
            } else {
                newestBySource[sourceID] = Array(dated.sorted { $0.1 > $1.1 }.prefix(Self.previewCount).map { $0.0 })
            }
        }
    }

    var count: Int { all.count }

    func entry(forKey key: String) -> CatalogEntry? {
        positions[key].map { all[$0] }
    }

    func count(in sourceID: UUID) -> Int { bySource[sourceID]?.count ?? 0 }

    /// The most recently released apps of a source.
    func newest(in sourceID: UUID, limit: Int = Self.previewCount) -> [CatalogEntry] {
        (newestBySource[sourceID] ?? []).prefix(limit).map { all[$0] }
    }

    /// Positions in `all` matching every word of the query, in one source or
    /// all of them. Names starting with the query come first. An empty query
    /// matches everything.
    func search(_ query: String, in sourceID: UUID? = nil) -> [Int] {
        let candidates: [Int] = sourceID.map { bySource[$0] ?? [] } ?? Array(all.indices)
        let folded = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folded.isEmpty else { return candidates }
        let words = folded.split(separator: " ")
        var starts: [Int] = []
        var others: [Int] = []
        for position in candidates {
            let haystack = haystacks[position]
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            if names[position].hasPrefix(folded) { starts.append(position) } else { others.append(position) }
        }
        return starts + others
    }

    func entries(at slots: some Sequence<Int>) -> [CatalogEntry] {
        slots.compactMap { all.indices.contains($0) ? all[$0] : nil }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
