import CryptoKit
import Foundation

// Shared pure core: lowercase hex of SHA256(utf8(string)) — the single source
// for the domain routing key (BackgroundConfigRefresh) and the short host digest
// used in logs (ConfigFetcher.hostHash8). Extracted from ConfigFetcher so it is
// unit-testable in isolation without pulling in the Network stack. Locked by
// golden/sha256.json across JS, Kotlin and Swift (audit C4 / Batch 3); asserted
// by ios/tests/Sha256GoldenCheck.swift (host `swiftc`, no simulator).
func sha256HexString(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}
