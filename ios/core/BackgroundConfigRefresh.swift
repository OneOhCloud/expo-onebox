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

    // MARK: - Execute refresh (usable from both background task and foreground JS call)

    /// Primary → accelerated fallback.
    /// HTTP errors (non-2xx) do NOT trigger fallback — only network-level failures do.
    static func executeRefreshWith(url: String, accelerateUrl: String?, userAgent: String) async -> ConfigRefreshResult {
        let start    = Date()
        let isoStart = ISO8601DateFormatter().string(from: start)

        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            return ConfigRefreshResult(
                status: "skipped",
                subscriptionUpload: 0, subscriptionDownload: 0,
                subscriptionTotal: 0, subscriptionExpire: 0,
                error: "No URL configured",
                timestamp: isoStart, durationMs: 0
            )
        }

        // ── Domain verification ───────────────────────────────────────────────
        let hostname    = parsedURL.host ?? ""
        let domainSha   = sha256Hex(hostname)
        let verified    = await verifyDomain(sha256: domainSha)
        if !verified {
            NSLog("[CONFIG_LOAD] 方式=DOMAIN_UNVERIFIED, 域名SHA256=%@, 加速备用已禁用", domainSha)
        }

        // ── Try primary URL ───────────────────────────────────────────────────
        do {
            let result = try await SubscriptionFetcher.fetch(url: parsedURL, userAgent: userAgent)
            let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

            guard result.statusCode >= 200 && result.statusCode < 300 else {
                // HTTP error — do not fall back
                return ConfigRefreshResult(
                    status: "failed",
                    subscriptionUpload: 0, subscriptionDownload: 0,
                    subscriptionTotal: 0, subscriptionExpire: 0,
                    error: "HTTP \(result.statusCode)",
                    timestamp: isoStart, durationMs: durationMs
                )
            }

            NSLog("[CONFIG_LOAD] 方式=PRIMARY, URL=%@", url)
            let info = parseSubscriptionUserinfo(result.headers["subscription-userinfo"])
            return ConfigRefreshResult(
                status: "success",
                content: result.body,
                subscriptionUpload: info.upload,
                subscriptionDownload: info.download,
                subscriptionTotal: info.total,
                subscriptionExpire: info.expire,
                timestamp: isoStart,
                durationMs: durationMs
            )
        } catch {
            // Network-level failure — try accelerated URL only for verified domains
            let primaryError = error.localizedDescription

            if !verified {
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)
                NSLog("[CONFIG_LOAD] 方式=ACCELERATOR_SKIPPED, 原因=域名未验证, 主地址原因=%@", primaryError)
                return ConfigRefreshResult(
                    status: "failed",
                    subscriptionUpload: 0, subscriptionDownload: 0,
                    subscriptionTotal: 0, subscriptionExpire: 0,
                    error: primaryError,
                    timestamp: isoStart, durationMs: durationMs
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
                    timestamp: isoStart, durationMs: durationMs
                )
            }

            NSLog("[CONFIG_LOAD] 方式=FALLBACK_ACCELERATOR, 原因=%@, 加速URL=%@", primaryError, accURL.absoluteString)

            // ── Try accelerated URL ───────────────────────────────────────────
            do {
                let accResult  = try await SubscriptionFetcher.fetch(url: accURL, userAgent: userAgent)
                let durationMs = Int64(Date().timeIntervalSince(start) * 1000)

                guard accResult.statusCode >= 200 && accResult.statusCode < 300 else {
                    NSLog("[CONFIG_LOAD] 方式=BOTH_FAILED, 主地址原因=%@, 加速地址原因=HTTP %d", primaryError, accResult.statusCode)
                    return ConfigRefreshResult(
                        status: "failed",
                        subscriptionUpload: 0, subscriptionDownload: 0,
                        subscriptionTotal: 0, subscriptionExpire: 0,
                        error: "primary=\(primaryError) accelerated=HTTP \(accResult.statusCode)",
                        timestamp: isoStart, durationMs: durationMs
                    )
                }

                let info = parseSubscriptionUserinfo(accResult.headers["subscription-userinfo"])
                return ConfigRefreshResult(
                    status: "success",
                    content: accResult.body,
                    subscriptionUpload: info.upload,
                    subscriptionDownload: info.download,
                    subscriptionTotal: info.total,
                    subscriptionExpire: info.expire,
                    timestamp: isoStart,
                    durationMs: durationMs
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
                    timestamp: isoStart, durationMs: durationMs
                )
            }
        }
    }

    // MARK: - Domain verification

    private static let knownDomainSha256 = "183a5526e76751b07cd57236bc8f253d5424e02a3fc7da7c30f80919e975125a"
    private static let verifiedListUrl   = "https://www.sing-box.net/verified_subscriptions_sha256.txt"

    /// Returns true if the domain's SHA256 matches the local known hash or the remote whitelist.
    private static func verifyDomain(sha256: String) async -> Bool {
        if sha256 == knownDomainSha256 { return true }
        guard let url = URL(string: verifiedListUrl) else { return false }
        do {
            let request = URLRequest(url: url, timeoutInterval: 10)
            let (data, _) = try await URLSession.shared.data(for: request)
            let text   = String(data: data, encoding: .utf8) ?? ""
            let hashes = text.components(separatedBy: "\n")
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }
            return hashes.contains(sha256)
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

    private struct SubscriptionInfo {
        let upload: Int64
        let download: Int64
        let total: Int64
        let expire: Int64
    }

    private static func parseSubscriptionUserinfo(_ header: String?) -> SubscriptionInfo {
        func extract(_ key: String, from str: String) -> Int64 {
            guard let range = str.range(of: "\(key)=(\\d+)", options: .regularExpression) else { return 0 }
            let match = String(str[range])
            let value = match.replacingOccurrences(of: "\(key)=", with: "")
            return Int64(value) ?? 0
        }
        let h = header ?? ""
        return SubscriptionInfo(
            upload:   extract("upload", from: h),
            download: extract("download", from: h),
            total:    extract("total", from: h),
            expire:   extract("expire", from: h)
        )
    }
}
