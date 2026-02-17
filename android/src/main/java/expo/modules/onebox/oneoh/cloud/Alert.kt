package expo.modules.onebox.oneoh.cloud

/**
 * VPN 服务告警类型枚举
 */
enum class Alert {
    RequestVPNPermission,
    RequestNotificationPermission,
    RequestLocationPermission,
    EmptyConfiguration,
    StartCommandServer,
    CreateService,
    StartService;
}
