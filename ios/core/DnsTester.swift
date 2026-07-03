import Foundation
import os.log

// MARK: - DNS latency tester

/// Concurrently tests a fixed set of DNS servers and returns the fastest responding IP.
/// All methods are static; no instance state is required.
struct DnsTester {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.onebox",
        category: "DnsTester"
    )

    static let servers = [
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
    ]

    /// Launches concurrent probes for all servers and returns the first one to respond.
    ///
    /// This is a first-response-wins race, not a collect-all-then-pick-lowest-latency
    /// scan: as soon as any server answers, its result is returned and `cancelAll()`
    /// tears down the remaining probes. Each probe is bounded by a 500 ms task-level
    /// timeout racing the query, plus a 450 ms SO_RCVTIMEO on the socket, so a
    /// non-responding server cannot stall the race. There is no global timeout —
    /// the per-probe bounds are the only cap (see Android for the ranked-latency variant).
    static func findBest() async -> String {
        let fallback = servers.first ?? "8.8.8.8"

        let best: String? = await withTaskGroup(
            of: (String, TimeInterval)?.self,
            returning: String?.self
        ) { group in
            for dns in servers {
                group.addTask { await testServer(dns) }
            }

            // Take the first non-nil result; cancelling the group tears down the rest.
            for await result in group {
                if let (dns, latency) = result {
                    logger.info("First response: \(dns, privacy: .public)  \(String(format: "%.1f", latency * 1000), privacy: .public) ms")
                    group.cancelAll()
                    return dns
                }
            }
            return nil
        }

        guard let winner = best else {
            logger.error("All servers failed, falling back to: \(fallback, privacy: .public)")
            return fallback
        }
        return winner
    }

    // MARK: - Private helpers

    private static func testServer(_ dnsServer: String) async -> (String, TimeInterval)? {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await performQuery(to: dnsServer) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    throw CancellationError()   // timeout branch
                }

                // First to finish wins: query success returns normally, timeout throws.
                try await group.next()!
                group.cancelAll()   // cancel the losing task immediately
            }

            let latency = CFAbsoluteTimeGetCurrent() - startTime
            logger.debug("\(dnsServer) responded, latency: \(String(format: "%.1f", latency * 1000)) ms")
            return (dnsServer, latency)

        } catch {
            logger.debug("\(dnsServer) failed or timed out")
            return nil
        }
    }

    private static func performQuery(to dnsServer: String) async throws {
        logger.debug("Testing DNS server: \(dnsServer, privacy: .public)")

        // NOTE: this inlines a fixed www.baidu.com A-query packet, a copy of the DNS
        // packet knowledge already implemented in ConfigFetcher.buildAQuery / resolveHostname.
        // The audit (D3b-05 / D3c-04) recommends replacing this probe with a call to
        // ConfigFetcher.resolveHostname("www.baidu.com", via: dnsServer). That is deferred
        // because it changes the probe's success criterion (any matching response ->
        // must contain an A record), which affects DNS server selection under DNS
        // poisoning/censorship and needs a build + on-device verification in adversarial
        // network conditions before it can land.

        // DNS query packet for www.baidu.com (type A)
        var queryData = Data([
            0x12, 0x34,  // Transaction ID
            0x01, 0x00,  // Standard query
            0x00, 0x01,  // Questions: 1
            0x00, 0x00,  // Answer RRs: 0
            0x00, 0x00,  // Authority RRs: 0
            0x00, 0x00   // Additional RRs: 0
        ])
        queryData.append(contentsOf: [3])
        queryData.append("www".data(using: .ascii)!)
        queryData.append(contentsOf: [5])
        queryData.append("baidu".data(using: .ascii)!)
        queryData.append(contentsOf: [3])
        queryData.append("com".data(using: .ascii)!)
        queryData.append(contentsOf: [0])       // null terminator
        queryData.append(contentsOf: [0x00, 0x01])  // Type A
        queryData.append(contentsOf: [0x00, 0x01])  // Class IN

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)

            DispatchQueue.global(qos: .userInitiated).async {
                let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
                guard socketFD > 0 else {
                    once.resume(throwing: NSError(domain: "SocketError", code: -1, userInfo: nil))
                    return
                }
                defer { close(socketFD) }

                // Set socket receive timeout to 450ms so recv() won't block indefinitely
                // when a Swift task is cancelled (task cancellation cannot interrupt blocking syscalls).
                var timeout = timeval(tv_sec: 0, tv_usec: 450_000)
                setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                var serverAddr = sockaddr_in()
                serverAddr.sin_family = sa_family_t(AF_INET)
                serverAddr.sin_port = UInt16(53).bigEndian
                guard inet_pton(AF_INET, dnsServer, &serverAddr.sin_addr) == 1 else {
                    once.resume(throwing: NSError(domain: "InvalidIPAddress", code: -1, userInfo: nil))
                    return
                }

                let sendResult = queryData.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &serverAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            sendto(socketFD, bytes.bindMemory(to: UInt8.self).baseAddress, queryData.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sendResult > 0 else {
                    once.resume(throwing: NSError(domain: "SendError", code: -1, userInfo: nil))
                    return
                }

                var buffer = [UInt8](repeating: 0, count: 512)
                let recvResult = recv(socketFD, &buffer, buffer.count, 0)

                if recvResult >= 12 && buffer[0] == 0x12 && buffer[1] == 0x34 {
                    once.resume(returning: ())
                } else {
                    once.resume(throwing: NSError(domain: "InvalidResponse", code: -1, userInfo: nil))
                }
            }
        }
    }
}
