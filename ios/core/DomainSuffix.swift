import Foundation

// Shared pure core: progressive hostname suffixes, shortest first
// ("a.b.c" → ["c", "b.c", "a.b.c"]). The single source for the domain-allowlist
// suffix walk (BackgroundConfigRefresh.verifyDomain). Locked by
// golden/domain-suffix.json across JS, Kotlin and Swift (audit C2 / D3c-02).
//
// `omittingEmptySubsequences: false` preserves empty segments to match JS
// String.split('.') and Kotlin split('.'); the default drop would diverge on
// inputs like "a..b".
func hostnameSuffixCandidates(_ hostname: String) -> [String] {
    if hostname.isEmpty { return [] }
    let parts = hostname.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    for i in stride(from: parts.count - 1, through: 0, by: -1) {
        out.append(parts[i ..< parts.count].joined(separator: "."))
    }
    return out
}
