package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.parseUserinfo
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 跨平台 userinfo golden 样本锁的 Kotlin 一环。加载与 JS、Swift 运行器共享的
 * 同一份 golden 样本——通过 build.gradle 中 `test.resources.srcDirs += '../golden'`
 * 挂到单元测试 classpath 上。运行：./gradlew :expo-onebox:testDebugUnitTest
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
            // 对 total=2^64-1，JS 保留一个有损的大数；Kotlin 的 Int64 解析器溢出为 0。
            // 本用例锁定这一分裂的原生一侧。
            assertEquals(obj.get("name").asString, 0L, parseUserinfo(obj.get("header").asString).total)
        }
    }
}
