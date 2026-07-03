package expo.modules.onebox.oneoh.cloud.core

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor
import kotlinx.coroutines.runBlocking
import java.net.InetAddress
import java.net.UnknownHostException
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * 本地 DNS 解析器。
 * 实现 LocalDNSTransport，使用 Android DnsResolver API 进行 DNS 查询。
 */
object LocalResolver : LocalDNSTransport {

    private const val RCODE_NXDOMAIN = 3

    /**
     * [exchange] 与 [lookup] 共享的 DnsResolver.Callback.onError 处理：
     * ErrnoException 映射为 errnoCode + resume；其他一律向上传播
     * （并防范 double-resume 竞态）。
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun handleDnsError(
        error: DnsResolver.DnsException,
        ctx: ExchangeContext,
        continuation: Continuation<Unit>,
    ) {
        val cause = error.cause
        if (cause is ErrnoException) {
            ctx.errnoCode(cause.errno)
            continuation.resume(Unit)
            return
        }
        try {
            continuation.resumeWithException(error)
        } catch (_: IllegalStateException) {
            // 已经 resume 过
        }
    }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        return runBlocking {
            val defaultNetwork = DefaultNetworkMonitor.require()
            suspendCoroutine { continuation ->
                val signal = CancellationSignal()
                ctx.onCancel(signal::cancel)
                val callback = object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) {
                            ctx.rawSuccess(answer)
                        } else {
                            ctx.errorCode(rcode)
                        }
                        continuation.resume(Unit)
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        handleDnsError(error, ctx, continuation)
                    }
                }
                DnsResolver.getInstance().rawQuery(
                    defaultNetwork,
                    message,
                    DnsResolver.FLAG_NO_RETRY,
                    Dispatchers.IO.asExecutor(),
                    signal,
                    callback,
                )
            }
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        return runBlocking {
            val defaultNetwork = DefaultNetworkMonitor.require()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                suspendCoroutine { continuation ->
                    val signal = CancellationSignal()
                    ctx.onCancel(signal::cancel)
                    val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                        override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                            if (rcode == 0) {
                                ctx.success(
                                    (answer as Collection<InetAddress?>)
                                        .mapNotNull { it?.hostAddress }
                                        .joinToString("\n")
                                )
                            } else {
                                ctx.errorCode(rcode)
                            }
                            continuation.resume(Unit)
                        }

                        override fun onError(error: DnsResolver.DnsException) {
                            handleDnsError(error, ctx, continuation)
                        }
                    }
                    val type = when {
                        network.endsWith("4") -> DnsResolver.TYPE_A
                        network.endsWith("6") -> DnsResolver.TYPE_AAAA
                        else -> null
                    }
                    if (type != null) {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            type,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback,
                        )
                    } else {
                        DnsResolver.getInstance().query(
                            defaultNetwork,
                            domain,
                            DnsResolver.FLAG_NO_RETRY,
                            Dispatchers.IO.asExecutor(),
                            signal,
                            callback,
                        )
                    }
                }
            } else {
                val answer = try {
                    defaultNetwork.getAllByName(domain)
                } catch (e: UnknownHostException) {
                    ctx.errorCode(RCODE_NXDOMAIN)
                    return@runBlocking
                }
                ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            }
        }
    }
}
