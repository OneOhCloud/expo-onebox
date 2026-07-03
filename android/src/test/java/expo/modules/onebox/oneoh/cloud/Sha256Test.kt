package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.sha256Hex
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * SHA-256 hex golden 样本锁的 Kotlin 运行器。加载与 JS、Swift 运行器共享的
 * 同一份 golden 样本。运行：./gradlew :expo-onebox:testDebugUnitTest
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
