import ExpoModulesCore
@preconcurrency import Libbox
@preconcurrency import NetworkExtension

/// 串行化对某个字段的访问——该字段被 Expo 异步执行器、主队列（NEVPNStatus
/// 观察者）与后台 dispatch 队列共享。每次 get/set 都获取该锁，且从不在锁内
/// 嵌套另一次受保护访问，因此不会死锁。
@propertyWrapper
final class Guarded<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(wrappedValue: T) { value = wrappedValue }
    var wrappedValue: T {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

// 这些可变字段用 @Guarded 保护；@unchecked Sendable 仍保留，因为该类仍会跨越
// 并发域（concurrency domain）。
public class ExpoOneBoxModule: Module, @unchecked Sendable {

    // Extension bundle 标识符——必须与 NE target 的 PRODUCT_BUNDLE_IDENTIFIER 一致
    private static let extensionBundleID = "cloud.oneoh.networktools.tunnel"
    // App Group 标识符——在主 App 与 extension 间共享
    private static let appGroupID = "group.cloud.oneoh.networktools"

    @Guarded private var vpnManager: NETunnelProviderManager?
    @Guarded private var trafficMonitor: TrafficMonitor?
    @Guarded private var currentStatus: Int = 0 // 0=Stopped, 1=Starting, 2=Started, 3=Stopping
    /// 跟踪 VPN 是否正处于启动过程中。
    /// 用户发起启动时置为 true，连接成功或断开时清除。
    /// 用于识别启动失败——即便 NEVPNStatus 走的是 connecting→disconnecting→disconnected。
    @Guarded private var isStartingUp: Bool = false
    /// 用户请求停止时置位，以便在 .disconnected 处理里把意外的隧道掉线（crash）
    /// 与正常停止区分开。
    @Guarded private var userInitiatedStop: Bool = false
    private var lastStartConfig: String = ""
    private var isInitialized = false
    private var statusObserver: NSObjectProtocol?
    internal var coreLogEnabled = false
    /// 转发给 JS 的 sing-box 日志等级上限。等级码对应内置 sing-box 源码树中的
    /// log/level.go：panic=0, fatal=1, error=2, warn=3, info=4, debug=5, trace=6。
    /// level > coreLogLevelMax 的条目会在 sendLog(...) 之前被丢弃。
    @Guarded internal var coreLogLevelMax: Int32 = 4 // info

    public func definition() -> ModuleDefinition {
        Name("ExpoOneBox")

        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate", "onGroupUpdate", "onNativeLog")

        OnCreate {
            self.initializeLibbox()
            self.observeVPNStatus()
            self.sendNativeLog(level: "info", tag: "Module", message: "ExpoOneBox Swift module initialized")
            // 同步初始 VPN 状态，让 JS 在 App 启动时拿到正确状态
            //（若 VPN 已在运行，NEVPNStatusDidChange 在启动时不会触发）
            Task {
                await self.syncInitialVPNStatus()
            }
        }

        OnDestroy {
            self.sendNativeLog(level: "info", tag: "Module", message: "ExpoOneBox Swift module destroying")
            self.cleanup()
        }

        Function("getLibBoxVersion") {
            return LibboxVersion()
        }

        Function("getStatus") { () -> Int in
            // 查询实时隧道状态（与 Android 的 getStatus 一致），而不是异步填充的
            // 缓存，这样 VPN 已连接时冷启动的 JS 也能读到正确值。
            guard let manager = self.vpnManager else { return self.currentStatus }
            let live: Int
            switch manager.connection.status {
            case .invalid, .disconnected: live = 0
            case .connecting, .reasserting: live = 1
            case .connected: live = 2
            case .disconnecting: live = 3
            @unknown default: return self.currentStatus
            }
            self.currentStatus = live
            return live
        }

        Function("setCoreLogEnabled") { (enabled: Bool) in
            self.coreLogEnabled = enabled
            NSLog("[ExpoOneBox] Core log output \(enabled ? "enabled" : "disabled")")
        }

        // CommandServer 日志流的客户端侧过滤。sing-box 的 log.level 配置只过滤
        // stdout / 可观察 sink——喂给我们的 platform writer 是无条件输出的。
        Function("setCoreLogLevel") { (level: String) in
            let code: Int32
            switch level.lowercased() {
            case "panic":   code = 0
            case "fatal":   code = 1
            case "error":   code = 2
            case "warn", "warning": code = 3
            case "info":    code = 4
            case "debug":   code = 5
            case "trace":   code = 6
            default:        code = 4
            }
            self.coreLogLevelMax = code
            self.sendNativeLog(level: "info", tag: "Module",
                               message: "core log level filter → \(level) (code \(code))")
        }

        AsyncFunction("checkVpnPermission") { () async -> Bool in
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                if let manager = managers.first {
                    self.vpnManager = manager
                    return manager.isEnabled
                }
                return false
            } catch {
                NSLog("[ExpoOneBox] checkVpnPermission error: \(error.localizedDescription)")
                return false
            }
        }

        AsyncFunction("requestVpnPermission") { () async -> Bool in
            do {
                let manager = try await self.loadOrCreateManager()
                self.vpnManager = manager
                // 与 Android 的语义差异：这里返回的是 VPN 配置文件是否已安装并
                // 启用，而不是用户在系统弹窗上的 Allow/Deny 选择。Android 返回的是
                // 真实的弹窗结果。调用方不得把 true 当作"用户已同意"。
                return manager.isEnabled
            } catch {
                NSLog("[ExpoOneBox] requestVpnPermission error: \(error.localizedDescription)")
                return false
            }
        }

        AsyncFunction("start") { (config: String) in
            self.sendNativeLog(level: "info", tag: "Tunnel", message: "start() requested, config bytes=\(config.count)")
            try await self.startVPN(config: config)
        }

        AsyncFunction("stop") {
            self.sendNativeLog(level: "info", tag: "Tunnel", message: "stop() requested")
            await self.stopVPN()
        }

        // 仅 Android 使用的 bridge 方法，在 iOS 上以 stub 形式存在，用于保持四层
        // 签名一致（docs/claude/bridge-signature.md）。每个 JS 调用点都用
        // Platform.OS === 'android' 守卫，因此在 iOS 上永不会到达；这些 stub 只是
        // 为了让签名在全部四层之间匹配。
        Function("checkBatteryOptimizationExemption") { () -> Bool in
            // iOS 没有电池优化白名单；直接报告"豁免"。
            return true
        }

        AsyncFunction("requestBatteryOptimizationExemption") { () async -> Bool in
            return true
        }

        Function("crashForBugsnagTest") { () -> Bool in
            // iOS 上为空操作（仅 Android 的诊断项）；此处永不调用。
            return false
        }

        Function("repairSQLiteDirectory") { () -> Bool in
            // SQLite 目录修复是 Android 的存储路径问题；iOS 上为空操作。
            return true
        }

        // 返回 Network Extension 写入共享 App Group 文件的最近一次启动错误。
        // 空字符串表示无错误（或上次启动成功）。
        // JS 层在状态从 STARTING → STOPPED 转换时调用此方法。
        Function("getStartError") { () -> String in
            return self.readStartupError()
        }

        Function("getStartConfig") { () -> String in
            if !self.lastStartConfig.isEmpty { return self.lastStartConfig }
            return self.readLastStartConfig()
        }

        // 对指定的 outbound tag 或 group tag（例如 "ExitGateway"）触发 URLTest。
        AsyncFunction("triggerURLTest") { (tag: String) async -> Bool in
            return await Task.detached(priority: .userInitiated) {
                guard let client = LibboxNewStandaloneCommandClient() else { return false }
                do {
                    try client.urlTest(tag)
                    return true
                } catch {
                    NSLog("[ExpoOneBox] triggerURLTest(\(tag)) error: \(error.localizedDescription)")
                    return false
                }
            }.value
        }

        // 通过 LibboxNewStandaloneCommandClient 在 ExitGateway selector group 中
        // 选择一个 proxy outbound（与 stopVPN 使用同一 IPC）。
        AsyncFunction("selectProxyNode") { (tag: String) async throws -> Bool in
            return try await Task.detached(priority: .userInitiated) {
                guard let client = LibboxNewStandaloneCommandClient() else {
                    throw NSError(domain: "ExpoOneBox", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to create standalone client"])
                }
                try client.selectOutbound("ExitGateway", outboundTag: tag)
                return true
            }.value
        }

        // 通过测试到多个 DNS 服务器的延迟，选出最优 DNS 服务器
        AsyncFunction("getBestDns") { () async -> String in
            return await DnsTester.findBest()
        }

        // ─── 配置拉取（DNS 解析）─────────────────────────────────────────────────

        // 拉取配置 URL：DNS 解析后的主地址 + 可选的 accelerator 回落。
        // accelerator URL 来自 JS 推送的共享选项（AppGroup UserDefaults）。
        AsyncFunction("fetchProfileConfig") { (url: String, userAgent: String) async throws -> [String: Any] in
            let result = try await BackgroundConfigRefresh.fetchProfileConfigWithFallback(
                url: url,
                userAgent: userAgent
            )
            return [
                "statusCode": result.statusCode,
                "headers": result.headers,
                "body": result.body,
            ]
        }

        // ─── 原生后台配置刷新 ────────────────────────────────────────────────────

        // 把 JS 管理的域名白名单推入 AppGroup UserDefaults，让 BGTaskScheduler
        // worker 无需重新拉取远端列表即可验证 hostname。每次缓存更新成功后由
        // domain-verification.ts 调用；当共享缓存缺失或过期时，worker 的 24 小时
        // TTL 闸门会回落到编译期列表。
        AsyncFunction("setVerificationData") { (data: [String: Any]) async in
            let known    = data["knownSha256List"]    as? [String] ?? []
            let verified = data["verifiedSha256List"] as? [String] ?? []
            BackgroundConfigRefresh.saveDomainVerificationCache(known: known, verified: verified)
        }

        // 把 JS 管理的刷新选项镜像到 AppGroup UserDefaults，使 BGTaskScheduler
        // worker 永远不会打开 JS 持有的 SQLite 数据库——对同一 WAL 文件使用第二个
        // SQLite 库会导致 SIGBUS 崩溃。
        AsyncFunction("setBackgroundConfigRefreshOptions") { (options: [String: Any]) async in
            let accelerateUrl = options["accelerateUrl"] as? String ?? ""
            let testFlag      = options["testPrimaryUrlUnavailable"] as? Bool ?? false
            BackgroundConfigRefresh.saveRefreshOptions(
                accelerateUrl: accelerateUrl,
                testPrimaryUrlUnavailable: testFlag
            )
        }

        // 注册（或更新）原生后台配置刷新任务。
        // 把 URL、userAgent、interval 持久化到 AppGroup UserDefaults，然后提交一个
        // BGAppRefreshTaskRequest，让 iOS 周期性唤醒 App。
        AsyncFunction("registerBackgroundConfigRefresh") { (url: String, userAgent: String, intervalSeconds: Int) async in
            BackgroundConfigRefresh.saveConfig(url: url, userAgent: userAgent, intervalSeconds: intervalSeconds)
            BackgroundConfigRefresh.scheduleNextRefresh()
            NSLog("[ExpoOneBox] Background config refresh registered (interval=\(intervalSeconds)s)")
        }

        // 立即执行一次配置刷新（供前台 / dev 屏幕使用）。
        // 使用与后台任务相同的 DNS 解析 fetcher，带 accelerator 回落。
        AsyncFunction("executeConfigRefreshNow") { (url: String, userAgent: String) async -> [String: Any] in
            let result = await BackgroundConfigRefresh.executeRefreshWith(url: url, userAgent: userAgent)
            // 此处切勿 storeResult：JS 会直接收到结果并自行调用
            // applyResultToSBConfig()。若在此存储，会覆盖任何待处理的后台刷新结果，
            // 并导致下一次前台同步把这个手动结果当作重复的 'auto' TaskLog 条目重放。
            //（与 Android 模块一致；持久化槽位保留给真正的后台运行——见
            // BackgroundConfigRefresh.registerHandler。）
            return result.toDictionary()
        }

        // 返回后台任务存储的最近一次结果（若无则为 nil）。
        // 在前台调用此方法，把原生结果同步进 JS 状态。
        // 读取后会清除存储的结果，因此后续调用返回 nil。
        Function("getLastConfigRefreshResult") { () -> [String: Any]? in
            guard let result = BackgroundConfigRefresh.loadLastResult() else { return nil }
            BackgroundConfigRefresh.clearLastResult()
            return result
        }

        // 当前是否有后台刷新任务已排期。
        AsyncFunction("isBackgroundConfigRefreshRegistered") { () async -> Bool in
            await BackgroundConfigRefresh.isRegistered()
        }

        // 把打包资源（sourceUri = file:// URI）复制到 AppGroup Caches 目录，命名为 tun.db。
        // 若目标已存在则跳过。复制返回 true，跳过返回 false。
        AsyncFunction("copy2CacheDbPath") { (sourceUri: String) -> Bool in
            guard let cacheDir = self.appGroupCachesURL() else { return false }
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let destURL = cacheDir.appendingPathComponent("tun.db")
            if FileManager.default.fileExists(atPath: destURL.path) {
                return false
            }
            guard let sourceURL = URL(string: sourceUri) else { return false }
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destURL, options: .atomic)
            return true
        }
    }

    // MARK: - App Group Paths

    /// 共享的 App Group 容器 URL，不可用时为 nil。
    /// Self.appGroupID 文件访问的唯一派生点。
    private func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    /// <AppGroup>/Library/Caches——必须与 extension 的 FilePath 一致。
    private func appGroupCachesURL() -> URL? {
        appGroupContainerURL()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    // MARK: - Initialization

    /// 在模块创建时同步当前 VPN 状态。
    /// 若 VPN 已在运行，NEVPNStatusDidChange 在 App 启动时不会触发，因此必须
    /// 自己加载 manager 并设置初始状态。
    private func syncInitialVPNStatus() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else { return }
            self.vpnManager = manager
            DispatchQueue.main.async { [weak self] in
                self?.handleVPNStatusChange(manager.connection.status)
            }
        } catch {
            NSLog("[ExpoOneBox] syncInitialVPNStatus error: \(error.localizedDescription)")
        }
    }

    private func initializeLibbox() {
        guard !isInitialized else { return }

        // 使用 App Group 共享目录——必须与 extension 的 FilePath 一致
        guard let sharedDir = appGroupContainerURL(),
              let cacheDir = appGroupCachesURL() else {
            NSLog("[ExpoOneBox] ERROR: App Group container not available")
            return
        }

        let workingDir = cacheDir.appendingPathComponent("Working", isDirectory: true)

        for dir in [workingDir, cacheDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 使用 relativePath，与参考项目的模式一致
        let options = LibboxSetupOptions()
        options.basePath = sharedDir.relativePath
        options.workingPath = workingDir.relativePath
        options.tempPath = cacheDir.relativePath

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            NSLog("[ExpoOneBox] Setup error: \(setupError.localizedDescription)")
            // 非致命：继续执行，extension 会做自己的 setup
        }

        // 与参考项目一致：主 App 只调用 LibboxSetup + LibboxSetLocale
        // 主 App 中切勿调用 LibboxRedirectStderr 或 LibboxSetMemoryLimit
        // 那些只用于 extension 进程
        LibboxSetLocale(Locale.current.identifier)

        isInitialized = true
        NSLog("[ExpoOneBox] Libbox initialized, version: \(LibboxVersion())")
    }

    // MARK: - VPN Manager

    /// 加载已有或创建新的 NETunnelProviderManager。
    /// 创建/保存时会在需要时触发系统的 "Allow VPN" 弹窗。
    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()

        manager.localizedDescription = "OneBox VPN"

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleID
        proto.serverAddress = "sing-box"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        NSLog("[ExpoOneBox] VPN profile installed, enabled=\(manager.isEnabled)")
        return manager
    }

    // MARK: - Config Processing

    /// Android processConfig 的 Swift 等价实现。
    /// 把 experimental.cache_file.path 改写为 <AppGroup>/Library/Caches/tun.db 的
    /// 绝对路径，让 sing-box 能找到预置的缓存。
    private func processConfig(_ config: String) -> String {
        guard
            let data = config.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }

        guard var experimental = json["experimental"] as? [String: Any],
              var cacheFile = experimental["cache_file"] as? [String: Any]
        else { return config }

        guard let cacheDir = appGroupCachesURL() else { return config }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        cacheFile["path"] = cacheDir.appendingPathComponent("tun.db").path
        cacheFile["enabled"] = true
        experimental["cache_file"] = cacheFile
        json["experimental"] = experimental

        guard let processed = try? JSONSerialization.data(withJSONObject: json),
              let result = String(data: processed, encoding: .utf8)
        else { return config }

        NSLog("[ExpoOneBox] processConfig: cache_file.path → %@",
              cacheDir.appendingPathComponent("tun.db").path)
        return result
    }

    // MARK: - Prepare Options (following ExtensionProfile pattern)

    private func prepareStartOptions(config: String) -> [String: NSObject] {
        let options: [String: NSObject] = [
            "configContent": NSString(string: config),
            "systemProxyEnabled": NSNumber(value: true),
            "excludeDefaultRoute": NSNumber(value: false),
            "autoRouteUseSubRangesByDefault": NSNumber(value: false),
            "excludeAPNsRoute": NSNumber(value: false),
            "includeAllNetworks": NSNumber(value: false),
        ]
        return options
    }

    // MARK: - Start / Stop VPN

    private func startVPN(config: String) async throws {
        guard isInitialized else {
            let error = NSError(domain: "ExpoOneBox", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "Libbox not initialized"])
            sendError(type: "StartService", message: error.localizedDescription, source: "module")
            throw error
        }

        // 加载或创建 VPN manager
        let manager: NETunnelProviderManager
        if let existing = vpnManager {
            try await existing.loadFromPreferences()
            manager = existing
        } else {
            manager = try await loadOrCreateManager()
        }
        self.vpnManager = manager

        // 启动前始终确保 profile 已启用并保存
        //（与参考项目 ExtensionProfile.start() 的写法一致）
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        isStartingUp = true
        userInitiatedStop = false
        updateStatus(1) // Starting

        // 把 experimental.cache_file.path 改写为正确的绝对路径
        let processedConfig = processConfig(config)
        self.lastStartConfig = processedConfig
        self.writeLastStartConfig(processedConfig)

        // 准备 options（与 extension 在 startTunnel 中收到的字典相同）
        let options = prepareStartOptions(config: processedConfig)

        do {
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            isStartingUp = false
            updateStatus(0)
            sendError(type: "StartVPN", message: error.localizedDescription, source: "module")
            throw error
        }

        NSLog("[ExpoOneBox] VPN start requested")
    }

    private func stopVPN() async {
        userInitiatedStop = true
        guard let manager = vpnManager else {
            updateStatus(0)
            return
        }

        updateStatus(3) // Stopping

        // 先断开流量监控
        trafficMonitor?.disconnect()
        trafficMonitor = nil

        // 通过 standalone CommandClient 尝试优雅关闭（与参考项目 ExtensionProfile.stop() 一致）
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibboxNewStandaloneCommandClient()!.serviceClose()
            }.value
        } catch {
            NSLog("[ExpoOneBox] Standalone close error (non-fatal): \(error.localizedDescription)")
        }

        manager.connection.stopVPNTunnel()

        NSLog("[ExpoOneBox] VPN stop requested")
    }

    // MARK: - VPN Status Observation

    private func observeVPNStatus() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let connection = notification.object as? NEVPNConnection
            else { return }
            self.handleVPNStatusChange(connection.status)
        }
    }

    private func handleVPNStatusChange(_ status: NEVPNStatus) {
        NSLog("[ExpoOneBox] NEVPNStatus changed: \(status.rawValue), currentStatus=\(currentStatus), isStartingUp=\(isStartingUp)")
        switch status {
        case .invalid:
            NSLog("[ExpoOneBox] VPN status: invalid")
            isStartingUp = false
            updateStatus(0)
        case .disconnected:
            // 通过 isStartingUp 标志检测启动失败，而不是 currentStatus==1：
            // NEVPNStatus 可能走 connecting→disconnecting→disconnected，因此到达
            // disconnected 时 currentStatus 已经是 3（disconnecting），而非 1。
            let wasStarting = self.isStartingUp
            NSLog("[ExpoOneBox] VPN status: disconnected, wasStarting=\(wasStarting), currentStatus=\(currentStatus)")
            isStartingUp = false
            trafficMonitor?.disconnect()
            trafficMonitor = nil
            updateStatus(0)
            // 主动检测启动失败：从共享文件读取错误并推送给 JS。
            if wasStarting {
                NSLog("[ExpoOneBox] Startup failure path entered, scheduling error check...")
                // 延迟 500ms，确保 extension 进程的文件写入已刷到磁盘。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else {
                        NSLog("[ExpoOneBox] self was deallocated before error check")
                        return
                    }
                    let errMsg = self.readStartupError()
                    NSLog("[ExpoOneBox] Read startup error file, content: '\(errMsg)'")
                    if !errMsg.isEmpty {
                        NSLog("[ExpoOneBox] Sending StartServiceFailed error event to JS")
                        self.sendError(type: "StartServiceFailed", message: errMsg, source: "binary")
                    } else {
                        NSLog("[ExpoOneBox] No error in file, sending generic failure")
                        // 发出稳定的机器 token，而非用户可见文本——由 JS 层映射为
                        // 本地化字符串。使原生层保持 i18n-free。
                        self.sendError(type: "StartServiceFailed", message: "START_FAILED_GENERIC", source: "binary")
                    }
                }
            } else if !userInitiatedStop {
                // 隧道在成功启动后、且没有用户主动停止的情况下掉线——把它暴露
                // 出来，使失败可观察，而不仅覆盖启动窗口。crash 写的是 stderr 而非
                // startup_error，因此即便 startup 文件为空也要上报。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    let errMsg = self.readStartupError()
                    self.sendError(type: "UnexpectedDisconnect",
                                   message: errMsg.isEmpty ? "TUNNEL_DISCONNECTED_UNEXPECTEDLY" : errMsg,
                                   source: "binary")
                }
            }
            userInitiatedStop = false
        case .connecting:
            updateStatus(1)
        case .connected:
            isStartingUp = false
            updateStatus(2)
            startTrafficMonitor()
        case .reasserting:
            updateStatus(1)
        case .disconnecting:
            updateStatus(3)
        @unknown default:
            break
        }
    }

    // MARK: - Traffic Monitoring

    /// 连接一个 CommandClient 到 extension 的 CommandServer，获取实时流量数据。
    private func startTrafficMonitor() {
        guard trafficMonitor == nil else { return }
        let monitor = TrafficMonitor(module: self)
        self.trafficMonitor = monitor
        monitor.connect()
    }

    // MARK: - Last Start Config File

    private func writeLastStartConfig(_ config: String) {
        guard let sharedDir = appGroupContainerURL() else { return }
        let filePath = sharedDir.appendingPathComponent("last_start_config.json")
        try? config.write(to: filePath, atomically: true, encoding: .utf8)
    }

    private func readLastStartConfig() -> String {
        guard let sharedDir = appGroupContainerURL() else { return "" }
        let filePath = sharedDir.appendingPathComponent("last_start_config.json")
        guard FileManager.default.fileExists(atPath: filePath.path) else { return "" }
        return (try? String(contentsOf: filePath, encoding: .utf8)) ?? ""
    }

    // MARK: - Startup Error File

    /// 读取 Network Extension 失败时写入的共享 startup_error.txt。
    /// 若文件不存在或上次启动成功，返回空字符串。
    private func readStartupError() -> String {
        guard let sharedDir = appGroupContainerURL() else { return "" }
        let errorFilePath = sharedDir.appendingPathComponent("startup_error.txt")
        guard FileManager.default.fileExists(atPath: errorFilePath.path) else { return "" }
        let content = (try? String(contentsOf: errorFilePath, encoding: .utf8)) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
        trafficMonitor?.disconnect()
        trafficMonitor = nil
    }

    // MARK: - Event Dispatch

    internal func updateStatus(_ status: Int) {
        currentStatus = status
        let statusName: String
        switch status {
        case 0: statusName = "stopped"
        case 1: statusName = "starting"
        case 2: statusName = "started"
        case 3: statusName = "stopping"
        default: statusName = "unknown"
        }

        sendNativeLog(level: "info", tag: "Tunnel", message: "status → \(statusName)")

        sendEvent("onStatusChange", [
            "status": status,
            "statusName": statusName,
            "message": "Service status: \(statusName)"
        ])
    }

    internal func sendError(type: String, message: String, source: String) {
        sendEvent("onError", [
            "type": type,
            "message": message,
            "source": source,
            "status": currentStatus
        ])
    }

    internal func sendLog(message: String) {
        // 对事件发送本身设闸（与 Android 的 appendLogs 一致），而不仅是 NSLog
        // 副作用——否则用户关闭后 JS 仍会持续收到 core 日志。
        guard coreLogEnabled else { return }
        NSLog("[sing-box] %@", message)
        sendEvent("onLog", [
            "message": message
        ])
    }

    /// 向 JS 发出一条原生层日志。
    ///
    /// 与 sendLog（libbox / sing-box core 输出）不同。此通道承载 Swift 模块
    /// 自身的活动——VPN manager 生命周期、权限流程、Network Extension 状态
    /// 转换——让用户能区分"JS–原生 bridge 是否存活"与"core 是否在运行"。
    internal func sendNativeLog(level: String, tag: String, message: String) {
        // 收敛到 JS onNativeLog 载荷声明的等级并集（'info' | 'warn' | 'error'），
        // 与 Kotlin 侧保持一致。
        let normalizedLevel: String
        switch level.lowercased() {
        case "warn", "warning": normalizedLevel = "warn"
        case "error", "err", "fatal", "panic": normalizedLevel = "error"
        default: normalizedLevel = "info"
        }
        NSLog("[ExpoOneBox/%@] %@", tag, message)
        sendEvent("onNativeLog", [
            "level": normalizedLevel,
            "tag": tag,
            "message": message,
        ])
    }

    internal func sendTrafficUpdate(_ status: LibboxStatusMessage) {
        sendEvent("onTrafficUpdate", [
            "uplink": status.uplink,
            "downlink": status.downlink,
            "uplinkTotal": status.uplinkTotal,
            "downlinkTotal": status.downlinkTotal,
            "memory": status.memory,
            "goroutines": Int(status.goroutines),
            "connectionsIn": Int(status.connectionsIn),
            "connectionsOut": Int(status.connectionsOut)
        ])
    }

    internal func sendGroupUpdate(all: [[String: Any]], now: String, autoNow: String) {
        sendEvent("onGroupUpdate", [
            "all": all,
            "now": now,
            "autoNow": autoNow,
        ])
    }

}
