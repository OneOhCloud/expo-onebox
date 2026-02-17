package expo.modules.onebox.oneoh.cloud.core

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import expo.modules.onebox.oneoh.cloud.aidl.IService
import expo.modules.onebox.oneoh.cloud.aidl.IServiceCallback
import expo.modules.onebox.oneoh.cloud.helper.Action
import expo.modules.onebox.oneoh.cloud.helper.Alert
import expo.modules.onebox.oneoh.cloud.helper.Settings
import expo.modules.onebox.oneoh.cloud.helper.Status

/**
 * VPN 服务连接管理。
 * 绑定到 VPNService，通过 AIDL 接口获取状态和注册回调。
 */
class ServiceConnection(
    private val context: Context,
    callback: Callback,
    private val register: Boolean = true
) : ServiceConnection {

    companion object {
        private const val TAG = "ServiceConnection"
    }

    private val serviceCallback = ServiceCallbackImpl(callback)
    private var service: IService? = null

    val status: Status
        get() = service?.status?.let { Status.values()[it] } ?: Status.Stopped

    fun connect() {
        val intent = Intent(context, Settings.serviceClass()).setAction(Action.SERVICE)
        context.bindService(intent, this, Context.BIND_AUTO_CREATE)
        Log.d(TAG, "request connect to ${Settings.serviceClass().simpleName}")
    }

    fun disconnect() {
        try {
            context.unbindService(this)
        } catch (_: IllegalArgumentException) {
        }
        Log.d(TAG, "request disconnect")
    }

    fun reconnect() {
        try {
            context.unbindService(this)
        } catch (_: IllegalArgumentException) {
        }
        val intent = Intent(context, Settings.serviceClass()).setAction(Action.SERVICE)
        context.bindService(intent, this, Context.BIND_AUTO_CREATE)
        Log.d(TAG, "request reconnect to ${Settings.serviceClass().simpleName}")
    }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        val service = IService.Stub.asInterface(binder)
        this.service = service
        try {
            if (register) service.registerCallback(serviceCallback)
            serviceCallback.onServiceStatusChanged(service.status)
        } catch (e: RemoteException) {
            Log.e(TAG, "initialize service connection", e)
        }
        Log.d(TAG, "service connected")
    }

    override fun onServiceDisconnected(name: ComponentName?) {
        try {
            service?.unregisterCallback(serviceCallback)
        } catch (e: RemoteException) {
            Log.e(TAG, "cleanup service connection", e)
        }
        Log.d(TAG, "service disconnected")
    }

    override fun onBindingDied(name: ComponentName?) {
        reconnect()
        Log.d(TAG, "service dead")
    }

    // ==================== 回调接口 ====================

    interface Callback {
        fun onServiceStatusChanged(status: Status)
        fun onServiceAlert(type: Alert, message: String?) {}
    }

    private class ServiceCallbackImpl(private val callback: Callback) : IServiceCallback.Stub() {
        override fun onServiceStatusChanged(status: Int) {
            callback.onServiceStatusChanged(Status.values()[status])
        }

        override fun onServiceAlert(type: Int, message: String?) {
            callback.onServiceAlert(Alert.values()[type], message)
        }
    }
}