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
import kotlinx.coroutines.CancellationException

private const val TAG = "BackgroundConfigWorker"
internal const val BG_PREFS_NAME = "expo_onebox_background_config"
// 通过 `setBackgroundConfigRefreshOptions` 从 JS 镜像过来的刷新选项。
// 切勿在此读取 JS 持有的 SQLite 数据库：同一个 WAL 文件上再挂一个
// SQLite 库会破坏进程内 POSIX 锁并以 SIGBUS 崩溃。
private const val KEY_ACCELERATE_URL               = "accelerate_url"
private const val KEY_TEST_PRIMARY_URL_UNAVAILABLE = "test_primary_url_unavailable"
private val gson = Gson()

// MARK: - 结果模型

data class ConfigRefreshResult(
    val status: String,           // "success" | "failed" | "skipped"
    val content: String? = null,
    val profileUpload: Long = 0,
    val profileDownload: Long = 0,
    val profileTotal: Long = 0,
    val profileExpire: Long = 0,
    val error: String? = null,
    val timestamp: String,
    val durationMs: Long,
    val profileUserinfoHeader: String? = null,
    val method: String? = null,   // "primary" | "fallback"
    val actualUrl: String? = null, // 实际请求的 URL（加速时为构造后的完整 URL）
    // 本次刷新的来源主配置 URL。JS 侧据此把结果绑定到对应的配置文件——
    // 绝不默认写当前活动配置。旧版本存的结果缺此字段（Gson 解码为 null）。
    val configUrl: String? = null,
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("status", status)
        put("profileUpload", profileUpload)
        put("profileDownload", profileDownload)
        put("profileTotal", profileTotal)
        put("profileExpire", profileExpire)
        put("timestamp", timestamp)
        put("durationMs", durationMs)
        content?.let { put("content", it) }
        error?.let { put("error", it) }
        profileUserinfoHeader?.let { put("profileUserinfoHeader", it) }
        method?.let { put("method", it) }
        actualUrl?.let { put("actualUrl", it) }
        configUrl?.let { put("configUrl", it) }
    }
}

// MARK: - Worker

class BackgroundConfigWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    companion object {
        const val WORK_NAME = "cloud.oneoh.networktools.config-refresh"
        // WorkManager 对周期性工作强制最少 15 分钟。
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
            // 锁在与 ExpoOneBoxModule.getLastConfigRefreshResult 相同的 monitor 上，
            // 使写入不会插在该读取方的 load 与 clear 之间而被静默丢弃。
            synchronized(BackgroundConfigWorker::class.java) {
                context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putString("last_result", gson.toJson(result))
                    .apply()
            }
        }

        fun loadLastResult(context: Context): Map<String, Any?>? {
            val json = context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .getString("last_result", null) ?: return null
            return try {
                // 先反序列化为带类型的 data class，使数值字段成为正确的 Long/String 值。
                // 用 Map::class.java 会把所有数字变成 LazilyParsedNumber，而 Expo Modules API
                // 无法把它序列化到 JS。
                gson.fromJson(json, ConfigRefreshResult::class.java).toMap()
            } catch (_: Exception) { null }
        }

        fun clearLastResult(context: Context) {
            context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .edit().remove("last_result").apply()
        }

        // ─── 域名验证缓存（从 JS 推送）──────────────────────

        private const val KEY_KNOWN_DOMAIN_SHA256     = "known_domain_sha256_list"
        private const val KEY_VERIFIED_DOMAIN_SHA256  = "verified_domain_sha256_list"
        private const val KEY_DOMAIN_VERIFICATION_AT  = "domain_verification_updated_at"
        /// 对应 `src/utils/domain-verification.ts` 中的 `CACHE_TTL_MS`（24 h）。
        internal const val DOMAIN_VERIFICATION_TTL_MS = 24L * 60L * 60L * 1000L

        /// 在每次 `updateVerificationData` 成功后由 JS
        /// （`ExpoOneBoxModule.setVerificationData`）调用。把一个 JSON 数组 + 时间戳
        /// 写入 worker 已在读取的同一份 SharedPreferences。
        fun saveDomainVerificationCache(
            context: Context,
            known: List<String>,
            verified: List<String>,
        ) {
            context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_KNOWN_DOMAIN_SHA256,    gson.toJson(known))
                .putString(KEY_VERIFIED_DOMAIN_SHA256, gson.toJson(verified))
                .putLong(KEY_DOMAIN_VERIFICATION_AT,   System.currentTimeMillis())
                .apply()
        }

        /// 若 JS 推送的 allowlist 存在且未超过 TTL，则返回它。
        /// 返回 null 表示调用方应回落到编译期列表 + 实时抓取。
        internal fun loadFreshDomainVerificationCache(
            context: Context,
        ): Pair<List<String>, List<String>>? {
            val prefs     = context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
            val updatedAt = prefs.getLong(KEY_DOMAIN_VERIFICATION_AT, 0L)
            if (updatedAt <= 0L) return null
            if (System.currentTimeMillis() - updatedAt >= DOMAIN_VERIFICATION_TTL_MS) return null

            val knownJson    = prefs.getString(KEY_KNOWN_DOMAIN_SHA256,    null) ?: return null
            val verifiedJson = prefs.getString(KEY_VERIFIED_DOMAIN_SHA256, null) ?: return null
            return try {
                val known    = gson.fromJson(knownJson,    Array<String>::class.java)?.toList()    ?: emptyList()
                val verified = gson.fromJson(verifiedJson, Array<String>::class.java)?.toList() ?: emptyList()
                if (known.isEmpty() && verified.isEmpty()) null
                else known to verified
            } catch (_: Exception) { null }
        }

        // ─── 刷新选项（从 JS 推送）────────────────────────────────

        /// 在 app 初始化以及每次 dev 开关翻转时由 JS
        /// （`ExpoOneBoxModule.setBackgroundConfigRefreshOptions`）调用。
        /// 全量覆盖两个值，幂等。与 worker 已在读取的同一份 prefs 文件。
        fun saveRefreshOptions(
            context: Context,
            accelerateUrl: String,
            testPrimaryUrlUnavailable: Boolean,
        ) {
            context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_ACCELERATE_URL, accelerateUrl)
                .putBoolean(KEY_TEST_PRIMARY_URL_UNAVAILABLE, testPrimaryUrlUnavailable)
                .apply()
        }

    }

    override suspend fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
        val url          = prefs.getString("config_url", null)
        val userAgent    = prefs.getString("user_agent", "") ?: ""

        Log.i(TAG, "doWork invoked, hasUrl=${!url.isNullOrEmpty()}, runAttempt=$runAttemptCount")

        if (url.isNullOrEmpty()) {
            Log.d(TAG, "No config URL stored, skipping")
            return Result.success()
        }

        val result = executeRefreshWith(applicationContext, url, userAgent)
        storeResult(applicationContext, result)
        return when {
            result.status == "success" -> Result.success()
            // 永久性的 HTTP 4xx（例如 403 表示配置 URL 已吊销）永远不会恢复；
            // 让 WorkManager 指数退避重试会永远循环，浪费唤醒 + 流量。
            // 网络错误和 5xx 才重试。
            isNonRetryableHttpError(result) -> Result.failure()
            else -> Result.retry()
        }
    }
}

/**
 * 当 [result] 因主 HTTP 4xx 状态失败时返回 true，该状态是永久性的，
 * WorkManager 不得重试。回落 both-failed 错误（以瞬时的主网络错误开头）
 * 仍保持可重试。
 */
private fun isNonRetryableHttpError(result: ConfigRefreshResult): Boolean {
    val error = result.error ?: return false
    return Regex("^HTTP 4\\d\\d$").matches(error)
}

// MARK: - 域名验证

// 编译期 allowlist。每一项是一个已批准后缀标签的 SHA256；verifyDomain 会对
// 目标 hostname 的每个渐进后缀（最短优先）做哈希，并在第一个匹配处返回 true，
// 因此更宽的项批准更宽的子树。切勿在本文件或任何注释中记录其原文（pre-image）。
private val KNOWN_DOMAIN_SHA256_LIST = listOf(
    "183a5526e76751b07cd57236bc8f253d5424e02a3fc7da7c30f80919e975125a",
    "59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1",
    "61e245b4e5c234b00865ab0f47ad1cc4a9b37dbc50159febea7e6dcaee8ce050",
)
private const val VERIFIED_LIST_URL   = "https://www.sing-box.net/verified_subscriptions_sha256.txt"

/**
 * 当 [hostname] 的任一后缀（最短优先）哈希后命中 allowlist 中的某项时返回 true。
 * 优先顺序：
 *   1. SharedPreferences 中 JS 推送的缓存（24h TTL，零网络）。
 *   2. 编译期 `KNOWN_DOMAIN_SHA256_LIST` —— 始终可用。
 *   3. 从 `VERIFIED_LIST_URL` 实时抓取 —— 仅当共享缓存缺失或过期时
 *      （例如周期 worker 在 JS 从未调用过 `setVerificationData` 之前就触发）。
 */
private suspend fun verifyDomain(hostname: String, context: Context): Boolean {
    val candidates = hostnameSuffixCandidates(hostname)
    val hashed     = candidates.map { sha256Hex(it) }
    val hashedSet  = hashed.toSet()

    // 来源 1 —— JS 推送的缓存。
    BackgroundConfigWorker.loadFreshDomainVerificationCache(context)?.let { (known, verified) ->
        val union = (known + verified).toSet()
        if (hashedSet.any { it in union }) return true
        // 缓存是新鲜的但未命中；放弃前仍先参考下面的编译期列表。
        if (hashed.any { it in KNOWN_DOMAIN_SHA256_LIST }) return true
        return false
    }

    // 来源 2 —— 编译期回落。
    if (hashed.any { it in KNOWN_DOMAIN_SHA256_LIST }) return true

    // 来源 3 —— 实时抓取（仅恢复路径）。
    return try {
        val conn = java.net.URL(VERIFIED_LIST_URL).openConnection() as java.net.HttpURLConnection
        conn.connectTimeout = 10_000
        conn.readTimeout    = 10_000
        if (conn.responseCode !in 200..299) return false
        val text   = conn.inputStream.bufferedReader().readText()
        val remote = text.lines().map { it.trim() }.filter { it.isNotEmpty() }.toSet()
        hashed.any { it in remote }
    } catch (_: Exception) {
        false
    }
}

// MARK: - 加速 URL 辅助函数

/** 构造加速变体：<accelerateBase>/<sha256(host)><path+query> */
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

private fun throwPrimaryUnavailableForTest(): Nothing {
    throw IllegalStateException("TEST MODE: primary URL unavailable")
}

private fun summarizeAccelerateUrl(value: String?): String {
    if (value.isNullOrBlank()) return "empty"
    val trimmed = value.trim()
    val host = runCatching { android.net.Uri.parse(trimmed).host }.getOrNull()
    return if (!host.isNullOrBlank()) "set(host=$host,len=${trimmed.length})"
    else "set(unparseable,len=${trimmed.length})"
}

private fun isTestPrimaryUrlUnavailableEnabled(context: Context): Boolean {
    return context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
        .getBoolean(KEY_TEST_PRIMARY_URL_UNAVAILABLE, false)
}

private fun readAccelerateUrl(context: Context): String? {
    return context.getSharedPreferences(BG_PREFS_NAME, Context.MODE_PRIVATE)
        .getString(KEY_ACCELERATE_URL, null)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
}

// MARK: - 回落预检（两个 fetch executor 共用）

internal data class FallbackPreflight(
    val host: String,
    val domainSha: String,
    val verified: Boolean,
    val testPrimaryUnavailable: Boolean,
    val accelerateUrl: String?,
)

/**
 * [fetchProfileConfigWithFallback] 与 [executeRefreshWith] 的共享前置逻辑：
 * 解析 host、验证域名，并读取 JS 推送的 test/accelerate 开关。两个调用方的行为
 * 完全相同；[logLabel] 只给诊断行打标签，使两个调用点在 logcat 中可区分。
 */
private suspend fun prepareFallbackPreflight(
    context: Context,
    url: String,
    logLabel: String,
): FallbackPreflight {
    val host      = android.net.Uri.parse(url).host ?: ""
    val domainSha = sha256Hex(host)
    val verified  = verifyDomain(host, context)
    if (!verified) {
        Log.w(TAG, "[CONFIG_LOAD] method=DOMAIN_UNVERIFIED, domainSha256=$domainSha, accelerator fallback disabled")
    }
    val testPrimaryUnavailable = isTestPrimaryUrlUnavailableEnabled(context)
    val accelerateUrl = readAccelerateUrl(context)
    Log.i(
        TAG,
        "[CONFIG_LOAD] pre-request switch state($logLabel): testPrimaryUnavailable=$testPrimaryUnavailable, accelerate=${summarizeAccelerateUrl(accelerateUrl)}",
    )
    return FallbackPreflight(host, domainSha, verified, testPrimaryUnavailable, accelerateUrl)
}

// MARK: - 共享 fetch executor（前台原生 fetchProfileConfig）

/**
 * 带可选加速回落的原生 fetchProfileConfig 路径。
 *
 * 规则与 executeRefreshWith 一致：
 *   1. 先尝试主 URL
 *   2. 只有网络异常才触发回落（HTTP 非 2xx 不触发）
 *   3. 回落要求域名已验证 + JS 推送的加速 URL
 *
 * 当 JS 推送的 `testPrimaryUrlUnavailable` 选项开启时，主请求会主动抛出，
 * 以模拟网络失败来测试回落。
 *
 * cancellation 会被重新抛出——它绝不能触发加速回落。
 */
/** 共享 [fetchWithFallback] 控制流的结果。 */
internal sealed class FallbackOutcome {
    /** 主结果（任意 HTTP 状态）或一次成功的加速抓取。 */
    data class Ok(
        val result: ConfigFetchResult,
        val method: String,        // "primary" | "fallback"
        val actualUrl: String,
        val primaryError: String? = null, // 当 method == "fallback" 时设置
    ) : FallbackOutcome()
    /** 主请求抛出网络错误且回落被跳过。 */
    data class NoFallback(val primaryError: String, val reason: String) : FallbackOutcome() // "unverified" | "no-accelerator"
    /** 主请求抛出，且加速抓取也抛出。 */
    data class BothFailed(val primaryError: String, val accError: String, val accUrl: String) : FallbackOutcome()
}

/**
 * 主 → gate → 加速器 的控制流。[fetch] 与 [log] 以注入方式传入，使决策是纯的、
 * 可在 JVM 上测试：结果只取决于 [preflight] 与 [fetch] 的结果。HTTP 错误作为主
 * Ok 返回（非 2xx 从不回落）；只有网络抛出才会走 gate；cancellation 始终重新抛出。
 */
internal suspend fun fetchWithFallback(
    preflight: FallbackPreflight,
    url: String,
    userAgent: String,
    fetch: suspend (String, String) -> ConfigFetchResult = ::fetchConfig,
    log: (String) -> Unit = { Log.i(TAG, it) },
    buildAccelUrl: (String, String) -> String = ::buildAcceleratedUrl,
): FallbackOutcome {
    val primaryError: String = try {
        if (preflight.testPrimaryUnavailable) {
            log("[CONFIG_LOAD] test mode: primary URL actively throwing exception")
            throwPrimaryUnavailableForTest()
        }
        // HTTP 错误（非 2xx）不触发回落——原样返回响应。
        return FallbackOutcome.Ok(fetch(url, userAgent), "primary", url)
    } catch (ce: CancellationException) {
        throw ce
    } catch (primaryEx: Exception) {
        val err = primaryEx.message ?: "Unknown error"
        log("[CONFIG_LOAD] primary URL exception: $err, checking fallback conditions")
        err
    }

    if (!preflight.verified) return FallbackOutcome.NoFallback(primaryError, "unverified")
    if (preflight.accelerateUrl.isNullOrBlank()) return FallbackOutcome.NoFallback(primaryError, "no-accelerator")

    val accUrl = buildAccelUrl(url, preflight.accelerateUrl)
    log("[CONFIG_LOAD] primary URL failed, trying accelerator fallback: ${summarizeAccelerateUrl(accUrl)}, reason: $primaryError")
    return try {
        FallbackOutcome.Ok(fetch(accUrl, userAgent), "fallback", accUrl, primaryError)
    } catch (ce: CancellationException) {
        throw ce
    } catch (accEx: Exception) {
        FallbackOutcome.BothFailed(primaryError, accEx.message ?: "Unknown error", accUrl)
    }
}

internal suspend fun fetchProfileConfigWithFallback(
    context: Context,
    url: String,
    userAgent: String,
): ConfigFetchResult {
    val preflight = prepareFallbackPreflight(context, url, "fetchProfileConfig")
    return when (val o = fetchWithFallback(preflight, url, userAgent)) {
        is FallbackOutcome.Ok         -> o.result
        is FallbackOutcome.NoFallback -> throw IllegalStateException(o.primaryError)
        is FallbackOutcome.BothFailed -> throw IllegalStateException("primary=${o.primaryError} accelerated=${o.accError}")
    }
}

// MARK: - 共享 refresh executor（前台 + 后台）

/**
 * 抓取 [url]，失败时回落到 JS 推送的加速 URL。
 * 核心逻辑：
 *   1. 尝试 [url]（主）
 *   2. 若失败（网络异常）且域名已验证 → 尝试加速 URL
 *   3. 返回带 method 信息的结果
 * HTTP 错误（非 2xx）不触发回落。
 * 测试模式：在主 URL 上主动抛出以测试回落路径。
 * cancellation 会被重新抛出——它绝不能触发加速回落。
 */
internal suspend fun executeRefreshWith(
    context: Context,
    url: String,
    userAgent: String,
): ConfigRefreshResult {
    val start     = System.currentTimeMillis()
    val timestamp = Instant.now().toString()
    val preflight = prepareFallbackPreflight(context, url, "executeRefresh")

    // 主 → gate → 加速器 的控制流与 fetchProfileConfigWithFallback 共享；
    // 这里只把结果解释为 ConfigRefreshResult + CONFIG_LOAD 诊断。
    // 末尾的 copy(configUrl = url) 单点覆盖全部分支：结果始终携带来源主 URL。
    return when (val o = fetchWithFallback(preflight, url, userAgent)) {
        is FallbackOutcome.Ok -> {
            val durationMs  = System.currentTimeMillis() - start
            val ok2xx       = o.result.statusCode in 200..299
            val headerValue = o.result.headers["subscription-userinfo"]
            when {
                o.method == "primary" && !ok2xx -> {
                    Log.w(TAG, "[CONFIG_LOAD] method=HTTP_ERROR_NO_FALLBACK, HTTP ${o.result.statusCode}, no fallback")
                    ConfigRefreshResult(
                        status    = "failed",
                        error     = "HTTP ${o.result.statusCode}",
                        timestamp = timestamp,
                        durationMs = durationMs,
                        method    = "primary",
                    )
                }
                o.method == "primary" -> {
                    val info = parseUserinfo(headerValue)
                    Log.i(TAG, "[CONFIG_LOAD] method=PRIMARY, upload=${info.upload}, download=${info.download}, total=${info.total}, expire=${info.expire}")
                    ConfigRefreshResult(
                        status             = "success",
                        content            = o.result.body,
                        profileUpload   = info.upload,
                        profileDownload = info.download,
                        profileTotal    = info.total,
                        profileExpire   = info.expire,
                        timestamp          = timestamp,
                        durationMs         = durationMs,
                        profileUserinfoHeader = headerValue,
                        method             = "primary",
                    )
                }
                !ok2xx -> {
                    // 加速抓取返回了 HTTP 错误 → 两者都失败。
                    val accError = "HTTP ${o.result.statusCode}"
                    Log.e(TAG, "[CONFIG_LOAD] method=BOTH_FAILED, accelerator reason=$accError, primary reason=${o.primaryError}")
                    ConfigRefreshResult(
                        status    = "failed",
                        error     = "primary=${o.primaryError} accelerated=$accError",
                        timestamp = timestamp,
                        durationMs = durationMs,
                        method    = "fallback",
                        actualUrl = o.actualUrl,
                    )
                }
                else -> {
                    val info = parseUserinfo(headerValue)
                    Log.i(TAG, "[CONFIG_LOAD] method=FALLBACK_ACCELERATOR, upload=${info.upload}, download=${info.download}, total=${info.total}, expire=${info.expire}")
                    ConfigRefreshResult(
                        status             = "success",
                        content            = o.result.body,
                        profileUpload   = info.upload,
                        profileDownload = info.download,
                        profileTotal    = info.total,
                        profileExpire   = info.expire,
                        timestamp          = timestamp,
                        durationMs         = durationMs,
                        profileUserinfoHeader = headerValue,
                        method             = "fallback",
                        actualUrl          = o.actualUrl,
                    )
                }
            }
        }
        is FallbackOutcome.NoFallback -> {
            val durationMs = System.currentTimeMillis() - start
            if (o.reason == "unverified") {
                Log.w(TAG, "[CONFIG_LOAD] method=ACCELERATOR_SKIPPED, reason=domain unverified (SHA256=${preflight.domainSha}), primary reason: ${o.primaryError}")
            } else {
                Log.w(TAG, "[CONFIG_LOAD] method=ACCELERATOR_UNAVAILABLE, reason=accelerate URL not configured, primary reason: ${o.primaryError}")
            }
            ConfigRefreshResult(
                status    = "failed",
                error     = o.primaryError,
                timestamp = timestamp,
                durationMs = durationMs,
                method    = "primary",
            )
        }
        is FallbackOutcome.BothFailed -> {
            val durationMs = System.currentTimeMillis() - start
            Log.e(TAG, "[CONFIG_LOAD] method=BOTH_FAILED, accelerator reason=${o.accError}, primary reason=${o.primaryError}")
            ConfigRefreshResult(
                status    = "failed",
                error     = "primary=${o.primaryError} accelerated=${o.accError}",
                timestamp = timestamp,
                durationMs = durationMs,
                method    = "fallback",
                actualUrl = o.accUrl,
            )
        }
    }.copy(configUrl = url)
}

// MARK: - subscription-userinfo header 解析器

internal data class TrafficInfo(
    val upload: Long,
    val download: Long,
    val total: Long,
    val expire: Long,
)

// 这是该解析器在 4 个平台上的副本之一（Android + iOS + JS + web stub）。
// 溢出行为尚未统一，在统一之前请保持本实现不变。
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
