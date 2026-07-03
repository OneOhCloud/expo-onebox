import Foundation

// subscription-userinfo HTTP 头解析器的跨平台纯核心。从 BackgroundConfigRefresh
// 中抽出，以便独立做单元测试。

struct UserinfoTraffic {
    let upload: Int64
    let download: Int64
    let total: Int64
    let expire: Int64
}

func parseUserinfo(_ header: String?) -> UserinfoTraffic {
    func extract(_ key: String, from str: String) -> Int64 {
        guard let range = str.range(of: "\(key)=(\\d+)", options: .regularExpression) else { return 0 }
        let match = String(str[range])
        let value = match.replacingOccurrences(of: "\(key)=", with: "")
        return Int64(value) ?? 0
    }
    let h = header ?? ""
    return UserinfoTraffic(
        upload:   extract("upload", from: h),
        download: extract("download", from: h),
        total:    extract("total", from: h),
        expire:   extract("expire", from: h)
    )
}
