package expo.modules.onebox.oneoh.cloud.helper

import java.security.MessageDigest

// Shared pure core: lowercase hex of SHA-256(utf8(input)). Single source for the
// domain routing key (accelerated URL path) and the short host digest used in
// logs (ConfigFetcher.hostHash8). Locked by golden/sha256.json across JS, Kotlin
// and Swift (audit C4 / Batch 3); asserted by the JVM unit test Sha256Test.
internal fun sha256Hex(input: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(input.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
