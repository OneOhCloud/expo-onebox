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
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
        }
        if effectiveOptions["configContent"] == nil {
            let msg = "(packet-tunnel) error: missing configContent in tunnel options"
            logger.error("missing configContent")
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
        }
        let configLen = (effectiveOptions["configContent"] as? String)?.count ?? 0
        logger.log("Config content length: \(configLen)")

        do {
            try persistStartOptions(effectiveOptions)
            logger.log("Start options persisted")
        } catch {
            let msg = "(packet-tunnel) error: persist start options: \(error.localizedDescription)"
            logger.error("persist start options: \(error.localizedDescription)")
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
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
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
        }
        logger.log("Libbox setup completed")

        let stderrPath = URL(fileURLWithPath: tempPath, isDirectory: true).appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)
        if let stderrError {
            let msg = "(packet-tunnel) redirect stderr error: \(stderrError.localizedDescription)"
            logger.error("redirect stderr: \(stderrError.localizedDescription)")
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
        }
        logger.log("Stderr redirected to: \(stderrPath)")

        let ignoreMemoryLimit = (effectiveOptions["ignoreMemoryLimit"] as? NSNumber)?.boolValue ?? false
        LibboxSetMemoryLimit(!ignoreMemoryLimit)

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            let msg = "(packet-tunnel): create command server error: \(error.localizedDescription)"
            logger.error("create command server: \(error.localizedDescription)")
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
        }
        logger.log("Command server created")

        do {
            try commandServer!.start()
            logger.log("Command server started")
        } catch {
            let msg = "(packet-tunnel): start command server error: \(error.localizedDescription)"
            logger.error("start command server: \(error.localizedDescription)")
            PacketTunnelProvider.writeStartupError(msg)
            throw ExtensionStartupError(msg)
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

    func writeMessage(_ message: String) {
        if let commandServer {
            commandServer.writeMessage(2, message: message)
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
            // Write to shared App Group file — main app reads this via getStartError()
            PacketTunnelProvider.writeStartupError(msg)
            logger.error("startOrReloadService failed: \(error.localizedDescription)")
            throw ExtensionStartupError(msg)
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

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        do {
            let options = try ExtensionStartOptions.decode(messageData)
            applyStartOptions(options)
            try persistStartOptions(options)
            try await reloadService()
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async {
        if let commandServer {
            commandServer.pause()
        }
    }

    override func wake() {
        if let commandServer {
            commandServer.wake()
        }
    }
}
