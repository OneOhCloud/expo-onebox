package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.hostnameSuffixCandidates
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * hostname 后缀 golden 锁的 Kotlin 运行器。加载与 JS、Swift 运行器共享的
 * 同一份 golden 样本。运行：./gradlew :expo-onebox:testDebugUnitTest
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
