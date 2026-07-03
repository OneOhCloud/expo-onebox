package expo.modules.onebox.oneoh.cloud

import expo.modules.onebox.oneoh.cloud.helper.ConfigFetchResult
import expo.modules.onebox.oneoh.cloud.helper.FallbackOutcome
import expo.modules.onebox.oneoh.cloud.helper.FallbackPreflight
import expo.modules.onebox.oneoh.cloud.helper.fetchWithFallback
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 特征测试（characterization test），锁定 fetchProfileConfigWithFallback 与
 * executeRefreshWith 共同委托的「fetch → 加速回落」控制流。用假 fetch + 空 log
 * 在没有网络、也不依赖 android.util.Log 的情况下驱动决策。
 * 运行：./gradlew :expo-onebox:testDebugUnitTest
 */
class FetchWithFallbackTest {
    private val noopLog: (String) -> Unit = {}
    // buildAcceleratedUrl 的无 Android 替身（真身用 android.net.Uri，在 JVM 单测中会
    // 抛异常；真身另行覆盖）。返回一个非主 URL，使注入的 fetch 把它路由到加速分支。
    private val fakeAccel: (String, String) -> String = { _, base -> "$base/hashed/path" }
    private val primaryUrl = "https://p.example"

    private fun preflight(
        verified: Boolean = true,
        accelerateUrl: String? = "https://accel.example",
        testPrimaryUnavailable: Boolean = false,
    ) = FallbackPreflight(
        host = "host.example",
        domainSha = "sha",
        verified = verified,
        testPrimaryUnavailable = testPrimaryUnavailable,
        accelerateUrl = accelerateUrl,
    )

    private fun ok(status: Int) = ConfigFetchResult(status, emptyMap(), "body")

    @Test
    fun primarySuccessReturnsPrimaryOk() = runBlocking {
        val o = fetchWithFallback(preflight(), primaryUrl, "UA", { _, _ -> ok(200) }, noopLog)
        assertTrue(o is FallbackOutcome.Ok)
        assertEquals("primary", (o as FallbackOutcome.Ok).method)
    }

    @Test
    fun primaryHttpErrorDoesNotFallBack() = runBlocking {
        var calls = 0
        val o = fetchWithFallback(preflight(), primaryUrl, "UA", { _, _ -> calls++; ok(503) }, noopLog)
        assertTrue(o is FallbackOutcome.Ok)
        o as FallbackOutcome.Ok
        assertEquals("primary", o.method)
        assertEquals(503, o.result.statusCode)
        assertEquals(1, calls) // 未尝试加速 fetch
    }

    @Test
    fun networkFailUnverifiedSkipsFallback() = runBlocking {
        val o = fetchWithFallback(preflight(verified = false), primaryUrl, "UA", { _, _ -> throw RuntimeException("net") }, noopLog)
        assertTrue(o is FallbackOutcome.NoFallback)
        assertEquals("unverified", (o as FallbackOutcome.NoFallback).reason)
    }

    @Test
    fun networkFailNoAcceleratorSkipsFallback() = runBlocking {
        val o = fetchWithFallback(preflight(accelerateUrl = null), primaryUrl, "UA", { _, _ -> throw RuntimeException("net") }, noopLog)
        assertTrue(o is FallbackOutcome.NoFallback)
        assertEquals("no-accelerator", (o as FallbackOutcome.NoFallback).reason)
    }

    @Test
    fun networkFailVerifiedFallsBack() = runBlocking {
        val o = fetchWithFallback(preflight(), primaryUrl, "UA",
            { u, _ -> if (u == primaryUrl) throw RuntimeException("net") else ok(200) }, noopLog, fakeAccel)
        assertTrue(o is FallbackOutcome.Ok)
        o as FallbackOutcome.Ok
        assertEquals("fallback", o.method)
        assertEquals("net", o.primaryError)
    }

    @Test
    fun bothFailWhenAcceleratedThrows() = runBlocking {
        val o = fetchWithFallback(preflight(), primaryUrl, "UA", { _, _ -> throw RuntimeException("net") }, noopLog, fakeAccel)
        assertTrue(o is FallbackOutcome.BothFailed)
        o as FallbackOutcome.BothFailed
        assertEquals("net", o.primaryError)
        assertEquals("net", o.accError)
    }

    @Test
    fun testModeForcesPrimaryFailureThenFallsBack() = runBlocking {
        // testPrimaryUnavailable 使主请求在任何 fetch 之前就抛出，因此已验证域名
        // 且有加速器时会回落。
        val o = fetchWithFallback(preflight(testPrimaryUnavailable = true), primaryUrl, "UA", { _, _ -> ok(200) }, noopLog, fakeAccel)
        assertTrue(o is FallbackOutcome.Ok)
        assertEquals("fallback", (o as FallbackOutcome.Ok).method)
    }

    @Test(expected = CancellationException::class)
    fun cancellationIsRethrown(): Unit = runBlocking {
        fetchWithFallback(preflight(), primaryUrl, "UA", { _, _ -> throw CancellationException("cancel") }, noopLog)
        Unit
    }
}
