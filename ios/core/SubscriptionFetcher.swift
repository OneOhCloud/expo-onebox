import Foundation
import Network

// MARK: - Result Type

struct SubscriptionFetchResult {
    let statusCode: Int
    let headers: [String: String]
    let body: String
}

// MARK: - Errors

private enum SubscriptionFetcherError: Error, LocalizedError {
    case malformedURL
    case dnsResolutionFailed(String)
    case noARecord
    case malformedDNSResponse
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .malformedURL:               return "Malformed URL"
        case .dnsResolutionFailed(let r): return "DNS resolution failed: \(r)"
        case .noARecord:                  return "No A record in DNS response"
        case .malformedDNSResponse:       return "Malformed DNS response"
        case .invalidResponse:            return "Invalid HTTP response"
        case .timeout:                    return "Request timed out"
        }
    }
}

// MARK: - SubscriptionFetcher

struct SubscriptionFetcher {

    // MARK: - Public API

    /// Fetch a subscription URL using the best DNS server for resolution.
    ///
    /// Resolves the hostname via a raw UDP A-record query, then connects using
    /// Network.framework (NWConnection) which lets us explicitly set the TLS SNI
    /// to the original hostname — even though we dial the resolved IP address.
    /// This ensures the server presents the correct certificate, and the system
    /// TLS stack performs full trust evaluation without any manual overrides.
    static func fetch(url: URL, userAgent: String) async throws -> SubscriptionFetchResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host       = components.host,
              let scheme     = components.scheme else {
            throw SubscriptionFetcherError.malformedURL
        }

        let port = UInt16(components.port ?? (scheme == "https" ? 443 : 80))!

        var requestPath = components.percentEncodedPath
        if requestPath.isEmpty { requestPath = "/" }
        if let q = components.percentEncodedQuery { requestPath += "?" + q }

        // Resolve hostname to IP via the best DNS server.
        // Skip resolution for bare IP addresses.
        let connectTarget: String
        if isIPAddress(host) {
            connectTarget = host
        } else {
            let bestDns = await DnsTester.findBest()
            do {
                connectTarget = try await resolveHostname(host, via: bestDns)
                NSLog("[SubscriptionFetcher] Resolved %@ → %@ via %@", host, connectTarget, bestDns)
            } catch {
                NSLog("[SubscriptionFetcher] DNS failed (%@), falling back to hostname", error.localizedDescription)
                connectTarget = host   // let NWConnection use system DNS
            }
        }

        return try await performRequest(
            host:          host,
            connectTarget: connectTarget,
            port:          port,
            path:          requestPath,
            useTLS:        scheme == "https",
            userAgent:     userAgent
        )
    }

    // MARK: - NWConnection HTTP(S) Request

    /// Makes an HTTP/1.1 request over NWConnection.
    ///
    /// When `useTLS` is true the TLS SNI is explicitly set to `host`, so the
    /// server selects the correct certificate even when `connectTarget` is a bare
    /// IP address.  Full system trust evaluation applies — no manual SecTrust
    /// overrides needed.
    private static func performRequest(
        host:          String,   // original hostname (Host header + TLS SNI)
        connectTarget: String,   // resolved IP or hostname to dial
        port:          UInt16,
        path:          String,
        useTLS:        Bool,
        userAgent:     String
    ) async throws -> SubscriptionFetchResult {

        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters.tls
            // Inject the original hostname as TLS SNI.
            // Without this, dialing an IP sends no SNI and the server may return
            // the wrong certificate, causing trust evaluation to fail.
            if let tlsOpts = parameters.defaultProtocolStack
                    .applicationProtocols.first as? NWProtocolTLS.Options {
                sec_protocol_options_set_tls_server_name(
                    tlsOpts.securityProtocolOptions, host)
            }
        } else {
            parameters = NWParameters.tcp
        }

        let conn = NWConnection(
            host: NWEndpoint.Host(connectTarget),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
        // Serial queue: all NWConnection callbacks, HTTP parsing, and state
        // mutations happen here — no additional locking required inside callbacks.
        let queue = DispatchQueue(label: "com.onebox.sub-fetch", qos: .userInitiated)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SubscriptionFetchResult, Error>) in

            // ── Finish helper ─────────────────────────────────────────────────
            // Called from the serial `queue` (callbacks) or the global timeout.
            // A simple atomic flag + NSLock guards the timeout cross-queue path.
            var finished = false
            let finishLock = NSLock()

            func finish(_ result: Result<SubscriptionFetchResult, Error>) {
                finishLock.lock(); defer { finishLock.unlock() }
                guard !finished else { return }
                finished = true
                conn.cancel()
                switch result {
                case .success(let r): cont.resume(returning: r)
                case .failure(let e): cont.resume(throwing: e)
                }
            }

            // ── HTTP response state (accessed only on `queue`) ────────────────
            var rawData     = Data()
            var headersEnd: Int?              // byte offset past the \r\n\r\n separator
            var statusCode  = 0
            var respHeaders = [String: String]()
            var contentLength: Int? = nil
            var isChunked   = false

            // ── Header parser ─────────────────────────────────────────────────
            func parseHeadersIfNeeded() {
                guard headersEnd == nil else { return }
                let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
                guard let sepRange = rawData.range(of: sep) else { return }

                guard let headerStr = String(data: rawData[rawData.startIndex ..< sepRange.lowerBound],
                                             encoding: .utf8) else {
                    finish(.failure(SubscriptionFetcherError.invalidResponse))
                    return
                }
                var lines = headerStr.components(separatedBy: "\r\n")
                guard !lines.isEmpty else {
                    finish(.failure(SubscriptionFetcherError.invalidResponse))
                    return
                }

                // Status line: "HTTP/1.x 200 Reason"
                let parts = lines.removeFirst().split(separator: " ", maxSplits: 2)
                if parts.count >= 2 { statusCode = Int(parts[1]) ?? 0 }

                // Header fields
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

            // ── Body completion check (Content-Length path) ───────────────────
            func tryCompleteWithContentLength() {
                guard let start = headersEnd, let needed = contentLength else { return }
                let body = rawData.dropFirst(start)
                guard body.count >= needed else { return }
                let text = String(data: body.prefix(needed), encoding: .utf8) ?? ""
                finish(.success(SubscriptionFetchResult(
                    statusCode: statusCode, headers: respHeaders, body: text)))
            }

            // ── Connection-close / chunked completion ─────────────────────────
            func completeOnEOF() {
                guard let start = headersEnd else {
                    finish(.failure(SubscriptionFetcherError.invalidResponse))
                    return
                }
                let bodyData = Data(rawData.dropFirst(start))
                let text: String
                if isChunked {
                    text = String(data: decodeChunked(bodyData), encoding: .utf8) ?? ""
                } else {
                    text = String(data: bodyData, encoding: .utf8) ?? ""
                }
                finish(.success(SubscriptionFetchResult(
                    statusCode: statusCode, headers: respHeaders, body: text)))
            }

            // ── Recursive receive ─────────────────────────────────────────────
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
                        // posix ENOTCONN / cancelled = server closed connection
                        // treat as EOF if we have headers already
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

            // ── Connection state machine ──────────────────────────────────────
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
                case .cancelled:       break   // already handled by finish()
                default:               break
                }
            }

            conn.start(queue: queue)

            // 30-second wall-clock timeout (fires on global queue)
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                finish(.failure(SubscriptionFetcherError.timeout))
            }
        }
    }

    // MARK: - Chunked Transfer Encoding Decoder

    private static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        let crlf   = Data([0x0D, 0x0A])

        while offset < data.count {
            guard let eol = data.range(of: crlf, in: offset ..< data.count) else { break }
            let sizeLine = String(data: data[offset ..< eol.lowerBound], encoding: .utf8) ?? ""
            // Strip chunk extensions (e.g. "1a; ext=foo" → "1a")
            let sizeHex  = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize > 0 else { break }

            let start = eol.upperBound
            let end   = start + chunkSize
            guard end <= data.count else { break }
            result.append(data[start ..< end])
            offset = end + 2   // skip trailing \r\n after chunk data
        }
        return result
    }

    // MARK: - DNS A-Record Resolution

    /// Resolve a hostname to an IPv4 address using the given DNS server IP.
    static func resolveHostname(_ hostname: String, via dnsServer: String) async throws -> String {
        let txID  = UInt16.random(in: 1...0xFFFF)
        let query = buildAQuery(for: hostname, transactionID: txID)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var resumed = false
            let lock = NSLock()

            DispatchQueue.global(qos: .userInitiated).async {
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                guard fd > 0 else {
                    lock.withLock {
                        guard !resumed else { return }; resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("socket() failed"))
                    }
                    return
                }
                defer { close(fd) }

                var tv = timeval(tv_sec: 0, tv_usec: 500_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port   = UInt16(53).bigEndian
                guard inet_pton(AF_INET, dnsServer, &addr.sin_addr) == 1 else {
                    lock.withLock {
                        guard !resumed else { return }; resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("Invalid server: \(dnsServer)"))
                    }
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
                    lock.withLock {
                        guard !resumed else { return }; resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("sendto() failed"))
                    }
                    return
                }

                var buf = [UInt8](repeating: 0, count: 512)
                let n   = recv(fd, &buf, buf.count, 0)

                lock.withLock {
                    guard !resumed else { return }; resumed = true
                    guard n >= 12 else {
                        continuation.resume(throwing: SubscriptionFetcherError.malformedDNSResponse); return
                    }
                    let respID = (UInt16(buf[0]) << 8) | UInt16(buf[1])
                    guard respID == txID else {
                        continuation.resume(throwing: SubscriptionFetcherError.malformedDNSResponse); return
                    }
                    guard (buf[2] & 0x80) != 0, (buf[3] & 0x0F) == 0 else {
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("RCODE=\(buf[3] & 0x0F)")); return
                    }
                    let ancount = Int((UInt16(buf[6]) << 8) | UInt16(buf[7]))
                    guard ancount > 0 else {
                        continuation.resume(throwing: SubscriptionFetcherError.noARecord); return
                    }
                    do {
                        let ip = try parseFirstARecord(from: buf, length: n, ancount: ancount)
                        continuation.resume(returning: ip)
                    } catch {
                        continuation.resume(throwing: error)
                    }
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

    private static func parseFirstARecord(from buf: [UInt8], length: Int, ancount: Int) throws -> String {
        var off = 12
        // Skip question QNAME
        while off < length {
            let b = Int(buf[off])
            if b == 0          { off += 1; break }
            if (b & 0xC0) == 0xC0 { off += 2; break }
            off += 1 + b
        }
        off += 4   // QTYPE + QCLASS

        for _ in 0 ..< ancount {
            guard off < length else { break }
            if (Int(buf[off]) & 0xC0) == 0xC0 { off += 2 }
            else {
                while off < length {
                    let b = Int(buf[off])
                    if b == 0 { off += 1; break }
                    off += 1 + b
                }
            }
            guard off + 10 <= length else { break }
            let rrType   = (UInt16(buf[off]) << 8) | UInt16(buf[off + 1])
            let rdlength = Int((UInt16(buf[off + 8]) << 8) | UInt16(buf[off + 9]))
            off += 10
            if rrType == 0x0001 && rdlength == 4 && off + 4 <= length {
                return "\(buf[off]).\(buf[off+1]).\(buf[off+2]).\(buf[off+3])"
            }
            off += rdlength
        }
        throw SubscriptionFetcherError.noARecord
    }

    // MARK: - Helper

    private static func isIPAddress(_ host: String) -> Bool {
        var a4 = in_addr(); var a6 = in6_addr()
        return inet_pton(AF_INET, host, &a4) == 1 || inet_pton(AF_INET6, host, &a6) == 1
    }
}
