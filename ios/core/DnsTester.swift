import Foundation
import os.log

// MARK: - DNS latency tester

/// 并发测试一组固定的 DNS 服务器，返回最先响应的 IP。
/// 所有方法均为 static；无需实例状态。
struct DnsTester {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.onebox",
        category: "DnsTester"
    )

    static let servers = [
        "1.0.0.1",        // Cloudflare DNS
        "1.1.1.1",        // Cloudflare DNS
        "1.2.4.8",        // 国内 DNS
        "101.101.101.101",
        "101.102.103.104",
        "114.114.114.114", // 国内 114DNS
        "114.114.115.115", // 国内 114DNS
        "119.29.29.29",    // 国内 Tencent DNS
        "149.112.112.112",
        "149.112.112.9",
        "180.184.1.1",
        "180.184.2.2",
        "180.76.76.76",
        "2.188.21.131",   // 伊朗 Yokhdi! DNS
        "2.188.21.132",   // 伊朗 Yokhdi! DNS
        "2.189.44.44",    // 伊朗 DNS
        "202.175.3.3",
        "202.175.3.8",
        "208.67.220.220", // OpenDNS
        "208.67.220.222", // OpenDNS
        "208.67.222.220", // OpenDNS
        "208.67.222.222", // OpenDNS
        "210.2.4.8",
        "223.5.5.5",      // 国内 Alibaba DNS
        "223.6.6.6",      // 国内 Alibaba DNS
        "77.88.8.1",
        "77.88.8.8",
        "8.8.4.4",        // Google DNS
        "8.8.8.8",        // Google DNS
        "9.9.9.9"         // Quad9 DNS
    ]

    /// 为所有服务器并发发起探测，返回最先响应的那个。
    ///
    /// 这是"首个响应胜出"的竞速，而不是"收集全部再挑最低延迟"的扫描：只要有
    /// 任一服务器应答，就返回其结果并用 cancelAll() 拆除其余探测。每个探测受
    /// 500ms 任务级超时与查询竞速，外加 socket 上 450ms 的 SO_RCVTIMEO 限制，
    /// 因此不响应的服务器无法拖住整场竞速。没有全局超时——每个探测各自的界限
    /// 是唯一的上限（ranked-latency 变体见 Android）。
    static func findBest() async -> String {
        let fallback = servers.first ?? "8.8.8.8"

        let best: String? = await withTaskGroup(
            of: (String, TimeInterval)?.self,
            returning: String?.self
        ) { group in
            for dns in servers {
                group.addTask { await testServer(dns) }
            }

            // 取第一个非 nil 结果；取消 group 会拆除其余任务。
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
                    throw CancellationError()   // 超时分支
                }

                // 先完成者胜出：查询成功正常返回，超时则抛出。
                try await group.next()!
                group.cancelAll()   // 立即取消落败的任务
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

        // 这里内联了一个固定的 www.baidu.com A 查询包，只校验响应的 transaction ID
        // 是否匹配，并不要求响应里含有 A 记录。切勿改成"必须包含 A 记录"的判据：
        // 那会改变 DNS 污染/审查环境下的 DNS 服务器选择行为，需在对抗性网络条件下
        // 经过构建 + 真机验证才能落地。

        // www.baidu.com 的 DNS 查询包（type A）
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

                // 把 socket 接收超时设为 450ms，避免 Swift 任务被取消时 recv() 无限
                // 阻塞（任务取消无法中断阻塞的系统调用）。
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
