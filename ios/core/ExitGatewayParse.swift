import Foundation

// proxy-group tag 名称的唯一来源；status monitor 与一次性查询都从这里读取，
// 不要再散布字符串字面量。
let exitGatewayGroupTag = "ExitGateway"
let autoGroupTag = "auto"

// 单个 outbound group 的朴素、不依赖 libbox 的快照。libbox 的 OutboundGroup
// 迭代器在每个调用点被适配成这个结构，从而让下面的 reducer 保持纯粹、可单元测试。
struct ProxyGroupSnapshot {
    let tag: String
    let selected: String
    let items: [(tag: String, delay: Int)]
}

// 把 group 快照归约为 JS 层消费的 { all, now, autoNow } 结构。
// 与 Kotlin 版实现保持一致。
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
