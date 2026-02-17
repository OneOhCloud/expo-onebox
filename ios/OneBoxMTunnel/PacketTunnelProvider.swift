import Foundation
import Libbox
import NetworkExtension

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

    override func startTunnel(options startOptions: [String: NSObject]?) async throws {
        let basePath = FilePath.sharedDirectory.relativePath
        let workingPath = FilePath.workingDirectory.relativePath
        let tempPath = FilePath.cacheDirectory.relativePath

        startOptionsURL = URL(fileURLWithPath: basePath).appendingPathComponent(ExtensionStartOptions.snapshotFileName)

        let effectiveOptions = try resolveStartOptions(startOptions)
        if effectiveOptions["configContent"] == nil {
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }
        do {
            try persistStartOptions(effectiveOptions)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: persist start options: \(error.localizedDescription)")
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
            throw ExtensionStartupError("(packet-tunnel) error: setup service: \(setupError.localizedDescription)")
        }

        let stderrPath = URL(fileURLWithPath: tempPath, isDirectory: true).appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)
        if let stderrError {
            throw ExtensionStartupError("(packet-tunnel) redirect stderr error: \(stderrError.localizedDescription)")
        }

        let ignoreMemoryLimit = (effectiveOptions["ignoreMemoryLimit"] as? NSNumber)?.boolValue ?? false
        LibboxSetMemoryLimit(!ignoreMemoryLimit)

        var error: NSError?
        commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &error)
        if let error {
            throw ExtensionStartupError("(packet-tunnel): create command server error: \(error.localizedDescription)")
        }
        do {
            try commandServer!.start()
        } catch {
            throw ExtensionStartupError("(packet-tunnel): start command server error: \(error.localizedDescription)")
        }

        writeMessage("(packet-tunnel): Here I stand")
        do {
            try await startService()
        } catch {
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
            throw ExtensionStartupError("(packet-tunnel) error: missing configContent in tunnel options")
        }

        let options = LibboxOverrideOptions()
        do {
            try commandServer!.startOrReloadService(configContent, options: options)
        } catch {
            throw ExtensionStartupError("(packet-tunnel) error: start service: \(error.localizedDescription)")
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
