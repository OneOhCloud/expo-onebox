package expo.modules.onebox.oneoh.cloud.helper

// Shared pure core: progressive hostname suffixes, shortest first
// ("a.b.c" -> ["c", "b.c", "a.b.c"]). Single source for the domain-allowlist
// suffix walk (verifyDomain). Locked by golden/domain-suffix.json across JS,
// Kotlin and Swift (audit C2 / D3c-02). Kotlin split('.') keeps empty segments,
// matching JS; the Swift core passes omittingEmptySubsequences:false to agree.
internal fun hostnameSuffixCandidates(hostname: String): List<String> {
    if (hostname.isEmpty()) return emptyList()
    val parts = hostname.split('.')
    return parts.indices.reversed().map { parts.subList(it, parts.size).joinToString(".") }
}
