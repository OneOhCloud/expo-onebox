import Foundation

// 共享纯核心：从最短开始的渐进 hostname 后缀
//（"a.b.c" → ["c", "b.c", "a.b.c"]）。域名白名单后缀遍历
//（BackgroundConfigRefresh.verifyDomain）的唯一来源，JS、Kotlin、Swift 三端共用。
//
// omittingEmptySubsequences: false 保留空段，以匹配 JS 的 String.split('.')
// 与 Kotlin 的 split('.')；默认丢弃空段会在 "a..b" 这类输入上产生分歧。
func hostnameSuffixCandidates(_ hostname: String) -> [String] {
    if hostname.isEmpty { return [] }
    let parts = hostname.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var out: [String] = []
    for i in stride(from: parts.count - 1, through: 0, by: -1) {
        out.append(parts[i ..< parts.count].joined(separator: "."))
    }
    return out
}
