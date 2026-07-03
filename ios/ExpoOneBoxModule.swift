import ExpoModulesCore
@preconcurrency import Libbox
@preconcurrency import NetworkExtension

// NOTE (D4-10): `@unchecked Sendable` suppresses the compiler's data-race
// checking but the races are real — `isStartingUp`, `currentStatus`,
// `coreLogLevelMax`, `trafficMonitor` and `vpnManager` are read/written across
// the Expo async executor, the main queue (NEVPNStatus observer) and background
// dispatch queues with no lock. A proper fix (actor isolation or a serial queue)
// needs a build to verify and is out of scope for this surgical pass.
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
    private var lastStartConfig: String = ""
    private var isInitialized = false
    private var statusObserver: NSObjectProtocol?
    internal var coreLogEnabled = false
    /// Maximum sing-box level code to forward to JS. Codes mirror
    /// `log/level.go` in the vendored sing-box tree: panic=0, fatal=1,
    /// error=2, warn=3, info=4, debug=5, trace=6. Entries with
    /// `level > coreLogLevelMax` are dropped before `sendLog(...)`.
    internal var coreLogLevelMax: Int32 = 4 // info

    public func definition() -> ModuleDefinition {
        Name("ExpoOneBox")

        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate", "onGroupUpdate", "onNativeLog")

        OnCreate {
            self.initializeLibbox()
            self.observeVPNStatus()
            self.sendNativeLog(level: "info", tag: "Module", message: "ExpoOneBox Swift module initialized")
            // Sync initial VPN state so JS gets correct status on app launch
            // (NEVPNStatusDidChange doesn't fire on launch if VPN was already running)
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
            // Query the live tunnel status (matching Android's getStatus) rather
            // than the async-populated cache, so JS reads the correct value on
            // cold start when the VPN was already connected.
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

        // Client-side filter for the CommandServer log stream. sing-box's
        // `log.level` config only filters stdout / observable sinks —
        // the platform writer feeding us is unconditional.
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
                // Semantic divergence from Android: this returns whether the VPN
                // profile was installed and enabled, NOT the user's Allow/Deny
                // choice on the system dialog. Android returns the real dialog
                // result. Callers must not treat `true` as "user consented".
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

        // Android-only bridge methods, stubbed on iOS for 4-layer signature
        // parity (docs/claude/bridge-signature.md). Every JS call site guards
        // with `Platform.OS === 'android'`, so these are never reached on iOS;
        // the stubs exist only so the signature matches across all four layers.
        Function("checkBatteryOptimizationExemption") { () -> Bool in
            // iOS has no battery-optimization allowlist; report "exempt".
            return true
        }

        AsyncFunction("requestBatteryOptimizationExemption") { () async -> Bool in
            return true
        }

        Function("crashForBugsnagTest") { () -> Bool in
            // No-op on iOS (Android-only diagnostic); never called here.
            return false
        }

        Function("repairSQLiteDirectory") { () -> Bool in
            // SQLite directory repair is an Android storage-path concern; no-op on iOS.
            return true
        }

        // Returns the last startup error written by the Network Extension to the shared
        // App Group file. Empty string means no error (or last start succeeded).
        // JS layer calls this when status transitions STARTING → STOPPED.
        Function("getStartError") { () -> String in
            return self.readStartupError()
        }

        Function("getStartConfig") { () -> String in
            if !self.lastStartConfig.isEmpty { return self.lastStartConfig }
            return self.readLastStartConfig()
        }

        // Trigger URLTest for a specific outbound tag or group tag (e.g. "ExitGateway").
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

        // Select a proxy outbound in the ExitGateway selector group
        // via LibboxNewStandaloneCommandClient (same IPC used by stopVPN).
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

        // Get the best DNS server by testing latency to multiple DNS servers
        AsyncFunction("getBestDns") { () async -> String in
            return await DnsTester.findBest()
        }

        // ─── Config Fetching (DNS-resolved) ─────────────────────────────────────

        // Fetch a config URL with DNS-resolved primary + optional accelerator fallback.
        // Accelerator URL comes from the JS-pushed shared options (AppGroup UserDefaults).
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

        // ─── Native Background Config Refresh ────────────────────────────────────

        // Push the JS-managed domain allowlist into AppGroup UserDefaults so the
        // BGTaskScheduler worker can verify hostnames without re-fetching the
        // remote list. Called from `domain-verification.ts` after every
        // successful cache update; the worker's 24h TTL gate falls back to the
        // compile-time list when the shared cache is missing or expired.
        AsyncFunction("setVerificationData") { (data: [String: Any]) async in
            let known    = data["knownSha256List"]    as? [String] ?? []
            let verified = data["verifiedSha256List"] as? [String] ?? []
            BackgroundConfigRefresh.saveDomainVerificationCache(known: known, verified: verified)
        }

        // Mirror JS-managed refresh options into AppGroup UserDefaults so the
        // BGTaskScheduler worker never opens the JS-owned SQLite database —
        // a second SQLite library on the same WAL file crashes with SIGBUS.
        AsyncFunction("setBackgroundConfigRefreshOptions") { (options: [String: Any]) async in
            let accelerateUrl = options["accelerateUrl"] as? String ?? ""
            let testFlag      = options["testPrimaryUrlUnavailable"] as? Bool ?? false
            BackgroundConfigRefresh.saveRefreshOptions(
                accelerateUrl: accelerateUrl,
                testPrimaryUrlUnavailable: testFlag
            )
        }

        // Register (or update) the native background config refresh task.
        // Persists URL, userAgent, and interval to AppGroup UserDefaults, then
        // submits a BGAppRefreshTaskRequest so iOS wakes the app periodically.
        AsyncFunction("registerBackgroundConfigRefresh") { (url: String, userAgent: String, intervalSeconds: Int) async in
            BackgroundConfigRefresh.saveConfig(url: url, userAgent: userAgent, intervalSeconds: intervalSeconds)
            BackgroundConfigRefresh.scheduleNextRefresh()
            NSLog("[ExpoOneBox] Background config refresh registered (interval=\(intervalSeconds)s)")
        }

        // Execute a config refresh immediately (used from foreground / dev screen).
        // Uses the same DNS-resolved fetcher as the background task, with accelerator fallback.
        AsyncFunction("executeConfigRefreshNow") { (url: String, userAgent: String) async -> [String: Any] in
            let result = await BackgroundConfigRefresh.executeRefreshWith(url: url, userAgent: userAgent)
            // Do NOT storeResult here: JS receives the result directly and calls
            // applyResultToSBConfig() itself. Storing would overwrite any pending
            // background refresh result and cause the next foreground sync to
            // replay this manual result as a duplicate 'auto' TaskLog entry.
            // (Matches the Android module; the persistence slot is reserved for
            // true background runs — see BackgroundConfigRefresh.registerHandler.)
            return result.toDictionary()
        }

        // Return the last result stored by the background task (or nil if none).
        // Call this on foreground to sync native results into JS state.
        // Clears the stored result after reading so subsequent calls return nil.
        Function("getLastConfigRefreshResult") { () -> [String: Any]? in
            guard let result = BackgroundConfigRefresh.loadLastResult() else { return nil }
            BackgroundConfigRefresh.clearLastResult()
            return result
        }

        // Whether a background refresh task is currently scheduled.
        AsyncFunction("isBackgroundConfigRefreshRegistered") { () async -> Bool in
            await BackgroundConfigRefresh.isRegistered()
        }

        // Copies the bundled asset (sourceUri = file:// URI) into the AppGroup Caches dir as tun.db.
        // Skips if the destination already exists. Returns true if copied, false if skipped.
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

    /// The shared App Group container URL, or nil if unavailable.
    /// Single derivation point for `Self.appGroupID` file access.
    private func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    /// `<AppGroup>/Library/Caches` — must match the extension's FilePath.
    private func appGroupCachesURL() -> URL? {
        appGroupContainerURL()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
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

    private func initializeLibbox() {
        guard !isInitialized else { return }

        // Use App Group shared directory — must match extension's FilePath
        guard let sharedDir = appGroupContainerURL(),
              let cacheDir = appGroupCachesURL() else {
            NSLog("[ExpoOneBox] ERROR: App Group container not available")
            return
        }

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

    // MARK: - Config Processing

    /// Swift equivalent of Android's processConfig.
    /// Rewrites `experimental.cache_file.path` to the absolute path of
    /// `<AppGroup>/Library/Caches/tun.db` so sing-box can find the pre-seeded cache.
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

        // Rewrite experimental.cache_file.path to the correct absolute path
        let processedConfig = processConfig(config)
        self.lastStartConfig = processedConfig
        self.writeLastStartConfig(processedConfig)

        // Prepare options (same dict the extension receives in startTunnel)
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
            // Detect startup failure via the isStartingUp flag, not currentStatus==1:
            // NEVPNStatus can pass through connecting→disconnecting→disconnected, so by the
            // time it reaches disconnected currentStatus is already 3 (disconnecting), not 1.
            let wasStarting = self.isStartingUp
            NSLog("[ExpoOneBox] VPN status: disconnected, wasStarting=\(wasStarting), currentStatus=\(currentStatus)")
            isStartingUp = false
            trafficMonitor?.disconnect()
            trafficMonitor = nil
            updateStatus(0)
            // Actively detect startup failure: read the error from the shared file and push it to JS.
            if wasStarting {
                NSLog("[ExpoOneBox] Startup failure path entered, scheduling error check...")
                // Delay 500ms so the extension process's file write has flushed to disk.
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
                        // Emit a stable machine token, not user-visible text — the
                        // JS layer maps it to a localized string (i18n follow-up owned
                        // by the coordinator). Keeps the native layer i18n-free.
                        self.sendError(type: "StartServiceFailed", message: "START_FAILED_GENERIC", source: "binary")
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

    /// Read the shared startup_error.txt written by the Network Extension on failure.
    /// Returns empty string if the file doesn't exist or the last start succeeded.
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
        // Gate the event emission itself (matching Android's appendLogs), not just
        // the NSLog side-effect — otherwise JS keeps receiving core logs after the
        // user disables them.
        guard coreLogEnabled else { return }
        NSLog("[sing-box] %@", message)
        sendEvent("onLog", [
            "message": message
        ])
    }

    /// Emit a native-layer log line to JS.
    ///
    /// Distinct from `sendLog` (libbox / sing-box core output). This
    /// channel carries the Swift module's own activity — VPN manager
    /// lifecycle, permission flows, Network Extension transitions — so
    /// the user can distinguish "the JS–native bridge is alive" from
    /// "the core is running."
    internal func sendNativeLog(level: String, tag: String, message: String) {
        // Clamp to the level union the JS `onNativeLog` payload declares
        // ('info' | 'warn' | 'error'), mirroring the Kotlin side (D2-16).
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

    internal func sendGroupUpdate(all: [[String: Any]], now: String, autoNow: String) {
        sendEvent("onGroupUpdate", [
            "all": all,
            "now": now,
            "autoNow": autoNow,
        ])
    }

}
