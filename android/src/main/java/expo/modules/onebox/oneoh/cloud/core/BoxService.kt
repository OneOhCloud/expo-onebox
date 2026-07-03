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

    // ==================== 启动错误文件 ====================

    /** 共享的 startup_error.txt——失败时写入，成功时清空。 */
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
        Log.d(TAG, "[android] starting CommandServer...")
        val commandServer = CommandServer(this, platformInterface)
        commandServer.start()
        this.commandServer = commandServer
        Log.d(TAG, "[android] CommandServer started, waiting for client connection")

        // 尝试启用状态更新（如果有这样的方法）
        try {
            // 检查 commandServer 是否有启用状态更新的方法
            Log.d(TAG, "[android] CommandServer started, ready to accept client connections")
        } catch (e: Exception) {
            Log.w(TAG, "[android] CommandServer post-start config failed: ${e.message}")
        }
    }

    /**
     * 使用处理后的 JSON 配置字符串启动 VPN 服务。
     * @param configContent 已经过 processConfig 处理的配置 JSON 字符串
     */
    suspend fun startService(configContent: String) {
        try {
            // 清除上一次启动残留的错误，使该文件只反映本次尝试；
            // 在下面每条失败路径上都写入，以便 JS 层（在停止转换时读取
            // startup_error.txt）能把它呈现出来。
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
            // 同一接口上的 IP/DNS 变化（WiFi 漫游、DHCP 续租）会被 sing-box 的
            // interface monitor 去重并跳过其自动 reset；因此当 link 属性变化时
            // 显式关闭陈旧连接。
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
     * 前台通知标题。逐节点名称尚未从配置中解析（`config` 参数是为此
     * 预留的接缝）；在此之前使用本地化的 app 名称，使通知读起来合理——
     * 不含硬编码或违禁术语字符串，且原生侧没有 JS 的 i18n 通道。
     */
    private fun extractServerName(config: String): String {
        return service.applicationInfo.loadLabel(service.packageManager).toString()
    }

    // ==================== CommandServerHandler ====================

    @OptIn(DelicateCoroutinesApi::class)
    override fun serviceStop() {
        // CommandServer 发起的停止（在 libbox 线程上调用）。转到主线程执行
        // 标准拆除流程，使状态机真正到达 Stopped。
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
        // receiver 在 startCommandServer() 完成之前就已注册，因此启动期间的
        // Doze 转换否则可能触及尚未初始化的 commandServer。
        if (!::commandServer.isInitialized || status.value != Status.Started) return
        val context = service.applicationContext
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isDeviceIdleMode) {
            commandServer.pause()
        } else {
            commandServer.wake()
            // 离开 Doze 意味着长时间空闲，代理 socket 几乎肯定已死。
            // 关闭所有连接，使下一个请求重新拨号，而不是卡在死 socket 的
            // 超时上——sing-box 的 Wake() 从不关闭它们。
            Log.d(TAG, "exited Doze → resetNetwork")
            commandServer.resetNetwork()
        }
    }

    // ==================== 停止服务 ====================

    @OptIn(DelicateCoroutinesApi::class)
    internal fun stopService() {
        // 允许在 STARTING 时也能停止（不只是 STARTED）：启动期间的 SERVICE_CLOSE
        // 必须被响应，否则隧道会卡在"connecting"，只能通过强制停止 app 才能杀掉。
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
            // 若在启动中途停止，commandServer 可能尚未初始化。
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
