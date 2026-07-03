import Foundation

// 可在宿主机用 swiftc 运行的 golden runner，针对 iOS 手写的分块传输解码器。
// 与 ../core/HttpChunked.swift 一起编译，用真实的 HttpChunked.decode 对
// golden/http-chunked.json 做断言。无需模拟器：
//
//   swiftc -parse-as-library ios/core/HttpChunked.swift \
//     ios/tests/HttpChunkedGoldenCheck.swift -o /tmp/hc \
//     && /tmp/hc src/modules/expo-onebox/golden/http-chunked.json

@main
enum HttpChunkedGoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func hexToData(_ s: String) -> Data {
        var out = Data(); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx ..< next], radix: 16) else { fail("bad hex") }
            out.append(b); idx = next
        }
        return out
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/http-chunked.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { fail("bad golden") }

        var checks = 0
        for c in cases {
            guard let hex = c["inputHex"] as? String, let want = c["expect"] as? String else { fail("case missing inputHex/expect") }
            let name = c["name"] as? String ?? "?"
            let decoded = HttpChunked.decode(hexToData(hex))
            let got = String(data: decoded, encoding: .utf8) ?? "<non-utf8>"
            if got != want { fail("\(name): got \(got) want \(want)") }
            checks += 1
        }
        print("ok - http chunked golden: \(checks) checks passed")
    }
}
