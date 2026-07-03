import Foundation

// Cross-platform pure core for the `subscription-userinfo` HTTP header parser
// (audit C6 / D3c-03 / Batch 3). Extracted out of BackgroundConfigRefresh so it
// can be unit-tested in isolation. Behaviour is locked by
// golden/userinfo.json — the same file the JS (profile-info.test.ts) and Kotlin
// (ParseUserinfoTest) runners assert against — and verified here by the host
// `swiftc` runner ios/tests/UserinfoGoldenCheck.swift.

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
