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

// 后台 worker 存储所镜像的 SharedPreferences key。
// 权威定义在 BackgroundConfigWorker.kt（与 KEY_ACCELERATE_URL 相邻）；
// 此处仅为写入侧的声明。
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
                    // 在 IPC 之前过滤：sing-box 的 platform writer 会绕过
                    // log.level，因此无论配置如何，每条日志都会到达这里。
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
                                "memory"              to status.memory,
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
         * 转发给 JS 的 sing-box level 上限。level code 对应
         * `log/level.go`：panic=0, fatal=1, error=2, warn=3, info=4,
         * debug=5, trace=6。`level > coreLogLevelMax` 的条目会在
         * `appendLogs` 处被丢弃。默认值与 app 默认值一致。
         */
        @Volatile var coreLogLevelMax: Int = 4 // info
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val packageManager by lazy { application.packageManager }
        val powerManager by lazy { application.getSystemService<PowerManager>()!! }
        val notificationManager by lazy { application.getSystemService<NotificationManager>()!! }
        // 单个 notificationManager 实例的别名（供 ServiceNotification 使用）。
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
     * 向 JS 发送一条原生层日志。
     *
     * 与承载 libbox / sing-box core 输出的 `sendEvent("onLog", ...)` 不同，
     * 本通道用于 Kotlin 模块自身的活动——生命周期钩子、权限流程、
     * 后台 worker 状态转换——以便用户区分"JS–原生桥是否存活"
     * 与"core 是否在运行"。
     *
     * 同时以匹配的 level 写入 logcat，使平台工具（`adb logcat`）
     * 仍能带上来源上下文看到该事件。
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
                Log.e(TAG, "init failed", e)
                sendNativeLog("error", "Module", "init failed: ${e.message}")
            }
        }

        OnDestroy {
            sendNativeLog("info", "Module", "ExpoOneBox Kotlin module destroying")
            try {
                statusMonitor.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "statusMonitor teardown failed", e)
            }
            try {
                connection.disconnect()
            } catch (e: Exception) {
                Log.w(TAG, "cleanup on destroy failed", e)
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
                Log.w(TAG, "query service status failed: ${e.message}")
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

        // CommandServer 日志流的客户端侧过滤。之所以需要，是因为
        // sing-box 的 `log.level` 配置只过滤 stdout 和 observable sink——
        // 而 platform writer（为我们的 CommandClient 供数）是无条件的。
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

        // 返回 VPN 服务写入 startup_error.txt 的最后一次启动错误。
        // 空字符串表示无错误（或上次启动成功）。
        // JS 层在状态从 STARTING → STOPPED 时调用。
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
                Log.e(TAG, "rule-set cache file missing: $cachePath")

            }else{
                Log.i(TAG, "rule-set cache file exists: $cachePath")
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
            Log.d(TAG, "service stop command sent")
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

        // ─── 配置抓取（DNS 解析）─────────────────────────────────────

        // 用 DNS 解析 + 可选加速回落抓取一个配置 URL。
        // 加速 URL 来自 JS 推送的共享选项（SharedPreferences）。
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

        // ─── 原生后台配置刷新 ────────────────────────────────────

        // 把 JS 管理的域名 allowlist 推入 WorkManager worker 读取的
        // 同一份 SharedPreferences。在 `domain-verification.ts` 中每次
        // `updateVerificationData()` 成功后调用，使 worker 不必在每次
        // 唤醒时都重新抓取远端列表。24h TTL 在读取侧强制执行
        // （BackgroundConfigWorker.verifyDomain）。
        AsyncFunction("setVerificationData") { data: Map<String, Any?> ->
            @Suppress("UNCHECKED_CAST")
            val known    = (data["knownSha256List"]    as? List<String>) ?: emptyList()
            @Suppress("UNCHECKED_CAST")
            val verified = (data["verifiedSha256List"] as? List<String>) ?: emptyList()
            BackgroundConfigWorker.saveDomainVerificationCache(app, known, verified)
        }

        // 把 JS 管理的刷新选项镜像进 worker 的 SharedPreferences，
        // 使 WorkManager 任务永不打开 JS 持有的 SQLite 数据库——
        // 同一个 WAL 文件上再挂一个 SQLite 库会以 SIGBUS 崩溃。
        AsyncFunction("setBackgroundConfigRefreshOptions") { options: Map<String, Any?> ->
            val accelerateUrl = options["accelerateUrl"] as? String ?: ""
            val testFlag      = options["testPrimaryUrlUnavailable"] as? Boolean ?: false
            BackgroundConfigWorker.saveRefreshOptions(app, accelerateUrl, testFlag)
        }

        // 注册（或更新）WorkManager 周期任务。
        AsyncFunction("registerBackgroundConfigRefresh") { url: String, userAgent: String, intervalSeconds: Int ->
            app.getSharedPreferences(BG_PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_BG_CONFIG_URL, url)
                .putString(KEY_BG_USER_AGENT, userAgent)
                .apply()
            BackgroundConfigWorker.schedule(app, intervalSeconds.toLong())
            Log.i(TAG, "Background config refresh registered (interval=${intervalSeconds}s)")
        }

        // 立即执行配置刷新（前台 / dev 屏幕）。
        AsyncFunction("executeConfigRefreshNow") Coroutine { url: String, userAgent: String ->
            val result = executeRefreshWith(app, url, userAgent)
            // 不要在此 storeResult：JS 直接收到结果并自行调用
            // applyResultToSBConfig()。存储会覆盖 SharedPrefs 中任何待处理的
            // 后台 doWork() 结果，导致其丢失。
            result.toMap()
        }

        // 返回并清除后台 worker 存储的最后一次结果。
        // 使用 app（而非 reactContext）以避免桥拆除期间的 NullPointerException。
        Function("getLastConfigRefreshResult") {
            // 把加载与清除作为单个临界区，使并发的 worker 写入不会在两次
            // 调用之间被静默丢弃。BackgroundConfigWorker.storeResult 锁在
            // 同一个 monitor 上，因此 load/clear 这对操作相对并发写入是原子的。
            synchronized(BackgroundConfigWorker::class.java) {
                val result = BackgroundConfigWorker.loadLastResult(app) ?: return@Function null
                BackgroundConfigWorker.clearLastResult(app)
                return@Function result
            }
        }

        // WorkManager 周期任务当前是否已入队/正在运行。
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
                Status.Starting -> "starting"
                Status.Started -> "started"
                Status.Stopping -> "stopping"
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
                    // 去掉与 onServiceAlert 相同的来源前缀，使同一次失败在两处
                    // onError 发射中呈现一致的文本。
                    if (file.exists()) file.readText().trim().removePrefix("[binary] ") else ""
                } catch (_: Exception) { "" }

                // 语言中立 token；由 JS 层本地化。
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
            Log.w(TAG, "send status change event failed: ${e.message}")
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
                // 语言中立 token；由 JS 层本地化。
                if (rawMessage.contains("connection reset by peer")) {
                    cleanMessage = "RULESET_DOWNLOAD_RESET"
                } else if (rawMessage.contains("Application error 0x0")) {
                    cleanMessage = "RULESET_DOWNLOAD_UNREACHABLE"
                } else if (rawMessage.contains("timeout") || rawMessage.contains("timed out")) {
                    cleanMessage = "RULESET_DOWNLOAD_TIMEOUT"
                }
            }

            Log.e(TAG, "VPN error [$source/${type.name}]: $cleanMessage")

            sendEvent("onError", mapOf(
                "type" to type.name,
                "message" to cleanMessage,
                "source" to source,
                "status" to currentStatus.ordinal
            ))
        } catch (e: Exception) {
            Log.w(TAG, "send error event failed: ${e.message}")
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
        Log.d(TAG, "VPN service start command sent")
    }

    /**
     * 把 libbox outbound-group 迭代器适配为纯快照，供纯 reducer
     * `parseExitGatewayGroups`（helper/ExitGatewayParse.kt）使用。
     * 由实时状态监控的 group 更新消费。
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
