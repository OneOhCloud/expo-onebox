import Foundation
import Libbox
import Network
import UserNotifications

/// Implements Libbox's PlatformInterface and CommandServerHandler protocols for iOS.
///
/// This runs in the main app process (not a Network Extension), so:
/// - `openTun` is not supported (requires NEPacketTunnelProvider)
/// - Network monitoring works via NWPathMonitor
/// - Notifications use UNUserNotificationCenter
/// - sing-box runs as a proxy service (HTTP/SOCKS5 inbound)
class PlatformInterfaceImpl: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {

    private weak var module: ExpoOneBoxModule?
    private var nwMonitor: NWPathMonitor?

    init(module: ExpoOneBoxModule) {
        self.module = module
        super.init()
    }

    // MARK: - LibboxPlatformInterfaceProtocol

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(
            domain: "ExpoOneBox",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "TUN mode requires a Network Extension target. Use proxy inbound (HTTP/SOCKS5) for in-process mode."]
        )
    }

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func autoDetectControl(_ fd: Int32) throws {
        // Not applicable without Network Extension
    }

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw NSError(
            domain: "ExpoOneBox",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner is not supported on iOS without Network Extension"]
        )
    }

    func useProcFS() -> Bool {
        false
    }

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }

        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handleNetworkPathUpdate(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        semaphore.wait()
    }

    private func handleNetworkPathUpdate(_ listener: any LibboxInterfaceUpdateListenerProtocol, _ path: NWPath) {
        guard path.status != .unsatisfied,
              let defaultInterface = path.availableInterfaces.first
        else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name,
            interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            return NetworkInterfaceArray([])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }

        var interfaces: [LibboxNetworkInterface] = []
        for it in path.availableInterfaces {
            let iface = LibboxNetworkInterface()
            iface.name = it.name
            iface.index = Int32(it.index)
            switch it.type {
            case .wifi:
                iface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                iface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                iface.type = LibboxInterfaceTypeEthernet
            default:
                iface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(iface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    func underNetworkExtension() -> Bool {
        false
    }

    func includeAllNetworks() -> Bool {
        false
    }

    func clearDNSCache() {
        // No-op without Network Extension tunnel settings
    }

    func readWIFIState() -> LibboxWIFIState? {
        // Requires NEHotspotNetwork + special entitlement; return nil for now
        nil
    }

    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        if !notification.openURL.isEmpty {
            content.userInfo["OPEN_URL"] = notification.openURL
            content.categoryIdentifier = "OPEN_URL"
        }
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        )

        try runBlocking {
            try await center.requestAuthorization(options: [.alert, .sound])
            try await center.add(request)
        }
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    // MARK: - LibboxCommandServerHandlerProtocol

    func serviceStop() throws {
        DispatchQueue.main.async { [weak self] in
            self?.module?.handleServiceStopped()
        }
    }

    func serviceReload() throws {
        // Reload not supported in in-process mode.
        // Users should call stop() then start() with a new config.
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        return LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        // Not supported in in-process mode
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        module?.sendLog(message: message)
    }

    // MARK: - Cleanup

    func reset() {
        nwMonitor?.cancel()
        nwMonitor = nil
    }
}

// MARK: - NetworkInterfaceArray

/// Wraps a Swift array of LibboxNetworkInterface into an iterator protocol that Libbox expects.
private class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
        super.init()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}
