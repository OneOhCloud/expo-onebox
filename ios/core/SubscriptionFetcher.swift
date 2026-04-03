import Foundation
import Security

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

    var errorDescription: String? {
        switch self {
        case .malformedURL: return "Malformed URL"
        case .dnsResolutionFailed(let reason): return "DNS resolution failed: \(reason)"
        case .noARecord: return "No A record found in DNS response"
        case .malformedDNSResponse: return "Malformed DNS response"
        case .invalidResponse: return "Invalid HTTP response"
        }
    }
}

// MARK: - TLS SNI Override Delegate
// When connecting to an IP address, URLSession validates TLS against the IP.
// This delegate re-evaluates the server certificate against the original hostname,
// allowing the connection to succeed for dedicated servers.

private final class SNISessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let originalHostname: String

    init(hostname: String) {
        self.originalHostname = hostname
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Override certificate evaluation to validate against the original hostname (not the IP)
        let policy = SecPolicyCreateSSL(true, originalHostname as CFString)
        SecTrustSetPolicies(serverTrust, [policy] as CFArray)
        SecTrustSetNetworkFetchAllowed(serverTrust, true)

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            NSLog("[SubscriptionFetcher] TLS validation failed for \(originalHostname): \(error?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - SubscriptionFetcher

struct SubscriptionFetcher {

    // MARK: - Public API

    /// Fetch a subscription URL using the best DNS server for resolution.
    /// Resolves the hostname via a custom DNS A-record query, then makes the
    /// HTTP(S) request to the resolved IP with proper Host header and TLS SNI handling.
    /// Falls back to direct fetch if DNS resolution fails.
    static func fetch(url: URL, userAgent: String) async throws -> SubscriptionFetchResult {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let originalHost = components.host else {
            throw SubscriptionFetcherError.malformedURL
        }

        // Skip DNS resolution for IP addresses (already an IP, no hostname to resolve)
        if isIPAddress(originalHost) {
            return try await fetchDirect(url: url, userAgent: userAgent)
        }

        let bestDns = await DnsTester.findBest()
        let resolvedIP: String
        do {
            resolvedIP = try await resolveHostname(originalHost, via: bestDns)
        } catch {
            // DNS resolution failed — fall back to system DNS
            NSLog("[SubscriptionFetcher] DNS resolution failed (\(error.localizedDescription)), falling back to direct fetch")
            return try await fetchDirect(url: url, userAgent: userAgent)
        }

        NSLog("[SubscriptionFetcher] Resolved \(originalHost) → \(resolvedIP) via \(bestDns)")

        // Replace host in URL with resolved IP, preserving scheme/port/path/query
        components.host = resolvedIP
        guard let resolvedURL = components.url else {
            throw SubscriptionFetcherError.malformedURL
        }

        var request = URLRequest(url: resolvedURL)
        request.setValue(originalHost, forHTTPHeaderField: "Host")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        let delegate = SNISessionDelegate(hostname: originalHost)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionFetcherError.invalidResponse
        }

        return SubscriptionFetchResult(
            statusCode: httpResponse.statusCode,
            headers: extractHeaders(httpResponse),
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }

    // MARK: - DNS A-Record Resolution

    /// Resolve a hostname to an IPv4 address using the given DNS server IP.
    static func resolveHostname(_ hostname: String, via dnsServer: String) async throws -> String {
        let txID = UInt16.random(in: 1...0xFFFF)
        let query = buildAQuery(for: hostname, transactionID: txID)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            var resumed = false
            let lock = NSLock()

            DispatchQueue.global(qos: .userInitiated).async {
                let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
                guard socketFD > 0 else {
                    lock.withLock {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("socket() failed"))
                    }
                    return
                }
                defer { close(socketFD) }

                var timeout = timeval(tv_sec: 0, tv_usec: 500_000) // 500 ms
                setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                var serverAddr = sockaddr_in()
                serverAddr.sin_family = sa_family_t(AF_INET)
                serverAddr.sin_port = UInt16(53).bigEndian
                guard inet_pton(AF_INET, dnsServer, &serverAddr.sin_addr) == 1 else {
                    lock.withLock {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("Invalid DNS server: \(dnsServer)"))
                    }
                    return
                }

                let sent = query.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &serverAddr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            sendto(socketFD, bytes.bindMemory(to: UInt8.self).baseAddress,
                                   query.count, 0, sockPtr,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard sent > 0 else {
                    lock.withLock {
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("sendto() failed"))
                    }
                    return
                }

                var buffer = [UInt8](repeating: 0, count: 512)
                let received = recv(socketFD, &buffer, buffer.count, 0)

                lock.withLock {
                    guard !resumed else { return }
                    resumed = true

                    guard received >= 12 else {
                        continuation.resume(throwing: SubscriptionFetcherError.malformedDNSResponse)
                        return
                    }
                    // Verify transaction ID matches
                    let responseID = (UInt16(buffer[0]) << 8) | UInt16(buffer[1])
                    guard responseID == txID else {
                        continuation.resume(throwing: SubscriptionFetcherError.malformedDNSResponse)
                        return
                    }
                    // Check QR bit (response=1) and RCODE (no error=0)
                    guard (buffer[2] & 0x80) != 0, (buffer[3] & 0x0F) == 0 else {
                        let rcode = buffer[3] & 0x0F
                        continuation.resume(throwing: SubscriptionFetcherError.dnsResolutionFailed("RCODE=\(rcode)"))
                        return
                    }
                    // Answer count
                    let ancount = Int((UInt16(buffer[6]) << 8) | UInt16(buffer[7]))
                    guard ancount > 0 else {
                        continuation.resume(throwing: SubscriptionFetcherError.noARecord)
                        return
                    }
                    do {
                        let ip = try parseFirstARecord(from: buffer, length: received, ancount: ancount)
                        continuation.resume(returning: ip)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Private: Fallback Direct Fetch

    private static func fetchDirect(url: URL, userAgent: String) async throws -> SubscriptionFetchResult {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionFetcherError.invalidResponse
        }
        return SubscriptionFetchResult(
            statusCode: httpResponse.statusCode,
            headers: extractHeaders(httpResponse),
            body: String(data: data, encoding: .utf8) ?? ""
        )
    }

    // MARK: - Private: DNS Packet Helpers

    private static func buildAQuery(for hostname: String, transactionID: UInt16) -> Data {
        var data = Data()
        data.append(UInt8(transactionID >> 8))
        data.append(UInt8(transactionID & 0xFF))
        data.append(contentsOf: [0x01, 0x00]) // Flags: RD=1
        data.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
        data.append(contentsOf: [0x00, 0x00]) // ANCOUNT = 0
        data.append(contentsOf: [0x00, 0x00]) // NSCOUNT = 0
        data.append(contentsOf: [0x00, 0x00]) // ARCOUNT = 0
        // QNAME: encode hostname as DNS labels
        for label in hostname.split(separator: ".") {
            let bytes = [UInt8](label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0x00)                      // null terminator
        data.append(contentsOf: [0x00, 0x01]) // QTYPE = A
        data.append(contentsOf: [0x00, 0x01]) // QCLASS = IN
        return data
    }

    /// Parse DNS response and return the first IPv4 address from an A record answer.
    private static func parseFirstARecord(from buffer: [UInt8], length: Int, ancount: Int) throws -> String {
        var offset = 12
        // Skip question section QNAME (variable-length label sequence)
        while offset < length {
            let b = Int(buffer[offset])
            if b == 0 { offset += 1; break }
            if (b & 0xC0) == 0xC0 { offset += 2; break } // compression pointer
            offset += 1 + b
        }
        offset += 4 // skip QTYPE (2) + QCLASS (2)

        // Parse each answer record looking for TYPE=A
        for _ in 0..<ancount {
            guard offset < length else { break }
            // Skip NAME field (pointer or labels)
            if (Int(buffer[offset]) & 0xC0) == 0xC0 {
                offset += 2
            } else {
                while offset < length {
                    let b = Int(buffer[offset])
                    if b == 0 { offset += 1; break }
                    offset += 1 + b
                }
            }
            guard offset + 10 <= length else { break }
            let rrType = (UInt16(buffer[offset]) << 8) | UInt16(buffer[offset + 1])
            let rdlength = Int((UInt16(buffer[offset + 8]) << 8) | UInt16(buffer[offset + 9]))
            offset += 10 // skip TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2)

            if rrType == 0x0001 && rdlength == 4 && offset + 4 <= length {
                // TYPE=A, RDLENGTH=4: rdata is a 4-byte IPv4 address
                let ip = "\(buffer[offset]).\(buffer[offset+1]).\(buffer[offset+2]).\(buffer[offset+3])"
                return ip
            }
            offset += rdlength
        }
        throw SubscriptionFetcherError.noARecord
    }

    // MARK: - Private: Helpers

    private static func extractHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k.lowercased()] = v
            }
        }
        return headers
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var addr = in_addr()
        var addr6 = in6_addr()
        return inet_pton(AF_INET, host, &addr) == 1 || inet_pton(AF_INET6, host, &addr6) == 1
    }
}
