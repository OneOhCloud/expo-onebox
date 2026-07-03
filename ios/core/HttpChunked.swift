import Foundation

/// 把 HTTP/1.1 分块传输体（RFC 7230 §4.1）解码为原始字节。这是 iOS 手写
/// fetcher 专用的解析器——Android 的 fetcher 把分块解码交给 OkHttp，因此这里
/// 只守护 iOS 手写路径。刻意宽容：遇到第一个非法长度或被截断的分块即停止，
/// 返回已解码的部分。`;` 之后的 chunk extension 会被忽略；终止的 0 长度分块
/// 结束循环。
enum HttpChunked {
    static func decode(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        let crlf   = Data([0x0D, 0x0A])

        while offset < data.count {
            guard let eol = data.range(of: crlf, in: offset ..< data.count) else { break }
            let sizeLine = String(data: data[offset ..< eol.lowerBound], encoding: .utf8) ?? ""
            // 剥离 chunk extension（例如 "1a; ext=foo" → "1a"）
            let sizeHex  = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let chunkSize = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize > 0 else { break }

            let start = eol.upperBound
            let end   = start + chunkSize
            guard end <= data.count else { break }
            result.append(data[start ..< end])
            let nextOffset = end + 2   // 跳过分块数据后的 \r\n
            guard nextOffset <= data.count else { break }
            offset = nextOffset
        }
        return result
    }
}
