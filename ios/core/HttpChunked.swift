import Foundation

/// Decodes an HTTP/1.1 chunked-transfer body (RFC 7230 §4.1) into the raw bytes.
/// Extracted from the hand-written iOS fetcher so the error-prone parser is unit-
/// testable against golden/http-chunked.json (audit D3c-08) — the Android fetcher
/// delegates chunk decoding to OkHttp, so this only guards the iOS hand-written
/// path. Lenient by design: stops at the first malformed length or truncated
/// chunk, returning what was decoded so far (matches the fetcher's prior inline
/// behavior). Chunk extensions after a `;` are ignored; the terminating 0-length
/// chunk ends the loop.
enum HttpChunked {
    static func decode(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        let crlf   = Data([0x0D, 0x0A])

        while offset < data.count {
            guard let eol = data.range(of: crlf, in: offset ..< data.count) else { break }
            let sizeLine = String(data: data[offset ..< eol.lowerBound], encoding: .utf8) ?? ""
            // Strip chunk extensions (e.g. "1a; ext=foo" → "1a")
            let sizeHex  = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize > 0 else { break }

            let start = eol.upperBound
            let end   = start + chunkSize
            guard end <= data.count else { break }
            result.append(data[start ..< end])
            let nextOffset = end + 2   // skip trailing \r\n after chunk data
            guard nextOffset <= data.count else { break }
            offset = nextOffset
        }
        return result
    }
}
