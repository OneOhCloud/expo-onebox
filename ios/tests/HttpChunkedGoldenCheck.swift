import Foundation

// Host-runnable (`swiftc`) golden runner for the iOS hand-written chunked-transfer
// decoder (audit D3c-08). Compiled with ../core/HttpChunked.swift, it asserts the
// ACTUAL HttpChunked.decode against golden/http-chunked.json. No simulator needed:
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
