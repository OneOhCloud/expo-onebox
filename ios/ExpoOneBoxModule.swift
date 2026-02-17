import ExpoModulesCore
import Libbox
import NetworkExtension

public class ExpoOneBoxModule: Module {

    // Extension bundle identifier — must match the NE target's PRODUCT_BUNDLE_IDENTIFIER
    private static let extensionBundleID = "cloud.oneoh.networktools.tunnel"
    // App Group identifier — shared between app and extension
    private static let appGroupID = "group.cloud.oneoh.networktools"

    private var vpnManager: NETunnelProviderManager?
    private var trafficMonitor: TrafficMonitor?
    private var currentStatus: Int = 0 // 0=Stopped, 1=Starting, 2=Started, 3=Stopping
    private var isInitialized = false
    private var statusObserver: NSObjectProtocol?

    public func definition() -> ModuleDefinition {
        Name("ExpoOneBox")

        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate")

        OnCreate {
            self.initializeLibbox()
            self.observeVPNStatus()
        }

        OnDestroy {
            self.cleanup()
        }

        Function("hello") {
            return "Hello world! 👋"
        }

        Function("getLibBoxVersion") {
            return LibboxVersion()
        }

        Function("getStatus") {
            return self.currentStatus
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
                return manager.isEnabled
            } catch {
                NSLog("[ExpoOneBox] requestVpnPermission error: \(error.localizedDescription)")
                return false
            }
        }

        AsyncFunction("start") { (config: String) in
            try await self.startVPN(config: config)
        }

        AsyncFunction("stop") {
            await self.stopVPN()
        }

        AsyncFunction("getExtensionLogs") { () -> String in
            return self.readExtensionLogs()
        }

        View(ExpoOneBoxView.self) {
            Prop("url") { (view: ExpoOneBoxView, url: URL) in
                if view.webView.url != url {
                    view.webView.load(URLRequest(url: url))
                }
            }
            Events("onLoad")
        }
    }

    // MARK: - Initialization

    private func initializeLibbox() {
        guard !isInitialized else { return }

        // Use App Group shared directory — must match extension's FilePath
        guard let sharedDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            NSLog("[ExpoOneBox] ERROR: App Group container not available")
            return
        }

        let cacheDir = sharedDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        let workingDir = cacheDir.appendingPathComponent("Working", isDirectory: true)

        for dir in [workingDir, cacheDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Use relativePath matching the reference project's pattern
        let options = LibboxSetupOptions()
        options.basePath = sharedDir.relativePath
        options.workingPath = workingDir.relativePath
        options.tempPath = cacheDir.relativePath
        options.logMaxLines = 3000

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            NSLog("[ExpoOneBox] Setup error: \(setupError.localizedDescription)")
            return
        }

        let stderrPath = cacheDir.appendingPathComponent("stderr.log").relativePath
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)
        if let stderrError {
            NSLog("[ExpoOneBox] Redirect stderr error: \(stderrError.localizedDescription)")
        }

        LibboxSetMemoryLimit(false) // No strict memory limit in main app

        isInitialized = true
        NSLog("[ExpoOneBox] Libbox initialized, version: \(LibboxVersion())")
    }

    // MARK: - VPN Manager

    /// Load existing or create a new NETunnelProviderManager.
    /// Creating/saving triggers the system "Allow VPN" dialog if needed.
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

    // MARK: - Prepare Options (following ExtensionProfile pattern)

    private func prepareStartOptions(config: String) -> [String: NSObject] {
        var options: [String: NSObject] = [
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

        // Load or create the VPN manager
        let manager: NETunnelProviderManager
        if let existing = vpnManager {
            try await existing.loadFromPreferences()
            manager = existing
        } else {
            manager = try await loadOrCreateManager()
        }
        self.vpnManager = manager

        // Ensure the profile is enabled
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }

        updateStatus(1) // Starting

        // Prepare options (same dict the extension receives in startTunnel)
        let options = prepareStartOptions(config: config)

        do {
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            updateStatus(0)
            sendError(type: "StartVPN", message: error.localizedDescription, source: "module")
            throw error
        }

        NSLog("[ExpoOneBox] VPN start requested")
    }

    private func stopVPN() async {
        guard let manager = vpnManager else {
            updateStatus(0)
            return
        }

        updateStatus(3) // Stopping

        // Disconnect traffic monitor first
        trafficMonitor?.disconnect()
        trafficMonitor = nil

        // Try graceful close via standalone CommandClient (same as reference's ExtensionProfile.stop())
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
        switch status {
        case .invalid:
            updateStatus(0)
        case .disconnected:
            trafficMonitor?.disconnect()
            trafficMonitor = nil
            updateStatus(0)
            // 读取扩展日志以了解为什么断开连接
            let logs = readExtensionLogs()
            if !logs.isEmpty {
                sendLog(message: "=== Extension Logs ===")
                sendLog(message: logs)
            }
        case .connecting:
            updateStatus(1)
        case .connected:
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

    /// Connect a CommandClient to the extension's CommandServer for live traffic data.
    private func startTrafficMonitor() {
        guard trafficMonitor == nil else { return }
        let monitor = TrafficMonitor(module: self)
        self.trafficMonitor = monitor
        monitor.connect()
    }

    // MARK: - Extension Logs

    /// 读取扩展的 stderr.log 文件
    private func readExtensionLogs() -> String {
        guard let sharedDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            return "Error: Cannot access app group container"
        }

        let cacheDir = sharedDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        let logPath = cacheDir.appendingPathComponent("stderr.log")

        do {
            let content = try String(contentsOf: logPath, encoding: .utf8)
            // 返回最后 50 行
            let lines = content.components(separatedBy: "\n")
            let lastLines = lines.suffix(50).joined(separator: "\n")
            return lastLines
        } catch {
            return "Error reading extension logs: \(error.localizedDescription)\nLog path: \(logPath.path)"
        }
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
        case 1: statusName = "connecting"
        case 2: statusName = "connected"
        case 3: statusName = "disconnecting"
        default: statusName = "unknown"
        }

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
        sendEvent("onLog", [
            "message": message
        ])
    }

    internal func sendTrafficUpdate(_ status: LibboxStatusMessage) {
        sendEvent("onTrafficUpdate", [
            "uplink": status.uplink,
            "downlink": status.downlink,
            "uplinkTotal": status.uplinkTotal,
            "downlinkTotal": status.downlinkTotal,
            "uplinkDisplay": LibboxFormatBytes(status.uplink) + "/s",
            "downlinkDisplay": LibboxFormatBytes(status.downlink) + "/s",
            "uplinkTotalDisplay": LibboxFormatBytes(status.uplinkTotal),
            "downlinkTotalDisplay": LibboxFormatBytes(status.downlinkTotal),
            "memory": status.memory,
            "memoryDisplay": LibboxFormatMemoryBytes(status.memory),
            "goroutines": Int(status.goroutines),
            "connectionsIn": Int(status.connectionsIn),
            "connectionsOut": Int(status.connectionsOut)
        ])
    }

    // MARK: - Compatibility

    /// Called by TrafficMonitor if service stops externally.
    internal func handleServiceStopped() {
        trafficMonitor?.disconnect()
        trafficMonitor = nil
        if currentStatus != 0 {
            updateStatus(0)
        }
        NSLog("[ExpoOneBox] Service stopped by external event")
    }
}
