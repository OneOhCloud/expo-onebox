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
            Log.i(TAG, "Scheduled periodic work every ${clamped}s")
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
                @Suppress("UNCHECKED_CAST")
                gson.fromJson(json, Map::class.java) as? Map<String, Any>
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

        if (url.isNullOrEmpty()) {
            Log.d(TAG, "No config URL stored, skipping")
            return Result.success()
        }

        val result = executeRefreshWith(url, accelerateUrl, userAgent)
        storeResult(applicationContext, result)
        return if (result.status == "success") Result.success() else Result.retry()
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
 * Fetch [url] and return a [ConfigRefreshResult].
 * On network-level failure (exception), retries via [accelerateUrl] if provided.
 * HTTP errors (non-2xx) do NOT trigger fallback.
 */
internal suspend fun executeRefreshWith(
    url: String,
    accelerateUrl: String?,
    userAgent: String,
): ConfigRefreshResult {
    val start     = System.currentTimeMillis()
    val timestamp = Instant.now().toString()

    // ── Try primary URL ───────────────────────────────────────────────────────
    try {
        val fetchResult = fetchSubscription(url, userAgent)
        val durationMs  = System.currentTimeMillis() - start

        if (fetchResult.statusCode < 200 || fetchResult.statusCode >= 300) {
            // HTTP error — do not fall back
            Log.w(TAG, "HTTP error ${fetchResult.statusCode} on primary, no fallback")
            return ConfigRefreshResult(
                status    = "failed",
                error     = "HTTP ${fetchResult.statusCode}",
                timestamp = timestamp,
                durationMs = durationMs,
            )
        }

        val info = parseSubscriptionUserinfo(fetchResult.headers["subscription-userinfo"])
        Log.i(TAG, "[CONFIG_LOAD] 方式=PRIMARY, URL=$url")
        return ConfigRefreshResult(
            status             = "success",
            content            = fetchResult.body,
            subscriptionUpload   = info.upload,
            subscriptionDownload = info.download,
            subscriptionTotal    = info.total,
            subscriptionExpire   = info.expire,
            timestamp          = timestamp,
            durationMs         = durationMs,
        )
    } catch (primaryEx: Exception) {
        val primaryError = primaryEx.message ?: "Unknown error"
        Log.w(TAG, "[CONFIG_LOAD] Primary failed: $primaryError")

        // ── Try accelerated URL ───────────────────────────────────────────────
        if (accelerateUrl.isNullOrBlank()) {
            val durationMs = System.currentTimeMillis() - start
            Log.w(TAG, "[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE (未配置)")
            return ConfigRefreshResult(
                status    = "failed",
                error     = primaryError,
                timestamp = timestamp,
                durationMs = durationMs,
            )
        }

        val accUrl = buildAcceleratedUrl(url, accelerateUrl)
        Log.i(TAG, "[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 原因=$primaryError, 加速URL=$accUrl")

        return try {
            val fetchResult = fetchSubscription(accUrl, userAgent)
            val durationMs  = System.currentTimeMillis() - start

            if (fetchResult.statusCode < 200 || fetchResult.statusCode >= 300) {
                val accError = "HTTP ${fetchResult.statusCode}"
                Log.e(TAG, "[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址=$primaryError, 加速地址=$accError")
                ConfigRefreshResult(
                    status    = "failed",
                    error     = "primary=$primaryError accelerated=$accError",
                    timestamp = timestamp,
                    durationMs = durationMs,
                )
            } else {
                val info = parseSubscriptionUserinfo(fetchResult.headers["subscription-userinfo"])
                ConfigRefreshResult(
                    status             = "success",
                    content            = fetchResult.body,
                    subscriptionUpload   = info.upload,
                    subscriptionDownload = info.download,
                    subscriptionTotal    = info.total,
                    subscriptionExpire   = info.expire,
                    timestamp          = timestamp,
                    durationMs         = durationMs,
                )
            }
        } catch (accEx: Exception) {
            val durationMs = System.currentTimeMillis() - start
            val accError   = accEx.message ?: "Unknown error"
            Log.e(TAG, "[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址=$primaryError, 加速地址=$accError")
            ConfigRefreshResult(
                status    = "failed",
                error     = "primary=$primaryError accelerated=$accError",
                timestamp = timestamp,
                durationMs = durationMs,
            )
        }
    }
}

// MARK: - subscription-userinfo header parser

internal data class SubscriptionInfo(
    val upload: Long,
    val download: Long,
    val total: Long,
    val expire: Long,
)

internal fun parseSubscriptionUserinfo(header: String?): SubscriptionInfo {
    fun extract(key: String): Long {
        val match = Regex("$key=(\\d+)").find(header ?: "") ?: return 0L
        return match.groupValues[1].toLongOrNull() ?: 0L
    }
    return SubscriptionInfo(
        upload   = extract("upload"),
        download = extract("download"),
        total    = extract("total"),
        expire   = extract("expire"),
    )
}
