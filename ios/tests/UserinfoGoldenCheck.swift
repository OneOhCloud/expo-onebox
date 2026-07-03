import Foundation

// Host-runnable (`swiftc`) golden-sample runner for the shared userinfo parser
// (audit C6 / D3c-03 / Batch 3). Compiled together with ../core/UserinfoParser.swift,
// it asserts the ACTUAL extracted parser against golden/userinfo.json — the same
// file the JS (profile-info.test.ts) and Kotlin (ParseUserinfoTest) runners use.
// No iOS simulator required; runs on the host Swift toolchain:
//
//   swiftc -parse-as-library ios/core/UserinfoParser.swift \
//     ios/tests/UserinfoGoldenCheck.swift -o /tmp/uc \
//     && /tmp/uc src/modules/expo-onebox/golden/userinfo.json
//
// Lives under ios/tests/ so the podspec (source_files = *.swift, core/*.swift)
// does not compile it into the shipped module.

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
            let header = c["header"] as? String   // nil for JSON null
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
            // JS keeps a lossy large number; the Swift Int64 parser overflows to 0.
            if parseUserinfo(header).total != 0 { fail("\(name): expected native total == 0") }
            checks += 1
        }

        print("ok - userinfo golden: \(checks) checks passed")
    }
}
