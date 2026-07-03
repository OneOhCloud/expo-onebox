import Foundation
import Libbox
import NetworkExtension
import os.log

private let logger = Logger(subsystem: "cloud.oneoh.networktools.tunnel", category: "PacketTunnel")

/// Strictly follows sing-box-for-apple's ExtensionProvider pattern.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private(set) var commandServer: LibboxCommandServer?
    private lazy var platformInterface = ExtensionPlatformInterface(self)
    var tunnelOptions: [String: NSObject]?
    private var startOptionsURL: URL?

    /// Timestamp captured in sleep() so wake() can tell how long the device idled.
    private var sleepStartedAt: Date?
    /// Only reset the network on wake when the device slept at least this long — a brief
    /// screen toggle shouldn't tear down live transfers, but a long idle almost certainly
    /// left the proxy sockets dead.
    private static let wakeResetThreshold: TimeInterval = 20
    /// Coalesce bursts of same-interface path updates into a single reset.
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

    /// Path to the shared startup_error.txt in App Group
    private static var startupErrorFileURL: URL {
        FilePath.sharedDirectory.appendingPathComponent("startup_error.txt")
    }

    /// Write a startup error message to the shared file so the main app can read it.
    private static func writeStartupError(_ message: String) {
        let url = startupErrorFileURL
        NSLog("Writing startup error to file: \(message)")
        try? message.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Clear the startup error file (called on successful start).
    private static func clearStartupError() {
        let url = startupErrorFileURL
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    /// Persist a startup failure to the shared file (so the main app can read it) and
    /// return the matching error for the caller to `throw`.
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

        // Ensure directories exist before LibboxSetup
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

        // 强制启用内存限制，确保在内存紧张时系统能正确回收资源，避免被杀死后无法清理的情况
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

    /// libbox log-level code for command-server messages (matches sing-box `log.Level`:
    /// panic=0, fatal=1, error=2 — see ExpoOneBoxModule.setCoreLogLevel).
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
            // Clear any previous error so JS gets a clean state
            PacketTunnelProvider.clearStartupError()
        } catch {
            let msg = "(packet-tunnel) error: start service: \(error.localizedDescription)"
            logger.error("startOrReloadService failed: \(error.localizedDescription)")
            // failStartup writes to the shared App Group file — main app reads it via getStartError()
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
        // Record when we go to sleep so wake() can gate the reset on idle duration.
        sleepStartedAt = Date()
        if let commandServer {
            commandServer.pause()
        }
    }

    override func wake() {
        guard let commandServer else { return }
        commandServer.wake()
        // A long idle usually leaves the proxy sockets dead (NAT/keepalive timeout while
        // radios were off). Proactively close all connections so the next request dials
        // fresh instead of stalling on a dead socket's TCP/QUIC timeout. This mirrors
        // sing-box's own desktop suspend/resume behaviour (route/network.go:526-536),
        // which the mobile Pause()/Wake() path omits.
        let elapsed = sleepStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        sleepStartedAt = nil
        if elapsed >= Self.wakeResetThreshold {
            logger.log("wake after long idle → resetNetwork")
            commandServer.resetNetwork()
        }
    }

    /// Debounced, thread-safe reset for same-interface path changes (WiFi roam / DHCP
    /// renew) whose (name, index) is unchanged and therefore deduped away by sing-box's
    /// interface monitor (experimental/libbox/monitor.go:95). Called from the NWPath
    /// update handler, so it may run off the provider queue.
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
