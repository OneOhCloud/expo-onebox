import ExpoModulesCore
import Libbox

public class ExpoOneBoxModule: Module {

    private var commandServer: LibboxCommandServer?
    private var platformInterface: PlatformInterfaceImpl?
    private var trafficMonitor: TrafficMonitor?
    private var currentStatus: Int = 0 // 0=Stopped, 1=Starting, 2=Started, 3=Stopping
    private var isInitialized = false

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

        AsyncFunction("checkVpnPermission") { () -> Bool in
            // iOS does not have a VPN permission dialog like Android.
            // VPN is configured via Settings or NETunnelProviderManager.
            return true
        }

        AsyncFunction("requestVpnPermission") { () -> Bool in
            // iOS does not have a VPN permission dialog like Android.
            return true
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

        let basePath = documentsDir.path
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

        // Start the sing-box service with the provided config
        let overrideOptions = LibboxOverrideOptions()
        do {
            try server.startOrReloadService(config, options: overrideOptions)
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
