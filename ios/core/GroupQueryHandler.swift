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
