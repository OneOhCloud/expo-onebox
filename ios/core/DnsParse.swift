import Foundation

enum DnsParseError: Error { case noARecord }

// 纯粹的 DNS A 记录答案遍历器：跳过 QNAME、处理压缩指针、按 rdlength 跳过
// 非 A 记录（如 CNAME）、提取首个 A 记录。不依赖 Network 栈，因此可脱离设备
// 做单元测试。调用方负责校验报文头（transaction id、RCODE）并传入答案数量。
// 与 Kotlin ConfigFetcher.kt 的 parseFirstARecord 保持一致。
func parseFirstARecord(from buf: [UInt8], length: Int, ancount: Int) throws -> String {
    var off = 12
    // 跳过 question 的 QNAME
    while off < length {
        let b = Int(buf[off])
        if b == 0          { off += 1; break }
        if (b & 0xC0) == 0xC0 { off += 2; break }
        off += 1 + b
    }
    off += 4   // QTYPE + QCLASS（跳过）

    for _ in 0 ..< ancount {
        guard off < length else { break }
        if (Int(buf[off]) & 0xC0) == 0xC0 { off += 2 }
        else {
            while off < length {
                let b = Int(buf[off])
                if b == 0 { off += 1; break }
                off += 1 + b
            }
        }
        guard off + 10 <= length else { break }
        let rrType   = (UInt16(buf[off]) << 8) | UInt16(buf[off + 1])
        let rdlength = Int((UInt16(buf[off + 8]) << 8) | UInt16(buf[off + 9]))
        off += 10
        if rrType == 0x0001 && rdlength == 4 && off + 4 <= length {
            return "\(buf[off]).\(buf[off+1]).\(buf[off+2]).\(buf[off+3])"
        }
        off += rdlength
    }
    throw DnsParseError.noARecord
}
