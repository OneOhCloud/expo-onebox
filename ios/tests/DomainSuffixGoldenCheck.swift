import Foundation

// 可在宿主机用 swiftc 运行的 golden 样本 runner，针对 hostnameSuffixCandidates。
// 与 ../core/DomainSuffix.swift 一起编译，用真实的函数对 golden/domain-suffix.json
// 做断言——与 JS、Kotlin runner 使用同一个文件。无需模拟器：
//
//   swiftc -parse-as-library ios/core/DomainSuffix.swift \
//     ios/tests/DomainSuffixGoldenCheck.swift -o /tmp/ds \
//     && /tmp/ds src/modules/expo-onebox/golden/domain-suffix.json

@main
enum DomainSuffixGoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/domain-suffix.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { fail("bad golden") }

        var checks = 0
        for c in cases {
            guard let hostname = c["hostname"] as? String, let want = c["candidates"] as? [String] else { fail("case missing hostname/candidates") }
            let got = hostnameSuffixCandidates(hostname)
            if got != want { fail("\(hostname): got \(got) want \(want)") }
            checks += 1
        }
        print("ok - domain-suffix golden: \(checks) checks passed")
    }
}
