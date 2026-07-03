import Foundation

// Host-runnable (`swiftc`) golden-sample runner for hostnameSuffixCandidates
// (audit C2 / D3c-02). Compiled with ../core/DomainSuffix.swift, it asserts the
// ACTUAL function against golden/domain-suffix.json — the same file the JS and
// Kotlin runners use. No simulator:
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
