package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.sha256Hex
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin runner for the SHA-256 hex golden-sample lock (audit C4 / Batch 3).
 * Loads the SAME golden/sha256.json that the JS (sha256.test.ts) and Swift
 * (Sha256GoldenCheck) runners use. Run: ./gradlew :expo-onebox:testDebugUnitTest
 */
class Sha256Test {
    @Test
    fun matchesTheGolden() {
        val root = JsonParser.parseReader(
            javaClass.getResourceAsStream("/sha256.json")!!.reader()
        ).asJsonObject
        for (case in root.getAsJsonArray("cases")) {
            val obj = case.asJsonObject
            val input = obj.get("input").asString
            assertEquals("sha256($input)", obj.get("hex").asString, sha256Hex(input))
        }
    }
}
