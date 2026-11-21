import Foundation

/// Case-insensitive glob match supporting `*` (any run) and `?` (one character).
public func globMatch(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.lowercased())
    let t = Array(text.lowercased())
    var pi = 0, ti = 0
    var starIndex = -1, matchIndex = 0

    while ti < t.count {
        if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
            pi += 1; ti += 1
        } else if pi < p.count && p[pi] == "*" {
            starIndex = pi; matchIndex = ti; pi += 1
        } else if starIndex != -1 {
            pi = starIndex + 1; matchIndex += 1; ti = matchIndex
        } else {
            return false
        }
    }
    while pi < p.count && p[pi] == "*" { pi += 1 }
    return pi == p.count
}
