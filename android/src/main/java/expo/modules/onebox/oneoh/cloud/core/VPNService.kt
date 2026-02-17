package expo.modules.onebox.oneoh.cloud.core

import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.Notification
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.TunOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.net.InetAddress

/**
 * VPN 前台服务。
 * 继承 android.net.VpnService，实现 PlatformInterfaceWrapper 提供平台能力。
 * 内部将所有逻辑委托给 BoxService。
 *
 * 接收配置字符串通过 Intent extra (EXTRA_CONFIG)。
 */
class VPNService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "VPNService"
        const val EXTRA_CONFIG = "config_content"
    }

    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val config = intent?.getStringExtra(EXTRA_CONFIG) ?: ""
        return service.onStartCommand(config)
    }

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind()
    }

    override fun onDestroy() {
        service.onDestroy()
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
    }

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun RoutePrefix.toIpPrefix(): IpPrefix {
        return IpPrefix(InetAddress.getByName(address()), prefix())
    }

    override fun openTun(options: TunOptions): Int {
        Log.d(TAG, "[android] openTun: preparing VPN interface")
        Log.d(TAG, "[android] TunOptions: mtu=${options.mtu}, autoRoute=${options.autoRoute}, strictRoute=${options.strictRoute}")

        try {
            if (prepare(this) != null) {
                error("android: missing vpn permission")
            }

            val builder = Builder()
                .setSession("sing-box")
                .setMtu(options.mtu)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            // 记录是否有 IPv4/IPv6 地址（迭代器只能消费一次）
            var hasInet4 = false
            var hasInet6 = false

            // IPv4 地址
            val inet4Address = options.inet4Address
            while (inet4Address.hasNext()) {
                val address = inet4Address.next()
                Log.d(TAG, "[android] addAddress IPv4: ${address.address()}/${address.prefix()}")
                builder.addAddress(address.address(), address.prefix())
                hasInet4 = true
            }

            // IPv6 地址
            val inet6Address = options.inet6Address
            while (inet6Address.hasNext()) {
                val address = inet6Address.next()
                Log.d(TAG, "[android] addAddress IPv6: ${address.address()}/${address.prefix()}")
                builder.addAddress(address.address(), address.prefix())
                hasInet6 = true
            }

            if (options.autoRoute) {
                val dnsServer = options.dnsServerAddress.value
                Log.d(TAG, "[android] addDnsServer: $dnsServer")
                builder.addDnsServer(dnsServer)

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    // API 33+ : 使用 IpPrefix，支持 excludeRoute
                    val inet4RouteAddress = options.inet4RouteAddress
                    if (inet4RouteAddress.hasNext()) {
                        while (inet4RouteAddress.hasNext()) {
                            val route = inet4RouteAddress.next()
                            Log.d(TAG, "[android] addRoute IPv4: ${route.address()}/${route.prefix()}")
                            builder.addRoute(route.toIpPrefix())
                        }
                    } else if (hasInet4) {
                        Log.d(TAG, "[android] addRoute IPv4 fallback: 0.0.0.0/0")
                        builder.addRoute("0.0.0.0", 0)
                    }

                    val inet6RouteAddress = options.inet6RouteAddress
                    if (inet6RouteAddress.hasNext()) {
                        while (inet6RouteAddress.hasNext()) {
                            val route = inet6RouteAddress.next()
                            Log.d(TAG, "[android] addRoute IPv6: ${route.address()}/${route.prefix()}")
                            builder.addRoute(route.toIpPrefix())
                        }
                    } else if (hasInet6) {
                        Log.d(TAG, "[android] addRoute IPv6 fallback: ::/0")
                        builder.addRoute("::", 0)
                    }

                    var excludeCount = 0
                    val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                    while (inet4RouteExcludeAddress.hasNext()) {
                        val route = inet4RouteExcludeAddress.next()
                        val addr = InetAddress.getByName(route.address())
                        if (addr.isLoopbackAddress || addr.isLinkLocalAddress) {
                            Log.d(TAG, "[android] skip excludeRoute IPv4 (loopback/linklocal): ${route.address()}/${route.prefix()}")
                            continue
                        }
                        excludeCount++
                        Log.d(TAG, "[android] excludeRoute IPv4 #$excludeCount: ${route.address()}/${route.prefix()}")
                        builder.excludeRoute(route.toIpPrefix())
                    }
                    Log.d(TAG, "[android] total IPv4 excludeRoutes: $excludeCount")

                    var excludeCount6 = 0
                    val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                    while (inet6RouteExcludeAddress.hasNext()) {
                        val route = inet6RouteExcludeAddress.next()
                        val addr = InetAddress.getByName(route.address())
                        if (addr.isLoopbackAddress || addr.isLinkLocalAddress) {
                            Log.d(TAG, "[android] skip excludeRoute IPv6 (loopback/linklocal): ${route.address()}/${route.prefix()}")
                            continue
                        }
                        excludeCount6++
                        Log.d(TAG, "[android] excludeRoute IPv6 #$excludeCount6: ${route.address()}/${route.prefix()}")
                        builder.excludeRoute(route.toIpPrefix())
                    }
                    Log.d(TAG, "[android] total IPv6 excludeRoutes: $excludeCount6")
                } else {
                    // API < 33 : 使用 RouteRange（libbox 已将 exclude 合并计算）
                    val inet4RouteAddress = options.inet4RouteRange
                    if (inet4RouteAddress.hasNext()) {
                        while (inet4RouteAddress.hasNext()) {
                            val address = inet4RouteAddress.next()
                            builder.addRoute(address.address(), address.prefix())
                        }
                    }

                    val inet6RouteAddress = options.inet6RouteRange
                    if (inet6RouteAddress.hasNext()) {
                        while (inet6RouteAddress.hasNext()) {
                            val address = inet6RouteAddress.next()
                            builder.addRoute(address.address(), address.prefix())
                        }
                    }
                }

                // 允许/排除应用
                val includePackage = options.includePackage
                if (includePackage.hasNext()) {
                    while (includePackage.hasNext()) {
                        try {
                            val pkg = includePackage.next()
                            Log.d(TAG, "[android] addAllowedApplication: $pkg")
                            builder.addAllowedApplication(pkg)
                        } catch (e: NameNotFoundException) {
                            Log.e(TAG, "[android] addAllowedApplication failed", e)
                        }
                    }
                }

                val excludePackage = options.excludePackage
                if (excludePackage.hasNext()) {
                    while (excludePackage.hasNext()) {
                        try {
                            val pkg = excludePackage.next()
                            Log.d(TAG, "[android] addDisallowedApplication: $pkg")
                            builder.addDisallowedApplication(pkg)
                        } catch (e: NameNotFoundException) {
                            Log.e(TAG, "[android] addDisallowedApplication failed", e)
                        }
                    }
                }
            }

            // HTTP 代理
            if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                systemProxyAvailable = true
                systemProxyEnabled = false
            } else {
                systemProxyAvailable = false
                systemProxyEnabled = false
            }

            Log.d(TAG, "[android] calling builder.establish()")
            val pfd = builder.establish()
                ?: error("android: the application is not prepared or is revoked")
            Log.d(TAG, "[android] TUN fd=${pfd.fd} established successfully")
            service.fileDescriptor = pfd
            return pfd.fd
        } catch (e: Exception) {
            Log.e(TAG, "[android] openTun FAILED: ${e.javaClass.simpleName}: ${e.message}", e)
            throw e
        }
    }

    override fun sendNotification(notification: Notification) {
        service.sendNotification(notification)
    }
}
