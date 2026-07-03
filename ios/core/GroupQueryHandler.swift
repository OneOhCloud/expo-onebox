import ExpoModulesCore
@preconcurrency import Libbox

// MARK: - Shared group-parse helpers

/// 把 libbox 的 outbound-group 迭代器适配成朴素快照，供纯 reducer
/// parseExitGatewayGroups（core/ExitGatewayParse.swift）使用。tag 常量与 reducer
/// 都放在那里，以保持二者不依赖 libbox 且可测试。
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
