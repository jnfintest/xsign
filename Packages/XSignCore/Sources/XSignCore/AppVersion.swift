import Foundation

/// A forgiving version number: accepts `1.2.3`, `v1.2`, `1.2.3-beta.1`,
/// `1.2.3+45` and compares them numerically component by component.
public struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let raw: String
    public let components: [Int]
    public let prerelease: String?

    public init(_ raw: String) {
        self.raw = raw
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        // Drop anything after whitespace, e.g. "1.2.3 (45)".
        if let space = s.firstIndex(where: \.isWhitespace) { s = String(s[..<space]) }
        // Drop build metadata.
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: String?
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        for part in parts {
            let digits = part.prefix(while: \.isNumber)
            guard let n = Int(digits) else { break }
            numbers.append(n)
        }
        self.components = numbers
        self.prerelease = (pre?.isEmpty ?? true) ? nil : pre
    }

    /// `true` when at least one numeric component could be parsed.
    public var isNumeric: Bool { !components.isEmpty }

    public var description: String { raw }

    private var normalized: [Int] {
        var c = components
        while let last = c.last, last == 0, c.count > 1 { c.removeLast() }
        return c
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalized == rhs.normalized && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalized)
        hasher.combine(prerelease)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        // Same numeric version: a release beats a pre-release.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedAscending
        }
    }
}
