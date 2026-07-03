import CryptoKit
import Foundation
import BackgroundTasks

// MARK: - Config Refresh Result

struct ConfigRefreshResult: Codable {
    var status: String           // "success" | "failed" | "skipped"
    var content: String? = nil
    var profileUpload: Int64 = 0
    var profileDownload: Int64 = 0
    var profileTotal: Int64 = 0
    var profileExpire: Int64 = 0
    var error: String? = nil
    var timestamp: String
    var durationMs: Int64
    var profileUserinfoHeader: String? = nil
    var method: String? = nil    // "primary" | "fallback"
    var actualUrl: String? = nil // accelerated URL when fallback is used

    /// Failure envelope with the traffic quad zero-filled.
    static func failed(
        error: String,
        method: String,
        timestamp: String,
        durationMs: Int64,
        actualUrl: String? = nil
    ) -> ConfigRefreshResult {
        ConfigRefreshResult(
            status: "failed",
            error: error,
            timestamp: timestamp,
            durationMs: durationMs,
            method: method,
            actualUrl: actualUrl
        )
    }

    /// Skipped envelope (no URL configured) — never ran, so duration is zero.
    static func skipped(error: String, timestamp: String) -> ConfigRefreshResult {
        ConfigRefreshResult(
            status: "skipped",
            error: error,
            timestamp: timestamp,
            durationMs: 0,
            method: "primary"
        )
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status,
            "profileUpload": profileUpload,
            "profileDownload": profileDownload,
            "profileTotal": profileTotal,
            "profileExpire": profileExpire,
            "timestamp": timestamp,
            "durationMs": durationMs,
        ]
        if let content { dict["content"] = content }
        if let error { dict["error"] = error }
        if let profileUserinfoHeader { dict["profileUserinfoHeader"] = profileUserinfoHeader }
        if let method { dict["method"] = method }
        if let actualUrl { dict["actualUrl"] = actualUrl }
        return dict
    }
}

/// Atomic on-disk shape for the JS-pushed domain allowlist (see D4-16).
private struct DomainVerificationCache: Codable {
    let known: [String]
    let verified: [String]
    let updatedAt: Double
}

// MARK: - Typed errors

/// Typed replacement for the untyped `NSError(domain:"ExpoOneBox", code:-1)`
/// idiom. `errorDescription` reproduces the exact strings the prior NSError
/// carried, so JS-side messages are unchanged.
enum ExpoOneBoxError: LocalizedError {
    case malformedURL(String)
    case testModePrimaryUnavailable
    case primaryFailed(String)
    case bothFailed(primary: String, accelerated: String)

    var errorDescription: String? {
        switch self {
        case .malformedURL(let url):
            return "Malformed URL: \(url)"
        case .testModePrimaryUnavailable:
            return "TEST MODE: primary URL unavailable"
        case .primaryFailed(let message):
            return message
        case .bothFailed(let primary, let accelerated):
            return "primary=\(primary) accelerated=\(accelerated)"
        }
    }
}

// MARK: - BackgroundConfigRefresh

struct BackgroundConfigRefresh {

    static let taskIdentifier = "cloud.oneoh.networktools.config-refresh"

    // AppGroup UserDefaults — shared between app and extension processes
    private static let appGroupID = "group.cloud.oneoh.networktools"
    private static let sharedDefaults = UserDefaults(suiteName: appGroupID)
    private static let kConfigUrl       = "bg_config_url"
    private static let kUserAgent       = "bg_user_agent"
    private static let kIntervalSeconds = "bg_interval_seconds"
    private static let kLastResultJSON  = "bg_last_result_json"
    private static let kIsRegistered    = "bg_task_registered"
    // Domain-verification cache pushed by JS (src/utils/domain-verification.ts)
    // so the bg worker does not re-fetch sing-box.net on every wake. Stored as a
    // single JSON blob so the three fields are written/read atomically (a
    // torn multi-key write could pair a fresh timestamp with a stale list).
    private static let kDomainVerificationCacheJSON = "bg_domain_verification_cache_json"
    // Refresh options mirrored from JS via `setBackgroundConfigRefreshOptions`.
    // Never read the JS-owned SQLite database here: a second SQLite library on
    // the same WAL file breaks in-process POSIX locking and crashes with SIGBUS.
    private static let kAccelerateUrl             = "bg_accelerate_url"
    private static let kTestPrimaryUrlUnavailable = "bg_test_primary_unavailable"
    /// Shared cache is honoured for 24h; after that the worker falls back to
    /// its own network fetch. Mirrors `CACHE_TTL_MS` in `domain-verification.ts`.
    private static let domainVerificationTtlSeconds: Double = 24 * 3600

    private static func summarizeAccelerateUrl(_ value: String?) -> String {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "empty"
        }
        let host = URL(string: raw)?.host
        if let host, !host.isEmpty {
            return "set(host=\(host),len=\(raw.count))"
        }
        return "set(unparseable,len=\(raw.count))"
    }

    private static func isTestPrimaryUrlUnavailableEnabled() -> Bool {
        return sharedDefaults?.bool(forKey: kTestPrimaryUrlUnavailable) ?? false
    }

    private static func readAccelerateUrl() -> String? {
        guard let value = sharedDefaults?
                .string(forKey: kAccelerateUrl)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Called from JS (`setBackgroundConfigRefreshOptions`) at app init and
    /// whenever the dev toggle flips. Full overwrite of both values, idempotent.
    static func saveRefreshOptions(accelerateUrl: String, testPrimaryUrlUnavailable: Bool) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(accelerateUrl, forKey: kAccelerateUrl)
        defaults.set(testPrimaryUrlUnavailable, forKey: kTestPrimaryUrlUnavailable)
    }

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
                let defaults     = sharedDefaults
                let url          = defaults?.string(forKey: kConfigUrl) ?? ""
                let ua           = defaults?.string(forKey: kUserAgent) ?? ""
                let result       = await executeRefreshWith(url: url, userAgent: ua)
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
        let defaults = sharedDefaults
        let interval = defaults?.double(forKey: kIntervalSeconds) ?? 1800
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog("[BackgroundConfigRefresh] Next refresh scheduled in \(Int(interval))s")
        } catch {
            // Submit failed → the continuation chain is broken. Clear the intent
            // flag so isRegistered() reflects reality instead of staying true
            // until the next cold start. (Follow-up: isRegistered() should query
            // BGTaskScheduler.getPendingTaskRequests for the authoritative state.)
            defaults?.set(false, forKey: kIsRegistered)
            NSLog("[BackgroundConfigRefresh] Failed to schedule: \(error.localizedDescription)")
        }
    }

    // MARK: - Persist configuration for native worker

    static func saveConfig(url: String, userAgent: String, intervalSeconds: Int) {
        guard let defaults = sharedDefaults else { return }
        defaults.set(url, forKey: kConfigUrl)
        defaults.set(userAgent, forKey: kUserAgent)
        defaults.set(intervalSeconds, forKey: kIntervalSeconds)
        defaults.set(true, forKey: kIsRegistered)
    }

    /// Called from JS (`ExpoOneBoxModule.setVerificationData`) after every
    /// successful `updateVerificationData` so the bg worker reuses the same
    /// allowlist instead of making its own HTTP fetch. Stores an
    /// updated-at timestamp for TTL comparison in `verifyDomain`.
    static func saveDomainVerificationCache(known: [String], verified: [String]) {
        guard let defaults = sharedDefaults else { return }
        let cache = DomainVerificationCache(
            known: known,
            verified: verified,
            updatedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(cache),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: kDomainVerificationCacheJSON)
    }

    /// Load the JS-pushed allowlist if it exists and has not expired. A nil
    /// return means the caller should fall back to its built-in list + live
    /// fetch; a non-nil tuple is authoritative.
    private static func loadFreshDomainVerificationCache() -> (known: [String], verified: [String])? {
        guard let defaults = sharedDefaults,
              let json = defaults.string(forKey: kDomainVerificationCacheJSON),
              let data = json.data(using: .utf8),
              let cache = try? JSONDecoder().decode(DomainVerificationCache.self, from: data) else {
            return nil
        }
        guard cache.updatedAt > 0,
              Date().timeIntervalSince1970 - cache.updatedAt < domainVerificationTtlSeconds else {
            return nil
        }
        if cache.known.isEmpty && cache.verified.isEmpty { return nil }
        return (cache.known, cache.verified)
    }

    // MARK: - Execute refresh (usable from both background task and foreground JS call)

    /// Reads the JS-pushed test/accelerate switches and logs their state before a
    /// fetch attempt. `context` identifies the calling path in the log line.
    /// Shared by `fetchProfileConfigWithFallback` and `executeRefreshWith`.
    private static func readRefreshSwitches(
        context: String
    ) -> (testPrimaryUnavailable: Bool, accelerateUrl: String?) {
        let testPrimaryUnavailable = isTestPrimaryUrlUnavailableEnabled()
        let accelerateUrl = readAccelerateUrl()
        NSLog(
            "[CONFIG_LOAD] 请求前开关状态(%@): testPrimaryUnavailable=%@, accelerate=%@",
            context,
            testPrimaryUnavailable ? "true" : "false",
            summarizeAccelerateUrl(accelerateUrl)
        )
        return (testPrimaryUnavailable, accelerateUrl)
    }

    /// Native fetchProfileConfig path with optional accelerator fallback.
    ///
    /// Rules:
    ///   1. Try primary URL first.
    ///   2. Only network-level failures trigger fallback (HTTP non-2xx does not).
    ///   3. Fallback requires verified domain + a JS-pushed accelerate URL.
    ///
    /// When the JS-pushed `testPrimaryUrlUnavailable` option is on, primary
    /// actively throws to simulate real network failure for fallback testing.
    ///
    /// Cancellation never triggers accelerator fallback.
    static func fetchProfileConfigWithFallback(
        url: String,
        userAgent: String
    ) async throws -> ConfigFetchResult {
        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            throw ExpoOneBoxError.malformedURL(url)
        }

        let hostname = parsedURL.host ?? ""
        let domainSha = sha256HexString(hostname)
        let verified = await verifyDomain(hostname: hostname)
        if !verified {
            NSLog("[CONFIG_LOAD] 方式=DOMAIN_UNVERIFIED, 域名SHA256=%@, 加速备用已禁用", domainSha)
        }
        let (testPrimaryUnavailable, accelerateUrl) = readRefreshSwitches(context: "fetchProfileConfig")

        var primaryError = ""
        do {
            if testPrimaryUnavailable {
                NSLog("[CONFIG_LOAD] 测试模式=PRIMARY_UNAVAILABLE, 主地址主动抛出异常")
                throw ExpoOneBoxError.testModePrimaryUnavailable
            }

            // HTTP errors do not trigger fallback — the primary response is returned as-is.
            return try await ConfigFetcher.fetch(url: parsedURL, userAgent: userAgent)
        } catch {
            primaryError = error.localizedDescription
        }

        if Task.isCancelled {
            NSLog("[CONFIG_LOAD] 方式=CANCELLED, 不触发回落")
            throw CancellationError()
        }

        if !verified {
            throw ExpoOneBoxError.primaryFailed(primaryError)
        }

        guard let accBase = accelerateUrl,
              let accURL  = buildAcceleratedURL(from: parsedURL, accelerateBase: accBase) else {
            throw ExpoOneBoxError.primaryFailed(primaryError)
        }

        // NOTE: iOS emits FALLBACK_ACCELERATOR here — i.e. when the accelerated
        // fetch is *about to be attempted* — whereas Android emits the same token
        // only after the fallback *succeeds* (see config-fetch-policy.md token
        // table). Aligning the emit timing (or documenting it per-token in that
        // doc) is a coordinator follow-up; the token value is left unchanged.
        NSLog("[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 原因=%@, 加速URL=%@", primaryError, summarizeAccelerateUrl(accURL.absoluteString))
        do {
            return try await ConfigFetcher.fetch(url: accURL, userAgent: userAgent)
        } catch {
            throw ExpoOneBoxError.bothFailed(primary: primaryError, accelerated: error.localizedDescription)
        }
    }

    /// Primary → accelerated fallback.
    /// HTTP errors (non-2xx) do NOT trigger fallback — only network-level failures do.
    /// When the JS-pushed `testPrimaryUrlUnavailable` option is on, primary
    /// request actively throws to test fallback behaviour.
    ///
    /// Cancellation (BGTask expiration) never triggers accelerator fallback —
    /// it surfaces as a failed result with error=CANCELLED.
    static func executeRefreshWith(url: String, userAgent: String) async -> ConfigRefreshResult {
        let start    = Date()
        let isoStart = ISO8601DateFormatter().string(from: start)

        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            return .skipped(error: "No URL configured", timestamp: isoStart)
        }

        // ── Domain verification ───────────────────────────────────────────────
        let hostname    = parsedURL.host ?? ""
        let domainSha   = sha256HexString(hostname)
        let verified    = await verifyDomain(hostname: hostname)
        if !verified {
            NSLog("[CONFIG_LOAD] 方式=DOMAIN_UNVERIFIED, 域名SHA256=%@, 加速备用已禁用", domainSha)
        }
        let (testPrimaryUnavailable, accelerateUrl) = readRefreshSwitches(context: "executeRefresh")

        // ── Try primary URL ───────────────────────────────────────────────────
        var primaryError = ""

        do {
            if testPrimaryUnavailable {
                NSLog("[CONFIG_LOAD] 测试模式=PRIMARY_UNAVAILABLE, 主地址主动抛出异常")
                throw ExpoOneBoxError.testModePrimaryUnavailable
            }

            let result = try await ConfigFetcher.fetch(url: parsedURL, userAgent: userAgent)
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

            guard result.statusCode >= 200 && result.statusCode < 300 else {
                // HTTP error — do not fall back
                return .failed(
                    error: "HTTP \(result.statusCode)",
                    method: "primary",
                    timestamp: isoStart,
                    durationMs: durationMs
                )
            }

            NSLog("[CONFIG_LOAD] 方式=PRIMARY")
            let headerValue = result.headers["subscription-userinfo"]
            let info = parseUserinfo(headerValue)
            return ConfigRefreshResult(
                status: "success",
                content: result.body,
                profileUpload: info.upload,
                profileDownload: info.download,
                profileTotal: info.total,
                profileExpire: info.expire,
                timestamp: isoStart,
                durationMs: durationMs,
                profileUserinfoHeader: headerValue,
                method: "primary"
            )
        } catch {
            // Network-level failure — try accelerated URL only for verified domains
            primaryError = error.localizedDescription
        }

        if Task.isCancelled {
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            NSLog("[CONFIG_LOAD] 方式=CANCELLED, 不触发回落")
            return .failed(
                error: "CANCELLED",
                method: "primary",
                timestamp: isoStart,
                durationMs: durationMs
            )
        }

        // ── Fallback to accelerated URL ───────────────────────────────────────
        if !verified {
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            NSLog("[CONFIG_LOAD] 方式=ACCELERATOR_SKIPPED, 原因=域名未验证, 主地址原因=%@", primaryError)
            return .failed(
                error: primaryError,
                method: "primary",
                timestamp: isoStart,
                durationMs: durationMs
            )
        }

        guard let accBase = accelerateUrl,
              let accURL  = buildAcceleratedURL(from: parsedURL, accelerateBase: accBase) else {
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            NSLog("[CONFIG_LOAD] 方式=ACCELERATOR_UNAVAILABLE, 原因=未配置或构建失败")
            return .failed(
                error: primaryError,
                method: "primary",
                timestamp: isoStart,
                durationMs: durationMs
            )
        }

        // NOTE: iOS emits FALLBACK_ACCELERATOR here — when the accelerated fetch
        // is *about to be attempted* — whereas Android emits the same token only
        // after the fallback *succeeds* (see config-fetch-policy.md token table).
        // Aligning the emit timing (or documenting it per-token) is a coordinator
        // follow-up; the token value is left unchanged.
        NSLog("[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 原因=%@, 加速URL=%@", primaryError, summarizeAccelerateUrl(accURL.absoluteString))

        // ── Try accelerated URL ───────────────────────────────────────────
        do {
            let accResult  = try await ConfigFetcher.fetch(url: accURL, userAgent: userAgent)
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

            guard accResult.statusCode >= 200 && accResult.statusCode < 300 else {
                NSLog("[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址原因=%@, 加速地址原因=HTTP %d", primaryError, accResult.statusCode)
                return .failed(
                    error: "primary=\(primaryError) accelerated=HTTP \(accResult.statusCode)",
                    method: "fallback",
                    timestamp: isoStart,
                    durationMs: durationMs,
                    actualUrl: accURL.absoluteString
                )
            }

            let headerValue = accResult.headers["subscription-userinfo"]
            let info = parseUserinfo(headerValue)
            NSLog("[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 上传=%lld, 下载=%lld, 总计=%lld, 过期=%lld", info.upload, info.download, info.total, info.expire)
            return ConfigRefreshResult(
                status: "success",
                content: accResult.body,
                profileUpload: info.upload,
                profileDownload: info.download,
                profileTotal: info.total,
                profileExpire: info.expire,
                timestamp: isoStart,
                durationMs: durationMs,
                profileUserinfoHeader: headerValue,
                method: "fallback",
                actualUrl: accURL.absoluteString
            )
        } catch {
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
            let accError   = error.localizedDescription
            NSLog("[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址原因=%@, 加速地址原因=%@", primaryError, accError)
            return .failed(
                error: "primary=\(primaryError) accelerated=\(accError)",
                method: "fallback",
                timestamp: isoStart,
                durationMs: durationMs,
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
    // hostnameSuffixCandidates now lives in the shared pure core
    // core/DomainSuffix.swift (audit D3c-02), locked by golden/domain-suffix.json.

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
        let hashed     = candidates.map { sha256HexString($0) }
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

    // MARK: - Accelerated URL helper

    /// Build the accelerated variant: <accelerateBase>/<sha256(host)><path+query>
    private static func buildAcceleratedURL(from original: URL, accelerateBase: String) -> URL? {
        guard let host = original.host else { return nil }
        let hashHex     = sha256HexString(host)
        let path        = original.path.isEmpty ? "/" : original.path
        let queryPart   = original.query.map { "?" + $0 } ?? ""
        return URL(string: "\(accelerateBase)/\(hashHex)\(path)\(queryPart)")
    }

    // MARK: - Persistent result storage

    static func storeResult(_ result: ConfigRefreshResult) {
        guard let defaults = sharedDefaults,
              let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: kLastResultJSON)
    }

    static func loadLastResult() -> [String: Any]? {
        guard let defaults = sharedDefaults,
              let json = defaults.string(forKey: kLastResultJSON),
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(ConfigRefreshResult.self, from: data)
        else { return nil }
        return result.toDictionary()
    }

    static func clearLastResult() {
        sharedDefaults?.removeObject(forKey: kLastResultJSON)
    }

    static func isRegistered() -> Bool {
        return sharedDefaults?.bool(forKey: kIsRegistered) ?? false
    }

    // The `subscription-userinfo` header parser now lives in the shared pure
    // core core/UserinfoParser.swift (audit C6 / Batch 3), locked by
    // golden/userinfo.json across JS, Kotlin and Swift.
}
