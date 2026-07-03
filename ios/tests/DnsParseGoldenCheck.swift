import Foundation

// 可在宿主机用 swiftc 运行的 golden 样本 runner，针对 DNS A 记录解析器。
// 与 ../core/DnsParse.swift 一起编译，用真实的 parseFirstARecord 对
// golden/dns-arecord.json 做断言——与 Kotlin runner（DnsParseTest）使用同一个
// 文件。无需模拟器：
//
//   swiftc -parse-as-library ios/core/DnsParse.swift \
//     ios/tests/DnsParseGoldenCheck.swift -o /tmp/dc \
//     && /tmp/dc src/modules/expo-onebox/golden/dns-arecord.json

@main
enum DnsParseGoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx ..< next], radix: 16) else { fail("bad hex") }
            out.append(b); idx = next
        }
        return out
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/dns-arecord.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { fail("bad golden") }

        var checks = 0
        for c in cases {
            guard let hex = c["responseHex"] as? String, let want = c["expect"] as? String else { fail("case missing responseHex/expect") }
            let name = c["name"] as? String ?? "?"
            let buf = hexToBytes(hex)
            // 报文头校验（txID/RCODE）在调用方；这里传入从字节 6-7 读出的答案
            // 数量，与生产调用点一致。
            let ancount = Int((UInt16(buf[6]) << 8) | UInt16(buf[7]))
            guard let got = try? parseFirstARecord(from: buf, length: buf.count, ancount: ancount) else { fail("\(name): parser threw") }
            if got != want { fail("\(name): got \(got) want \(want)") }
            checks += 1
        }
        print("ok - dns a-record golden: \(checks) checks passed")
    }
}
