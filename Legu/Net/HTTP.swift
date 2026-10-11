import Foundation

/// 网络层:URLSession 封装 + 编码识别 + 表单编码
enum HTTP {
    /// 移动端浏览器 UA(多数小说站对移动 UA 返回更稳定的模板)
    static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static let desktopUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/125.0 Safari/537.36"

    enum TextEncoding {
        case utf8
        case gb18030

        init?(label: String?) {
            guard let l = label?.lowercased(), !l.isEmpty else { return nil }
            if l.contains("gbk") || l.contains("gb2312") || l.contains("gb18030") || l.contains("gb_2312") {
                self = .gb18030
            } else if l.contains("utf") {
                self = .utf8
            } else {
                return nil
            }
        }
    }

    static func session(timeout: TimeInterval = 25) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 3
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9"]
        return URLSession(configuration: config)
    }

    // MARK: - 请求

    static func fetchData(
        _ url: URL,
        session: URLSession,
        headers: [String: String] = [:],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SourceError.network("HTTP \(http.statusCode)")
            }
            return (data, response)
        } catch let e as SourceError {
            throw e
        } catch {
            throw SourceError.network(error.localizedDescription)
        }
    }

    /// 抓取并按编码解码为文本。
    /// 编码判定优先级:显式 hint > HTTP 头 charset > 页面 meta charset > UTF-8
    static func fetchHTML(
        _ url: URL,
        session: URLSession,
        headers: [String: String] = [:],
        method: String = "GET",
        form: [String: String]? = nil,
        body: Data? = nil,
        encoding: TextEncoding? = nil
    ) async throws -> String {
        var all = headers
        all["User-Agent"] = all["User-Agent"] ?? mobileUA
        var bodyData = body
        if let form {
            bodyData = encodeForm(form, encoding: .utf8)
        }
        let (data, response) = try await fetchData(url, session: session, headers: all, method: method, body: bodyData)
        let headerCharset = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            .flatMap { Self.charsetLabel(in: $0) }
        let resolved = encoding ?? TextEncoding(label: headerCharset) ?? sniffEncoding(data) ?? .utf8
        return decode(data, encoding: resolved)
    }

    static func fetchJSON(
        _ url: URL,
        session: URLSession,
        headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        var all = headers
        all["User-Agent"] = all["User-Agent"] ?? mobileUA
        let (data, _) = try await fetchData(url, session: session, headers: all)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.decode("响应不是有效 JSON")
        }
        return obj
    }

    // MARK: - 编码

    static func decode(_ data: Data, encoding: TextEncoding) -> String {
        switch encoding {
        case .utf8:
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .gb18030:
            let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            if let s = NSString(data: data, encoding: cfEncoding) {
                return s as String
            }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
    }

    /// 从响应头/HTML 片段里嗅探 charset
    static func sniffEncoding(_ data: Data) -> TextEncoding? {
        let head = data.prefix(4096)
        guard let ascii = String(data: head, encoding: .isoLatin1) else { return nil }
        if let label = charsetLabel(in: ascii) {
            return TextEncoding(label: label)
        }
        return nil
    }

    static func charsetLabel(in text: String) -> String? {
        guard let range = text.range(of: "charset=", options: .caseInsensitive) else { return nil }
        let tail = text[range.upperBound...]
        var label = ""
        for ch in tail {
            if ch == "\"" || ch == "'" || ch == ">" || ch == ";" || ch == " " || ch == "\n" || ch == "\r" {
                break
            }
            label.append(ch)
            if label.count > 20 { break }
        }
        return label.isEmpty ? nil : label
    }

    /// 表单编码(指定字符集)
    static func encodeForm(_ form: [String: String], encoding: TextEncoding) -> Data {
        let pairs = form.map { k, v in
            "\(percentEncode(k, encoding: encoding))=\(percentEncode(v, encoding: encoding))"
        }
        let joined = pairs.joined(separator: "&")
        switch encoding {
        case .utf8:
            return Data(joined.utf8)
        case .gb18030:
            let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return (joined as NSString).data(using: cfEncoding) ?? Data(joined.utf8)
        }
    }

    /// 百分号转义(按指定字符集,用于 URL 参数与表单)
    static func percentEncode(_ s: String, encoding: TextEncoding) -> String {
        let bytes: [UInt8]
        switch encoding {
        case .utf8:
            bytes = Array(s.utf8)
        case .gb18030:
            let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            bytes = Array((s as NSString).data(using: cfEncoding) ?? Data(s.utf8))
        }
        var out = ""
        out.reserveCapacity(bytes.count * 3)
        for b in bytes {
            let c = Character(UnicodeScalar(b))
            if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9")
                || c == "-" || c == "_" || c == "." || c == "~" {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// GBK 百分号转义(GBK 站点搜索参数)
    static func percentEncodedGBK(_ s: String) -> String {
        percentEncode(s, encoding: .gb18030)
    }

    /// 同步抓取(供书源 JS 的 java.ajax 使用)
    static func fetchDataSync(_ urlString: String, timeout: TimeInterval = 20) -> String {
        guard let url = URL(string: urlString) else { return "" }
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        var request = URLRequest(url: url)
        request.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, _, _ in
            if let data {
                result = decode(data, encoding: sniffEncoding(data) ?? .utf8)
            }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        session.invalidateAndCancel()
        return result
    }
}
