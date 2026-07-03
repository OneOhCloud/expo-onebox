import Foundation

/// 主 App 与 Network Extension 之间共享的文件路径。
/// 严格遵循 sing-box-for-apple 的 FilePath 模式。
enum FilePath {
    /// App Group 标识符——必须与两个 target 的 entitlements 一致
    static let appGroupID = "group.cloud.oneoh.networktools"

    /// 主 App 与 extension 均可访问的共享容器目录
    static let sharedDirectory: URL =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!

    /// 缓存目录：sharedDirectory/Library/Caches
    static let cacheDirectory: URL = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    /// 工作目录：cacheDirectory/Working
    static let workingDirectory: URL = cacheDirectory
        .appendingPathComponent("Working", isDirectory: true)
}
