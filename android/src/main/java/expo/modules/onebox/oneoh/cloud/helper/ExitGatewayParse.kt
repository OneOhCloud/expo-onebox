package expo.modules.onebox.oneoh.cloud.helper

// Single source for the proxy-group tag names (audit C2 / Batch 3).
const val GROUP_EXIT_GATEWAY = "ExitGateway"
const val GROUP_AUTO = "auto"

// Plain, libbox-free snapshot of one outbound group. The libbox OutboundGroup
// iterator is adapted into these at each call site so the reducer below is pure
// and unit-testable.
data class ProxyGroupSnapshot(
    val tag: String,
    val selected: String,
    val items: List<Pair<String, Int>>,
)

// Reduce the group snapshots into the (all, now, autoNow) shape the JS layer
// consumes. Locked by golden/exitgateway.json against the Swift twin.
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
