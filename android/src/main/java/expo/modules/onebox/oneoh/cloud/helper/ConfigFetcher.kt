package expo.modules.onebox.oneoh.cloud.helper

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager
import kotlin.random.Random

private const val TAG = "ConfigFetcher"

// MARK: - 结果

data class ConfigFetchResult(
    val statusCode: Int,
    val headers: Map<String, String>,
    val body: String,
)

/** 把 OkHttp 响应映射为传输无关的结果（header 名转小写，取首个值）。 */
private fun Response.toConfigFetchResult(): ConfigFetchResult {
    val flatHeaders = mutableMapOf<String, String>()
    for (name in headers.names()) {
        headers(name).firstOrNull()?.let { flatHeaders[name.lowercase()] = it }
    }
    return ConfigFetchResult(
        statusCode = code,
        headers = flatHeaders,
        body = body?.string() ?: "",
    )
}

// MARK: - 覆盖 SNI 的 SSLSocketFactory
// 连接到 IP 地址时，TLS 会失败，因为服务器证书是签发给 hostname 而非 IP 的。
// 本 factory 把原始 hostname 作为 SNI server name 注入，使 TLS 握手使用正确的名字。

/**
 * 平台默认的 X509TrustManager（系统信任库）。
 *
 * OkHttp 通过传给 sslSocketFactory(factory, trustManager) 的 trust manager
 * 执行证书链的校验/清理——在这条自定义 factory 路径上，factory 自身的
 * SSLContext 并不覆盖它。这里若换成一个直通（pass-through）manager 会彻底
 * 关闭链校验，使配置抓取暴露于 MITM。切勿替换为空实现（no-op）。
 */
private fun systemDefaultTrustManager(): X509TrustManager {
    val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
    tmf.init(null as KeyStore?)
    return tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
}

/** 用于日志的短 host 摘要——hostname 属于用户配置数据。 */
private fun hostHash8(host: String): String = sha256Hex(host).take(8)

private class SNISocketFactory(
    private val delegate: SSLSocketFactory,
    private val hostname: String,
) : SSLSocketFactory() {

    override fun getDefaultCipherSuites(): Array<String> = delegate.defaultCipherSuites
    override fun getSupportedCipherSuites(): Array<String> = delegate.supportedCipherSuites

    override fun createSocket(): Socket = configureSNI(delegate.createSocket() as SSLSocket)

    override fun createSocket(host: String, port: Int): Socket =
        configureSNI(delegate.createSocket(hostname, port) as SSLSocket)

    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
        configureSNI(delegate.createSocket(hostname, port, localHost, localPort) as SSLSocket)

    override fun createSocket(host: InetAddress, port: Int): Socket =
        configureSNI(delegate.createSocket(host, port) as SSLSocket)

    override fun createSocket(address: InetAddress, port: Int, localAddress: InetAddress, localPort: Int): Socket =
        configureSNI(delegate.createSocket(address, port, localAddress, localPort) as SSLSocket)

    override fun createSocket(s: Socket, host: String, port: Int, autoClose: Boolean): Socket =
        configureSNI(delegate.createSocket(s, hostname, port, autoClose) as SSLSocket)

    private fun configureSNI(socket: SSLSocket): SSLSocket {
        val params = SSLParameters()
        params.serverNames = listOf(SNIHostName(hostname))
        socket.sslParameters = params
        return socket
    }
}

// MARK: - fetchConfig

/**
 * 使用最佳 DNS server 解析 hostname 来抓取一个配置 URL。
 * 通过原始 UDP DNS A 记录查询解析 hostname，然后带自定义 SNI 覆盖对解析出的
 * IP 发起 HTTPS 请求，使 TLS 证书校验针对原始 hostname 通过。
 * 若解析失败，回落到直连抓取（系统 DNS）。
 */
internal suspend fun fetchConfig(url: String, userAgent: String): ConfigFetchResult {
    val parsedUri = android.net.Uri.parse(url)
    val originalHost = parsedUri.host ?: throw IllegalArgumentException("Malformed URL: $url")
    val scheme = parsedUri.scheme ?: "https"

    // 对字面 IP 地址跳过 DNS 解析
    if (isIPAddress(originalHost)) {
        return fetchDirect(url, userAgent)
    }

    val bestDns = findBestDnsServer()
    val resolvedIP: String = try {
        resolveHostname(originalHost, bestDns)
    } catch (e: Exception) {
        Log.w(TAG, "DNS resolution failed ($e), falling back to direct fetch")
        return fetchDirect(url, userAgent)
    }

    // 只记录哈希后的 host——解析出的 IP 属于用户配置数据，绝不能明文写出
    // （那会使 hostHash8 掩码形同虚设）。
    Log.i(TAG, "Resolved host(sha8=${hostHash8(originalHost)}) via $bestDns")

    // 用解析出的 IP 替换 host，保留 scheme/port/path/query
    val port = parsedUri.port.let { if (it == -1) "" else ":$it" }
    val pathAndQuery = buildString {
        append(parsedUri.encodedPath ?: "/")
        parsedUri.encodedQuery?.let { append("?$it") }
    }
    val resolvedUrl = "$scheme://$resolvedIP$port$pathAndQuery"

    val sslContext = SSLContext.getDefault()
    val sniFactory = SNISocketFactory(sslContext.socketFactory, originalHost)

    // HostnameVerifier：针对原始 hostname（而非 IP）校验
    val hostnameVerifier = HostnameVerifier { _, session ->
        HttpsURLConnection.getDefaultHostnameVerifier().verify(originalHost, session)
    }

    // 真正的系统 trust manager——OkHttp 通过它驱动链校验
    // （见 systemDefaultTrustManager 文档）。这条路径上只覆盖 SNI 和 hostname 校验。
    val trustManager = systemDefaultTrustManager()

    val client = OkHttpClient.Builder()
        .sslSocketFactory(sniFactory, trustManager)
        .hostnameVerifier(hostnameVerifier)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        // 30 s wall-clock 与 iOS fetcher 对齐（config-fetch-policy）。
        .callTimeout(30, TimeUnit.SECONDS)
        .build()

    val request = Request.Builder()
        .url(resolvedUrl)
        .header("Host", originalHost)
        .header("User-Agent", userAgent)
        .header("Accept", "application/json, */*")
        .get()
        .build()

    return withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { it.toConfigFetchResult() }
    }
}

// MARK: - DNS A 记录解析

internal suspend fun resolveHostname(hostname: String, dnsServer: String): String {
    val txID = Random.nextInt(1, 0xFFFF).toShort()
    val query = buildAQuery(hostname, txID)

    return withContext(Dispatchers.IO) {
        DatagramSocket().use { socket ->
            socket.soTimeout = 500
            val serverAddr = InetSocketAddress(dnsServer, 53)
            socket.send(DatagramPacket(query, query.size, serverAddr))

            // 用 4096 以容纳 EDNS0 大小的响应，与 iOS 的接收缓冲区一致。
            val buf = ByteArray(4096)
            val packet = DatagramPacket(buf, buf.size)
            socket.receive(packet)

            parseFirstARecord(buf, packet.length, txID)
        }
    }
}

internal fun buildAQuery(hostname: String, txID: Short): ByteArray {
    val labels = hostname.split(".")
    val qname = mutableListOf<Byte>()
    for (label in labels) {
        qname.add(label.length.toByte())
        qname.addAll(label.toByteArray().toList())
    }
    qname.add(0)

    return buildList<Byte> {
        add((txID.toInt() shr 8).toByte())
        add((txID.toInt() and 0xFF).toByte())
        addAll(listOf(0x01, 0x00).map { it.toByte() }) // RD=1
        addAll(listOf(0x00, 0x01).map { it.toByte() }) // QDCOUNT=1
        addAll(listOf(0x00, 0x00, 0x00, 0x00, 0x00, 0x00).map { it.toByte() })
        addAll(qname)
        addAll(listOf(0x00, 0x01).map { it.toByte() }) // QTYPE=A
        addAll(listOf(0x00, 0x01).map { it.toByte() }) // QCLASS=IN
    }.toByteArray()
}

internal fun parseFirstARecord(buf: ByteArray, length: Int, txID: Short): String {
    if (length < 12) throw IllegalStateException("DNS response too short")

    val responseID = ((buf[0].toInt() and 0xFF) shl 8) or (buf[1].toInt() and 0xFF)
    if (responseID != (txID.toInt() and 0xFFFF)) throw IllegalStateException("Transaction ID mismatch")

    // QR 位必须被置位（这是响应而非查询）——与 iOS 保持一致。
    if ((buf[2].toInt() and 0x80) == 0) throw IllegalStateException("Not a DNS response (QR=0)")

    val rcode = buf[3].toInt() and 0x0F
    if (rcode != 0) throw IllegalStateException("DNS RCODE=$rcode")

    val ancount = ((buf[6].toInt() and 0xFF) shl 8) or (buf[7].toInt() and 0xFF)
    if (ancount == 0) throw IllegalStateException("No answers in DNS response")

    var offset = 12
    // 跳过 question 的 QNAME
    while (offset < length) {
        val b = buf[offset].toInt() and 0xFF
        if (b == 0) { offset++; break }
        if ((b and 0xC0) == 0xC0) { offset += 2; break }
        offset += 1 + b
    }
    offset += 4 // 跳过 QTYPE + QCLASS

    // 遍历 answer 记录
    repeat(ancount) {
        if (offset >= length) return@repeat
        // NAME
        if ((buf[offset].toInt() and 0xFF and 0xC0) == 0xC0) {
            offset += 2
        } else {
            while (offset < length) {
                val b = buf[offset].toInt() and 0xFF
                if (b == 0) { offset++; break }
                offset += 1 + b
            }
        }
        if (offset + 10 > length) return@repeat
        val rrType = ((buf[offset].toInt() and 0xFF) shl 8) or (buf[offset + 1].toInt() and 0xFF)
        val rdlength = ((buf[offset + 8].toInt() and 0xFF) shl 8) or (buf[offset + 9].toInt() and 0xFF)
        offset += 10

        if (rrType == 0x0001 && rdlength == 4 && offset + 4 <= length) {
            return "${buf[offset].toInt() and 0xFF}.${buf[offset+1].toInt() and 0xFF}" +
                    ".${buf[offset+2].toInt() and 0xFF}.${buf[offset+3].toInt() and 0xFF}"
        }
        offset += rdlength
    }
    throw IllegalStateException("No A record found")
}

// MARK: - 辅助函数

// 纯格式检查——不做 DNS 解析。字面 IP 要么是点分四段 IPv4，要么含 ':'（IPv6）。
// 其他一律视为需要解析的 hostname。
private fun isIPAddress(host: String): Boolean {
    return host.matches(Regex("^(\\d{1,3}\\.){3}\\d{1,3}$")) || host.contains(":")
}

private suspend fun fetchDirect(url: String, userAgent: String): ConfigFetchResult {
    val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        // 30 s wall-clock 与 iOS fetcher 对齐（config-fetch-policy）。
        .callTimeout(30, TimeUnit.SECONDS)
        .build()
    val request = Request.Builder()
        .url(url)
        .header("User-Agent", userAgent)
        .header("Accept", "application/json, */*")
        .get()
        .build()
    return withContext(Dispatchers.IO) {
        client.newCall(request).execute().use { it.toConfigFetchResult() }
    }
}
