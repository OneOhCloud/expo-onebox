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

    /** Set by BoxService; invoked (debounced) when the current default network's link
     *  properties change without an interface-identity change — a case sing-box's
     *  interface monitor dedups, so stale connections must be closed explicitly. */
    @Volatile var onNetworkReset: (() -> Unit)? = null
    @Volatile private var lastResetAt = 0L
    private const val RESET_DEBOUNCE_MS = 800L

    /** Coalesces bursts of link-property callbacks into at most one reset per window. */
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
