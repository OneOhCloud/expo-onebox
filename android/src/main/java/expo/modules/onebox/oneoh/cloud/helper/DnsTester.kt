package expo.modules.onebox.oneoh.cloud.helper

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
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
 * 并发测试所有 DNS 服务器，返回响应最快的 IP 地址。
 * 总超时 10 秒，单服务器超时 500ms。
 */
internal suspend fun findBestDnsServer(): String {
    val firstDns = DNS_SERVERS.firstOrNull() ?: "8.8.8.8"
    return try {
        withTimeoutOrNull(10000) {
            async { findBestDnsServerInternal() }.await()
        } ?: firstDns
    } catch (e: Exception) {
        Log.w(TAG, "DNS test failed", e)
        firstDns
    }
}

private suspend fun findBestDnsServerInternal(): String {
    val firstDns = DNS_SERVERS.first()
    return coroutineScope {
        val deferredResults = DNS_SERVERS.map { dns ->
            async { testDnsServer(dns) }
        }

        for (result in awaitAll(*deferredResults.toTypedArray())) {
            result?.let { (dnsServer, latency) ->
                Log.i(TAG, "✓ DNS $dnsServer selected as optimal server with latency ${latency}ms")
                return@coroutineScope dnsServer
            }
        }

        Log.i(TAG, "✗ All DNS servers failed, falling back to: $firstDns")
        firstDns
    }
}

private suspend fun testDnsServer(dnsServer: String): Pair<String, Long>? {
    val startTime = System.currentTimeMillis()
    return try {
        withTimeoutOrNull(500) {
            performDnsQuery(dnsServer)
            val latency = System.currentTimeMillis() - startTime
            Log.i(TAG, "✓ DNS ${dnsServer.padEnd(20)} responded successfully, latency: ${latency}ms")
            Pair(dnsServer, latency)
        }
    } catch (e: Exception) {
        Log.i(TAG, "✗ DNS ${dnsServer.padEnd(20)} failed or timed out")
        null
    }
}

private suspend fun performDnsQuery(dnsServer: String) {
    withContext(Dispatchers.IO) {
        Log.d(TAG, "Testing DNS server: $dnsServer")

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

        val socket = java.net.DatagramSocket()
        socket.use { udpSocket ->
            udpSocket.soTimeout = 500

            val serverAddress = java.net.InetSocketAddress(dnsServer, 53)
            udpSocket.send(java.net.DatagramPacket(queryData, queryData.size, serverAddress))

            val buffer = ByteArray(512)
            val receivePacket = java.net.DatagramPacket(buffer, buffer.size)
            udpSocket.receive(receivePacket)

            if (receivePacket.length >= 12 && buffer[0] == 0x12.toByte() && buffer[1] == 0x34.toByte()) {
                return@withContext
            } else {
                throw Exception("Invalid DNS response")
            }
        }
    }
}
