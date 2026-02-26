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
import expo.modules.onebox.oneoh.cloud.helper.Bugs
import expo.modules.onebox.oneoh.cloud.helper.Status
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import kotlinx.coroutines.DelicateCoroutinesApi
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


    companion object {
        private const val TAG = "ExpoOneBoxModule"

        lateinit var application: Application
        const val VPN_REQUEST_CODE = 1001

        var currentStatus: Status = Status.Stopped
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
                it.workingPath = workingDir.path
                it.tempPath = tempDir.path
                it.fixAndroidStack = Bugs.fixAndroidStack
                it.logMaxLines = 3000
                it.debug = BuildConfig.DEBUG
            },
        )
        Libbox.redirectStderr(File(workingDir, "stderr.log").path)
    }

    override fun definition() = ModuleDefinition {
        Name("ExpoOneBox")

        // 定义发送到 JS 的事件
        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate")

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

        AsyncFunction("start") { config: String ->
            val processedConfig = processConfig(config)

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
            val workingDir = getWorkingDir().absolutePath
            val cachePath = "$workingDir/cache/tun-cache-rule-v1.db"



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
            val statusName = when (status) {
                Status.Stopped -> "stopped"
                Status.Starting -> "connecting"
                Status.Started -> "connected"
                Status.Stopping -> "disconnecting"
            }
            sendEvent("onStatusChange", mapOf(
                "status" to status.ordinal,
                "statusName" to statusName,
                "message" to "Service status: $statusName"
            ))

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

    // ==================== 配置处理 ====================

    private fun getWorkingDir(): File {
        return context.getExternalFilesDir(null) ?: context.filesDir
    }

    /**
     * 处理配置：将缓存文件路径替换为 Android 应用目录。
     * 保持 processConfig 处理后的 JSON 格式字符串传入 core.BoxService。
     */
    private fun processConfig(config: String): String {
        try {
            val json = JSONObject(config)
            val workingDir = getWorkingDir().absolutePath

            // 处理 experimental.cache_file.path
            if (json.has("experimental")) {
                val experimental = json.getJSONObject("experimental")
                if (experimental.has("cache_file")) {
                    val cacheFile = experimental.getJSONObject("cache_file")
                    if (cacheFile.has("path")) {
                        val cachePath = "$workingDir/cache/tun-cache-rule-v1.db"
                        cacheFile.put("path", cachePath)

                        val cacheDirectory = File("$workingDir/cache")
                        if (!cacheDirectory.exists()) {
                            cacheDirectory.mkdirs()
                        }
                    }
                }
            }
            return json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to process config", e)
            return config
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
     * 从配置中移除 TUN 类型的 inbound，用于预处理阶段。
     * 保留 mixed 等其他 inbound。
     */
    private fun removeTunInbound(config: String): String {
        try {
            val json = JSONObject(config)

            return json.toString()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove TUN inbound", e)
            return config
        }
    }
}
