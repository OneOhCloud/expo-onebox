import Foundation
import Libbox

/// Monitors traffic and status from the Libbox CommandServer using a CommandClient.
/// Receives status updates (speed, memory, connections) and log entries,
/// then forwards them to the ExpoOneBoxModule as JS events.
class TrafficMonitor: NSObject {

    private weak var module: ExpoOneBoxModule?
    private var commandClient: LibboxCommandClient?

    init(module: ExpoOneBoxModule) {
        self.module = module
        super.init()
    }

    func connect() {
        guard commandClient == nil else { return }

        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandLog)
        options.statusInterval = Int64(NSEC_PER_SEC) // 1-second update interval

        let handler = ClientHandler(monitor: self)

        guard let client = LibboxNewCommandClient(handler, options) else {
            NSLog("[ExpoOneBox] Failed to create CommandClient")
            return
        }

        // Store the client BEFORE launching the background thread and before calling
        // the blocking connect().  This is critical: client.connect() runs the entire
        // IPC event loop and only returns after the connection is closed.  If we set
        // commandClient *after* connect() returns (old code), disconnect() would always
        // find commandClient==nil and be a no-op, leaving the Go-side CommandServer
        // goroutines alive until the Extension process exits.  Storing it here lets
        // disconnect() correctly interrupt an in-progress connect() from any thread.
        commandClient = client

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                // Blocks until the connection is closed (by disconnect() or server side).
                try client.connect()
            } catch {
                NSLog("[ExpoOneBox] CommandClient connect error: \(error.localizedDescription)")
            }
            // Clear the stored reference once the connection is fully done.
            self?.commandClient = nil
        }
    }

    func disconnect() {
        guard let client = commandClient else { return }
        commandClient = nil
        try? client.disconnect()
    }

    // MARK: - Handler Callbacks (called by ClientHandler)

    fileprivate func onStatusUpdate(_ status: LibboxStatusMessage) {
        module?.sendTrafficUpdate(status)
    }

    fileprivate func onLogMessage(level: Int32, message: String) {
        module?.sendLog(message: message)
    }

    private func logLevelName(_ level: Int32) -> String {
        switch level {
        case 2: return "ERROR"
        case 3: return "WARN"
        case 4: return "INFO"
        case 5: return "DEBUG"
        case 6: return "TRACE"
        default: return "LOG"
        }
    }
}

// MARK: - LibboxCommandClientHandlerProtocol

private class ClientHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private weak var monitor: TrafficMonitor?

    init(monitor: TrafficMonitor) {
        self.monitor = monitor
        super.init()
    }

    func connected() {
        NSLog("[ExpoOneBox] TrafficMonitor connected to CommandServer")
    }

    func disconnected(_ message: String?) {
        if let message {
            NSLog("[ExpoOneBox] TrafficMonitor disconnected: \(message)")
        }
    }

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message, let monitor else { return }
        monitor.onStatusUpdate(message)
    }

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        guard let messageList, let monitor else { return }
        while messageList.hasNext() {
            if let entry = messageList.next() {
                monitor.onLogMessage(level: entry.level, message: entry.message)
            }
        }
    }

    func clearLogs() {
        // No-op
    }

    func setDefaultLogLevel(_ level: Int32) {
        // No-op
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        // No-op - groups monitoring not needed for basic traffic display
    }

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {
        // No-op
    }

    func updateClashMode(_ newMode: String?) {
        // No-op
    }

    func write(_ events: LibboxConnectionEvents?) {
        // No-op - connection event monitoring not needed for basic traffic display
    }
}
