package expo.modules.onebox.oneoh.cloud.helper

// 共享纯核心：渐进的 hostname 后缀，最短优先
//（"a.b.c" -> ["c", "b.c", "a.b.c"]）。是域名 allowlist 后缀遍历
//（verifyDomain）的单一来源，需与 JS、Kotlin、Swift 三端保持一致。
// Kotlin 的 split('.') 会保留空段以与 JS 一致；Swift 核心传
// omittingEmptySubsequences:false 来与之吻合。
internal fun hostnameSuffixCandidates(hostname: String): List<String> {
    if (hostname.isEmpty()) return emptyList()
    val parts = hostname.split('.')
    return parts.indices.reversed().map { parts.subList(it, parts.size).joinToString(".") }
}
