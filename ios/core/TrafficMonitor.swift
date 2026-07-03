import Foundation
import Libbox

/// 通过 CommandClient 监控来自 Libbox CommandServer 的流量与状态。
/// 接收状态更新（速率、内存、连接数）与日志条目，然后作为 JS 事件转发给
/// ExpoOneBoxModule。
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
        options.addCommand(LibboxCommandGroup)
        options.statusInterval = Int64(NSEC_PER_SEC) // 1 秒更新间隔

        let handler = ClientHandler(monitor: self)

        guard let client = LibboxNewCommandClient(handler, options) else {
            NSLog("[ExpoOneBox] Failed to create CommandClient")
            return
        }

        // 必须在启动后台线程、以及调用阻塞式 connect() 之前就存下 client。这很
        // 关键：client.connect() 会运行整个 IPC 事件循环，只有连接关闭后才返回。
        // 若在 connect() 返回之后才设置 commandClient，disconnect() 就会总是发现
        // commandClient==nil 而变成空操作，导致 Go 侧 CommandServer 的 goroutine
        // 一直存活到 Extension 进程退出。在这里存下它，能让 disconnect() 从任意
        // 线程正确中断进行中的 connect()。
        commandClient = client

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                // 阻塞直到连接关闭（由 disconnect() 或服务端关闭）。
                try client.connect()
            } catch {
                NSLog("[ExpoOneBox] CommandClient connect error: \(error.localizedDescription)")
            }
            // 连接完全结束后清除存下的引用。
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
        // 客户端侧过滤：sing-box 的 log.level 配置不作用于 platform writer
        //（我们的 IPC 来源），因此在序列化成 JS 事件之前，这里丢弃高于用户所选
        // 上限的条目。见 ExpoOneBoxModule.coreLogLevelMax。
        guard let module else { return }
        if level > module.coreLogLevelMax { return }
        module.sendLog(message: message)
    }

    fileprivate func onGroupUpdate(all: [[String: Any]], now: String, autoNow: String) {
        module?.sendGroupUpdate(all: all, now: now, autoNow: autoNow)
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
        // 空操作
    }

    func setDefaultLogLevel(_ level: Int32) {
        // 空操作
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message, let monitor else { return }
        let (all, now, autoNow) = parseExitGatewayGroups(snapshotGroups(message))
        monitor.onGroupUpdate(all: all, now: now, autoNow: autoNow)
    }

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {
        // 空操作
    }

    func updateClashMode(_ newMode: String?) {
        // 空操作
    }

    func write(_ events: LibboxConnectionEvents?) {
        // 空操作——基础流量展示不需要连接事件监控
    }
}
