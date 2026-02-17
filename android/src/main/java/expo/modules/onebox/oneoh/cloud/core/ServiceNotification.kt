package expo.modules.onebox.oneoh.cloud.core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.MutableLiveData
import expo.modules.onebox.oneoh.cloud.R
import expo.modules.onebox.oneoh.cloud.Status
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.sfa.utils.CommandClient
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.withContext
import expo.modules.onebox.oneoh.cloud.Action
import expo.modules.onebox.oneoh.cloud.ExpoOneBoxModule.Companion.notification
import expo.modules.onebox.oneoh.cloud.ExpoOneBoxModule.Companion.notificationManager

/**
 * VPN 前台通知管理。
 * 显示连接状态和网速信息。
 */

class ServiceNotification(
    private val status: MutableLiveData<Status>,
    private val service: Service
) :
    BroadcastReceiver(),
    CommandClient.Handler
{

    companion object {
        private const val NOTIFICATION_ID = 1
        private const val NOTIFICATION_CHANNEL = "vpn_service"
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
    }


    @OptIn(DelicateCoroutinesApi::class)
    private val commandClient =
        CommandClient(GlobalScope, CommandClient.ConnectionType.Status, this)
    private var receiverRegistered = false


    private val notificationBuilder by lazy {
        val packageName = service.packageName
        val launchIntent = service.packageManager.getLaunchIntentForPackage(packageName)
        NotificationCompat.Builder(service, NOTIFICATION_CHANNEL).setShowWhen(false).setOngoing(true)
            .setContentTitle("sing-box").setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_menu)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
//                   等价写法： launchIntent?.flag = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    launchIntent?.apply {
                        // 保持你原来的 Flag
                        flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                    },
                    flags,
                ),
            )
            .setPriority(NotificationCompat.PRIORITY_LOW).apply {
                addAction(
                    NotificationCompat.Action.Builder(
                        0,
                        service.getText(R.string.stop),
                        PendingIntent.getBroadcast(
                            service,
                            0,
                            Intent(Action.SERVICE_CLOSE).setPackage(service.packageName),
                            flags,
                        ),
                    ).build(),
                )
            }
    }

    fun show(lastProfileName: String, @StringRes contentTextId: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
           notification.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "Service Notifications",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        service.startForeground(
            NOTIFICATION_ID,
            notificationBuilder
                .setContentTitle(lastProfileName.takeIf { it.isNotBlank() } ?: "sing-box")
                .setContentText(service.getString(contentTextId)).build(),
        )
    }

    suspend fun start() {
            commandClient.connect()
            withContext(Dispatchers.Main) {
                registerReceiver()
            }

    }

    private fun registerReceiver() {
        service.registerReceiver(
            this,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            },
        )
        receiverRegistered = true
    }

    override fun updateStatus(status: StatusMessage) {
        val content =
            Libbox.formatBytes(status.uplink) + "/s ↑\t" + Libbox.formatBytes(status.downlink) + "/s ↓"
        notificationManager.notify(
            NOTIFICATION_ID,
            notificationBuilder.setContentText(content).build(),
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                commandClient.connect()
            }

            Intent.ACTION_SCREEN_OFF -> {
                commandClient.disconnect()
            }
        }
    }

    fun close() {
        commandClient.disconnect()
        ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (receiverRegistered) {
            service.unregisterReceiver(this)
            receiverRegistered = false
        }
    }
}
