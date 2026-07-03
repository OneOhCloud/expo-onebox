import Foundation
import Network

// MARK: - Result Type

struct ConfigFetchResult {
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

// MARK: - Errors

private enum ConfigFetcherError: Error, LocalizedError {
    case malformedURL
    case dnsResolutionFailed(String)
    case noARecord
    case malformedDNSResponse
    case invalidResponse
    case timeout
    case tooManyRedirects

    var errorDescription: String? {
        switch self {
        case .malformedURL:               return "Malformed URL"
        case .dnsResolutionFailed(let r): return "DNS resolution failed: \(r)"
        case .noARecord:                  return "No A record in DNS response"
        case .malformedDNSResponse:       return "Malformed DNS response"
        case .invalidResponse:            return "Invalid HTTP response"
        case .timeout:                    return "Request timed out"
        case .tooManyRedirects:           return "Too many redirects"
        }
    }
}

// MARK: - ConfigFetcher

struct ConfigFetcher {

    /// 日志用的短 host 摘要——hostname 属于用户配置文件数据。
    private static func hostHash8(_ host: String) -> String {
        String(sha256HexString(host).prefix(8))
    }

    // MARK: - Public API

    /// 使用最优 DNS 服务器解析并拉取配置 URL。
    ///
    /// 通过原始 UDP A 记录查询解析 hostname，然后用 Network.framework
    ///（NWConnection）连接——即便我们拨号的是解析出的 IP 地址，也能显式把
    /// TLS SNI 设为原始 hostname。这样服务器会出示正确证书，系统 TLS 栈完成
    /// 完整的信任评估，无需任何手动覆盖。
    static func fetch(url: URL, userAgent: String) async throws -> ConfigFetchResult {
        var currentURL = url
        let maxRedirects = 5

        for _ in 0...maxRedirects {
            guard let components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false),
                  let host       = components.host,
                  let scheme     = components.scheme else {
                throw ConfigFetcherError.malformedURL
            }

            guard let port = UInt16(exactly: components.port ?? (scheme == "https" ? 443 : 80)) else {
                throw ConfigFetcherError.malformedURL
            }

            var requestPath = components.percentEncodedPath
            if requestPath.isEmpty { requestPath = "/" }
            if let q = components.percentEncodedQuery { requestPath += "?" + q }

            // 通过最优 DNS 服务器把 hostname 解析为 IP。
            // 裸 IP 地址跳过解析。
            let connectTarget: String
            if isIPAddress(host) {
                connectTarget = host
            } else {
                let bestDns = await DnsTester.findBest()
                do {
                    connectTarget = try await resolveHostname(host, via: bestDns)
                    NSLog("[ConfigFetcher] Resolved host(sha8=%@) → %@ via %@", hostHash8(host), connectTarget, bestDns)
                } catch {
                    NSLog("[ConfigFetcher] DNS failed (%@), falling back to hostname", error.localizedDescription)
                    connectTarget = host   // 让 NWConnection 使用系统 DNS
                }
            }

            let result = try await performRequest(RequestSpec(
                host:          host,
                connectTarget: connectTarget,
                port:          port,
                path:          requestPath,
                useTLS:        scheme == "https",
                userAgent:     userAgent
            ))

            // 跟随标准 3xx 重定向（301、302、303、307、308）。
            // 配置 URL 经常重定向，若默默返回重定向响应，会让调用方拿到空 body。
            if (301...308).contains(result.statusCode),
               let location = result.headers["location"],
               let redirectURL = URL(string: location, relativeTo: currentURL)?.absoluteURL {
                NSLog("[ConfigFetcher] Redirect %d → host(sha8=%@)", result.statusCode, hostHash8(redirectURL.host ?? ""))
                currentURL = redirectURL
                continue
            }

            return result
        }

        throw ConfigFetcherError.tooManyRedirects
    }

    // MARK: - NWConnection HTTP(S) Request

    /// 单次 NWConnection HTTP(S) 请求的参数。
    private struct RequestSpec {
        let host:          String   // 原始 hostname（Host 头 + TLS SNI）
        let connectTarget: String   // 拨号用的解析 IP 或 hostname
        let port:          UInt16
        let path:          String
        let useTLS:        Bool
        let userAgent:     String
    }

    /// 构建 NWParameters，在 HTTPS 请求时注入 TLS SNI。
    ///
    /// 显式创建 TLS options 以确保 SNI 一定被注入。NWParameters.tls 是工厂属性
    ///（每次访问都是新实例），且在某些 iOS 版本上把 applicationProtocols.first
    /// 强转为 NWProtocolTLS.Options 会静默失败——导致 SNI 未设置，当 connectTarget
    /// 是裸 IP 地址时引发证书信任失败。
    private static func makeParameters(useTLS: Bool, sni host: String) -> NWParameters {
        guard useTLS else { return NWParameters.tcp }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(
            tlsOptions.securityProtocolOptions, host)
        return NWParameters(tls: tlsOptions)
    }

    /// 通过 NWConnection 发起一次 HTTP/1.1 请求。
    ///
    /// HTTPS 请求时，TLS SNI 被显式设为 host，因此即便 connectTarget 是裸 IP
    /// 地址，服务器也会选对证书。系统会做完整的信任评估——无需手动覆盖 SecTrust。
    private static func performRequest(_ spec: RequestSpec) async throws -> ConfigFetchResult {
        let host          = spec.host
        let connectTarget = spec.connectTarget
        let port          = spec.port
        let path          = spec.path
        let userAgent     = spec.userAgent

        let parameters = makeParameters(useTLS: spec.useTLS, sni: host)

        let conn = NWConnection(
            host: NWEndpoint.Host(connectTarget),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        // 串行队列：所有 NWConnection 回调、HTTP 解析与状态修改都在这里发生——
        // 回调内部无需额外加锁。
        let queue = DispatchQueue(label: "com.onebox.sub-fetch", qos: .userInitiated)

        return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ConfigFetchResult, Error>) in

            // ── finish 辅助 ─────────────────────────────────────────────────
            // 从串行 queue（回调）或全局超时调用。一个简单的原子标志 + NSLock
            // 守护超时的跨队列路径。
            var finished = false
            let finishLock = NSLock()

            func finish(_ result: Result<ConfigFetchResult, Error>) {
                finishLock.lock(); defer { finishLock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                switch result {
                case .success(let r): cont.resume(returning: r)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            // ── HTTP 响应状态（只在 queue 上访问）────────────────
            var rawData     = Data()
            var headersEnd: Int?              // \r\n\r\n 分隔符之后的字节偏移
            var statusCode  = 0
            var respHeaders = [String: String]()
            var contentLength: Int? = nil
            var isChunked   = false

            // ── 头部解析器 ─────────────────────────────────────────────────
            func parseHeadersIfNeeded() {
                guard headersEnd == nil else { return }
                let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
                guard let sepRange = rawData.range(of: sep) else { return }

                guard let headerStr = String(data: rawData[rawData.startIndex ..< sepRange.lowerBound],
                                             encoding: .utf8) else {
                    finish(.failure(ConfigFetcherError.invalidResponse))
                    return
                }
                var lines = headerStr.components(separatedBy: "\r\n")
                guard !lines.isEmpty else {
                    finish(.failure(ConfigFetcherError.invalidResponse))
                    return
                }

                // 状态行："HTTP/1.x 200 Reason"
                let parts = lines.removeFirst().split(separator: " ", maxSplits: 2)
                if parts.count >= 2 { statusCode = Int(parts[1]) ?? 0 }

                // 头部字段
                for line in lines where !line.isEmpty {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    respHeaders[k] = v
                }

                headersEnd    = rawData.distance(from: rawData.startIndex, to: sepRange.upperBound)
                contentLength = respHeaders["content-length"].flatMap { Int($0) }
                isChunked     = respHeaders["transfer-encoding"]?.lowercased().contains("chunked") ?? false
            }

            // ── body 完成检查（Content-Length 路径）───────────────────
            func tryCompleteWithContentLength() {
                guard let start = headersEnd, let needed = contentLength else { return }
                let body = rawData.dropFirst(start)
                guard body.count >= needed else { return }
                let text = String(data: body.prefix(needed), encoding: .utf8) ?? ""
                finish(.success(ConfigFetchResult(
                    statusCode: statusCode, headers: respHeaders, body: text)))
            }

            // ── 连接关闭 / chunked 完成 ─────────────────────────
            func completeOnEOF() {
                guard let start = headersEnd else {
                    finish(.failure(ConfigFetcherError.invalidResponse))
                    return
                }
                let bodyData = Data(rawData.dropFirst(start))
                let text: String
                if isChunked {
                    text = String(data: decodeChunked(bodyData), encoding: .utf8) ?? ""
                } else {
                    text = String(data: bodyData, encoding: .utf8) ?? ""
                }
                finish(.success(ConfigFetchResult(
                    statusCode: statusCode, headers: respHeaders, body: text)))
            }

            // ── 递归接收 ─────────────────────────────────────────────
            func receiveMore() {
                guard !finished else { return }
                conn.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { chunk, _, isComplete, error in
                    if let chunk, !chunk.isEmpty { rawData.append(chunk) }

                    parseHeadersIfNeeded()
                    tryCompleteWithContentLength()

                    if isComplete {
                        completeOnEOF()
                        return
                    }
                    if let error {
                        // posix ENOTCONN / cancelled = 服务器关闭了连接
                        // 若已拿到头部，按 EOF 处理
                        if headersEnd != nil {
                            completeOnEOF()
                        } else {
                            finish(.failure(error))
                        }
                        return
                    }
                    receiveMore()
                }
            }

            // ── 连接状态机 ──────────────────────────────────────
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET \(path) HTTP/1.1\r\n" +
                              "Host: \(host)\r\n" +
                              "User-Agent: \(userAgent)\r\n" +
                              "Accept: */*\r\n" +
                              "Connection: close\r\n\r\n"
                    conn.send(content: req.data(using: .utf8),
                              completion: .contentProcessed { err in
                        if let err { finish(.failure(err)); return }
                        receiveMore()
                    })
                case .failed(let err): finish(.failure(err))
                // 外部取消（经 onCancel 的 Task 取消）到达这里时 finished == false
                // → 以 CancellationError resume。正常路径自身的 conn.cancel() 也会
                // 到达这里，但发现 finished == true，因此是受保护的空操作
                //（不会重复 resume）。
                case .cancelled:       finish(.failure(CancellationError()))
                default:               break
                }
            }

            conn.start(queue: queue)

            // 30 秒 wall-clock 超时（在全局队列上触发）。
            // finish() 受 NSLock 保护，因此这次跨队列调用是安全的。
            // finish() 内部的 conn.cancel() 会在 queue 上触发一次 .cancelled 状态
            // 回调，但此时 finished == true，故为空操作。
            // queue 上排队的 receiveMore() 闭包也会看到 finished == true 并立即
            // 返回——无重复 resume 风险。
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                finish(.failure(ConfigFetcherError.timeout))
            }
        }
        } onCancel: {
            // BGTask 过期（或任何 Task 取消）会立即中止进行中的 NWConnection，
            // 而不是干等到 30 秒超时。
            conn.cancel()
        }
    }

    // MARK: - Chunked Transfer Encoding Decoder

    // 分块传输解码放在不依赖框架的 HttpChunked 中，以便脱离设备做测试。
    private static func decodeChunked(_ data: Data) -> Data {
        HttpChunked.decode(data)
    }

    // MARK: - DNS A-Record Resolution

    /// 使用给定的 DNS 服务器 IP 把 hostname 解析为 IPv4 地址。
    static func resolveHostname(_ hostname: String, via dnsServer: String) async throws -> String {
        let txID  = UInt16.random(in: 1...0xFFFF)
        let query = buildAQuery(for: hostname, transactionID: txID)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = ResumeOnce(continuation)

            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                guard fd > 0 else {
                    once.resume(throwing: ConfigFetcherError.dnsResolutionFailed("socket() failed"))
                    return
                }
                defer { close(fd) }

                var tv = timeval(tv_sec: 0, tv_usec: 500_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port   = UInt16(53).bigEndian
                guard inet_pton(AF_INET, dnsServer, &addr.sin_addr) == 1 else {
                    once.resume(throwing: ConfigFetcherError.dnsResolutionFailed("Invalid server: \(dnsServer)"))
                    return
                }

                let sent = query.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &addr) { ap in
                        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                            sendto(fd, bytes.bindMemory(to: UInt8.self).baseAddress,
                                   query.count, 0, sp,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent > 0 else {
                    once.resume(throwing: ConfigFetcherError.dnsResolutionFailed("sendto() failed"))
                    return
                }

                var buf = [UInt8](repeating: 0, count: 4096)
                let n   = recv(fd, &buf, buf.count, 0)

                guard n >= 12 else {
                    once.resume(throwing: ConfigFetcherError.malformedDNSResponse); return
                }
                let respID = (UInt16(buf[0]) << 8) | UInt16(buf[1])
                guard respID == txID else {
                    once.resume(throwing: ConfigFetcherError.malformedDNSResponse); return
                }
                guard (buf[2] & 0x80) != 0, (buf[3] & 0x0F) == 0 else {
                    once.resume(throwing: ConfigFetcherError.dnsResolutionFailed("RCODE=\(buf[3] & 0x0F)")); return
                }
                let ancount = Int((UInt16(buf[6]) << 8) | UInt16(buf[7]))
                guard ancount > 0 else {
                    once.resume(throwing: ConfigFetcherError.noARecord); return
                }
                do {
                    let ip = try parseFirstARecord(from: buf, length: n, ancount: ancount)
                    once.resume(returning: ip)
                } catch {
                    once.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - DNS Packet Helpers

    private static func buildAQuery(for hostname: String, transactionID: UInt16) -> Data {
        var d = Data()
        d.append(UInt8(transactionID >> 8))
        d.append(UInt8(transactionID & 0xFF))
        d.append(contentsOf: [0x01, 0x00])   // Flags: RD=1
        d.append(contentsOf: [0x00, 0x01])   // QDCOUNT=1
        d.append(contentsOf: [0x00, 0x00])   // ANCOUNT=0
        d.append(contentsOf: [0x00, 0x00])   // NSCOUNT=0
        d.append(contentsOf: [0x00, 0x00])   // ARCOUNT=0
        for label in hostname.split(separator: ".") {
            let bytes = [UInt8](label.utf8)
            d.append(UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(0x00)
        d.append(contentsOf: [0x00, 0x01])   // QTYPE=A
        d.append(contentsOf: [0x00, 0x01])   // QCLASS=IN
        return d
    }

    // MARK: - Helper

    private static func isIPAddress(_ host: String) -> Bool {
        var a4 = in_addr(); var a6 = in6_addr()
        return inet_pton(AF_INET, host, &a4) == 1 || inet_pton(AF_INET6, host, &a6) == 1
    }
}

// MARK: - Single-shot continuation guard

/// 最多 resume 一次 CheckedContinuation。守护那些本可能导致 continuation
/// 被 resume 两次的跨线程路径（阻塞的 socket 回调、超时）——对 checked
/// continuation 多次 resume 会崩溃。
// 可安全跨线程共享：resumed 与 resume 调用都由 lock 守护，这正是本类型
// 要防止的跨线程重复 resume。
final class ResumeOnce<T>: @unchecked Sendable {
    private let continuation: CheckedContinuation<T, Error>
    private let lock = NSLock()
    private var resumed = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        completeOnce { $0.resume(returning: value) }
    }

    func resume(throwing error: Error) {
        completeOnce { $0.resume(throwing: error) }
    }

    private func completeOnce(_ body: (CheckedContinuation<T, Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body(continuation)
    }
}
