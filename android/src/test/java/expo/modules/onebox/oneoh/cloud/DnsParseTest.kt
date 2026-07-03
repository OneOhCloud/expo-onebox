package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.parseFirstARecord
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * DNS A 记录解析器 golden 锁的 Kotlin 运行器。加载与 Swift 运行器共享的
 * 同一份 golden 样本，使各端保持一致。Kotlin 解析器自身校验头部
 * （txID/RCODE），因此 fixture 的 txID 会被透传。
 * 运行：./gradlew :expo-onebox:testDebugUnitTest
 */
class DnsParseTest {
    private fun hexToBytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    @Test
    fun matchesTheGolden() {
        val root = JsonParser.parseReader(
            javaClass.getResourceAsStream("/dns-arecord.json")!!.reader()
        ).asJsonObject
        for (case in root.getAsJsonArray("cases")) {
            val obj = case.asJsonObject
            val buf = hexToBytes(obj.get("responseHex").asString)
            val txID = obj.get("txID").asInt.toShort()
            assertEquals(obj.get("name").asString, obj.get("expect").asString, parseFirstARecord(buf, buf.size, txID))
        }
    }
}
