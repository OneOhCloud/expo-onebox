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
    var actualUrl: String? = nil // 使用回落时的加速 URL

    /// 失败信封，流量四元组（upload/download/total/expire）置零。
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

    /// 跳过信封（未配置 URL）——从未执行，因此耗时为零。
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

/// JS 推送的域名白名单在磁盘上的原子存储结构。
private struct DomainVerificationCache: Codable {
    let known: [String]
    let verified: [String]
    let updatedAt: Double
}

// MARK: - Typed errors

/// 带类型的错误类型。errorDescription 逐字复现这些错误字符串——它们会被
/// JS 侧直接消费，改动即改变 JS 端收到的消息，勿改。
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

    // AppGroup UserDefaults —— 在主 App 与 extension 进程间共享
    private static let appGroupID = "group.cloud.oneoh.networktools"
    private static let sharedDefaults = UserDefaults(suiteName: appGroupID)
    private static let kConfigUrl       = "bg_config_url"
    private static let kUserAgent       = "bg_user_agent"
    private static let kIntervalSeconds = "bg_interval_seconds"
    private static let kLastResultJSON  = "bg_last_result_json"
    private static let kIsRegistered    = "bg_task_registered"
    // JS（src/utils/domain-verification.ts）推送的域名验证缓存，让后台 worker
    // 每次唤醒时不必重新拉取远端验证列表。以单个 JSON blob 存储，保证三个
    // 字段原子读写（分散多键写入可能让新时间戳与旧列表配对）。
    private static let kDomainVerificationCacheJSON = "bg_domain_verification_cache_json"
    // 通过 JS 的 setBackgroundConfigRefreshOptions 镜像过来的刷新选项。
    // 切勿在此读取 JS 持有的 SQLite 数据库：对同一 WAL 文件使用第二个 SQLite
    // 库会破坏进程内 POSIX 文件锁，导致 SIGBUS 崩溃。
    private static let kAccelerateUrl             = "bg_accelerate_url"
    private static let kTestPrimaryUrlUnavailable = "bg_test_primary_unavailable"
    /// 共享缓存有效期 24 小时；超时后 worker 回落到自身的网络拉取。
    /// 与 domain-verification.ts 中的 CACHE_TTL_MS 保持一致。
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

    /// 由 JS（setBackgroundConfigRefreshOptions）在 App 初始化时以及每次 dev
    /// 开关切换时调用。完整覆盖两个值，幂等。
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
            // submit 失败 → 续期链已断裂。清除注册意图标志，避免它一直
            // 停留在已注册状态直到下次冷启动。
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

    /// 由 JS（ExpoOneBoxModule.setVerificationData）在每次 updateVerificationData
    /// 成功后调用，让后台 worker 复用同一份白名单，而不是自行发起 HTTP 拉取。
    /// 同时存入 updated-at 时间戳，供 verifyDomain 做 TTL 比较。
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

    /// 加载 JS 推送的白名单（若存在且未过期）。返回 nil 表示调用方应回落到
    /// 内置列表 + 实时拉取；非 nil 元组即权威结果。
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

    /// 读取 JS 推送的 test/accelerate 开关，并在发起拉取前记录其状态。
    /// context 用于在日志行中标识调用路径。
    /// 由 fetchProfileConfigWithFallback 与 executeRefreshWith 共用。
    private static func readRefreshSwitches(
        context: String
    ) -> (testPrimaryUnavailable: Bool, accelerateUrl: String?) {
        let testPrimaryUnavailable = isTestPrimaryUrlUnavailableEnabled()
        let accelerateUrl = readAccelerateUrl()
        NSLog(
            "[CONFIG_LOAD] pre-request switch state(%@): testPrimaryUnavailable=%@, accelerate=%@",
            context,
            testPrimaryUnavailable ? "true" : "false",
            summarizeAccelerateUrl(accelerateUrl)
        )
        return (testPrimaryUnavailable, accelerateUrl)
    }

    /// 原生 fetchProfileConfig 路径，带可选的 accelerator 回落。
    ///
    /// 规则：
    ///   1. 先尝试主 URL。
    ///   2. 只有网络层失败才触发回落（HTTP 非 2xx 不触发）。
    ///   3. 回落要求域名已验证 + JS 推送的 accelerate URL。
    ///
    /// 当 JS 推送的 testPrimaryUrlUnavailable 选项开启时，主请求会主动抛出
    /// 异常，以模拟真实网络失败来测试回落。
    ///
    /// 取消（cancellation）永远不触发 accelerator 回落。
    /// 共享 fetchWithFallback 控制流的结果类型。
    enum FallbackOutcome {
        /// 主结果（任意 HTTP 状态）或一次成功的加速拉取。
        case ok(result: ConfigFetchResult, method: String, actualUrl: String, primaryError: String?)
        /// 主请求抛出网络错误且回落被跳过。
        case noFallback(primaryError: String, reason: String) // "unverified" | "no-accelerator"
        /// 主请求抛出异常，且加速拉取也抛出异常。
        case bothFailed(primaryError: String, accError: String, accUrl: String)
        /// 主尝试之后任务被取消——绝不回落。
        case cancelled
    }

    /// 主 → 闸门 → accelerator 的控制流。前台 fetchProfileConfigWithFallback
    /// 与后台 executeRefreshWith 共用同一份实现。fetch/log 以参数注入，使这段
    /// 决策逻辑在 host 测试 runner 里无需真实网络或 NSLog 即可运行。HTTP 错误
    /// 作为主结果 .ok 返回（非 2xx 绝不回落）；只有网络抛错才进入闸门；取消则
    /// 为 .cancelled。
    static func fetchWithFallback(
        parsedURL: URL,
        userAgent: String,
        verified: Bool,
        testPrimaryUnavailable: Bool,
        accelerateUrl: String?,
        fetch: (URL, String) async throws -> ConfigFetchResult = { try await ConfigFetcher.fetch(url: $0, userAgent: $1) },
        log: (String) -> Void = { NSLog("%@", $0) }
    ) async -> FallbackOutcome {
        var primaryError = ""
        do {
            if testPrimaryUnavailable {
                log("[CONFIG_LOAD] test_mode=PRIMARY_UNAVAILABLE, primary URL actively throws")
                throw ExpoOneBoxError.testModePrimaryUnavailable
            }
            // HTTP 错误不触发回落——主响应原样返回。
            return .ok(result: try await fetch(parsedURL, userAgent), method: "primary", actualUrl: parsedURL.absoluteString, primaryError: nil)
        } catch {
            primaryError = error.localizedDescription
        }

        if Task.isCancelled { return .cancelled }
        if !verified { return .noFallback(primaryError: primaryError, reason: "unverified") }
        guard let accBase = accelerateUrl,
              let accURL  = buildAcceleratedURL(from: parsedURL, accelerateBase: accBase) else {
            return .noFallback(primaryError: primaryError, reason: "no-accelerator")
        }

        log("[CONFIG_LOAD] method=FALLBACK_TRY, reason=\(primaryError), accelerateUrl=\(summarizeAccelerateUrl(accURL.absoluteString))")
        do {
            return .ok(result: try await fetch(accURL, userAgent), method: "fallback", actualUrl: accURL.absoluteString, primaryError: primaryError)
        } catch {
            return .bothFailed(primaryError: primaryError, accError: error.localizedDescription, accUrl: accURL.absoluteString)
        }
    }

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
            NSLog("[CONFIG_LOAD] method=DOMAIN_UNVERIFIED, domainSha256=%@, accelerator fallback disabled", domainSha)
        }
        let (testPrimaryUnavailable, accelerateUrl) = readRefreshSwitches(context: "fetchProfileConfig")

        switch await fetchWithFallback(parsedURL: parsedURL, userAgent: userAgent, verified: verified,
                                       testPrimaryUnavailable: testPrimaryUnavailable, accelerateUrl: accelerateUrl) {
        case .ok(let result, _, _, _):
            return result
        case .cancelled:
            NSLog("[CONFIG_LOAD] method=CANCELLED, no fallback")
            throw CancellationError()
        case .noFallback(let primaryError, _):
            throw ExpoOneBoxError.primaryFailed(primaryError)
        case .bothFailed(let primaryError, let accError, _):
            throw ExpoOneBoxError.bothFailed(primary: primaryError, accelerated: accError)
        }
    }

    /// 主 → 加速回落。
    /// HTTP 错误（非 2xx）不触发回落——只有网络层失败才会。
    /// 当 JS 推送的 testPrimaryUrlUnavailable 选项开启时，主请求会主动抛出
    /// 异常，用于测试回落行为。
    ///
    /// 取消（BGTask 过期）永远不触发 accelerator 回落——它以 error=CANCELLED
    /// 的失败结果呈现。
    static func executeRefreshWith(url: String, userAgent: String) async -> ConfigRefreshResult {
        let start    = Date()
        let isoStart = ISO8601DateFormatter().string(from: start)

        guard !url.isEmpty, let parsedURL = URL(string: url) else {
            return .skipped(error: "No URL configured", timestamp: isoStart)
        }

        // ── 域名验证 ──────────────────────────────────────────────────────────
        let hostname    = parsedURL.host ?? ""
        let domainSha   = sha256HexString(hostname)
        let verified    = await verifyDomain(hostname: hostname)
        if !verified {
            NSLog("[CONFIG_LOAD] method=DOMAIN_UNVERIFIED, domainSha256=%@, accelerator fallback disabled", domainSha)
        }
        let (testPrimaryUnavailable, accelerateUrl) = readRefreshSwitches(context: "executeRefresh")

        // 主 → 闸门 → accelerator 的控制流与 fetchProfileConfigWithFallback 共用；
        // 这里只负责把结果解释为 ConfigRefreshResult + CONFIG_LOAD 诊断。
        func ms() -> Int64 { Int64(Date().timeIntervalSince(start) * 1000) }

        switch await fetchWithFallback(parsedURL: parsedURL, userAgent: userAgent, verified: verified,
                                       testPrimaryUnavailable: testPrimaryUnavailable, accelerateUrl: accelerateUrl) {
        case .ok(let result, let method, let actualUrl, let primaryError):
            let ok2xx = result.statusCode >= 200 && result.statusCode < 300
            if method == "primary" && !ok2xx {
                // HTTP 错误——不回落
                return .failed(error: "HTTP \(result.statusCode)", method: "primary", timestamp: isoStart, durationMs: ms())
            } else if method == "primary" {
                NSLog("[CONFIG_LOAD] method=PRIMARY")
                let headerValue = result.headers["subscription-userinfo"]
                let info = parseUserinfo(headerValue)
                return ConfigRefreshResult(
                    status: "success", content: result.body,
                    profileUpload: info.upload, profileDownload: info.download,
                    profileTotal: info.total, profileExpire: info.expire,
                    timestamp: isoStart, durationMs: ms(),
                    profileUserinfoHeader: headerValue, method: "primary"
                )
            } else if !ok2xx {
                NSLog("[CONFIG_LOAD] method=BOTH_FAILED, accelerator reason=HTTP %d, primary reason=%@", result.statusCode, primaryError ?? "")
                return .failed(
                    error: "primary=\(primaryError ?? "") accelerated=HTTP \(result.statusCode)",
                    method: "fallback", timestamp: isoStart, durationMs: ms(), actualUrl: actualUrl
                )
            } else {
                let headerValue = result.headers["subscription-userinfo"]
                let info = parseUserinfo(headerValue)
                NSLog("[CONFIG_LOAD] method=FALLBACK_ACCELERATOR, upload=%lld, download=%lld, total=%lld, expire=%lld", info.upload, info.download, info.total, info.expire)
                return ConfigRefreshResult(
                    status: "success", content: result.body,
                    profileUpload: info.upload, profileDownload: info.download,
                    profileTotal: info.total, profileExpire: info.expire,
                    timestamp: isoStart, durationMs: ms(),
                    profileUserinfoHeader: headerValue, method: "fallback", actualUrl: actualUrl
                )
            }
        case .cancelled:
            NSLog("[CONFIG_LOAD] method=CANCELLED, no fallback")
            return .failed(error: "CANCELLED", method: "primary", timestamp: isoStart, durationMs: ms())
        case .noFallback(let primaryError, let reason):
            if reason == "unverified" {
                NSLog("[CONFIG_LOAD] method=ACCELERATOR_SKIPPED, reason=domain unverified, primary reason=%@", primaryError)
            } else {
                NSLog("[CONFIG_LOAD] method=ACCELERATOR_UNAVAILABLE, reason=not configured or build failed")
            }
            return .failed(error: primaryError, method: "primary", timestamp: isoStart, durationMs: ms())
        case .bothFailed(let primaryError, let accError, let accUrl):
            NSLog("[CONFIG_LOAD] method=BOTH_FAILED, accelerator reason=%@, primary reason=%@", accError, primaryError)
            return .failed(
                error: "primary=\(primaryError) accelerated=\(accError)",
                method: "fallback", timestamp: isoStart, durationMs: ms(), actualUrl: accUrl
            )
        }
    }

    // MARK: - Domain verification

    // 编译期白名单。每一项都是某个已批准后缀标签的 SHA256；verifyDomain 会对
    // 目标 hostname 的每个渐进后缀（从最短开始）求哈希，命中第一个匹配即返回
    // true，因此更宽的条目会批准更宽的子树。切勿在本文件或任何注释中记录其
    // 明文原像（pre-image）。
    private static let knownDomainSha256List: [String] = [
        "183a5526e76751b07cd57236bc8f253d5424e02a3fc7da7c30f80919e975125a",
        "59fe86216c23236fb4c6ab50cd8d1e261b7cad754e3e7cab33058df5b32d12e1",
        "61e245b4e5c234b00865ab0f47ad1cc4a9b37dbc50159febea7e6dcaee8ce050",
    ]
    private static let verifiedListUrl   = "https://www.sing-box.net/verified_subscriptions_sha256.txt"

    /// 当且仅当 hostname 的任一后缀（从最短开始）哈希后命中白名单中某项时
    /// 返回 true。优先级顺序：
    ///   1. JS 推送的共享缓存（setVerificationData）——零网络，覆盖 JS 上次刷新
    ///      后的 24 小时。
    ///   2. 编译期 knownDomainSha256List——始终可用。
    ///   3. 从 verifiedListUrl 实时拉取——仅当共享缓存缺失或过期时；内置列表
    ///      不会过期，因此该分支严格来说只是恢复路径。
    private static func verifyDomain(hostname: String) async -> Bool {
        let candidates = hostnameSuffixCandidates(hostname)
        let hashed     = candidates.map { sha256HexString($0) }
        let hashedSet  = Set(hashed)

        // 来源 1 —— JS 推送的缓存。
        if let cache = loadFreshDomainVerificationCache() {
            let union = Set(cache.known).union(cache.verified)
            if !hashedSet.isDisjoint(with: union) { return true }
            // 缓存存在且新鲜但未命中；放弃前仍用下面的编译期列表做最后一次
            // 检查。
            if hashed.contains(where: { knownDomainSha256List.contains($0) }) {
                return true
            }
            return false
        }

        // 来源 2 —— 编译期回落。
        if hashed.contains(where: { knownDomainSha256List.contains($0) }) {
            return true
        }

        // 来源 3 —— 网络拉取（仅当 JS 从未推送过新鲜数据时到达，例如后台
        // 任务在 App 从未打开过之前就触发）。
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

    /// 构造加速变体：<accelerateBase>/<sha256(host)><path+query>
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

    // 查询 BGTaskScheduler 获取权威的 pending-request 状态，而不是依赖
    // kIsRegistered 意图标志——系统丢弃请求后该标志仍可能停留在 true。
    static func isRegistered() async -> Bool {
        let requests = await BGTaskScheduler.shared.pendingTaskRequests()
        return requests.contains { $0.identifier == taskIdentifier }
    }
}
