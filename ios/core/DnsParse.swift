import Foundation

enum DnsParseError: Error { case noARecord }

// Pure DNS A-record answer walker (audit C7 / D3c-04 / Batch 3). Extracted from
// ConfigFetcher so the answer-parsing logic — QNAME skip, compression pointers,
// non-A record (e.g. CNAME) skipping via rdlength, first-A extraction — can be
// unit-tested against golden/dns-arecord.json without the Network stack. The
// caller validates the header (transaction id, RCODE) and passes the answer
// count. Mirrors the Kotlin parseFirstARecord in ConfigFetcher.kt.
func parseFirstARecord(from buf: [UInt8], length: Int, ancount: Int) throws -> String {
    var off = 12
    // Skip question QNAME
    while off < length {
        let b = Int(buf[off])
        if b == 0          { off += 1; break }
        if (b & 0xC0) == 0xC0 { off += 2; break }
        off += 1 + b
    }
    off += 4   // QTYPE + QCLASS

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
