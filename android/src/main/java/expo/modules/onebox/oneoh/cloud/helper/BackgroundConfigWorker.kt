package expo.modules.onebox.oneoh.cloud.helper

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.gson.Gson
import java.time.Instant
import java.util.concurrent.TimeUnit

private const val TAG = "BackgroundConfigWorker"
internal const val BG_PREFS_NAME = "expo_onebox_background_config"
private val gson = Gson()

// MARK: - Result model

data class ConfigRefreshResult(
    val status: String,           // "success" | "failed" | "skipped"
    val content: String? = null,
    val subscriptionUpload: Long = 0,
    val subscriptionDownload: Long = 0,
    val subscriptionTotal: Long = 0,
    val subscriptionExpire: Long = 0,
    val error: String? = null,
    val timestamp: String,
    val durationMs: Long,
    val subscriptionUserinfoHeader: String? = null,
    val method: String? = null,   // "primary" | "fallback"
    val actualUrl: String? = null, // 实际请求的 URL（加速时为构造后的完整 URL）
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("status", status)
        put("subscriptionUpload", subscriptionUpload)
        put("subscriptionDownload", subscriptionDownload)
        put("subscriptionTotal", subscriptionTotal)
        put("subscriptionExpire", subscriptionExpire)
        put("timestamp", timestamp)
        put("durationMs", durationMs)
        content?.let { put("content", it) }
        error?.let { put("error", it) }
        subscriptionUserinfoHeader?.let { put("subscriptionUserinfoHeader", it) }
        method?.let { put("method", it) }
        actualUrl?.let { put("actualUrl", it) }
    }
}

// MARK: - Worker

class BackgroundConfigWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    companion object {
        const val WORK_NAME = "cloud.oneoh.networktools.config-refresh"
        // WorkManager enforces a minimum of 15 minutes for periodic work.
        private const val MIN_INTERVAL_SECONDS = 15L * 60L

        fun schedule(context: Context, intervalSeconds: Long) {
            val clamped = maxOf(intervalSeconds, MIN_INTERVAL_SECONDS)
            val request = PeriodicWorkRequestBuilder<BackgroundConfigWorker>(clamped, TimeUnit.SECONDS)
                .addTag(WORK_NAME)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build()
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.UPDATE,
                request,
            )
            Log.i(TAG, "Scheduled periodic work every ${clamped}s, workId=${request.id}")
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
            Log.i(TAG, "Periodic work cancelled")
        }

        fun isRegistered(context: Context): Boolean {
            return try {
                val infos = WorkManager.getInstance(context)
                    .getWorkInfosForUniqueWork(WORK_NAME).get()
                infos.any { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.RUNNING }
            } catch (_: Exception) { false }
        }

        fun storeResult(context: Context, result: ConfigRefreshResult) {
            context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString("last_result", gson.toJson(result))
                .apply()
        }

        fun loadLastResult(context: Context): Map<String, Any>? {
            val json = context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .getString("last_result", null) ?: return null
            return try {
                // Deserialize into the typed data class first so numeric fields become
                // proper Long/String values. Using Map::class.java produces LazilyParsedNumber
                // for all numbers, which the Expo Modules API cannot serialize to JS.
                gson.fromJson(json, ConfigRefreshResult::class.java).toMap()
            } catch (_: Exception) { null }
        }

        fun clearLastResult(context: Context) {
            context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .edit().remove("last_result").apply()
        }

    }

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
        val url          = prefs.getString("config_url", null)
        val userAgent    = prefs.getString("user_agent", "") ?: ""
        val accelerateUrl = prefs.getString("accelerate_url", null)

        Log.i(TAG, "doWork invoked, hasUrl=${!url.isNullOrEmpty()}, runAttempt=$runAttemptCount")

        if (url.isNullOrEmpty()) {
            Log.d(TAG, "No config URL stored, skipping")
            return Result.success()
        }

        val result = executeRefreshWith(url, accelerateUrl, userAgent)
        storeResult(applicationContext, result)
        return if (result.status == "success") Result.success() else Result.retry()
    }
}

// MARK: - Domain verification

private const val KNOWN_DOMAIN_SHA256 = "59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1"
private const val VERIFIED_LIST_URL   = "https://www.sing-box.net/verified_subscriptions_sha256.txt"

/**
 * Returns true if [sha256] matches the local known hash or the remote whitelist.
 */
private suspend fun verifyDomain(sha256: String): Boolean {
    if (sha256 == KNOWN_DOMAIN_SHA256) return true
    return try {
        val conn = java.net.URL(VERIFIED_LIST_URL).openConnection() as java.net.HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout    = 10_000
        if (conn.responseCode !in 200..299) return false
        val text   = conn.inputStream.bufferedReader().readText()
        val hashes = text.lines().map { it.trim() }.filter { it.isNotEmpty() }
        hashes.contains(sha256)
    } catch (_: Exception) {
        false
    }
}

// MARK: - SHA256 + accelerated URL helpers

private fun sha256Hex(input: String): String {
    val digest = java.security.MessageDigest.getInstance("SHA-256")
    return digest.digest(input.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}

/** Build the accelerated variant: <accelerateBase>/<sha256(host)><path+query> */
private fun buildAcceleratedUrl(originalUrl: String, accelerateBase: String): String {
    val uri = android.net.Uri.parse(originalUrl)
    val host = uri.host ?: return originalUrl
    val hashHex = sha256Hex(host)
    val pathAndQuery = buildString {
        append(uri.encodedPath ?: "/")
        uri.encodedQuery?.let { append("?$it") }
    }
    return "$accelerateBase/$hashHex$pathAndQuery"
}

// MARK: - Shared refresh executor (foreground + background)

/**
 * Fetch [url] with fallback to [accelerateUrl].
 * Core logic (unified):
 *   1. Try [url] (primary)
 *   2. If fails (network exception) and domain verified → try accelerated URL
 *   3. Return result with method info
 * HTTP errors (non-2xx) do NOT trigger fallback.
 * Test mode: simulates primary URL unavailable to test fallback path.
 */
internal suspend fun executeRefreshWith(
    url: String,
    accelerateUrl: String?,
    userAgent: String,
    testPrimaryUrlUnavailable: Boolean = false,
): ConfigRefreshResult {
    val start     = System.currentTimeMillis()
    val timestamp = Instant.now().toString()

    // ── Domain verification ───────────────────────────────────────────────────
    val host      = android.net.Uri.parse(url).host ?: ""
    val domainSha = sha256Hex(host)
    val verified  = verifyDomain(domainSha)
    if (!verified) {
        Log.w(TAG, "[CONFIG_LOAD] 域名未验证: SHA256=$domainSha, 加速备用已禁用")
    }

    // ── Try primary URL first ────────────────────────────────────────────────
    val primaryError: String = if (testPrimaryUrlUnavailable) {
        // Test mode: simulate primary URL unavailable to trigger fallback path
        Log.w(TAG, "[CONFIG_LOAD] 测试模式: 跳过主URL直接尝试加速回落")
        "TEST MODE: primary URL unavailable"
    } else {
        try {
            val fetchResult = fetchConfig(url, userAgent)
            val durationMs  = System.currentTimeMillis() - start

            if (fetchResult.statusCode < 200 || fetchResult.statusCode >= 300) {
                // HTTP error — do not fall back, return error
                Log.w(TAG, "[CONFIG_LOAD] 主URL返回HTTP ${fetchResult.statusCode}, 不触发回落")
                return ConfigRefreshResult(
                    status    = "failed",
                    error     = "HTTP ${fetchResult.statusCode}",
                    timestamp = timestamp,
                    durationMs = durationMs,
                    method    = "primary",
                )
            }

            val headerValue = fetchResult.headers["subscription-userinfo"]
            val info = parseUserinfo(headerValue)
            Log.i(TAG, "[CONFIG_LOAD] 主URL成功: 上传=${info.upload}, 下载=${info.download}, 总计=${info.total}, 过期=${info.expire}")
            return ConfigRefreshResult(
                status             = "success",
                content            = fetchResult.body,
                subscriptionUpload   = info.upload,
                subscriptionDownload = info.download,
                subscriptionTotal    = info.total,
                subscriptionExpire   = info.expire,
                timestamp          = timestamp,
                durationMs         = durationMs,
                subscriptionUserinfoHeader = headerValue,
                method             = "primary",
            )
        } catch (primaryEx: Exception) {
            val err = primaryEx.message ?: "Unknown error"
            Log.w(TAG, "[CONFIG_LOAD] 主URL异常: $err, 检查回落条件")
            err
        }
    }

    // ── Try accelerated URL (verified domains only) ───────────────────────
    // This code executes when either testPrimaryUrlUnavailable=true or primary fetch failed
    if (!verified) {
        val durationMs = System.currentTimeMillis() - start
        Log.w(TAG, "[CONFIG_LOAD] 回落被禁用: 域名未验证 (SHA256=$domainSha), 主URL原因: $primaryError")
        return ConfigRefreshResult(
            status    = "failed",
            error     = primaryError,
            timestamp = timestamp,
            durationMs = durationMs,
            method    = "primary",
        )
    }

    if (accelerateUrl.isNullOrBlank()) {
        val durationMs = System.currentTimeMillis() - start
        Log.w(TAG, "[CONFIG_LOAD] 回落被禁用: 加速URL未配置, 主URL原因: $primaryError")
        return ConfigRefreshResult(
            status    = "failed",
            error     = primaryError,
            timestamp = timestamp,
            durationMs = durationMs,
            method    = "primary",
        )
    }

    val accUrl = buildAcceleratedUrl(url, accelerateUrl)
    Log.i(TAG, "[CONFIG_LOAD] 主URL失败, 尝试加速回落: $accUrl, 原因: $primaryError")

    return try {
        val fetchResult = fetchConfig(accUrl, userAgent)
        val durationMs  = System.currentTimeMillis() - start

        if (fetchResult.statusCode < 200 || fetchResult.statusCode >= 300) {
            val accError = "HTTP ${fetchResult.statusCode}"
            Log.e(TAG, "[CONFIG_LOAD] 加速URL也失败: $accError (主URL: $primaryError)")
            ConfigRefreshResult(
                status    = "failed",
                error     = "primary=$primaryError accelerated=$accError",
                timestamp = timestamp,
                durationMs = durationMs,
                method    = "fallback",
                actualUrl = accUrl,
            )
        } else {
            val headerValue = fetchResult.headers["subscription-userinfo"]
            Log.i(TAG, "[CONFIG_LOAD] 加速回落成功: subscription-userinfo=$headerValue")
            val info = parseUserinfo(headerValue)
            ConfigRefreshResult(
                status             = "success",
                content            = fetchResult.body,
                subscriptionUpload   = info.upload,
                subscriptionDownload = info.download,
                subscriptionTotal    = info.total,
                subscriptionExpire   = info.expire,
                timestamp          = timestamp,
                durationMs         = durationMs,
                subscriptionUserinfoHeader = headerValue,
                method             = "fallback",
                actualUrl          = accUrl,
            )
        }
    } catch (accEx: Exception) {
        val durationMs = System.currentTimeMillis() - start
        val accError   = accEx.message ?: "Unknown error"
        Log.e(TAG, "[CONFIG_LOAD] 加速回落也失败: $accError (主URL: $primaryError)")
        ConfigRefreshResult(
            status    = "failed",
            error     = "primary=$primaryError accelerated=$accError",
            timestamp = timestamp,
            durationMs = durationMs,
            method    = "fallback",
            actualUrl = accUrl,
        )
    }
}

// MARK: - subscription-userinfo header parser

internal data class TrafficInfo(
    val upload: Long,
    val download: Long,
    val total: Long,
    val expire: Long,
)

internal fun parseUserinfo(header: String?): TrafficInfo {
    fun extract(key: String): Long {
        val match = Regex("$key=(\\d+)").find(header ?: "") ?: return 0L
        return match.groupValues[1].toLongOrNull() ?: 0L
    }
    return TrafficInfo(
        upload   = extract("upload"),
        download = extract("download"),
        total    = extract("total"),
        expire   = extract("expire"),
    )
}
