package expo.modules.onebox.oneoh.cloud

import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService
import expo.modules.kotlin.Promise
import expo.modules.kotlin.functions.Coroutine
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.onebox.oneoh.cloud.core.ServiceConnection
import expo.modules.onebox.oneoh.cloud.core.VPNService
import expo.modules.onebox.oneoh.cloud.helper.Action
import expo.modules.onebox.oneoh.cloud.helper.Alert
import expo.modules.onebox.oneoh.cloud.helper.BackgroundConfigWorker
import expo.modules.onebox.oneoh.cloud.helper.BG_PREFS_NAME
import expo.modules.onebox.oneoh.cloud.helper.Bugs
import expo.modules.onebox.oneoh.cloud.helper.Status
import expo.modules.onebox.oneoh.cloud.helper.fetchProfileConfigWithFallback
import expo.modules.onebox.oneoh.cloud.helper.findBestDnsServer
import expo.modules.onebox.oneoh.cloud.helper.getWorkingDir
import expo.modules.onebox.oneoh.cloud.helper.executeRefreshWith
import expo.modules.onebox.oneoh.cloud.helper.processConfig
import expo.modules.onebox.oneoh.cloud.helper.GROUP_AUTO
import expo.modules.onebox.oneoh.cloud.helper.GROUP_EXIT_GATEWAY
import expo.modules.onebox.oneoh.cloud.helper.ProxyGroupSnapshot
import expo.modules.onebox.oneoh.cloud.helper.parseExitGatewayGroups
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogEntry
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.sfa.utils.CommandClient
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.GlobalScope
import org.json.JSONObject
import java.io.File

// SharedPreferences keys mirrored into the background worker's store.
// Canonical home is BackgroundConfigWorker.kt (alongside KEY_ACCELERATE_URL);
// declared here for the write side until the worker file is migrated to share them.
private const val KEY_BG_CONFIG_URL = "config_url"
private const val KEY_BG_USER_AGENT = "user_agent"

class ExpoOneBoxModule : ServiceConnection.Callback, Module() {

    private val context
        get() = appContext.reactContext!!

    private val app: Application
        get() = appContext.reactContext?.applicationContext as? Application
            ?: throw IllegalStateException("Application context not available")

    private lateinit var connection: ServiceConnection
    private var vpnPermissionPromise: Promise? = null
    private var batteryOptPromise: Promise? = null
    @Volatile private var lastStartConfig: String = ""

    // ==================== 日志/流量实时监控 ====================

    /** 监听 libbox CommandServer 的日志和状态流量，并推送到 JS 层 */
    @OptIn(DelicateCoroutinesApi::class)
    private val statusMonitor by lazy {
        CommandClient(
            GlobalScope,
            listOf(CommandClient.ConnectionType.Log, CommandClient.ConnectionType.Status, CommandClient.ConnectionType.Groups),
            object : CommandClient.Handler {
                override fun appendLogs(message: List<LogEntry>) {
                    if (!coreLogEnabled) return
                    // Filter before IPC: sing-box's platform writer
                    // bypasses log.level, so every entry arrives here
                    // regardless of config. See vpn-context.tsx top-of-
                    // file comment for the source reference.
                    val max = coreLogLevelMax
                    for (entry in message) {
                        if (entry.level.toInt() > max) continue
                        try {
                            sendEvent("onLog", mapOf("message" to entry.message))
                        } catch (_: Exception) {}
                    }
                }
                override fun updateStatus(status: StatusMessage) {
                    try {
                        sendEvent(
                            "onTrafficUpdate",
                            mapOf(
                                "uplink"              to status.uplink,
                                "downlink"            to status.downlink,
                                "uplinkTotal"         to status.uplinkTotal,
                                "downlinkTotal"       to status.downlinkTotal,
                                "uplinkDisplay"       to (Libbox.formatBytes(status.uplink) + "/s"),
                                "downlinkDisplay"     to (Libbox.formatBytes(status.downlink) + "/s"),
                                "uplinkTotalDisplay"  to Libbox.formatBytes(status.uplinkTotal),
                                "downlinkTotalDisplay" to Libbox.formatBytes(status.downlinkTotal),
                                "memory"              to status.memory,
                                "memoryDisplay"       to Libbox.formatBytes(status.memory),
                                "goroutines"          to status.goroutines,
                                "connectionsIn"       to status.connectionsIn,
                                "connectionsOut"      to status.connectionsOut
                            )
                        )
                    } catch (_: Exception) {}
                }
                override fun updateGroups(newGroups: MutableList<OutboundGroup>) {
                    try {
                        val (all, now, autoNow) = parseExitGatewayGroups(snapshotGroups(newGroups.iterator()))
                        sendEvent("onGroupUpdate", mapOf("all" to all, "now" to now, "autoNow" to autoNow))
                    } catch (_: Exception) {}
                }
            }
        )
    }

    companion object {
        private const val TAG = "ExpoOneBoxModule"

        lateinit var application: Application
        const val VPN_REQUEST_CODE = 1001
        const val BATTERY_OPT_REQUEST_CODE = 1002

        @Volatile var currentStatus: Status = Status.Stopped
        @Volatile var isStartingUp: Boolean = false
        @Volatile var coreLogEnabled: Boolean = false
        /**
         * Maximum sing-box level code to forward to JS. Codes mirror
         * `log/level.go`: panic=0, fatal=1, error=2, warn=3, info=4,
         * debug=5, trace=6. Entries with `level > coreLogLevelMax` are
         * dropped at `appendLogs`. Default matches the app default.
         */
        @Volatile var coreLogLevelMax: Int = 4 // info
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val packageManager by lazy { application.packageManager }
        val powerManager by lazy { application.getSystemService<PowerManager>()!! }
        val notificationManager by lazy { application.getSystemService<NotificationManager>()!! }
        // Alias for the single notificationManager instance (kept for ServiceNotification).
        val notification get() = notificationManager
        val wifiManager by lazy { application.getSystemService<WifiManager>()!! }
        val clipboard by lazy { application.getSystemService<ClipboardManager>()!! }
    }

    private fun initialize() {
        application = app
        val baseDir = context.filesDir
        baseDir.mkdirs()
        val workingDir = getWorkingDir(context)
        workingDir.mkdirs()
        val tempDir = context.cacheDir
        tempDir.mkdirs()
        Libbox.setup(
            SetupOptions().also {
                it.basePath = baseDir.path
                Log.i(TAG, "basePath: ${it.basePath}")
                it.workingPath = workingDir.path
                Log.i(TAG, "workingPath: ${it.workingPath}")
                it.tempPath = tempDir.path
                Log.i(TAG, "tempPath: ${it.tempPath}")
                it.fixAndroidStack = Bugs.fixAndroidStack
                it.logMaxLines = 3000
                it.debug = BuildConfig.DEBUG
            },
        )
        Libbox.setMemoryLimit(true)
        Libbox.redirectStderr(File(workingDir, "stderr.log").path)
    }

    /**
     * Emit a native-layer log line to JS.
     *
     * Distinct from `sendEvent("onLog", ...)` which carries the libbox /
     * sing-box core output. This channel is for the Kotlin module's own
     * activity — lifecycle hooks, permission flows, background worker
     * transitions — so the user can distinguish "the JS–native bridge is
     * alive" from "the core is running."
     *
     * Writes to logcat at the matching level as well, so platform
     * tooling (`adb logcat`) still sees the event with source context.
     */
    private fun sendNativeLog(level: String, tag: String, message: String) {
        val logTag = "ExpoOneBox/$tag"
        val normalizedLevel = when (level) {
            "error" -> "error"
            "warn"  -> "warn"
            else    -> "info"
        }
        when (normalizedLevel) {
            "error" -> Log.e(logTag, message)
            "warn"  -> Log.w(logTag, message)
            else    -> Log.i(logTag, message)
        }
        try {
            sendEvent("onNativeLog", mapOf(
                "level" to normalizedLevel,
                "tag" to tag,
                "message" to message,
            ))
        } catch (_: Exception) {}
    }

    override fun definition() = ModuleDefinition {
        Name("ExpoOneBox")

        // 定义发送到 JS 的事件
        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate", "onGroupUpdate", "onNativeLog")

        OnCreate {
            try {
                initialize()
                connection = ServiceConnection(context, this@ExpoOneBoxModule)
                connection.connect()
                sendNativeLog("info", "Module", "ExpoOneBox Kotlin module initialized")
            } catch (e: Exception) {
                Log.e(TAG, "初始化失败", e)
                sendNativeLog("error", "Module", "init failed: ${e.message}")
            }
        }

        OnDestroy {
            sendNativeLog("info", "Module", "ExpoOneBox Kotlin module destroying")
            try {
                statusMonitor.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "statusMonitor 销毁失败", e)
            }
            try {
                connection.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "销毁时清理失败", e)
            }
        }

        OnActivityResult { _, (requestCode, resultCode, _) ->
            if (requestCode == VPN_REQUEST_CODE) {
                vpnPermissionPromise?.let { promise ->
                    promise.resolve(resultCode == Activity.RESULT_OK)
                    vpnPermissionPromise = null
                }
            }
            if (requestCode == BATTERY_OPT_REQUEST_CODE) {
                batteryOptPromise?.let { promise ->
                    val exempt = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                        powerManager.isIgnoringBatteryOptimizations(context.packageName)
                    } else {
                        true
                    }
                    promise.resolve(exempt)
                    batteryOptPromise = null
                }
            }
        }

        // 获取当前 VPN 状态
        Function("getStatus") {
            return@Function try {
                // 主动查询服务的真实状态，而不是依赖可能过期的 currentStatus
                val actualStatus = connection.status
                // 同时更新内部状态变量，保持同步
                currentStatus = actualStatus
                actualStatus.ordinal
            } catch (e: Exception) {
                Log.w(TAG, "查询服务状态失败: ${e.message}")
                // 查询失败时返回当前缓存的状态
                currentStatus.ordinal
            }
        }

        Function("crashForBugsnagTest") {
            Log.e(TAG, "Triggering intentional native crash for Bugsnag verification")
            Handler(Looper.getMainLooper()).post {
                throw RuntimeException("Bugsnag Android native crash test")
            }
            true
        }

        Function("repairSQLiteDirectory") {
            val sqliteDir = File(context.filesDir, "SQLite")
            return@Function try {
                if (sqliteDir.exists() && !sqliteDir.isDirectory) {
                    val deleted = sqliteDir.delete()
                    if (!deleted) {
                        Log.w(TAG, "[SQLiteRepair] Failed to delete non-directory path: ${sqliteDir.absolutePath}")
                        return@Function false
                    }
                    Log.w(TAG, "[SQLiteRepair] Deleted non-directory path: ${sqliteDir.absolutePath}")
                }
                sqliteDir.mkdirs() || sqliteDir.isDirectory
            } catch (e: Exception) {
                Log.w(TAG, "[SQLiteRepair] Failed to repair SQLite directory: ${e.message}")
                false
            }
        }

        Function("setCoreLogEnabled") { enabled: Boolean ->
            coreLogEnabled = enabled
            Log.d(TAG, "Core log output ${if (enabled) "enabled" else "disabled"}")
        }

        // Client-side filter for the CommandServer log stream. Needed
        // because sing-box's `log.level` config only filters stdout
        // and the observable sink — the platform writer (which feeds
        // our CommandClient) is unconditional.
        Function("setCoreLogLevel") { level: String ->
            val code = when (level.lowercase()) {
                "panic" -> 0
                "fatal" -> 1
                "error" -> 2
                "warn", "warning" -> 3
                "info" -> 4
                "debug" -> 5
                "trace" -> 6
                else -> 4
            }
            coreLogLevelMax = code
            sendNativeLog("info", "Module", "core log level filter → $level (code $code)")
        }

        // Returns the last startup error written to startup_error.txt by the VPN service.
        // Empty string means no error (or last start succeeded).
        // JS layer calls this when status transitions STARTING → STOPPED.
        Function("getStartError") {
            return@Function try {
                val file = File(getWorkingDir(context), "startup_error.txt")
                if (file.exists()) file.readText().trim() else ""
            } catch (e: Exception) {
                ""
            }
        }

        Function("getStartConfig") {
            if (lastStartConfig.isNotEmpty()) return@Function lastStartConfig
            return@Function try {
                val file = File(getWorkingDir(context), "last_start_config.json")
                if (file.exists()) file.readText().trim() else ""
            } catch (_: Exception) { "" }
        }

        AsyncFunction("checkVpnPermission") {
            val vpnIntent = VpnService.prepare(context)
            return@AsyncFunction vpnIntent == null
        }

        AsyncFunction("requestVpnPermission") { promise: Promise ->
            val vpnIntent = VpnService.prepare(context)
            if (vpnIntent != null) {
                vpnPermissionPromise = promise
                appContext.currentActivity?.startActivityForResult(vpnIntent, VPN_REQUEST_CODE)
            } else {
                promise.resolve(true)
            }
        }

        Function("checkBatteryOptimizationExemption") {
            return@Function if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                powerManager.isIgnoringBatteryOptimizations(context.packageName)
            } else {
                true
            }
        }

        AsyncFunction("requestBatteryOptimizationExemption") { promise: Promise ->
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) {
                promise.resolve(true)
                return@AsyncFunction
            }
            if (powerManager.isIgnoringBatteryOptimizations(context.packageName)) {
                promise.resolve(true)
                return@AsyncFunction
            }
            val intent = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
            }
            batteryOptPromise = promise
            appContext.currentActivity?.startActivityForResult(intent, BATTERY_OPT_REQUEST_CODE)
                ?: run {
                    batteryOptPromise = null
                    promise.resolve(false)
                }
        }

        // ---- copy2CacheDbPath: 将 JS 传入的 asset URI 原生复制为 tun.db，已存在则跳过 ----
        AsyncFunction("copy2CacheDbPath") { sourceUri: String ->
            val workingDir = getWorkingDir(context)
            val destFile = File(workingDir, "tun.db")
            if (destFile.exists()) {
                Log.i(TAG, "[copy2CacheDbPath] tun.db already exists, skipping")
                return@AsyncFunction false
            }
            val uri = android.net.Uri.parse(sourceUri)
            val inputStream = context.contentResolver.openInputStream(uri)
                ?: context.contentResolver.openInputStream(android.net.Uri.fromFile(File(uri.path ?: sourceUri.removePrefix("file://"))))
                ?: throw Exception("Cannot open sourceUri: $sourceUri")
            inputStream.use { input ->
                destFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            Log.i(TAG, "[copy2CacheDbPath] tun.db copied to ${destFile.absolutePath}")
            return@AsyncFunction true
        }

        AsyncFunction("start") { config: String ->
            sendNativeLog("info", "Tunnel", "start() requested, config bytes=${config.length}")
            val processedConfig = processConfig(config, context)
            lastStartConfig = processedConfig
            try {
                File(getWorkingDir(context), "last_start_config.json").writeText(processedConfig)
            } catch (_: Exception) {}

            // 打印实际传给 VPN 的配置中 inbounds 地址信息，用于排查
            try {
                val debugJson = JSONObject(processedConfig)
                val inbounds = debugJson.optJSONArray("inbounds")
                if (inbounds != null && inbounds.length() > 0) {
                    val tun = inbounds.getJSONObject(0)
                    Log.d(TAG, "[module] TUN config address: ${tun.optJSONArray("address")}")
                    Log.d(TAG, "[module] TUN config route_exclude: ${tun.optJSONArray("route_exclude_address")}")
                }
            } catch (_: Exception) {}

            // 检查规则集缓存文件是否存在
            val workingDir = getWorkingDir(context).absolutePath
            val cachePath = "$workingDir/tun.db"
            Log.i(TAG, "cachePath: $cachePath")
            if (!File(cachePath).exists()){
                Log.e(TAG, "规则集缓存文件不存在: $cachePath")

            }else{
                Log.i(TAG, "规则集缓存文件存在: $cachePath")
            }

            isStartingUp = true
            startVPNService(processedConfig)
        }

        AsyncFunction("stop") {
            sendNativeLog("info", "Tunnel", "stop() requested")
            // 发送停止广播
            context.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(context.packageName)
            )
            Log.d(TAG, "服务停止命令已发送")
        }

        // ---- triggerURLTest: 触发 URLTest (单节点 tag 或 group tag 如 "ExitGateway") ----
        AsyncFunction("triggerURLTest") { tag: String ->
            try {
                val client = Libbox.newStandaloneCommandClient()
                client?.urlTest(tag)
                true
            } catch (e: Exception) {
                Log.w(TAG, "triggerURLTest failed: ${e.message}")
                false
            }
        }

        // ---- selectProxyNode: 通过 libbox StandaloneCommandClient 选择节点 ----
        AsyncFunction("selectProxyNode") { tag: String ->
            try {
                val client = Libbox.newStandaloneCommandClient()
                client?.selectOutbound(GROUP_EXIT_GATEWAY, tag)
                true
            } catch (e: Exception) {
                Log.w(TAG, "selectProxyNode failed: ${e.message}")
                false
            }
        }

        Function("getLibBoxVersion") {
            return@Function Libbox.version()
        }

        AsyncFunction("getBestDns") Coroutine { ->
            findBestDnsServer()
        }

        // ─── Config Fetching (DNS-resolved) ─────────────────────────────────────

        // Fetch a config URL using DNS resolution + optional accelerator fallback.
        // Accelerator URL comes from the JS-pushed shared options (SharedPreferences).
        AsyncFunction("fetchProfileConfig") Coroutine { url: String, userAgent: String ->
            val result = fetchProfileConfigWithFallback(
                app,
                url,
                userAgent,
            )
            mapOf(
                "statusCode" to result.statusCode,
                "headers" to result.headers,
                "body" to result.body,
            )
        }

        // ─── Native Background Config Refresh ────────────────────────────────────

        // Push the JS-managed domain allowlist into the same SharedPreferences
        // the WorkManager worker reads. Called after every successful
        // `updateVerificationData()` in `domain-verification.ts` so the worker
        // does not re-fetch the remote list on every wake. 24h TTL is enforced
        // on the read side (BackgroundConfigWorker.verifyDomain).
        AsyncFunction("setVerificationData") { data: Map<String, Any?> ->
            @Suppress("UNCHECKED_CAST")
            val known    = (data["knownSha256List"]    as? List<String>) ?: emptyList()
            @Suppress("UNCHECKED_CAST")
            val verified = (data["verifiedSha256List"] as? List<String>) ?: emptyList()
            BackgroundConfigWorker.saveDomainVerificationCache(app, known, verified)
        }

        // Mirror JS-managed refresh options into the worker's SharedPreferences
        // so the WorkManager task never opens the JS-owned SQLite database —
        // a second SQLite library on the same WAL file crashes with SIGBUS.
        AsyncFunction("setBackgroundConfigRefreshOptions") { options: Map<String, Any?> ->
            val accelerateUrl = options["accelerateUrl"] as? String ?: ""
            val testFlag      = options["testPrimaryUrlUnavailable"] as? Boolean ?: false
            BackgroundConfigWorker.saveRefreshOptions(app, accelerateUrl, testFlag)
        }

        // Register (or update) the WorkManager periodic task.
        AsyncFunction("registerBackgroundConfigRefresh") { url: String, userAgent: String, intervalSeconds: Int ->
            app.getSharedPreferences(BG_PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_BG_CONFIG_URL, url)
                .putString(KEY_BG_USER_AGENT, userAgent)
                .apply()
            BackgroundConfigWorker.schedule(app, intervalSeconds.toLong())
            Log.i(TAG, "Background config refresh registered (interval=${intervalSeconds}s)")
        }

        // Execute config refresh immediately (foreground / dev screen).
        AsyncFunction("executeConfigRefreshNow") Coroutine { url: String, userAgent: String ->
            val result = executeRefreshWith(app, url, userAgent)
            // Do NOT storeResult here: JS receives the result directly and calls
            // applyResultToSBConfig() itself. Storing would overwrite any pending
            // background doWork() result in SharedPrefs, causing it to be lost.
            result.toMap()
        }

        // Return and clear the last result stored by the background worker.
        // Use app (not reactContext) to avoid NullPointerException during bridge teardown.
        Function("getLastConfigRefreshResult") {
            // Load and clear as one critical section so a concurrent worker write
            // is not silently dropped between the two calls. BackgroundConfigWorker
            // .storeResult locks on this same monitor, so the load/clear pair is
            // atomic against a concurrent write.
            synchronized(BackgroundConfigWorker::class.java) {
                val result = BackgroundConfigWorker.loadLastResult(app) ?: return@Function null
                BackgroundConfigWorker.clearLastResult(app)
                return@Function result
            }
        }

        // Whether a WorkManager periodic task is currently enqueued/running.
        AsyncFunction("isBackgroundConfigRefreshRegistered") {
            BackgroundConfigWorker.isRegistered(app)
        }
    }

    // ==================== ServiceConnection.Callback ====================

    @OptIn(DelicateCoroutinesApi::class)
    override fun onServiceStatusChanged(status: Status) {

        try {
            // 使用独立的 isStartingUp 标记而非检查 currentStatus，
            // 因为状态可能经过 Starting → Stopping → Stopped，
            // 到达 Stopped 时 currentStatus 已经是 Stopping。
            val wasStarting = isStartingUp

            val statusName = when (status) {
                Status.Stopped -> "stopped"
                Status.Starting -> "connecting"
                Status.Started -> "connected"
                Status.Stopping -> "disconnecting"
            }

            when (status) {
                Status.Starting -> isStartingUp = true
                Status.Started -> {
                    isStartingUp = false
                    // VPN 已连接，开始监听日志和流量
                    try { statusMonitor.connect() } catch (e: Exception) {
                        Log.w(TAG, "statusMonitor connect failed: ${e.message}")
                    }
                }
                Status.Stopped -> {
                    isStartingUp = false
                    // VPN 已停止，断开监控
                    try { statusMonitor.disconnect() } catch (e: Exception) {
                        Log.w(TAG, "statusMonitor disconnect failed: ${e.message}")
                    }
                }
                else -> {}
            }

            currentStatus = status

            Log.d(TAG, "Status changed: $statusName, wasStarting=$wasStarting, isStartingUp=$isStartingUp")
            sendNativeLog("info", "Tunnel", "status → $statusName")

            sendEvent("onStatusChange", mapOf(
                "status" to status.ordinal,
                "statusName" to statusName,
                "message" to "Service status: $statusName"
            ))

            // 主动检测启动失败
            if (status == Status.Stopped && wasStarting) {
                val errMsg = try {
                    val file = File(getWorkingDir(context), "startup_error.txt")
                    // Strip the same source prefix onServiceAlert removes so a single
                    // failure surfaces consistent text across both onError emissions.
                    if (file.exists()) file.readText().trim().removePrefix("[binary] ") else ""
                } catch (_: Exception) { "" }

                // Language-neutral token; the JS layer localizes it (audit C9).
                val message = errMsg.ifEmpty { "START_FAILED_GENERIC" }
                Log.e(TAG, "Startup failure detected: $message")
                sendEvent("onError", mapOf(
                    "type" to "StartServiceFailed",
                    "message" to message,
                    "source" to "binary",
                    "status" to status.ordinal
                ))
            }

        } catch (e: Exception) {
            Log.w(TAG, "发送状态变更事件失败: ${e.message}")
        }
    }

    override fun onServiceAlert(type: Alert, message: String?) {


        try {
            val rawMessage = message ?: "Unknown error"

            // 从错误消息前缀判断错误来源
            // [binary] = libbox Go 二进制错误 (配置解析、TUN 创建、协议错误等)
            // [android] = Android 平台代码错误 (VPN 权限、通知、服务生命周期等)
            // [module] = Expo 模块层错误 (JS 交互、配置处理等)
            val source = when {
                rawMessage.startsWith("[binary]") -> "binary"
                rawMessage.startsWith("[android]") -> "android"
                rawMessage.startsWith("[module]") -> "module"
                // 没有前缀的错误根据 Alert 类型推断来源
                type == Alert.CreateService -> "binary"   // commandServer.startOrReloadService 抛出的
                type == Alert.StartCommandServer -> "android"
                type == Alert.EmptyConfiguration -> "module"
                type == Alert.StartService -> "android"
                else -> "unknown"
            }

            // 清理前缀，让消息更干净
            var cleanMessage = rawMessage
                .removePrefix("[binary] ")
                .removePrefix("[android] ")
                .removePrefix("[module] ")

            // 检测是否为规则集下载失败
            if (type == Alert.CreateService && rawMessage.contains("initialize rule-set")) {
                // Language-neutral tokens; the JS layer localizes them (audit C9).
                if (rawMessage.contains("connection reset by peer")) {
                    cleanMessage = "RULESET_DOWNLOAD_RESET"
                } else if (rawMessage.contains("Application error 0x0")) {
                    cleanMessage = "RULESET_DOWNLOAD_UNREACHABLE"
                } else if (rawMessage.contains("timeout") || rawMessage.contains("timed out")) {
                    cleanMessage = "RULESET_DOWNLOAD_TIMEOUT"
                }
            }

            Log.e(TAG, "VPN 错误 [$source/${type.name}]: $cleanMessage")

            sendEvent("onError", mapOf(
                "type" to type.name,
                "message" to cleanMessage,
                "source" to source,
                "status" to currentStatus.ordinal
            ))
        } catch (e: Exception) {
            Log.w(TAG, "发送错误事件失败: ${e.message}")
        }
    }

    /**
     * 启动 VPNService 前台服务。
     */
    private fun startVPNService(config: String) {
        val intent = Intent(context, VPNService::class.java).apply {
            putExtra(VPNService.EXTRA_CONFIG, config)
        }
        ContextCompat.startForegroundService(context, intent)
        // 不在此处连接 StatusMonitor，等待服务状态变为 Started 时再连接
        Log.d(TAG, "VPN 服务启动命令已发送")
    }

    /**
     * Adapt a libbox outbound-group iterator into plain snapshots for the pure
     * reducer `parseExitGatewayGroups` (helper/ExitGatewayParse.kt). Consumed by
     * the live status monitor's group updates (audit C2 / Batch 3).
     */
    private fun snapshotGroups(groups: Iterator<OutboundGroup>): List<ProxyGroupSnapshot> {
        val out = mutableListOf<ProxyGroupSnapshot>()
        for (group in groups) {
            val items = mutableListOf<Pair<String, Int>>()
            val it = group.getItems()
            while (it?.hasNext() == true) {
                val item = it.next()
                items.add(item.tag to item.urlTestDelay.toInt())
            }
            out.add(ProxyGroupSnapshot(group.tag, group.selected ?: "", items))
        }
        return out
    }

}
