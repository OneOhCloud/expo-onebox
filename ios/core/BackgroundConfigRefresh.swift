import CryptoKit
import Foundation
import BackgroundTasks

// MARK: - Config Refresh Result

struct ConfigRefreshResult: Codable {
    var status: String           // "success" | "failed" | "skipped"
    var content: String?
    var subscriptionUpload: Int64
    var subscriptionDownload: Int64
    var subscriptionTotal: Int64
    var subscriptionExpire: Int64
    var error: String?
    var timestamp: String
    var durationMs: Int64
    var subscriptionUserinfoHeader: String?
    var method: String?          // "primary" | "fallback"
    var actualUrl: String?       // accelerated URL when fallback is used

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "subscriptionUpload": subscriptionUpload,
            "subscriptionDownload": subscriptionDownload,
            "subscriptionTotal": subscriptionTotal,
            "subscriptionExpire": subscriptionExpire,
            "timestamp": timestamp,
            "durationMs": durationMs,
        ]
        if let content { dict["content"] = content }
        if let error { dict["error"] = error }
        if let subscriptionUserinfoHeader { dict["subscriptionUserinfoHeader"] = subscriptionUserinfoHeader }
        if let method { dict["method"] = method }
        if let actualUrl { dict["actualUrl"] = actualUrl }
        return dict
    }
}

// MARK: - BackgroundConfigRefresh

struct BackgroundConfigRefresh {

    static let taskIdentifier = "cloud.oneoh.networktools.config-refresh"

    // AppGroup UserDefaults — shared between app and extension processes
    private static let appGroupID = "group.cloud.oneoh.networktools"
    private static let kConfigUrl       = "bg_config_url"
    private static let kUserAgent       = "bg_user_agent"
    private static let kIntervalSeconds = "bg_interval_seconds"
    private static let kAccelerateUrl   = "bg_accelerate_url"
    private static let kLastResultJSON  = "bg_last_result_json"
    private static let kIsRegistered    = "bg_task_registered"
    // Domain-verification cache pushed by JS (src/utils/domain-verification.ts)
    // so the bg worker does not re-fetch sing-box.net on every wake.
    private static let kKnownDomainSha256List    = "bg_known_domain_sha256_list"
    private static let kVerifiedDomainSha256List = "bg_verified_domain_sha256_list"
    private static let kDomainVerificationUpdatedAt = "bg_domain_verification_updated_at"
    /// Shared cache is honoured for 24h; after that the worker falls back to
    /// its own network fetch. Mirrors `CACHE_TTL_MS` in `domain-verification.ts`.
    private static let domainVerificationTtlSeconds: Double = 24 * 3600

    // MARK: - Registration (must be called at app launch, before didFinishLaunching returns)

    static func registerHandler() {
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let handle = Task {
                let defaults     = UserDefaults(suiteName: appGroupID)
                let url          = defaults?.string(forKey: kConfigUrl) ?? ""
                let ua           = defaults?.string(forKey: kUserAgent) ?? ""
                let accelerateUrl = defaults?.string(forKey: kAccelerateUrl)
                let result       = await executeRefreshWith(url: url, accelerateUrl: accelerateUrl, userAgent: ua)
                storeResult(result)
                scheduleNextRefresh()
                refreshTask.setTaskCompleted(success: result.status == "success")
            }
            refreshTask.expirationHandler = {
                handle.cancel()
            }
        }
        if registered {
            NSLog("[BackgroundConfigRefresh] BGTask handler registered")
        } else {
            NSLog("[BackgroundConfigRefresh] WARN: BGTask handler registration failed (normal in simulator)")
        }
    }

    // MARK: - Schedule

    static func scheduleNextRefresh() {
        let defaults = UserDefaults(suiteName: appGroupID)
        let interval = defaults?.double(forKey: kIntervalSeconds) ?? 1800
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BackgroundConfigRefresh] Next refresh scheduled in \(Int(interval))s")
        } catch {
            NSLog("[BackgroundConfigRefresh] Failed to schedule: \(error.localizedDescription)")
        }
    }

    static func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        UserDefaults(suiteName: appGroupID)?.set(false, forKey: kIsRegistered)
        NSLog("[BackgroundConfigRefresh] Scheduled task cancelled")
    }

    // MARK: - Persist configuration for native worker

    static func saveConfig(url: String, userAgent: String, intervalSeconds: Int, accelerateUrl: String?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(url, forKey: kConfigUrl)
        defaults.set(userAgent, forKey: kUserAgent)
        defaults.set(intervalSeconds, forKey: kIntervalSeconds)
        defaults.set(true, forKey: kIsRegistered)
        if let acc = accelerateUrl, !acc.isEmpty {
            defaults.set(acc, forKey: kAccelerateUrl)
        } else {
            defaults.removeObject(forKey: kAccelerateUrl)
        }
    }

    /// Called from JS (`ExpoOneBoxModule.setVerificationData`) after every
    /// successful `updateVerificationData` so the bg worker reuses the same
    /// allowlist instead of making its own HTTP fetch. Stores an
    /// updated-at timestamp for TTL comparison in `verifyDomain`.
    static func saveDomainVerificationCache(known: [String], verified: [String]) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(known,    forKey: kKnownDomainSha256List)
        defaults.set(verified, forKey: kVerifiedDomainSha256List)
        defaults.set(Date().timeIntervalSince1970, forKey: kDomainVerificationUpdatedAt)
    }

    /// Load the JS-pushed allowlist if it exists and has not expired. A nil
    /// return means the caller should fall back to its built-in list + live
    /// fetch; a non-nil tuple is authoritative.
    private static func loadFreshDomainVerificationCache() -> (known: [String], verified: [String])? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        let updatedAt = defaults.double(forKey: kDomainVerificationUpdatedAt)
        guard updatedAt > 0,
              Date().timeIntervalSince1970 - updatedAt < domainVerificationTtlSeconds else {
            return nil
        }
        let known    = defaults.stringArray(forKey: kKnownDomainSha256List)    ?? []
        let verified = defaults.stringArray(forKey: kVerifiedDomainSha256List) ?? []
        if known.isEmpty && verified.isEmpty { return nil }
        return (known, verified)
    }

    // MARK: - Execute refresh (usable from both background task and foreground JS call)

    /// Primary → accelerated fallback.
    /// HTTP errors (non-2xx) do NOT trigger fallback — only network-level failures do.
    /// testPrimaryUrlUnavailable: if true, skip primary URL and use accelerator directly (for testing)
    static func executeRefreshWith(url: String, accelerateUrl: String?, userAgent: String, testPrimaryUrlUnavailable: Bool = false) async -> ConfigRefreshResult {
        let start    = Date()
        let isoStart = ISO8601DateFormatter().string(from: start)

        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            return ConfigRefreshResult(
                status: "skipped",
                subscriptionUpload: 0, subscriptionDownload: 0,
                subscriptionTotal: 0, subscriptionExpire: 0,
                error: "No URL configured",
                timestamp: isoStart, durationMs: 0,
                method: "primary"
            )
        }

        // ── Domain verification ───────────────────────────────────────────────
        let hostname    = parsedURL.host ?? ""
        let domainSha   = sha256Hex(hostname)
        let verified    = await verifyDomain(hostname: hostname)
        if !verified {
            NSLog("[CONFIG_LOAD] 方式=DOMAIN_UNVERIFIED, 域名SHA256=%@, 加速备用已禁用", domainSha)
        }

        // ── Try primary URL ───────────────────────────────────────────────────
        var primaryError = ""

        if testPrimaryUrlUnavailable {
            // Test mode: simulate primary URL unavailable
            primaryError = "TEST MODE: primary URL unavailable"
            NSLog("[CONFIG_LOAD] 测试模式=PRIMARY_UNAVAILABLE, 跳过主地址直接尝试加速备用")
        } else {
            do {
                let result = try await ConfigFetcher.fetch(url: parsedURL, userAgent: userAgent)
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

                guard result.statusCode >= 200 && result.statusCode < 300 else {
                    // HTTP error — do not fall back
                    return ConfigRefreshResult(
                        status: "failed",
                        subscriptionUpload: 0, subscriptionDownload: 0,
                        subscriptionTotal: 0, subscriptionExpire: 0,
                        error: "HTTP \(result.statusCode)",
                        timestamp: isoStart, durationMs: durationMs,
                        method: "primary"
                    )
                }

                NSLog("[CONFIG_LOAD] 方式=PRIMARY, URL=%@", url)
                let headerValue = result.headers["subscription-userinfo"]
                let info = parseUserinfo(headerValue)
                return ConfigRefreshResult(
                    status: "success",
                    content: result.body,
                    subscriptionUpload: info.upload,
                    subscriptionDownload: info.download,
                    subscriptionTotal: info.total,
                    subscriptionExpire: info.expire,
                    timestamp: isoStart,
                    durationMs: durationMs,
                    subscriptionUserinfoHeader: headerValue,
                    method: "primary"
                )
            } catch {
                // Network-level failure — try accelerated URL only for verified domains
                primaryError = error.localizedDescription
            }
        }

        // ── Fallback to accelerated URL ───────────────────────────────────────
        if !verified {
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
                NSLog("[CONFIG_LOAD] 方式=ACCELERATOR_SKIPPED, 原因=域名未验证, 主地址原因=%@", primaryError)
                return ConfigRefreshResult(
                    status: "failed",
                    subscriptionUpload: 0, subscriptionDownload: 0,
                    subscriptionTotal: 0, subscriptionExpire: 0,
                    error: primaryError,
                    timestamp: isoStart, durationMs: durationMs,
                    method: "primary"
                )
            }

            guard let accBase = accelerateUrl, !accBase.isEmpty,
                  let accURL  = buildAcceleratedURL(from: parsedURL, accelerateBase: accBase) else {
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
                NSLog("[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE, 原因=未配置或构建失败")
                return ConfigRefreshResult(
                    status: "failed",
                    subscriptionUpload: 0, subscriptionDownload: 0,
                    subscriptionTotal: 0, subscriptionExpire: 0,
                    error: primaryError,
                    timestamp: isoStart, durationMs: durationMs,
                    method: "primary"
                )
            }

            NSLog("[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 原因=%@, 加速URL=%@", primaryError, accURL.absoluteString)

            // ── Try accelerated URL ───────────────────────────────────────────
            do {
                let accResult  = try await ConfigFetcher.fetch(url: accURL, userAgent: userAgent)
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

                guard accResult.statusCode >= 200 && accResult.statusCode < 300 else {
                    NSLog("[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址原因=%@, 加速地址原因=HTTP %d", primaryError, accResult.statusCode)
                    return ConfigRefreshResult(
                        status: "failed",
                        subscriptionUpload: 0, subscriptionDownload: 0,
                        subscriptionTotal: 0, subscriptionExpire: 0,
                        error: "primary=\(primaryError) accelerated=HTTP \(accResult.statusCode)",
                        timestamp: isoStart, durationMs: durationMs,
                        method: "fallback",
                        actualUrl: accURL.absoluteString
                    )
                }

                let headerValue = accResult.headers["subscription-userinfo"]
                NSLog("[CONFIG_LOAD] 加速URL响应头 subscription-userinfo: %@", headerValue ?? "nil")
                let info = parseUserinfo(headerValue)
                return ConfigRefreshResult(
                    status: "success",
                    content: accResult.body,
                    subscriptionUpload: info.upload,
                    subscriptionDownload: info.download,
                    subscriptionTotal: info.total,
                    subscriptionExpire: info.expire,
                    timestamp: isoStart,
                    durationMs: durationMs,
                    subscriptionUserinfoHeader: headerValue,
                    method: "fallback",
                    actualUrl: accURL.absoluteString
                )
            } catch {
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
                let accError   = error.localizedDescription
                NSLog("[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址原因=%@, 加速地址原因=%@", primaryError, accError)
                return ConfigRefreshResult(
                    status: "failed",
                    subscriptionUpload: 0, subscriptionDownload: 0,
                    subscriptionTotal: 0, subscriptionExpire: 0,
                    error: "primary=\(primaryError) accelerated=\(accError)",
                    timestamp: isoStart, durationMs: durationMs,
                    method: "fallback",
                    actualUrl: accURL.absoluteString
                )
            }
    }

    // MARK: - Domain verification

    // Compile-time allowlist. Each entry is the SHA256 of an approved suffix
    // label; verifyDomain hashes every progressive suffix of the target
    // hostname (shortest first) and returns true on the first match, so
    // broader entries approve broader subtrees. Never record the pre-image
    // in this file or any comment.
    private static let knownDomainSha256List: [String] = [
        "183a5526e76751b07cd57236bc8f253d5424e02a3fc7da7c30f80919e975125a",
        "59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1",
        "61e245b4e5c234b00865ab0f47ad1cc4a9b37dbc50159febea7e6dcaee8ce050",
    ]
    private static let verifiedListUrl   = "https://www.sing-box.net/verified_subscriptions_sha256.txt"

    /// Progressive suffix candidates, shortest first.
    ///   "a.b.c" -> ["c", "b.c", "a.b.c"]
    private static func hostnameSuffixCandidates(_ hostname: String) -> [String] {
        if hostname.isEmpty { return [] }
        let parts = hostname.split(separator: ".").map(String.init)
        var out: [String] = []
        for i in stride(from: parts.count - 1, through: 0, by: -1) {
            out.append(parts[i..<parts.count].joined(separator: "."))
        }
        return out
    }

    /// Returns true iff any suffix of `hostname` (shortest first) hashes to
    /// an entry in the allowlist. Preference order:
    ///   1. Shared cache pushed by JS (`setVerificationData`) — zero network,
    ///      covers the 24 h since JS last refreshed.
    ///   2. Compile-time `knownDomainSha256List` — always available.
    ///   3. Live fetch from `verifiedListUrl` — only when the shared cache is
    ///      missing or expired; the built-in list does not expire so this
    ///      branch is strictly a recovery path.
    private static func verifyDomain(hostname: String) async -> Bool {
        let candidates = hostnameSuffixCandidates(hostname)
        let hashed     = candidates.map { sha256Hex($0) }
        let hashedSet  = Set(hashed)

        // Source 1 — JS-pushed cache.
        if let cache = loadFreshDomainVerificationCache() {
            let union = Set(cache.known).union(cache.verified)
            if !hashedSet.isDisjoint(with: union) { return true }
            // Cache exists and is fresh but did not match; still try the
            // compile-time list below as a final check before giving up.
            if hashed.contains(where: { knownDomainSha256List.contains($0) }) {
                return true
            }
            return false
        }

        // Source 2 — compile-time fallback.
        if hashed.contains(where: { knownDomainSha256List.contains($0) }) {
            return true
        }

        // Source 3 — network fetch (only reached when JS has never pushed
        // fresh data, e.g. bg task fires before the app has ever opened).
        guard let url = URL(string: verifiedListUrl) else { return false }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, _) = try await URLSession.shared.data(for: request)
            let text   = String(data: data, encoding: .utf8) ?? ""
            let remote = Set(
                text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            return hashed.contains(where: { remote.contains($0) })
        } catch {
            return false
        }
    }

    // MARK: - SHA256 + accelerated URL helpers

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the accelerated variant: <accelerateBase>/<sha256(host)><path+query>
    private static func buildAcceleratedURL(from original: URL, accelerateBase: String) -> URL? {
        guard let host = original.host else { return nil }
        let hashHex     = sha256Hex(host)
        let path        = original.path.isEmpty ? "/" : original.path
        let queryPart   = original.query.map { "?" + $0 } ?? ""
        return URL(string: "\(accelerateBase)/\(hashHex)\(path)\(queryPart)")
    }

    // MARK: - Persistent result storage

    static func storeResult(_ result: ConfigRefreshResult) {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: kLastResultJSON)
    }

    static func loadLastResult() -> [String: Any]? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let json = defaults.string(forKey: kLastResultJSON),
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ConfigRefreshResult.self, from: data)
        else { return nil }
        return result.toDictionary()
    }

    static func clearLastResult() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: kLastResultJSON)
    }

    static func isRegistered() -> Bool {
        return UserDefaults(suiteName: appGroupID)?.bool(forKey: kIsRegistered) ?? false
    }

    // MARK: - subscription-userinfo header parser

    private struct TrafficInfo {
        let upload: Int64
        let download: Int64
        let total: Int64
        let expire: Int64
    }

    private static func parseUserinfo(_ header: String?) -> TrafficInfo {
        func extract(_ key: String, from str: String) -> Int64 {
            guard let range = str.range(of: "\(key)=(\\d+)", options: .regularExpression) else { return 0 }
            let match = String(str[range])
            let value = match.replacingOccurrences(of: "\(key)=", with: "")
            return Int64(value) ?? 0
        }
        let h = header ?? ""
        return TrafficInfo(
            upload:   extract("upload", from: h),
            download: extract("download", from: h),
            total:    extract("total", from: h),
            expire:   extract("expire", from: h)
        )
    }
}
