import Foundation
import Libbox
import NetworkExtension
import os.log

private let logger = Logger(subsystem: "cloud.oneoh.networktools.tunnel", category: "PacketTunnel")

/// 严格遵循 sing-box-for-apple 的 ExtensionProvider 模式。
class PacketTunnelProvider: NEPacketTunnelProvider {

    private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?

    /// 在 sleep() 中记录的时间戳，供 wake() 判断设备空闲了多久。
    private var sleepStartedAt: Date?
    /// 仅当设备至少睡眠了这么久才在唤醒时重置网络——短暂的息屏不该中断
    /// 进行中的传输，但长时间空闲几乎必然让 proxy socket 已失效。
    private static let wakeResetThreshold: TimeInterval = 20
    /// 把同一接口的成串 path 更新合并为单次重置。
    private static let networkResetDebounce: TimeInterval = 0.8
    private var lastNetworkResetAt: Date?
    private let networkResetLock = NSLock()

    struct OverridePreferences {
        var includeAllNetworks: Bool = false
        var systemProxyEnabled: Bool = true
        var excludeDefaultRoute: Bool = false
        var autoRouteUseSubRangesByDefault: Bool = false
        var excludeAPNsRoute: Bool = false
    }

    var overridePreferences: OverridePreferences?

    private func applyStartOptions(_ options: [String: NSObject]) {
        tunnelOptions = options
        overridePreferences = OverridePreferences(
            includeAllNetworks: (options["includeAllNetworks"] as? NSNumber)?.boolValue ?? false,
            systemProxyEnabled: (options["systemProxyEnabled"] as? NSNumber)?.boolValue ?? true,
            excludeDefaultRoute: (options["excludeDefaultRoute"] as? NSNumber)?.boolValue ?? false,
            autoRouteUseSubRangesByDefault: (options["autoRouteUseSubRangesByDefault"] as? NSNumber)?.boolValue ?? false,
            excludeAPNsRoute: (options["excludeAPNsRoute"] as? NSNumber)?.boolValue ?? false
        )
    }

    private func persistStartOptions(_ options: [String: NSObject]) throws {
        guard let startOptionsURL else {
            return
        }
        let data = try ExtensionStartOptions.encode(options)
        try data.write(to: startOptionsURL, options: .atomic)
    }

    private func loadPersistedStartOptions() throws -> [String: NSObject]? {
        guard let startOptionsURL, FileManager.default.fileExists(atPath: startOptionsURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: startOptionsURL)
        return try ExtensionStartOptions.decode(data)
    }

    private func resolveStartOptions(_ startOptions: [String: NSObject]?) throws -> [String: NSObject] {
        if let startOptions, startOptions["configContent"] as? String != nil {
            return startOptions
        }
        let persistedOptions: [String: NSObject]?
        do {
            persistedOptions = try loadPersistedStartOptions()
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: load start options: \(error.localizedDescription)")
        }
        if let persistedOptions {
            if let startOptions {
                return persistedOptions.merging(startOptions) { _, new in new }
            }
            return persistedOptions
        }
        throw ExtensionStartupError("(packet-tunnel) error: missing start options")
    }

// MARK: - Shared startup error file

    /// App Group 中共享 startup_error.txt 的路径
    private static var startupErrorFileURL: URL {
        FilePath.sharedDirectory.appendingPathComponent("startup_error.txt")
    }

    /// 把启动错误消息写入共享文件，供主 App 读取。
    private static func writeStartupError(_ message: String) {
        let url = startupErrorFileURL
        NSLog("Writing startup error to file: \(message)")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 清空启动错误文件（启动成功时调用）。
    private static func clearStartupError() {
        let url = startupErrorFileURL
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    /// 把启动失败持久化到共享文件（供主 App 读取），并返回对应错误供调用方 throw。
    private func failStartup(_ message: String) -> ExtensionStartupError {
        PacketTunnelProvider.writeStartupError(message)
        return ExtensionStartupError(message)
    }

    override func startTunnel(options startOptions: [String: NSObject]?) async throws {
        let basePath = FilePath.sharedDirectory.relativePath
        let workingPath = FilePath.workingDirectory.relativePath
        let tempPath = FilePath.cacheDirectory.relativePath

        logger.log("Starting tunnel...")
        logger.log("basePath: \(basePath)")
        logger.log("workingPath: \(workingPath)")
        logger.log("tempPath: \(tempPath)")

        // 在 LibboxSetup 之前确保目录存在
        for dir in [FilePath.workingDirectory, FilePath.cacheDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        let effectiveOptions: [String: NSObject]
        do {
            effectiveOptions = try resolveStartOptions(startOptions)
        } catch {
            let msg = "(packet-tunnel) error: resolve start options: \(error.localizedDescription)"
            throw failStartup(msg)
        }
        if effectiveOptions["configContent"] == nil {
            let msg = "(packet-tunnel) error: missing configContent in tunnel options"
            logger.error("missing configContent")
            throw failStartup(msg)
        }
        let configLen = (effectiveOptions["configContent"] as? String)?.count ?? 0
        logger.log("Config content length: \(configLen)")

        do {
            try persistStartOptions(effectiveOptions)
            logger.log("Start options persisted")
        } catch {
            let msg = "(packet-tunnel) error: persist start options: \(error.localizedDescription)"
            logger.error("persist start options: \(error.localizedDescription)")
            throw failStartup(msg)
        }

        applyStartOptions(effectiveOptions)

        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingPath
        options.tempPath = tempPath
        options.logMaxLines = 3000

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            let msg = "(packet-tunnel) error: setup service: \(setupError.localizedDescription)"
            logger.error("setup service: \(setupError.localizedDescription)")
            throw failStartup(msg)
        }
        logger.log("Libbox setup completed")

        let stderrPath = URL(fileURLWithPath: tempPath, isDirectory: true).appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)
        if let stderrError {
            let msg = "(packet-tunnel) redirect stderr error: \(stderrError.localizedDescription)"
            logger.error("redirect stderr: \(stderrError.localizedDescription)")
            throw failStartup(msg)
        }
        logger.log("Stderr redirected to: \(stderrPath)")

        // 强制开启内存上限，让系统在内存压力下能回收资源，避免 extension 被杀后
        // 残留不干净的状态。
        LibboxSetMemoryLimit(true)

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            let msg = "(packet-tunnel): create command server error: \(error.localizedDescription)"
            logger.error("create command server: \(error.localizedDescription)")
            throw failStartup(msg)
        }
        logger.log("Command server created")

        do {
            try commandServer!.start()
            logger.log("Command server started")
        } catch {
            let msg = "(packet-tunnel): start command server error: \(error.localizedDescription)"
            logger.error("start command server: \(error.localizedDescription)")
            throw failStartup(msg)
        }

        writeMessage("(packet-tunnel): Here I stand")
        logger.log("Starting service...")
        do {
            try await startService()
            logger.log("Service started successfully")
        } catch {
            logger.error("start service: \(error.localizedDescription)")
            throw error
        }
    }

    /// command-server 消息使用的 libbox 日志等级码（对应 sing-box log.Level：
    /// panic=0, fatal=1, error=2——见 ExpoOneBoxModule.setCoreLogLevel）。
    private static let libboxLogLevelError: Int32 = 2

    func writeMessage(_ message: String) {
        if let commandServer {
            commandServer.writeMessage(PacketTunnelProvider.libboxLogLevelError, message: message)
        }
    }

    private func startService() async throws {
        guard let configContent = tunnelOptions?["configContent"] as? String else {
            logger.error("missing configContent in startService")
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }

        logger.log("Starting service with config length: \(configContent.count)")
        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(configContent, options: options)
            logger.log("Service started/reloaded successfully")
            // 清除任何先前的错误，让 JS 得到干净状态
            PacketTunnelProvider.clearStartupError()
        } catch {
            let msg = "(packet-tunnel) error: start service: \(error.localizedDescription)"
            logger.error("startOrReloadService failed: \(error.localizedDescription)")
            // failStartup 写入共享 App Group 文件——主 App 通过 getStartError() 读取
            throw failStartup(msg)
        }
    }

    func stopService() {
        do {
            try commandServer?.closeService()
        } catch {
            writeMessage("(packet-tunnel) stop service: \(error.localizedDescription)")
        }
        platformInterface.reset()
    }

    func reloadService() async throws {
        writeMessage("(packet-tunnel) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        try await startService()
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(packet-tunnel) stopping, reason: \(reason)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            server.close()
            commandServer = nil
        }
    }

    override func sleep() async {
        // 记录进入睡眠的时间，让 wake() 能按空闲时长决定是否重置。
        sleepStartedAt = Date()
        if let commandServer {
            commandServer.pause()
        }
    }

    override func wake() {
        guard let commandServer else { return }
        commandServer.wake()
        // 长时间空闲通常会让 proxy socket 失效（无线电关闭期间 NAT/keepalive
        // 超时）。主动关闭所有连接，让下一个请求重新拨号，而不是卡在失效 socket
        // 的 TCP/QUIC 超时上。这与 sing-box 桌面端自身的挂起/恢复行为一致
        //（route/network.go:526-536），而移动端 Pause()/Wake() 路径省略了它。
        let elapsed = sleepStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        sleepStartedAt = nil
        if elapsed >= Self.wakeResetThreshold {
            logger.log("wake after long idle → resetNetwork")
            commandServer.resetNetwork()
        }
    }

    /// 针对同一接口 path 变化（WiFi 漫游 / DHCP 续租）的去抖、线程安全重置——
    /// 这类变化的 (name, index) 不变，因而会被 sing-box 的接口监视器去重
    ///（experimental/libbox/monitor.go:95）。由 NWPath 更新 handler 调用，因此
    /// 可能运行在 provider 队列之外。
    func requestNetworkReset() {
        networkResetLock.lock()
        let now = Date()
        if let last = lastNetworkResetAt, now.timeIntervalSince(last) < Self.networkResetDebounce {
            networkResetLock.unlock()
            return
        }
        lastNetworkResetAt = now
        networkResetLock.unlock()
        logger.log("same-interface path change → resetNetwork")
        commandServer?.resetNetwork()
    }
}
