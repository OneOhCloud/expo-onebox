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
 * Characterization test locking the shared fetch → accelerator-fallback control
 * flow (audit D3c-01 / C4) that both fetchProfileConfigWithFallback and
 * executeRefreshWith now delegate to. A fake fetch + no-op log exercise the
 * decision without a network or android.util.Log. Mirrors the language-agnostic
 * golden/fetch-fallback-decision.json (asserted on the JS side by
 * fetch-fallback-decision-golden.test.ts). Run: ./gradlew :expo-onebox:testDebugUnitTest
 */
class FetchWithFallbackTest {
    private val noopLog: (String) -> Unit = {}
    // Android-free stand-in for buildAcceleratedUrl (which uses android.net.Uri and
    // throws in a JVM unit test); the real one is covered separately. Returns a
    // non-primary URL so the injected fetch routes it down the accelerated branch.
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
        assertEquals(1, calls) // no accelerated fetch attempted
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
        // testPrimaryUnavailable makes the primary throw before any fetch, so a
        // verified domain with an accelerator falls back.
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
