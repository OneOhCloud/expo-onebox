package expo.modules.onebox.oneoh.cloud.core

import android.app.Service
import android.content.Intent
import android.os.IBinder
import io.nekohasekai.libbox.Notification

/**
 * 代理前台服务（非 VPN）。
 * 继承 android.app.Service（非 VpnService），用于预处理阶段（下载和缓存规则集）。
 * 不创建 TUN 接口，不拦截系统流量。
 */
class ProxyService : Service(), PlatformInterfaceWrapper {

    companion object {
        const val EXTRA_CONFIG = "config_content"
    }

    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val config = intent?.getStringExtra(EXTRA_CONFIG) ?: ""
        return service.onStartCommand(config)
    }

    override fun onBind(intent: Intent): IBinder = service.onBind()

    override fun onDestroy() = service.onDestroy()

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)
}
