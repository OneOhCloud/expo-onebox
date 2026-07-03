import Foundation

// Host-runnable (`swiftc`) golden-sample runner for the shared SHA-256 hex core
// (audit C4 / Batch 3). Compiled together with ../core/Sha256.swift, it asserts
// the ACTUAL sha256HexString against golden/sha256.json — the same file the JS
// (sha256.test.ts) and Kotlin (Sha256Test) runners use. No simulator required:
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
