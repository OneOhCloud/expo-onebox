package expo.modules.onebox.oneoh.cloud

import com.google.gson.Gson
import expo.modules.onebox.oneoh.cloud.helper.ConfigRefreshResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 锁定 ConfigRefreshResult 的 configUrl 契约（config-fetch-policy §F-02 来源绑定）：
 * - toMap() 在 configUrl 存在时输出、缺失时省略键（桥接层形状）；
 * - 旧版本存进结果槽的 JSON 没有 configUrl —— Gson 解码必须得到 null
 *   （JS 侧 resolveResultOriginUrl 的 legacy 回落依赖这一点）。
 * 运行：./gradlew :expo-onebox:testDebugUnitTest
 */
class ConfigRefreshResultTest {
    private val gson = Gson()

    private fun sample(configUrl: String? = null) = ConfigRefreshResult(
        status = "success",
        content = "{\"outbounds\":[]}",
        profileUpload = 100,
        profileDownload = 300,
        profileTotal = 1000,
        profileExpire = 1_735_689_600,
        timestamp = "2026-07-02T08:00:00.000Z",
        durationMs = 420,
        method = "primary",
        configUrl = configUrl,
    )

    @Test
    fun toMapCarriesConfigUrlWhenPresent() {
        val map = sample(configUrl = "https://config.example.invalid/path/profile").toMap()
        assertEquals("https://config.example.invalid/path/profile", map["configUrl"])
    }

    @Test
    fun toMapOmitsConfigUrlWhenAbsent() {
        assertFalse(sample().toMap().containsKey("configUrl"))
    }

    @Test
    fun legacyStoredJsonWithoutConfigUrlDecodesToNull() {
        // 升级前旧原生版本写入结果槽的形状（无 configUrl 键）。
        val legacyJson = """
            {"status":"success","content":"{}","profileUpload":1,"profileDownload":2,
             "profileTotal":3,"profileExpire":4,"timestamp":"2026-07-02T08:00:00.000Z",
             "durationMs":5,"method":"primary"}
        """.trimIndent()
        val decoded = gson.fromJson(legacyJson, ConfigRefreshResult::class.java)
        assertNull(decoded.configUrl)
        assertFalse(decoded.toMap().containsKey("configUrl"))
    }

    @Test
    fun copyStampsConfigUrlWithoutTouchingOtherFields() {
        // executeRefreshWith 末尾的单点 copy(configUrl = url) 所依赖的语义。
        val stamped = sample().copy(configUrl = "https://config.example.invalid/path/profile")
        assertEquals("https://config.example.invalid/path/profile", stamped.configUrl)
        assertEquals(sample(), stamped.copy(configUrl = null))
    }
}
