package expo.modules.onebox.oneoh.cloud.helper

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.flow.flatMapMerge
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

private const val TAG = "DnsTester"

internal val DNS_SERVERS = arrayOf(
    "1.0.0.1",        // Cloudflare DNS
    "1.1.1.1",        // Cloudflare DNS
    "1.2.4.8",        // CN DNS
    "101.101.101.101",
    "101.102.103.104",
    "114.114.114.114", // CN 114DNS
    "114.114.115.115", // CN 114DNS
    "119.29.29.29",    // CN Tencent DNS
    "149.112.112.112",
    "149.112.112.9",
    "180.184.1.1",
    "180.184.2.2",
    "180.76.76.76",
    "2.188.21.131",   // Iran Yokhdi! DNS
    "2.188.21.132",   // Iran Yokhdi! DNS
    "2.189.44.44",    // Iran DNS
    "202.175.3.3",
    "202.175.3.8",
    "208.67.220.220", // OpenDNS
    "208.67.220.222", // OpenDNS
    "208.67.222.220", // OpenDNS
    "208.67.222.222", // OpenDNS
    "210.2.4.8",
    "223.5.5.5",      // CN Alibaba DNS
    "223.6.6.6",      // CN Alibaba DNS
    "77.88.8.1",
    "77.88.8.8",
    "8.8.4.4",        // Google DNS
    "8.8.8.8",        // Google DNS
    "9.9.9.9"         // Quad9 DNS
)

/**
 * 并发测试所有 DNS 服务器，返回第一个响应的 IP 地址（其余立即取消）。
 * 全部超时则返回默认第一个。总超时 10 秒，单服务器超时 500ms（由 soTimeout 控制）。
 */
internal suspend fun findBestDnsServer(): String {
    val fallback = DNS_SERVERS.firstOrNull() ?: "8.8.8.8"
    return try {
        withTimeoutOrNull(10_000) {
            findBestDnsServerInternal()
        } ?: fallback.also { Log.w(TAG, "DNS test global timeout, falling back to: $fallback") }
    } catch (e: Exception) {
        Log.w(TAG, "DNS test failed", e)
        fallback
    }
}

@Suppress("OPT_IN_USAGE")
private suspend fun findBestDnsServerInternal(): String {
    val fallback = DNS_SERVERS.first()
    val results = mutableListOf<Pair<String, Long>>()
    val resultsLock = Any()
    val globalStart = System.currentTimeMillis()

    Log.i(TAG, "====== DNS Test Started (${DNS_SERVERS.size} servers) ======")

    val winner = DNS_SERVERS.asFlow()
        .flatMapMerge(concurrency = DNS_SERVERS.size) { dns ->
            flow {
                testDnsServer(dns, globalStart)?.let { result ->
                    synchronized(resultsLock) { results.add(result) }
                    emit(result)
                }
            }.flowOn(Dispatchers.IO)
        }
        .firstOrNull()

    // 打印已收集到的响应排名（firstOrNull 取消后部分任务可能还未完成，属正常现象）
    synchronized(resultsLock) {
        val sorted = results.sortedBy { it.second }
        Log.i(TAG, "====== DNS Results (${results.size}/${DNS_SERVERS.size} responded before cancel) ======")
        sorted.forEachIndexed { index, (dns, latency) ->
            val marker = if (dns == winner?.first) "👑" else "  "
            Log.i(TAG, "$marker #${index + 1}  ${dns.padEnd(20)}  ${latency}ms")
        }
        Log.i(TAG, "=================================================================")
    }

    return winner?.also { (dns, latency) ->
        val totalElapsed = System.currentTimeMillis() - globalStart
        Log.i(TAG, "✅ Selected: $dns  rtt=${latency}ms  total_elapsed=${totalElapsed}ms")
    }?.first ?: fallback.also {
        Log.w(TAG, "✗ All DNS servers failed, falling back to: $fallback")
    }
}

/**
 * 测试单个 DNS 服务器。
 * @param globalStart 全局开始时间，用于计算 elapsed（方便对比各服务器竞争情况）
 */
private suspend fun testDnsServer(dnsServer: String, globalStart: Long): Pair<String, Long>? {
    val startTime = System.currentTimeMillis()
    return try {
        performDnsQuery(dnsServer)
        val latency = System.currentTimeMillis() - startTime
        val elapsed = System.currentTimeMillis() - globalStart
        Log.d(TAG, "✓ ${dnsServer.padEnd(20)}  rtt=${latency}ms  elapsed=${elapsed}ms")
        Pair(dnsServer, latency)
    } catch (e: Exception) {
        val elapsed = System.currentTimeMillis() - globalStart
        Log.d(TAG, "✗ ${dnsServer.padEnd(20)}  elapsed=${elapsed}ms  reason=${e.message}")
        null
    }
}

private suspend fun performDnsQuery(dnsServer: String) {
    withContext(Dispatchers.IO) {
        // DNS query packet for www.baidu.com (type A)
        val queryData = byteArrayOf(
            0x12, 0x34,  // Transaction ID
            0x01, 0x00,  // Standard query
            0x00, 0x01,  // Questions: 1
            0x00, 0x00,  // Answer RRs: 0
            0x00, 0x00,  // Authority RRs: 0
            0x00, 0x00,  // Additional RRs: 0
            3, 'w'.code.toByte(), 'w'.code.toByte(), 'w'.code.toByte(),
            5, 'b'.code.toByte(), 'a'.code.toByte(), 'i'.code.toByte(), 'd'.code.toByte(), 'u'.code.toByte(),
            3, 'c'.code.toByte(), 'o'.code.toByte(), 'm'.code.toByte(),
            0,           // null terminator
            0x00, 0x01,  // Type A
            0x00, 0x01   // Class IN
        )

        java.net.DatagramSocket().use { udpSocket ->
            udpSocket.soTimeout = 500  // 唯一的超时控制点，不依赖协程层 timeout

            val serverAddress = java.net.InetSocketAddress(dnsServer, 53)
            udpSocket.send(java.net.DatagramPacket(queryData, queryData.size, serverAddress))

            val buffer = ByteArray(512)
            val receivePacket = java.net.DatagramPacket(buffer, buffer.size)
            udpSocket.receive(receivePacket)

            if (receivePacket.length < 12 || buffer[0] != 0x12.toByte() || buffer[1] != 0x34.toByte()) {
                throw Exception("Invalid DNS response")
            }
        }
    }
}