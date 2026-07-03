import Foundation

// Single source for the proxy-group tag names (was duplicated as string
// literals across the status monitor and the one-shot query).
let exitGatewayGroupTag = "ExitGateway"
let autoGroupTag = "auto"

// Plain, libbox-free snapshot of one outbound group. The libbox
// OutboundGroup iterator is adapted into these at each call site so the reducer
// below is pure and unit-testable (audit C2 / D3c-05 / Batch 3).
struct ProxyGroupSnapshot {
    let tag: String
    let selected: String
    let items: [(tag: String, delay: Int)]
}

// Reduce the group snapshots into the { all, now, autoNow } shape the JS layer
// consumes. Locked by golden/exitgateway.json against the Kotlin twin.
func parseExitGatewayGroups(_ groups: [ProxyGroupSnapshot]) -> (all: [[String: Any]], now: String, autoNow: String) {
    var all: [[String: Any]] = []
    var now = ""
    var autoNow = ""
    for group in groups {
        if group.tag == exitGatewayGroupTag {
            now = group.selected
            for item in group.items {
                all.append(["tag": item.tag, "delay": item.delay])
            }
            continue
        }
        if group.tag == autoGroupTag {
            autoNow = group.selected
        }
    }
    return (all, now, autoNow)
}
