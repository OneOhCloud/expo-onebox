package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.hostnameSuffixCandidates
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin runner for the hostname-suffix golden lock (audit C2 / D3c-02). Loads the
 * SAME golden/domain-suffix.json the JS (domain-suffix-golden.test.ts) and Swift
 * (DomainSuffixGoldenCheck) runners use. Run: ./gradlew :expo-onebox:testDebugUnitTest
 */
class DomainSuffixTest {
    @Test
    fun matchesTheGolden() {
        val root = JsonParser.parseReader(
            javaClass.getResourceAsStream("/domain-suffix.json")!!.reader()
        ).asJsonObject
        for (case in root.getAsJsonArray("cases")) {
            val obj = case.asJsonObject
            val hostname = obj.get("hostname").asString
            val want = obj.getAsJsonArray("candidates").map { it.asString }
            assertEquals(hostname, want, hostnameSuffixCandidates(hostname))
        }
    }
}
