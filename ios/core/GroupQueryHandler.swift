import ExpoModulesCore
@preconcurrency import Libbox

// MARK: - Shared group-parse helpers

/// Adapts a libbox outbound-group iterator into plain snapshots for the pure
/// reducer `parseExitGatewayGroups` (core/ExitGatewayParse.swift). The tag
/// constants and the reducer live there so both stay libbox-free and testable
/// (audit C2 / Batch 3).
func snapshotGroups(_ iterator: any LibboxOutboundGroupIteratorProtocol) -> [ProxyGroupSnapshot] {
    var out: [ProxyGroupSnapshot] = []
    while let group = iterator.next() {
        var items: [(tag: String, delay: Int)] = []
        if let it = group.getItems() {
            while let item = it.next() {
                items.append((tag: item.tag, delay: Int(item.urlTestDelay)))
            }
        }
        out.append(ProxyGroupSnapshot(tag: group.tag, selected: group.selected, items: items))
    }
    return out
}

// MARK: - One-shot proxy group query handler

/// Connects to the libbox CommandServer, waits for the first CommandGroup update,
/// extracts ExitGateway group info, then disconnects.
class OneShotGroupQueryHandler: NSObject, LibboxCommandClientHandlerProtocol, @unchecked Sendable {
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
        // Capture a strong reference NOW, while we are still guaranteed to be executing
        // inside libbox's client.connect() call (i.e. the connect-closure's strong `client`
        // is still alive on the stack).  If we only use [weak self]/self?.client in the
        // async block, connect() can return and ARC can deallocate the client before the
        // block runs, making the weak reference nil and leaving the Go-side CommandServer
        // goroutines permanently leaked (one goroutine-set per poll cycle → slow growth).
        let clientToDisconnect = client   // strong capture, breaks free from the weak var
        DispatchQueue.global().async {
            _ = try? clientToDisconnect?.disconnect()
        }
        switch result {
        case .success(let val): continuation.resume(returning: val)
        case .failure(let err): continuation.resume(throwing: err)
        }
    }

    func fail(_ error: Error) { settle(.failure(error)) }
    func timeout() { settle(.success(["all": [] as [[String: Any]], "now": "", "autoNow": ""])) }

    func connected() {}
    func disconnected(_ message: String?) {
        settle(.success(["all": [] as [[String: Any]], "now": "", "autoNow": ""]))
    }

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let message else { return }
        let groups = parseExitGatewayGroups(snapshotGroups(message))
        settle(.success(["all": groups.all, "now": groups.now, "autoNow": groups.autoNow]))
    }

    // writeLogs forwards sing-box log lines; libbox checks respondsToSelector before calling.
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        guard let messageList else { return }
        while let msg = messageList.next() {
            NSLog("[sing-box] %@", msg.message)
        }
    }

    // Unused callbacks — no-ops; libbox checks respondsToSelector before calling.
    func writeStatus(_ message: LibboxStatusMessage?) {}
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
}
