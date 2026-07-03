import Foundation

// 可在宿主机用 swiftc 运行的 golden 样本 runner，针对共享的 SHA-256 十六进制
// 核心。与 ../core/Sha256.swift 一起编译，用真实的 sha256HexString 对
// golden/sha256.json 做断言——与 JS（sha256.test.ts）、Kotlin（Sha256Test）
// runner 使用同一个文件。无需模拟器：
//
//   swiftc -parse-as-library ios/core/Sha256.swift \
//     ios/tests/Sha256GoldenCheck.swift -o /tmp/sc \
//     && /tmp/sc src/modules/expo-onebox/golden/sha256.json

@main
enum Sha256GoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/sha256.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { fail("golden is not a JSON object") }
        guard let cases = root["cases"] as? [[String: Any]] else { fail("missing cases[]") }

        var checks = 0
        for c in cases {
            guard let input = c["input"] as? String, let want = c["hex"] as? String else { fail("case missing input/hex") }
            let got = sha256HexString(input)
            if got != want { fail("sha256(\(input)): got \(got) want \(want)") }
            checks += 1
        }
        print("ok - sha256 golden: \(checks) checks passed")
    }
}
