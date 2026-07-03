package expo.modules.onebox.oneoh.cloud.helper

// proxy-group tag 名称的单一来源。
const val GROUP_EXIT_GATEWAY = "ExitGateway"
const val GROUP_AUTO = "auto"

// 单个 outbound group 的纯（不依赖 libbox）快照。libbox 的 OutboundGroup
// 迭代器会在每个调用点被适配成这些快照，使下面的 reducer 是纯的、可单测。
data class ProxyGroupSnapshot(
    val tag: String,
    val selected: String,
    val items: List<Pair<String, Int>>,
)

// 把 group 快照归约成 JS 层消费的 (all, now, autoNow) 形态，
// 需与 Swift 对应实现保持一致。
internal fun parseExitGatewayGroups(
    groups: List<ProxyGroupSnapshot>,
): Triple<List<Map<String, Any>>, String, String> {
    val all = mutableListOf<Map<String, Any>>()
    var now = ""
    var autoNow = ""
    for (group in groups) {
        when (group.tag) {
            GROUP_EXIT_GATEWAY -> {
                now = group.selected
                for ((tag, delay) in group.items) {
                    all.add(mapOf("tag" to tag, "delay" to delay))
                }
            }
            GROUP_AUTO -> autoNow = group.selected
        }
    }
    return Triple(all, now, autoNow)
}
