import Foundation

// Host-runnable (`swiftc`) golden-sample runner for the ExitGateway/auto group
// reducer (audit C2 / Batch 3). Compiled with ../core/ExitGatewayParse.swift, it
// asserts the ACTUAL parseExitGatewayGroups against golden/exitgateway.json —
// the same file the Kotlin runner (ExitGatewayParseTest) uses. No simulator:
//
//   swiftc -parse-as-library ios/core/ExitGatewayParse.swift \
//     ios/tests/ExitGatewayGoldenCheck.swift -o /tmp/ec \
//     && /tmp/ec src/modules/expo-onebox/golden/exitgateway.json

@main
enum ExitGatewayGoldenCheck {
    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8))
        exit(1)
    }

    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../golden/exitgateway.json"
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read golden file at \(path)") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cases = root["cases"] as? [[String: Any]] else { fail("bad golden") }

        var checks = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            guard let groupsJson = c["groups"] as? [[String: Any]], let expect = c["expect"] as? [String: Any] else { fail("\(name): missing groups/expect") }
            let snapshots: [ProxyGroupSnapshot] = groupsJson.map { g in
                let items = (g["items"] as? [[String: Any]] ?? []).map {
                    (tag: $0["tag"] as? String ?? "", delay: ($0["delay"] as? NSNumber)?.intValue ?? 0)
                }
                return ProxyGroupSnapshot(tag: g["tag"] as? String ?? "", selected: g["selected"] as? String ?? "", items: items)
            }
            let (all, now, autoNow) = parseExitGatewayGroups(snapshots)
            if now != (expect["now"] as? String ?? "") { fail("\(name): now got \(now)") }
            if autoNow != (expect["autoNow"] as? String ?? "") { fail("\(name): autoNow got \(autoNow)") }
            let wantAll = expect["all"] as? [[String: Any]] ?? []
            if all.count != wantAll.count { fail("\(name): all count \(all.count) want \(wantAll.count)") }
            for (i, item) in all.enumerated() {
                let gt = item["tag"] as? String ?? ""
                let gd = (item["delay"] as? Int) ?? -1
                let wt = wantAll[i]["tag"] as? String ?? ""
                let wd = (wantAll[i]["delay"] as? NSNumber)?.intValue ?? -1
                if gt != wt || gd != wd { fail("\(name): all[\(i)] got (\(gt),\(gd)) want (\(wt),\(wd))") }
            }
            checks += 1
        }
        print("ok - exitgateway golden: \(checks) checks passed")
    }
}
