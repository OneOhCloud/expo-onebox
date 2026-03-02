import ExpoModulesCore
import Libbox
@preconcurrency import NetworkExtension

// MARK: - One-shot proxy group query handler

/// Connects to the libbox CommandServer, waits for the first CommandGroup update,
/// extracts ExitGateway group info, then disconnects.
private class OneShotGroupQueryHandler: NSObject, LibboxCommandClientHandlerProtocol {
    weak var client: LibboxCommandClient?
    private let continuation: CheckedContinuation<[String: Any], Error>
    private let lock = NSLock()
    private var settled = false

    init(continuation: CheckedContinuation<[String: Any], Error>) {
        self.continuation = continuation
    }

    private func settle(_ result: Result<[String: Any], Error>) {
        lock.lock()
        let wasSettled = settled
        settled = true
        lock.unlock()
        guard !wasSettled else { return }
        DispatchQueue.global().async { [weak self] in
            _ = try? self?.client?.disconnect()
        }
        switch result {
        case .success(let val): continuation.resume(returning: val)
        case .failure(let err): continuation.resume(throwing: err)
        }
    }

    func fail(_ error: Error) { settle(.failure(error)) }
    func timeout() { settle(.success(["all": [] as [[String: Any]], "now": ""])) }

    func connected() {}
    func disconnected(_ message: String?) {
        settle(.success(["all": [] as [[String: Any]], "now": ""]))
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message else { return }
        var all: [[String: Any]] = []
        var now = ""
        while let group = message.next() {
            if group.tag == "ExitGateway" {
                now = group.selected
                if let items = group.getItems() {
                    while let item = items.next() {
                        all.append(["tag": item.tag, "delay": Int(item.urlTestDelay)])
                    }
                }
                break
            }
        }
        settle(.success(["all": all, "now": now]))
    }

    // Unused callbacks — libbox runtime checks respondsToSelector before calling
    func writeStatus(_ message: LibboxStatusMessage?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
}

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
    internal var coreLogEnabled = false
    // Log polling
    private var logPoller: Timer?
    private var logFileReadOffset: UInt64 = 0

    public func definition() -> ModuleDefinition {
        Name("ExpoOneBox")

        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate")

        OnCreate {
            self.initializeLibbox()
            self.observeVPNStatus()
            // Sync initial VPN state so JS gets correct status on app launch
            // (NEVPNStatusDidChange doesn't fire on launch if VPN was already running)
            Task {
                await self.syncInitialVPNStatus()
            }
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

        Function("setCoreLogEnabled") { (enabled: Bool) in
            self.coreLogEnabled = enabled
            NSLog("[ExpoOneBox] Core log output \(enabled ? "enabled" : "disabled")")
        }

        Function("getCoreLogEnabled") {
            return self.coreLogEnabled
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

        // Returns the last startup error written by the Network Extension to the shared
        // App Group file. Empty string means no error (or last start succeeded).
        // JS layer calls this when status transitions STARTING → STOPPED.
        Function("getStartError") { () -> String in
            return self.readStartupError()
        }

        // Query the libbox CommandServer (in the Network Extension) for the
        // ExitGateway selector group — returns { all: [String], now: String }.
        // Uses LibboxCommandClient + LibboxCommandGroup subscription.
        AsyncFunction("getProxyNodes") { () async throws -> [String: Any] in
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                let handler = OneShotGroupQueryHandler(continuation: continuation)

                let options = LibboxCommandClientOptions()
                options.addCommand(LibboxCommandGroup)

                guard let client = LibboxNewCommandClient(handler, options) else {
                    continuation.resume(throwing: NSError(
                        domain: "ExpoOneBox", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create CommandClient"]))
                    return
                }
                handler.client = client

                // Timeout after 5 s in case CommandServer is not ready
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    handler.timeout()
                }

                DispatchQueue.global(qos: .utility).async {
                    do {
                        try client.connect()
                    } catch {
                        handler.fail(error)
                    }
                }
            }
        }

        // Select a proxy outbound in the ExitGateway selector group
        // via LibboxNewStandaloneCommandClient (same IPC used by stopVPN).
        AsyncFunction("selectProxyNode") { (node: String) async throws -> Bool in
            return try await Task.detached(priority: .userInitiated) {
                guard let client = LibboxNewStandaloneCommandClient() else {
                    throw NSError(domain: "ExpoOneBox", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Failed to create standalone client"])
                }
                try client.selectOutbound("ExitGateway", outboundTag: node)
                return true
            }.value
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

    /// Sync current VPN state on module creation.
    /// NEVPNStatusDidChange does NOT fire on app launch if VPN was already running,
    /// so we must load managers and set the initial status ourselves.
    private func syncInitialVPNStatus() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = managers.first else { return }
            self.vpnManager = manager
            DispatchQueue.main.async {
                self.handleVPNStatusChange(manager.connection.status)
            }
        } catch {
            NSLog("[ExpoOneBox] syncInitialVPNStatus error: \(error.localizedDescription)")
        }
    }

    private func initializeLibbox() {        guard !isInitialized else { return }

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

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            NSLog("[ExpoOneBox] Setup error: \(setupError.localizedDescription)")
            // Non-fatal: continue anyway, extension will do its own setup
        }

        // Match reference: main app only calls LibboxSetup + LibboxSetLocale
        // Do NOT call LibboxRedirectStderr or LibboxSetMemoryLimit in main app
        // Those are only for the extension process
        LibboxSetLocale(Locale.current.identifier)

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

        // Load or create the VPN manager
        let manager: NETunnelProviderManager
        if let existing = vpnManager {
            try await existing.loadFromPreferences()
            manager = existing
        } else {
            manager = try await loadOrCreateManager()
        }
        self.vpnManager = manager

        // Always ensure the profile is enabled and save before starting
        // (matching reference project's ExtensionProfile.start() pattern)
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

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
            stopLogPolling()
            updateStatus(0)
        case .disconnected:
            trafficMonitor?.disconnect()
            trafficMonitor = nil
            stopLogPolling()
            updateStatus(0)
            // JS 层在收到 STOPPED 状态后主动调用 getStartError() 查询原因，无需在此推送
        case .connecting:
            updateStatus(1)
        case .connected:
            updateStatus(2)
            startTrafficMonitor()
            startLogPolling()
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

    // MARK: - Log Polling

    private var logFilePath: URL? {
        guard let sharedDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        return sharedDir
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("stderr.log")
    }

    private func startLogPolling() {
        guard logPoller == nil else { return }
        // Reset offset to end of file so we only tail new lines written after connection
        if let path = logFilePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let fileSize = attrs[.size] as? UInt64 {
            logFileReadOffset = fileSize
        } else {
            logFileReadOffset = 0
        }
        logPoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollLogFile()
        }
        NSLog("[ExpoOneBox] Log polling started")
    }

    private func stopLogPolling() {
        logPoller?.invalidate()
        logPoller = nil
        logFileReadOffset = 0
        NSLog("[ExpoOneBox] Log polling stopped")
    }

    private func pollLogFile() {
        guard let path = logFilePath else { return }
        guard FileManager.default.fileExists(atPath: path.path) else { return }

        guard let fileHandle = try? FileHandle(forReadingFrom: path) else { return }
        defer { try? fileHandle.close() }

        let fileSize: UInt64
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let s = attrs[.size] as? UInt64 {
            fileSize = s
        } else { return }

        // Handle log rotation (file shrank)
        if fileSize < logFileReadOffset {
            logFileReadOffset = 0
        }
        guard fileSize > logFileReadOffset else { return }

        try? fileHandle.seek(toOffset: logFileReadOffset)
        let newData = fileHandle.readDataToEndOfFile()
        logFileReadOffset = fileSize

        guard !newData.isEmpty,
              let text = String(data: newData, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sendLog(message: trimmed)
        }
    }

    // MARK: - Startup Error File

    /// Read the shared startup_error.txt written by the Network Extension on failure.
    /// Returns empty string if the file doesn't exist or the last start succeeded.
    private func readStartupError() -> String {
        guard let sharedDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return "" }
        let errorFilePath = sharedDir.appendingPathComponent("startup_error.txt")
        guard FileManager.default.fileExists(atPath: errorFilePath.path) else { return "" }
        let content = (try? String(contentsOf: errorFilePath, encoding: .utf8)) ?? ""
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
        stopLogPolling()
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
        if coreLogEnabled {
            NSLog("[sing-box] %@", message)
        }
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
