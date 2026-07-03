package expo.modules.onebox.oneoh.cloud.helper

import java.security.MessageDigest

// 共享纯核心：SHA-256(utf8(input)) 的小写 hex。它是域名路由 key（加速 URL 路径）
// 与日志中短 host 摘要（ConfigFetcher.hostHash8）的单一来源，需与 JS、Kotlin、
// Swift 三端实现保持一致。
internal fun sha256Hex(input: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(input.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
