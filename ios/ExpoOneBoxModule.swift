import ExpoModulesCore
@preconcurrency import Libbox
@preconcurrency import NetworkExtension

// MARK: - One-shot proxy group query handler

/// Connects to the libbox CommandServer, waits for the first CommandGroup update,
/// extracts ExitGateway group info, then disconnects.
private class OneShotGroupQueryHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
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
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        // print logs if coreLogEnabled, otherwise ignore
        guard let messageList else { return }
        while let msg = messageList.next() {
            NSLog("[sing-box] %@", msg.message)
        }            
    }
    
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
}

public class ExpoOneBoxModule: Module, @unchecked Sendable {

    // Extension bundle identifier — must match the NE target's PRODUCT_BUNDLE_IDENTIFIER
    private static let extensionBundleID = "cloud.oneoh.networktools.tunnel"
    // App Group identifier — shared between app and extension
    private static let appGroupID = "group.cloud.oneoh.networktools"

    private var vpnManager: NETunnelProviderManager?
    private var trafficMonitor: TrafficMonitor?
    private var currentStatus: Int = 0 // 0=Stopped, 1=Starting, 2=Started, 3=Stopping
    /// Tracks whether VPN is in the process of starting up.
    /// Set to true when user initiates start, cleared on connected or disconnected.
    /// Used to detect startup failures even when NEVPNStatus goes connecting→disconnecting→disconnected.
    private var isStartingUp: Bool = false
    private var isInitialized = false
    private var statusObserver: NSObjectProtocol?
    internal var coreLogEnabled = false

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

        // Get the best DNS server by testing latency to multiple DNS servers
        AsyncFunction("getBestDns") { () async throws -> String in
            return await self.getBestDnsServer()
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
            DispatchQueue.main.async { [weak self] in
                self?.handleVPNStatusChange(manager.connection.status)
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

        isStartingUp = true
        updateStatus(1) // Starting

        // Prepare options (same dict the extension receives in startTunnel)
        let options = prepareStartOptions(config: config)

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
        NSLog("[ExpoOneBox] NEVPNStatus changed: \(status.rawValue), currentStatus=\(currentStatus), isStartingUp=\(isStartingUp)")
        switch status {
        case .invalid:
            NSLog("[ExpoOneBox] VPN status: invalid")
            isStartingUp = false
            updateStatus(0)
        case .disconnected:
            // 关键：使用 isStartingUp 标记而非 currentStatus==1 来判断启动失败。
            // 因为 NEVPNStatus 可能经过 connecting→disconnecting→disconnected，
            // 到达 disconnected 时 currentStatus 已经是 3(disconnecting) 而非 1(starting)。
            let wasStarting = self.isStartingUp
            NSLog("[ExpoOneBox] VPN status: disconnected, wasStarting=\(wasStarting), currentStatus=\(currentStatus)")
            isStartingUp = false
            trafficMonitor?.disconnect()
            trafficMonitor = nil
            updateStatus(0)
            // 主动检测启动失败：从共享文件读取错误并推送给 JS。
            if wasStarting {
                NSLog("[ExpoOneBox] Startup failure path entered, scheduling error check...")
                // 延迟 500ms 确保 Extension 进程的文件写入已刷盘
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
                        self.sendError(type: "StartServiceFailed", message: "启动异常退出，请检查配置文件。", source: "binary")
                    }
                }
            }
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

    /// Connect a CommandClient to the extension's CommandServer for live traffic data.
    private func startTrafficMonitor() {
        guard trafficMonitor == nil else { return }
        let monitor = TrafficMonitor(module: self)
        self.trafficMonitor = monitor
        monitor.connect()
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
    
    // MARK: - DNS Testing
    
    private static let dnsServers = [
        "1.0.0.1",        // Cloudflare DNS
        "1.1.1.1",        // Cloudflare DNS  
        "1.2.4.8",        // CN DNS
        "101.101.101.101",
        "101.102.103.104",
        "114.114.114.114", // CN 114DNS
        "114.114.115.115", // CN 114DNS
        "119.29.29.29",    // CN Tencent DNS
        "149.112.112.112",
        "149.112.112.9",
        "180.184.1.1",
        "180.184.2.2",
        "180.76.76.76",
        "2.188.21.131",   // Iran Yokhdi! DNS
        "2.188.21.132",   // Iran Yokhdi! DNS
        "2.189.44.44",    // Iran DNS
        "202.175.3.3",
        "202.175.3.8",
        "208.67.220.220", // OpenDNS
        "208.67.220.222", // OpenDNS
        "208.67.222.220", // OpenDNS
        "208.67.222.222", // OpenDNS
        "210.2.4.8",
        "223.5.5.5",     // CN Alibaba DNS
        "223.6.6.6",     // CN Alibaba DNS
        "77.88.8.1",
        "77.88.8.8",
        "8.8.4.4",       // Google DNS
        "8.8.8.8",       // Google DNS
        "9.9.9.9"        // Quad9 DNS
    ]
    
    private func getBestDnsServer() async -> String {
        let firstDns = type(of: self).dnsServers.first ?? "8.8.8.8"
        
        return await withTaskGroup(of: (String, TimeInterval)?.self, returning: String.self) { group in
            
            // Add tasks for each DNS server
            for dns in type(of: self).dnsServers {
                group.addTask {
                    return await self.testDnsServer(dns)
                }
            }
            
            // Wait for the first successful response
            for await result in group {
                if let (dnsServer, latency) = result {
                    NSLog("[ExpoOneBox] DNS %@ selected as optimal server with latency %.3fms", dnsServer, latency * 1000)
                    group.cancelAll()
                    return dnsServer
                }
            }
            
            // All DNS servers failed, fallback to first one
            NSLog("[ExpoOneBox] All DNS servers failed, falling back to: %@", firstDns)
            return firstDns
        }
    }
    
    private func testDnsServer(_ dnsServer: String) async -> (String, TimeInterval)? {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let result = try await withThrowingTaskGroup(of: Void.self, returning: Bool.self) { group in
                group.addTask {
                    try await self.performDnsQuery(to: dnsServer)
                }
                
                // Add timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    throw NSError(domain: "DNSTimeout", code: -1, userInfo: nil)
                }
                
                // Return on first completion (either success or timeout)
                guard let _ = try await group.next() else {
                    throw NSError(domain: "DNSError", code: -1, userInfo: nil)
                }
                
                return true
            }
            
            if result {
                let latency = CFAbsoluteTimeGetCurrent() - startTime
                let paddedDns = String(format: "%-20s", dnsServer)
                NSLog("[ExpoOneBox] ✓ DNS %@ responded successfully, latency: %.3fms", paddedDns, latency * 1000)
                return (dnsServer, latency)
            }
        } catch {
            let paddedDns = String(format: "%-20s", dnsServer)
            NSLog("[ExpoOneBox] ✗ DNS %@ failed or timed out", paddedDns)
        }
        
        return nil
    }
    
    private func performDnsQuery(to dnsServer: String) async throws {
        NSLog("[ExpoOneBox] Testing DNS server: %@", dnsServer)
        
        // Create DNS query packet for www.baidu.com
        var queryData = Data([
            0x12, 0x34,  // Transaction ID
            0x01, 0x00,  // Standard query
            0x00, 0x01,  // Questions: 1  
            0x00, 0x00,  // Answer RRs: 0
            0x00, 0x00,  // Authority RRs: 0
            0x00, 0x00   // Additional RRs: 0
        ])
        
        // Query for www.baidu.com
        queryData.append(contentsOf: [3])  // length of "www"
        queryData.append("www".data(using: .ascii)!)
        queryData.append(contentsOf: [5])  // length of "baidu"
        queryData.append("baidu".data(using: .ascii)!)
        queryData.append(contentsOf: [3])  // length of "com"
        queryData.append("com".data(using: .ascii)!)
        queryData.append(contentsOf: [0])  // null terminator
        queryData.append(contentsOf: [0x00, 0x01])  // Type A
        queryData.append(contentsOf: [0x00, 0x01])  // Class IN
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedThrowingContinuation<Void, Error>) in
            var isResumed = false
            let lock = NSLock()
            
            let queue = DispatchQueue.global(qos: .userInitiated)
            
            queue.async {
                do {
                    // Create UDP socket
                    let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
                    guard socketFD > 0 else {
                        lock.lock()
                        if !isResumed {
                            isResumed = true
                            continuation.resume(throwing: NSError(domain: "SocketError", code: -1, userInfo: nil))
                        }
                        lock.unlock()
                        return
                    }
                    
                    defer { close(socketFD) }
                    
                    // Configure server address
                    let serverIP = inet_addr(dnsServer)
                    var serverAddr = sockaddr_in()
                    serverAddr.sin_family = sa_family_t(AF_INET)
                    serverAddr.sin_port = htons(53)
                    serverAddr.sin_addr.s_addr = serverIP
                    
                    // Send query
                    let sendResult = queryData.withUnsafeBytes { queryBytes in
                        withUnsafePointer(to: &serverAddr) { serverAddrPtr in
                            serverAddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                                sendto(socketFD, queryBytes.bindMemory(to: UInt8.self).baseAddress, queryData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    
                    guard sendResult > 0 else {
                        lock.lock()
                        if !isResumed {
                            isResumed = true
                            continuation.resume(throwing: NSError(domain: "SendError", code: -1, userInfo: nil))
                        }
                        lock.unlock()
                        return
                    }
                    
                    // Receive response
                    var buffer = [UInt8](repeating: 0, count: 512)
                    let recvResult = recv(socketFD, &buffer, buffer.count, 0)
                    
                    if recvResult >= 12 && buffer[0] == 0x12 && buffer[1] == 0x34 {
                        lock.lock()
                        if !isResumed {
                            isResumed = true
                            continuation.resume()
                        }
                        lock.unlock()
                    } else {
                        lock.lock()
                        if !isResumed {
                            isResumed = true
                            continuation.resume(throwing: NSError(domain: "InvalidResponse", code: -1, userInfo: nil))
                        }
                        lock.unlock()
                    }
                    
                } catch {
                    lock.lock()
                    if !isResumed {
                        isResumed = true
                        continuation.resume(throwing: error)
                    }
                    lock.unlock()
                }
            }
        }
    }
}
