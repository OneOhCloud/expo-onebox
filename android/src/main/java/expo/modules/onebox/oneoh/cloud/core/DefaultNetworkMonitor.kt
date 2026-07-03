package expo.modules.onebox.oneoh.cloud.core

import android.net.Network
import android.os.Build
import android.os.SystemClock
import expo.modules.onebox.oneoh.cloud.ExpoOneBoxModule
import expo.modules.onebox.oneoh.cloud.ExpoOneBoxModule.Companion.connectivity
import io.nekohasekai.libbox.InterfaceUpdateListener
import java.net.NetworkInterface

/**
 * 默认网络监控器。
 * 跟踪系统默认网络变化，通知 libbox 核心接口变更。
 */
object DefaultNetworkMonitor {

    var defaultNetwork: Network? = null
    @Volatile private var listener: InterfaceUpdateListener? = null

    /** 由 BoxService 设置；当当前默认网络的 link properties 发生变化但接口标识
     *  未变时（去抖后）调用——这是 sing-box 的 interface monitor 会去重的情况，
     *  因此必须显式关闭陈旧连接。 */
    @Volatile var onNetworkReset: (() -> Unit)? = null
    @Volatile private var lastResetAt = 0L
    private const val RESET_DEBOUNCE_MS = 800L

    /** 把 link-property 回调的突发合并为每个时间窗最多一次 reset。 */
    fun notifyLinkChanged() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastResetAt < RESET_DEBOUNCE_MS) return
        lastResetAt = now
        onNetworkReset?.invoke()
    }

    suspend fun start() {
        DefaultNetworkListener.start(this) {
            defaultNetwork = it
            checkDefaultInterfaceUpdate(it)
        }
        defaultNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivity.activeNetwork
        } else {
            DefaultNetworkListener.get()
        }
    }

    suspend fun stop() {
        DefaultNetworkListener.stop(this)
    }

    suspend fun require(): Network {
        val network = defaultNetwork
        if (network != null) {
            return network
        }
        return DefaultNetworkListener.get()
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        this.listener = listener
        checkDefaultInterfaceUpdate(defaultNetwork)
    }

    private fun checkDefaultInterfaceUpdate(newNetwork: Network?) {
        val listener = listener ?: return
        if (newNetwork != null) {
            val interfaceName =
                (connectivity.getLinkProperties(newNetwork) ?: return).interfaceName ?: return
            for (times in 0 until 10) {
                val interfaceIndex: Int
                try {
                    interfaceIndex = NetworkInterface.getByName(interfaceName).index
                } catch (e: Exception) {
                    Thread.sleep(100)
                    continue
                }
                if (this.listener !== listener) return
                try {
                    listener.updateDefaultInterface(interfaceName, interfaceIndex, false, false)
                } catch (e: Exception) {
                    return
                }
                break
            }
        } else {
            if (this.listener !== listener) return
            try {
                listener.updateDefaultInterface("", -1, false, false)
            } catch (e: Exception) {
                return
            }
        }
    }
}
