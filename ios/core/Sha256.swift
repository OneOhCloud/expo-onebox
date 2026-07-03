import CryptoKit
import Foundation

// 共享纯核心：SHA256(utf8(string)) 的小写十六进制——域名路由 key
//（BackgroundConfigRefresh）与日志中短 host 摘要（ConfigFetcher.hostHash8）的
// 唯一来源。不依赖 Network 栈，可独立做单元测试。
func sha256HexString(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
