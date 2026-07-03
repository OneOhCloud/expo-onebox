import Foundation

// 可在宿主机用 swiftc 运行的 golden 样本 runner，针对共享的 userinfo 解析器。
// 与 ../core/UserinfoParser.swift 一起编译，用真实抽出的解析器对
// golden/userinfo.json 做断言——与 JS（profile-info.test.ts）、Kotlin
//（ParseUserinfoTest）runner 使用同一个文件。无需 iOS 模拟器，在宿主 Swift
// 工具链上运行：
//
//   swiftc -parse-as-library ios/core/UserinfoParser.swift \
//     ios/tests/UserinfoGoldenCheck.swift -o /tmp/uc \
//     && /tmp/uc src/modules/expo-onebox/golden/userinfo.json
//
// 放在 ios/tests/ 下，这样 podspec（source_files = *.swift, core/*.swift）不会
// 把它编进发布的模块里。

@main
enum UserinfoGoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func int64(_ v: Any?) -> Int64 {
        guard let n = v as? NSNumber else { fail("expected a number, got \(String(describing: v))") }
        return n.int64Value
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/userinfo.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { fail("golden is not a JSON object") }

        var checks = 0

        guard let cases = root["cases"] as? [[String: Any]] else { fail("missing cases[]") }
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let header = c["header"] as? String   // JSON null 对应 nil
            guard let expect = c["expect"] as? [String: Any] else { fail("\(name): missing expect") }
            let got = parseUserinfo(header)
            let have = [got.upload, got.download, got.total, got.expire]
            let want = [int64(expect["upload"]), int64(expect["download"]), int64(expect["total"]), int64(expect["expire"])]
            if have != want { fail("\(name): got \(have) want \(want)") }
            checks += 1
        }

        guard let divs = root["knownDivergences"] as? [[String: Any]] else { fail("missing knownDivergences[]") }
        for d in divs {
            let name = d["name"] as? String ?? "?"
            let header = d["header"] as? String
            // JS 保留一个有损的大数；Swift 的 Int64 解析器会溢出为 0。
            if parseUserinfo(header).total != 0 { fail("\(name): expected native total == 0") }
            checks += 1
        }

        print("ok - userinfo golden: \(checks) checks passed")
    }
}
