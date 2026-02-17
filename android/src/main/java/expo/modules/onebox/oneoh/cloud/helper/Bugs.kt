package expo.modules.onebox.oneoh.cloud.helper

/**
 * Android 平台相关 Bug 修复标志
 */
object Bugs {
    /**
     * 是否修复 Android 栈追踪问题。
     * 在 Android 上 libbox 的 Go 运行时可能产生不完整的栈追踪，
     * 该标志启用修复。
     */
    val fixAndroidStack: Boolean
        get() = true
}
