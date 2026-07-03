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

// MARK: - Result

data class ConfigFetchResult(
    val statusCode: Int,
    val headers: Map<String, String>,
    val body: String,
)

/** Map an OkHttp response into the transport-neutral result (lower-cased headers, first value wins). */
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

// MARK: - SNI-overriding SSLSocketFactory
// When connecting to an IP address, TLS would fail because the server certificate
// is issued for the hostname, not the IP. This factory injects the original hostname
// as the SNI server name so the TLS handshake uses the correct name.

/**
 * Platform-default X509TrustManager (system trust store).
 *
 * OkHttp performs certificate-chain validation/cleaning through the
 * trust manager passed to sslSocketFactory(factory, trustManager) — the
 * factory's own SSLContext does NOT cover it on this custom-factory
 * path. A pass-through manager here disables chain validation entirely
 * and exposes config fetching to MITM. Never substitute a no-op
 * implementation.
 */
private fun systemDefaultTrustManager(): X509TrustManager {
    val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
    tmf.init(null as KeyStore?)
    return tmf.trustManagers.filterIsInstance<X509TrustManager>().first()
}

/** Short host digest for logs — the hostname is user profile data. */
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
 * Fetch a config URL using the best DNS server for hostname resolution.
 * Resolves the hostname via a raw UDP DNS A-record query, then makes an HTTPS
 * request to the resolved IP with a custom SNI override so TLS cert validation
 * passes against the original hostname.
 * Falls back to a direct fetch (system DNS) if resolution fails.
 */
internal suspend fun fetchConfig(url: String, userAgent: String): ConfigFetchResult {
    val parsedUri = android.net.Uri.parse(url)
    val originalHost = parsedUri.host ?: throw IllegalArgumentException("Malformed URL: $url")
    val scheme = parsedUri.scheme ?: "https"

    // Skip DNS resolution for literal IP addresses
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

    // Log the hashed host only — the resolved IP is user profile data and must
    // not be written in plaintext (it would defeat the hostHash8 masking).
    Log.i(TAG, "Resolved host(sha8=${hostHash8(originalHost)}) via $bestDns")

    // Replace host with resolved IP, keep scheme/port/path/query
    val port = parsedUri.port.let { if (it == -1) "" else ":$it" }
    val pathAndQuery = buildString {
        append(parsedUri.encodedPath ?: "/")
        parsedUri.encodedQuery?.let { append("?$it") }
    }
    val resolvedUrl = "$scheme://$resolvedIP$port$pathAndQuery"

    val sslContext = SSLContext.getDefault()
    val sniFactory = SNISocketFactory(sslContext.socketFactory, originalHost)

    // HostnameVerifier: validate against original hostname (not IP)
    val hostnameVerifier = HostnameVerifier { _, session ->
        HttpsURLConnection.getDefaultHostnameVerifier().verify(originalHost, session)
    }

    // Real system trust manager — OkHttp drives chain validation through it
    // (see systemDefaultTrustManager doc). Only SNI and the hostname check
    // are overridden on this path.
    val trustManager = systemDefaultTrustManager()

    val client = OkHttpClient.Builder()
        .sslSocketFactory(sniFactory, trustManager)
        .hostnameVerifier(hostnameVerifier)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        // 30 s wall clock aligns with the iOS fetcher (config-fetch-policy).
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

// MARK: - DNS A-record resolution

internal suspend fun resolveHostname(hostname: String, dnsServer: String): String {
    val txID = Random.nextInt(1, 0xFFFF).toShort()
    val query = buildAQuery(hostname, txID)

    return withContext(Dispatchers.IO) {
        DatagramSocket().use { socket ->
            socket.soTimeout = 500
            val serverAddr = InetSocketAddress(dnsServer, 53)
            socket.send(DatagramPacket(query, query.size, serverAddr))

            val buf = ByteArray(512)
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

    val rcode = buf[3].toInt() and 0x0F
    if (rcode != 0) throw IllegalStateException("DNS RCODE=$rcode")

    val ancount = ((buf[6].toInt() and 0xFF) shl 8) or (buf[7].toInt() and 0xFF)
    if (ancount == 0) throw IllegalStateException("No answers in DNS response")

    var offset = 12
    // Skip question QNAME
    while (offset < length) {
        val b = buf[offset].toInt() and 0xFF
        if (b == 0) { offset++; break }
        if ((b and 0xC0) == 0xC0) { offset += 2; break }
        offset += 1 + b
    }
    offset += 4 // skip QTYPE + QCLASS

    // Walk answer records
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

// MARK: - Helpers

// Pure format check — no DNS resolution. A literal IP is either dotted-quad
// IPv4 or contains ':' (IPv6). Anything else is a hostname to resolve.
private fun isIPAddress(host: String): Boolean {
    return host.matches(Regex("^(\\d{1,3}\\.){3}\\d{1,3}$")) || host.contains(":")
}

private suspend fun fetchDirect(url: String, userAgent: String): ConfigFetchResult {
    val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        // 30 s wall clock aligns with the iOS fetcher (config-fetch-policy).
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
