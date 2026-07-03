package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.parseUserinfo
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin third of the cross-platform userinfo golden-sample lock (audit C6 /
 * D3c-03 / Batch 3). Loads the SAME golden/userinfo.json that the JS
 * (src/utils/profile-info.test.ts) and Swift (ParseUserinfoTests) runners use —
 * wired onto the unit-test classpath via `test.resources.srcDirs += '../golden'`
 * in build.gradle. Run: ./gradlew :expo-onebox:testDebugUnitTest
 */
class ParseUserinfoTest {
    private fun goldenRoot() =
        JsonParser.parseReader(
            javaClass.getResourceAsStream("/userinfo.json")!!.reader()
        ).asJsonObject

    @Test
    fun sharedCasesMatchTheGolden() {
        for (case in goldenRoot().getAsJsonArray("cases")) {
            val obj = case.asJsonObject
            val name = obj.get("name").asString
            val headerNode = obj.get("header")
            val header = if (headerNode.isJsonNull) null else headerNode.asString
            val expect = obj.getAsJsonObject("expect")
            val info = parseUserinfo(header)
            assertEquals("$name / upload", expect.get("upload").asLong, info.upload)
            assertEquals("$name / download", expect.get("download").asLong, info.download)
            assertEquals("$name / total", expect.get("total").asLong, info.total)
            assertEquals("$name / expire", expect.get("expire").asLong, info.expire)
        }
    }

    @Test
    fun knownDivergencesOverflowToZeroOnNative() {
        for (div in goldenRoot().getAsJsonArray("knownDivergences")) {
            val obj = div.asJsonObject
            // JS keeps a lossy large number for total=2^64-1; the Kotlin Int64
            // parser overflows to 0. This locks the native half of the split.
            assertEquals(obj.get("name").asString, 0L, parseUserinfo(obj.get("header").asString).total)
        }
    }
}
