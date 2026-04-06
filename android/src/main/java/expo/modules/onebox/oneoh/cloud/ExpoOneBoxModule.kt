package expo.modules.onebox.oneoh.cloud

import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.ClipboardManager
import android.content.Intent
import android.net.ConnectivityManager
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.content.getSystemService
import expo.modules.kotlin.Promise
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
import expo.modules.onebox.oneoh.cloud.helper.fetchSubscription
import expo.modules.onebox.oneoh.cloud.helper.findBestDnsServer
import expo.modules.onebox.oneoh.cloud.helper.getWorkingDir
import expo.modules.onebox.oneoh.cloud.helper.parseSubscriptionUserinfo
import expo.modules.onebox.oneoh.cloud.helper.processConfig
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogEntry
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroup
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.sfa.utils.CommandClient
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.io.File
import java.net.URL

class ExpoOneBoxModule : ServiceConnection.Callback, Module() {

    private val context
        get() = appContext.reactContext!!

    private val app: Application
        get() = appContext.reactContext?.applicationContext as? Application
            ?: throw IllegalStateException("Application context not available")

    private lateinit var connection: ServiceConnection
    private var vpnPermissionPromise: Promise? = null
    private var batteryOptPromise: Promise? = null

    // ==================== 日志/流量实时监控 ====================

    /** 订阅 libbox CommandServer 的日志和状态流量，并推送到 JS 层 */
    @OptIn(DelicateCoroutinesApi::class)
    private val statusMonitor by lazy {
        CommandClient(
            GlobalScope,
            listOf(CommandClient.ConnectionType.Log, CommandClient.ConnectionType.Status, CommandClient.ConnectionType.Groups),
            object : CommandClient.Handler {
                override fun appendLogs(message: List<LogEntry>) {
                    if (!coreLogEnabled) return
                    for (entry in message) {
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
                        val all = mutableListOf<Map<String, Any>>()
                        var now = ""
                        for (group in newGroups) {
                            if (group.tag == "ExitGateway") {
                                now = group.selected ?: ""
                                val items = group.getItems()
                                while (items?.hasNext() == true) {
                                    val item = items.next()
                                    all.add(mapOf("tag" to item.tag, "delay" to item.urlTestDelay.toInt()))
                                }
                                break
                            }
                        }
                        sendEvent("onGroupUpdate", mapOf("all" to all, "now" to now))
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

        var currentStatus: Status = Status.Stopped
        var isStartingUp: Boolean = false
        var coreLogEnabled: Boolean = false
        val notification by lazy { application.getSystemService<NotificationManager>()!! }
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val packageManager by lazy { application.packageManager }
        val powerManager by lazy { application.getSystemService<PowerManager>()!! }
        val notificationManager by lazy { application.getSystemService<NotificationManager>()!! }
        val wifiManager by lazy { application.getSystemService<WifiManager>()!! }
        val clipboard by lazy { application.getSystemService<ClipboardManager>()!! }
    }

    private fun initialize() {
        application = app
        val baseDir = context.filesDir
        baseDir.mkdirs()
        val workingDir = context.getExternalFilesDir(null) ?: return
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

    override fun definition() = ModuleDefinition {
        Name("ExpoOneBox")

        // 定义发送到 JS 的事件
        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate", "onGroupUpdate", "onConfigRefreshResult")

        OnCreate {
            try {
                initialize()
                connection = ServiceConnection(context, this@ExpoOneBoxModule)
                connection.connect()
            } catch (e: Exception) {
                Log.e(TAG, "初始化失败", e)
            }
        }

        OnDestroy {
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

        Function("setCoreLogEnabled") { enabled: Boolean ->
            coreLogEnabled = enabled
            Log.d(TAG, "Core log output ${if (enabled) "enabled" else "disabled"}")
        }

        Function("getCoreLogEnabled") {
            return@Function coreLogEnabled
        }

        // Returns the last startup error written to startup_error.txt by the VPN service.
        // Empty string means no error (or last start succeeded).
        // JS layer calls this when status transitions STARTING → STOPPED.
        Function("getStartError") {
            return@Function try {
                val file = java.io.File(getWorkingDir(context), "startup_error.txt")
                if (file.exists()) file.readText().trim() else ""
            } catch (e: Exception) {
                ""
            }
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
                ?: context.contentResolver.openInputStream(android.net.Uri.fromFile(java.io.File(uri.path ?: sourceUri.removePrefix("file://"))))
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
            val processedConfig = processConfig(config, context)

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

            // 发送停止广播
            context.sendBroadcast(
                Intent(Action.SERVICE_CLOSE).setPackage(context.packageName)
            )
            Log.d(TAG, "服务停止命令已发送")
        }

        // ---- getProxyNodes: 通过 libbox CommandClient IPC 获取 ExitGateway 节点列表 ----
        AsyncFunction("getProxyNodes") { promise: Promise ->
            var settled = false
            var rawClient: io.nekohasekai.libbox.CommandClient? = null

            val options = CommandClientOptions()
            options.addCommand(Libbox.CommandGroup)

            val handler = object : CommandClientHandler {
                private fun settle(all: List<Map<String, Any>>, now: String) {
                    if (!settled) {
                        settled = true
                        rawClient?.runCatching { disconnect() }
                        promise.resolve(mapOf("all" to all, "now" to now))
                    }
                }

                override fun connected() {}

                override fun disconnected(message: String?) {
                    settle(emptyList(), "")
                }

                override fun writeGroups(message: OutboundGroupIterator?) {
                    val all = mutableListOf<Map<String, Any>>()
                    var now = ""
                    while (message?.hasNext() == true) {
                        val group = message.next()
                        if (group.tag == "ExitGateway") {
                            now = group.selected ?: ""
                            val items = group.getItems()
                            while (items?.hasNext() == true) {
                                val item = items.next()
                                all.add(mapOf("tag" to item.tag, "delay" to item.urlTestDelay.toInt()))
                            }
                            break
                        }
                    }
                    settle(all, now)
                }

                override fun writeStatus(message: StatusMessage?) {}
                override fun writeLogs(messageList: LogIterator?) {}
                override fun clearLogs() {}
                override fun setDefaultLogLevel(level: Int) {}
                override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {}
                override fun updateClashMode(newMode: String?) {}
                override fun writeConnectionEvents(events: ConnectionEvents?) {}
            }

            val client = io.nekohasekai.libbox.CommandClient(handler, options)
            rawClient = client

            // 5 秒超时保护
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                if (!settled) {
                    settled = true
                    client.runCatching { disconnect() }
                    promise.resolve(mapOf("all" to emptyList<Map<String, Any>>(), "now" to ""))
                }
            }, 5000)

            // 在后台线程中连接
            Thread {
                try {
                    client.connect()
                } catch (e: Exception) {
                    if (!settled) {
                        settled = true
                        promise.resolve(mapOf("all" to emptyList<Map<String, Any>>(), "now" to ""))
                    }
                }
            }.start()
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
        AsyncFunction("selectProxyNode") { node: String ->
            try {
                val client = Libbox.newStandaloneCommandClient()
                client?.selectOutbound("ExitGateway", node)
                true
            } catch (e: Exception) {
                Log.w(TAG, "selectProxyNode failed: ${e.message}")
                false
            }
        }

        Function("getLibBoxVersion") {
            return@Function Libbox.version()
        }

        Function("hello") {
            "Hello world! 👋"
        }

        AsyncFunction("getBestDns") {
            return@AsyncFunction runBlocking { findBestDnsServer() }
        }

        // ─── Subscription Fetching (DNS-resolved) ────────────────────────────────

        // Fetch a subscription URL using DNS resolution + OkHttp with SNI override.
        AsyncFunction("fetchSubscription") { url: String, userAgent: String ->
            val result = runBlocking { fetchSubscription(url, userAgent) }
            mapOf(
                "statusCode" to result.statusCode,
                "headers" to result.headers,
                "body" to result.body,
            )
        }

        // ─── Native Background Config Refresh ────────────────────────────────────

        // Register (or update) the WorkManager periodic task.
        AsyncFunction("registerBackgroundConfigRefresh") { url: String, userAgent: String, intervalSeconds: Int, accelerateUrl: String? ->
            context.getSharedPreferences(BG_PREFS_NAME, android.content.Context.MODE_PRIVATE)
                .edit()
                .putString("config_url", url)
                .putString("user_agent", userAgent)
                .putLong("interval_seconds", intervalSeconds.toLong())
                .also { ed ->
                    val acc = accelerateUrl?.takeIf { it.isNotBlank() }
                    if (acc != null) ed.putString("accelerate_url", acc)
                    else ed.remove("accelerate_url")
                }
                .apply()
            BackgroundConfigWorker.schedule(context, intervalSeconds.toLong())
            Log.i(TAG, "Background config refresh registered (interval=${intervalSeconds}s, accelerate=${accelerateUrl != null})")
        }

        // Cancel the periodic WorkManager task.
        AsyncFunction("unregisterBackgroundConfigRefresh") {
            BackgroundConfigWorker.cancel(context)
        }

        // Execute config refresh immediately (foreground / dev screen).
        AsyncFunction("executeConfigRefreshNow") { url: String, userAgent: String, accelerateUrl: String? ->
            val acc    = accelerateUrl?.takeIf { it.isNotBlank() }
            val result = runBlocking { executeRefreshWith(url, acc, userAgent) }
            BackgroundConfigWorker.storeResult(context, result)
            result.toMap()
        }

        // Return and clear the last result stored by the background worker.
        Function("getLastConfigRefreshResult") {
            val result = BackgroundConfigWorker.loadLastResult(context) ?: return@Function null
            BackgroundConfigWorker.clearLastResult(context)
            return@Function result
        }

        // Whether a WorkManager periodic task is currently enqueued/running.
        AsyncFunction("isBackgroundConfigRefreshRegistered") {
            BackgroundConfigWorker.isRegistered(context)
        }

        View(ExpoOneBoxView::class) {
            Prop("url") { view: ExpoOneBoxView, url: URL ->
                view.webView.loadUrl(url.toString())
            }
            Events("onLoad")
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

            sendEvent("onStatusChange", mapOf(
                "status" to status.ordinal,
                "statusName" to statusName,
                "message" to "Service status: $statusName"
            ))

            // 主动检测启动失败
            if (status == Status.Stopped && wasStarting) {
                val errMsg = try {
                    val file = java.io.File(getWorkingDir(context), "startup_error.txt")
                    if (file.exists()) file.readText().trim() else ""
                } catch (_: Exception) { "" }

                val message = errMsg.ifEmpty { "启动异常退出，请检查配置文件。" }
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
                if (rawMessage.contains("connection reset by peer")) {
                    cleanMessage = "规则集下载失败：网络连接被重置。请检查网络连接后重试。"
                } else if (rawMessage.contains("Application error 0x0")) {
                    cleanMessage = "规则集下载失败：无法连接到规则集服务器。请检查网络连接后重试。"
                } else if (rawMessage.contains("timeout") || rawMessage.contains("timed out")) {
                    cleanMessage = "规则集下载超时。请检查网络连接后重试。"
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

}
