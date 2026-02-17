import ExpoModulesCore
import Libbox
import NetworkExtension

public class ExpoOneBoxModule: Module {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: PlatformInterfaceImpl?
    private var trafficMonitor: TrafficMonitor?
    private var currentStatus: Int = 0 // 0=Stopped, 1=Starting, 2=Started, 3=Stopping
    private var isInitialized = false
    private var vpnManager: NETunnelProviderManager?

    public func definition() -> ModuleDefinition {
        Name("ExpoOneBox")

        Events("onStatusChange", "onError", "onLog", "onTrafficUpdate")

        OnCreate {
            self.initializeLibbox()
        }

        OnDestroy {
            self.stopServiceInternal()
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
            // Check if a VPN configuration profile is already installed
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
            // Install or update the VPN profile. iOS will show a system "Allow VPN" prompt
            // if no profile is installed yet, or if the user previously removed it.
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                let manager = managers.first ?? NETunnelProviderManager()

                manager.localizedDescription = "OneBox VPN"

                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = Bundle.main.bundleIdentifier
                proto.serverAddress = "sing-box"
                manager.protocolConfiguration = proto
                manager.isEnabled = true

                // This triggers the system "Allow VPN Configurations" dialog
                try await manager.saveToPreferences()

                // Re-load to get the updated state after user approval
                try await manager.loadFromPreferences()

                self.vpnManager = manager
                NSLog("[ExpoOneBox] VPN profile installed, enabled=\(manager.isEnabled)")
                return manager.isEnabled
            } catch {
                NSLog("[ExpoOneBox] requestVpnPermission error: \(error.localizedDescription)")
                return false
            }
        }

        AsyncFunction("start") { (config: String) in
            try self.startService(config: config)
        }

        AsyncFunction("stop") {
            self.stopServiceInternal()
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

        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            NSLog("[ExpoOneBox] Failed to get documents directory")
            return
        }

        // Unix socket path limit is 104 bytes on macOS/iOS.
        // Simulator container paths are very long (~170 chars), so we use /tmp/ as basePath
        // on the simulator. On real devices, container paths are short (~60 chars).
        let basePath: String
        #if targetEnvironment(simulator)
        let bundleID = Bundle.main.bundleIdentifier ?? "expo-onebox"
        let simBase = URL(fileURLWithPath: "/tmp/\(bundleID)")
        try? FileManager.default.createDirectory(at: simBase, withIntermediateDirectories: true)
        basePath = simBase.path
        #else
        basePath = documentsDir.path
        #endif

        let workingDir = documentsDir.appendingPathComponent("working")
        let tempDir = FileManager.default.temporaryDirectory

        // Ensure directories exist
        try? FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)

        let options = LibboxSetupOptions()
        options.basePath = basePath
        options.workingPath = workingDir.path
        options.tempPath = tempDir.path
        options.logMaxLines = 3000
        #if DEBUG
        options.debug = true
        #else
        options.debug = false
        #endif

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            NSLog("[ExpoOneBox] Setup error: \(setupError.localizedDescription)")
            return
        }

        // Redirect stderr for crash debugging
        let stderrPath = tempDir.appendingPathComponent("stderr.log").path
        var stderrError: NSError?
        LibboxRedirectStderr(stderrPath, &stderrError)
        if let stderrError {
            NSLog("[ExpoOneBox] Redirect stderr error: \(stderrError.localizedDescription)")
        }

        LibboxSetMemoryLimit(false) // No strict memory limit in main app

        isInitialized = true
        NSLog("[ExpoOneBox] Libbox initialized successfully, version: \(LibboxVersion())")
    }

    // MARK: - Service Management

    private func startService(config: String) throws {
        guard isInitialized else {
            let error = NSError(domain: "ExpoOneBox", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Libbox not initialized"
            ])
            sendError(type: "StartService", message: error.localizedDescription, source: "module")
            throw error
        }

        // Stop any existing service first
        stopServiceInternal()

        updateStatus(1) // Starting

        // Create platform interface
        let pi = PlatformInterfaceImpl(module: self)
        self.platformInterface = pi

        // Create CommandServer
        var serverError: NSError?
        let server = LibboxNewCommandServer(pi, pi, &serverError)
        if let serverError {
            updateStatus(0)
            platformInterface = nil
            sendError(type: "CreateService", message: serverError.localizedDescription, source: "binary")
            throw serverError
        }

        guard let server else {
            updateStatus(0)
            platformInterface = nil
            let error = NSError(domain: "ExpoOneBox", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create command server"
            ])
            sendError(type: "CreateService", message: error.localizedDescription, source: "module")
            throw error
        }

        self.commandServer = server

        // Start CommandServer
        do {
            try server.start()
        } catch {
            updateStatus(0)
            self.commandServer = nil
            platformInterface = nil
            sendError(type: "StartCommandServer", message: error.localizedDescription, source: "module")
            throw error
        }

        // Process config: fix cache-file path for iOS
        let processedConfig = processConfig(config)

        // Start the sing-box service with the provided config
        let overrideOptions = LibboxOverrideOptions()
        do {
            try server.startOrReloadService(processedConfig, options: overrideOptions)
        } catch {
            updateStatus(0)
            server.close()
            self.commandServer = nil
            platformInterface = nil
            sendError(type: "StartService", message: error.localizedDescription, source: "binary")
            throw error
        }

        updateStatus(2) // Started

        // Start traffic monitoring via CommandClient
        let monitor = TrafficMonitor(module: self)
        self.trafficMonitor = monitor
        monitor.connect()

        NSLog("[ExpoOneBox] Service started successfully")
    }

    // MARK: - Config Processing

    /// Rewrites cache-file and rule-set paths in the config JSON
    /// so they point to a valid iOS-writable directory.
    private func processConfig(_ config: String) -> String {
        guard let data = config.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            NSLog("[ExpoOneBox] Failed to parse config JSON, using as-is")
            return config
        }

        let workingDir = getWorkingDir()
        let cacheDir = workingDir + "/cache"
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        // Fix experimental.cache_file.path
        if var experimental = json["experimental"] as? [String: Any] {
            if var cacheFile = experimental["cache_file"] as? [String: Any] {
                if cacheFile["path"] != nil {
                    cacheFile["path"] = cacheDir + "/cache.db"
                    experimental["cache_file"] = cacheFile
                    json["experimental"] = experimental
                    NSLog("[ExpoOneBox] Rewrote cache_file.path → \(cacheDir)/cache.db")
                }
            }
            json["experimental"] = experimental
        }

        guard let outputData = try? JSONSerialization.data(withJSONObject: json),
              let outputString = String(data: outputData, encoding: .utf8)
        else {
            return config
        }
        return outputString
    }

    private func getWorkingDir() -> String {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return dir.appendingPathComponent("working").path
        }
        return NSTemporaryDirectory()
    }

    private func stopServiceInternal() {
        guard currentStatus == 2 || currentStatus == 1 else { return }

        let wasStarted = currentStatus == 2
        updateStatus(3) // Stopping

        // Disconnect traffic monitor first
        trafficMonitor?.disconnect()
        trafficMonitor = nil

        // Close the service
        if let server = commandServer {
            do {
                try server.closeService()
            } catch {
                NSLog("[ExpoOneBox] Close service error: \(error.localizedDescription)")
            }
            server.close()
            commandServer = nil
        }

        // Reset platform interface
        platformInterface?.reset()
        platformInterface = nil

        updateStatus(0) // Stopped

        if wasStarted {
            NSLog("[ExpoOneBox] Service stopped")
        }
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

    // MARK: - Service Callback

    /// Called by PlatformInterfaceImpl when the service stops externally (e.g., libbox error).
    internal func handleServiceStopped() {
        trafficMonitor?.disconnect()
        trafficMonitor = nil

        // Don't call closeService() — the service is already stopping.
        // Just close the command server.
        if let server = commandServer {
            server.close()
            commandServer = nil
        }

        platformInterface?.reset()
        platformInterface = nil

        if currentStatus != 0 {
            updateStatus(0) // Stopped
        }

        NSLog("[ExpoOneBox] Service stopped by external event")
    }
}
