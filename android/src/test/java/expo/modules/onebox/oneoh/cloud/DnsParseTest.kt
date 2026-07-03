package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.parseFirstARecord
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Kotlin runner for the DNS A-record parser golden lock (audit C7 / D3c-04 /
 * Batch 3). Loads the SAME golden/dns-arecord.json the Swift runner
 * (DnsParseGoldenCheck) uses. The Kotlin parser validates the header (txID/RCODE)
 * itself, so the fixture's txID is passed through. Run:
 * ./gradlew :expo-onebox:testDebugUnitTest
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
