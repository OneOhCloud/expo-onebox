import Foundation

// MARK: - DNS latency tester

/// Concurrently tests a fixed set of DNS servers and returns the fastest responding IP.
/// All methods are static; no instance state is required.
struct DnsTester {

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

    /// Launches concurrent tests for all servers and returns the fastest responding one.
    /// Falls back to `servers[0]` if all fail. Total budget is governed by the per-server
    /// timeout (500 ms) plus Swift concurrency scheduling.
    static func findBest() async -> String {
        let firstDns = servers.first ?? "8.8.8.8"

        return await withTaskGroup(of: (String, TimeInterval)?.self, returning: String.self) { group in
            for dns in servers {
                group.addTask {
                    return await testServer(dns)
                }
            }

            for await result in group {
                if let (dnsServer, latency) = result {
                    NSLog("[DnsTester] %@ selected as optimal server, latency: %.3fms", dnsServer, latency * 1000)
                    group.cancelAll()
                    return dnsServer
                }
            }

            NSLog("[DnsTester] All servers failed, falling back to: %@", firstDns)
            return firstDns
        }
    }

    // MARK: - Private helpers

    private static func testServer(_ dnsServer: String) async -> (String, TimeInterval)? {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            let succeeded = try await withThrowingTaskGroup(of: Void.self, returning: Bool.self) { group in
                group.addTask {
                    try await performQuery(to: dnsServer)
                }
                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500 ms
                    throw NSError(domain: "DNSTimeout", code: -1, userInfo: nil)
                }
                guard (try await group.next()) != nil else {
                    throw NSError(domain: "DNSError", code: -1, userInfo: nil)
                }
                return true
            }

            if succeeded {
                let latency = CFAbsoluteTimeGetCurrent() - startTime
                let paddedDns = dnsServer.padding(toLength: 20, withPad: " ", startingAt: 0)
                NSLog("[DnsTester] ✓ %@ responded, latency: %.3fms", paddedDns, latency * 1000)
                return (dnsServer, latency)
            }
        } catch {
            let paddedDns = dnsServer.padding(toLength: 20, withPad: " ", startingAt: 0)
            NSLog("[DnsTester] ✗ %@ failed or timed out", paddedDns)
        }

        return nil
    }

    private static func performQuery(to dnsServer: String) async throws {
        NSLog("[DnsTester] Testing DNS server: %@", dnsServer)

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
            var isResumed = false
            let lock = NSLock()

            DispatchQueue.global(qos: .userInitiated).async {
                let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
                guard socketFD > 0 else {
                    lock.lock(); defer { lock.unlock() }
                    if !isResumed { isResumed = true; continuation.resume(throwing: NSError(domain: "SocketError", code: -1, userInfo: nil)) }
                    return
                }
                defer { close(socketFD) }

                var serverAddr = sockaddr_in()
                serverAddr.sin_family = sa_family_t(AF_INET)
                serverAddr.sin_port = UInt16(53).bigEndian
                guard inet_pton(AF_INET, dnsServer, &serverAddr.sin_addr) == 1 else {
                    lock.lock(); defer { lock.unlock() }
                    if !isResumed { isResumed = true; continuation.resume(throwing: NSError(domain: "InvalidIPAddress", code: -1, userInfo: nil)) }
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
                    lock.lock(); defer { lock.unlock() }
                    if !isResumed { isResumed = true; continuation.resume(throwing: NSError(domain: "SendError", code: -1, userInfo: nil)) }
                    return
                }

                var buffer = [UInt8](repeating: 0, count: 512)
                let recvResult = recv(socketFD, &buffer, buffer.count, 0)

                lock.lock(); defer { lock.unlock() }
                guard !isResumed else { return }
                isResumed = true
                if recvResult >= 12 && buffer[0] == 0x12 && buffer[1] == 0x34 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(domain: "InvalidResponse", code: -1, userInfo: nil))
                }
            }
        }
    }
}
