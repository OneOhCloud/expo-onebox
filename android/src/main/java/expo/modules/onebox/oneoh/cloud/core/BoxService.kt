package expo.modules.onebox.oneoh.cloud.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import expo.modules.onebox.oneoh.cloud.helper.Action
import expo.modules.onebox.oneoh.cloud.helper.Alert
import expo.modules.onebox.oneoh.cloud.helper.getWorkingDir
import expo.modules.onebox.oneoh.cloud.R
import expo.modules.onebox.oneoh.cloud.helper.Status
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 核心 VPN 后台服务逻辑。
 * 管理 CommandServer 生命周期、VPN 状态、前台通知、启动/停止流程。
 * 接收已处理的 JSON 配置字符串来启动服务。
 *
 * 不包含：UI、配置文件管理、profile 管理
 */
class BoxService(
    private val service: Service,
    private val platformInterface: PlatformInterface
) : CommandServerHandler {



    companion object {
        private const val TAG = "BoxService"
    }

    var fileDescriptor: ParcelFileDescriptor? = null

    val status = MutableLiveData(Status.Stopped)
    val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
    private lateinit var commandServer: CommandServer

    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService()
                }
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        serviceUpdateIdleMode()
                    }
                }
            }
        }
    }

    // ==================== Startup error file ====================

    /** Shared startup_error.txt — written on failure, cleared on success. */
    private val startupErrorFile: java.io.File
        get() = java.io.File(getWorkingDir(service), "startup_error.txt")

    private fun writeStartupError(message: String) {
        try { startupErrorFile.writeText(message) } catch (_: Exception) {}
    }

    private fun clearStartupError() {
        try { startupErrorFile.writeText("") } catch (_: Exception) {}
    }

    // ==================== 服务控制 ====================

    private fun startCommandServer() {
        Log.d(TAG, "[android] 开始启动 CommandServer...")
        val commandServer = CommandServer(this, platformInterface)
        commandServer.start()
        this.commandServer = commandServer
        Log.d(TAG, "[android] CommandServer 启动完成，等待客户端连接")
        
        // 尝试启用状态更新（如果有这样的方法）
        try {
            // 检查 commandServer 是否有启用状态更新的方法
            Log.d(TAG, "[android] CommandServer 已启动，可接受客户端连接")
        } catch (e: Exception) {
            Log.w(TAG, "[android] CommandServer 后续配置失败: ${e.message}")
        }
    }

    /**
     * 使用处理后的 JSON 配置字符串启动 VPN 服务。
     * @param configContent 已经过 processConfig 处理的配置 JSON 字符串
     */
    suspend fun startService(configContent: String) {
        try {
            // Clear any error from a previous start so the file reflects only
            // this attempt; write it on every failure path below so the JS layer
            // (which reads startup_error.txt on the stop transition) surfaces it.
            clearStartupError()
            val serverName = extractServerName(configContent)

            withContext(Dispatchers.Main) {
                notification.show(serverName, R.string.status_starting)
            }

            if (configContent.isBlank()) {
                writeStartupError("[config] empty configuration")
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            DefaultNetworkMonitor.start()
            // Same-interface IP/DNS changes (WiFi roam, DHCP renew) are deduped by
            // sing-box's interface monitor and skip its auto-reset; close stale
            // connections explicitly when the link properties change.
            DefaultNetworkMonitor.onNetworkReset = {
                if (::commandServer.isInitialized && status.value == Status.Started) {
                    Log.d(TAG, "link properties changed → resetNetwork")
                    commandServer.resetNetwork()
                }
            }

            try {
                commandServer.startOrReloadService(
                    configContent,
                    OverrideOptions()
                )
            } catch (e: Exception) {
                Log.e(TAG, "[binary] startOrReloadService failed", e)
                writeStartupError("[binary] ${e.message ?: "unknown error"}")
                stopAndAlert(Alert.CreateService, "[binary] ${e.message}")
                return
            }

            clearStartupError()
            status.postValue(Status.Started)
            withContext(Dispatchers.Main) {
                notification.show(serverName, R.string.status_started)

            }
            notification.start()
        } catch (e: Exception) {
            Log.e(TAG, "[android] startService failed", e)
            writeStartupError("[android] ${e.message ?: "unknown error"}")
            stopAndAlert(Alert.StartService, "[android] ${e.message}")
        }
    }

    /**
     * Foreground-notification title. The per-node name is not yet parsed from
     * the config (the `config` param is the seam for that); until then use the
     * localized app label so the notification reads sensibly — no hardcoded or
     * banned-terminology string, and the native side has no JS i18n channel.
     */
    private fun extractServerName(config: String): String {
        return service.applicationInfo.loadLabel(service.packageManager).toString()
    }

    // ==================== CommandServerHandler ====================

    @OptIn(DelicateCoroutinesApi::class)
    override fun serviceStop() {
        // CommandServer-initiated stop (invoked on a libbox thread). Route to the
        // standard teardown on the main thread so the state machine actually
        // reaches Stopped — this previously posted Status.Starting and returned,
        // leaving the tunnel stuck "connecting" and un-stoppable.
        GlobalScope.launch(Dispatchers.Main) { stopService() }
    }

    override fun serviceReload() {
        // 不在此模块实现配置重新加载 — 由 JS 层控制
        Log.d(TAG, "serviceReload called (no-op in minimal core)")
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? {
        val proxyStatus = SystemProxyStatus()
        if (service is VPNService) {
            proxyStatus.available = service.systemProxyAvailable
            proxyStatus.enabled = service.systemProxyEnabled
        }
        return proxyStatus
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        // 不在此模块实现系统代理开关
    }

    override fun writeDebugMessage(message: String?) {
        Log.d("sing-box", message ?: "")
    }

    private fun serviceUpdateIdleMode() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        // The receiver is registered before startCommandServer() finishes, so a Doze
        // transition during startup could otherwise touch an uninitialized commandServer.
        if (!::commandServer.isInitialized || status.value != Status.Started) return
        val context = service.applicationContext
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isDeviceIdleMode) {
            commandServer.pause()
        } else {
            commandServer.wake()
            // Leaving Doze implies a long idle; the proxy sockets are almost certainly dead.
            // Close all connections so the next request dials fresh instead of stalling on a
            // dead socket's timeout — sing-box's Wake() never closes them.
            Log.d(TAG, "exited Doze → resetNetwork")
            commandServer.resetNetwork()
        }
    }

    // ==================== 停止服务 ====================

    @OptIn(DelicateCoroutinesApi::class)
    internal fun stopService() {
        // Allow stopping while STARTING too (not just STARTED): a SERVICE_CLOSE
        // during startup must be honoured, otherwise the tunnel gets stuck
        // "connecting" and can only be killed by force-stopping the app (D4-03).
        if (status.value == Status.Stopped || status.value == Status.Stopping) return
        status.value = Status.Stopping
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        GlobalScope.launch(Dispatchers.IO) {
            val pfd = fileDescriptor
            if (pfd != null) {
                pfd.close()
                fileDescriptor = null
            }
            DefaultNetworkMonitor.onNetworkReset = null
            DefaultNetworkMonitor.stop()
            // commandServer may not be initialised yet if we stop mid-startup.
            if (::commandServer.isInitialized) {
                closeService()
                commandServer.close()
            }
            withContext(Dispatchers.Main) {
                status.value = Status.Stopped
                service.stopSelf()
            }
        }
    }

    private fun closeService() {
        runCatching {
            commandServer.closeService()
        }.onFailure {
            commandServer.setError("android: close service: ${it.message}")
        }
    }


    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        withContext(Dispatchers.Main) {
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            notification.close()
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
        }
    }

    // ==================== 生命周期 ====================

    /**
     * 由 VPNService.onStartCommand 调用启动流程。
     * @param configContent 已处理的 JSON 配置字符串
     */
    @OptIn(DelicateCoroutinesApi::class)
    @Suppress("SameReturnValue")
    internal fun onStartCommand(configContent: String): Int {
        if (status.value != Status.Stopped) return Service.START_NOT_STICKY
        status.value = Status.Starting

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                service,
                receiver,
                IntentFilter().apply {
                    addAction(Action.SERVICE_CLOSE)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                    }
                },
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            receiverRegistered = true
        }

        GlobalScope.launch(Dispatchers.IO) {
            try {
                startCommandServer()
            } catch (e: Exception) {
                Log.e(TAG, "[android] startCommandServer failed", e)
                stopAndAlert(Alert.StartCommandServer, "[android] ${e.message}")
                return@launch
            }
            startService(configContent)
        }
        return Service.START_NOT_STICKY
    }

    internal fun onBind(): IBinder = binder

    internal fun onDestroy() {
        binder.close()
    }

    internal fun onRevoke() {
        stopService()
    }

    /**
     * 发送 libbox 通知到 Android 通知栏
     */
    @OptIn(DelicateCoroutinesApi::class)
    internal fun sendNotification(boxNotification: Notification) {
        val builder = NotificationCompat.Builder(service, boxNotification.identifier)
            .setShowWhen(false)
            .setContentTitle(boxNotification.title)
            .setContentText(boxNotification.body)
            .setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setCategory(NotificationCompat.CATEGORY_EVENT)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)

        if (!boxNotification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(boxNotification.subtitle)
        }

        GlobalScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = service.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.createNotificationChannel(
                    NotificationChannel(
                        boxNotification.identifier,
                        boxNotification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    )
                )
                nm.notify(boxNotification.typeID, builder.build())
            }
        }
    }
}
