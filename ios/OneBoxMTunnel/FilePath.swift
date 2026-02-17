import Foundation

/// Shared file paths between the main app and the Network Extension.
/// Strictly follows sing-box-for-apple's FilePath pattern.
enum FilePath {
    /// App Group identifier - must match in both targets' entitlements
    static let appGroupID = "group.cloud.oneoh.networktools"

    /// Shared container directory accessible by both app and extension
    static let sharedDirectory: URL =
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!

    /// Cache directory: sharedDirectory/Library/Caches
    static let cacheDirectory: URL = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    /// Working directory: cacheDirectory/Working
    static let workingDirectory: URL = cacheDirectory
        .appendingPathComponent("Working", isDirectory: true)
}
