package expo.modules.onebox.oneoh.cloud.helper

import expo.modules.onebox.oneoh.cloud.core.ProxyService
import expo.modules.onebox.oneoh.cloud.core.VPNService

/**
 * 服务模式枚举。
 */
enum class ServiceMode {
    /** VPN 模式：使用 VpnService 创建 TUN 接口 */
    VPN,
    /** 代理模式：使用普通 Service，不创建 TUN 接口 */
    PROXY
}

/**
 * 服务模式设置。
 * 根据当前模式动态选择使用 VPNService 或 ProxyService。
 *
 * - 预处理阶段（下载规则集）：serviceMode = PROXY → ProxyService
 * - 正常 VPN 运行阶段：serviceMode = VPN → VPNService
 */
object Settings {
    var serviceMode: ServiceMode = ServiceMode.VPN

    /**
     * 返回当前模式对应的 Service 类。
     * VPN 模式 → VPNService（创建 TUN 接口）
     * PROXY 模式 → ProxyService（普通代理，不创建 TUN）
     */
    fun serviceClass(): Class<*> = when (serviceMode) {
        ServiceMode.VPN -> VPNService::class.java
        ServiceMode.PROXY -> ProxyService::class.java
    }
}
