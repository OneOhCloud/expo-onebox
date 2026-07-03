package expo.modules.onebox.oneoh.cloud

import com.google.gson.JsonParser
import expo.modules.onebox.oneoh.cloud.helper.ProxyGroupSnapshot
import expo.modules.onebox.oneoh.cloud.helper.parseExitGatewayGroups
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * ExitGateway/auto group reducer golden 锁的 Kotlin 运行器。加载与 Swift
 * 运行器共享的同一份 golden 样本。运行：./gradlew :expo-onebox:testDebugUnitTest
 */
class ExitGatewayParseTest {
    @Test
    fun matchesTheGolden() {
        val root = JsonParser.parseReader(
            javaClass.getResourceAsStream("/exitgateway.json")!!.reader()
        ).asJsonObject
        for (case in root.getAsJsonArray("cases")) {
            val obj = case.asJsonObject
            val name = obj.get("name").asString
            val groups = obj.getAsJsonArray("groups").map { g ->
                val go = g.asJsonObject
                val items = go.getAsJsonArray("items").map { i ->
                    val io = i.asJsonObject
                    io.get("tag").asString to io.get("delay").asInt
                }
                ProxyGroupSnapshot(go.get("tag").asString, go.get("selected").asString, items)
            }
            val expect = obj.getAsJsonObject("expect")
            val (all, now, autoNow) = parseExitGatewayGroups(groups)
            assertEquals("$name / now", expect.get("now").asString, now)
            assertEquals("$name / autoNow", expect.get("autoNow").asString, autoNow)
            val wantAll = expect.getAsJsonArray("all").map { it.asJsonObject }
            assertEquals("$name / all.size", wantAll.size, all.size)
            for (idx in all.indices) {
                assertEquals("$name / all[$idx].tag", wantAll[idx].get("tag").asString, all[idx]["tag"])
                assertEquals("$name / all[$idx].delay", wantAll[idx].get("delay").asInt, all[idx]["delay"])
            }
        }
    }
}
