import Foundation

/// Z-Library EAPI 客户端(登录 / 搜索 / 详情 / 下载)
/// 协议对照 zlib / zlibrary-mcp 等社区实现实测(2026-10)
@MainActor
final class ZLibraryClient {
    static let shared = ZLibraryClient()

    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let session: URLSession
    /// 进行中的下载会话(供取消)
    private var activeDownloadSession: URLSession?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
    }

    // MARK: - 请求

    private func makeRequest(
        _ url: URL,
        method: String = "GET",
        form: [String: String]? = nil,
        cookies: [String: String]
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://\(url.host ?? "")/", forHTTPHeaderField: "Referer")
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var comps = URLComponents()
            comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        }
        if !cookies.isEmpty {
            req.setValue(
                cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "),
                forHTTPHeaderField: "Cookie"
            )
        }
        return req
    }

    private func fetchJSON(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SourceError.network("HTTP \(http.statusCode)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SourceError.network("接口返回异常(域名可能被拦截)")
            }
            return json
        } catch let e as SourceError {
            throw e
        } catch {
            throw SourceError.network(error.localizedDescription)
        }
    }

    // MARK: - 登录

    struct LoginResult {
        var cookies: [String: String]
        var userName: String
        var userId: String
        var downloadsToday: Int
        var downloadsLimit: Int
    }

    func login(domain: String, email: String, password: String) async throws -> LoginResult {
        guard let url = URL(string: "https://\(domain)/eapi/user/login") else {
            throw SourceError.network("域名无效")
        }
        let request = makeRequest(url, method: "POST", form: ["email": email, "password": password], cookies: [:])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.network("响应异常") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.network("该域名不可用(返回的不是接口数据)")
        }
        guard HTMLText.flag(json["success"]) else {
            let msg = HTMLText.string(json["error"])
            throw SourceError.network(msg.isEmpty ? "登录失败" : "登录失败:\(msg)")
        }
        let user = HTMLText.dict(json["user"]) ?? [:]

        // 收集 Set-Cookie(可能有多个头,字段名大小写不定)
        var cookieHeader = ""
        for (k, v) in http.allHeaderFields where String(describing: k).lowercased() == "set-cookie" {
            cookieHeader += String(describing: v) + ", "
        }
        var cookies = Self.parseCookies(cookieHeader)
        if cookies["remix_userkey"] == nil {
            let key = HTMLText.string(user["remix_userkey"])
            if !key.isEmpty { cookies["remix_userkey"] = key }
        }
        guard !cookies.isEmpty else { throw SourceError.network("登录响应缺少 Cookie") }

        return LoginResult(
            cookies: cookies,
            userName: HTMLText.string(user["name"]),
            userId: HTMLText.string(user["id"]),
            downloadsToday: HTMLText.int(user["downloads_today"]) ?? 0,
            downloadsLimit: HTMLText.int(user["downloads_limit"]) ?? 10
        )
    }

    /// 从 Set-Cookie 文本里提取需要的 cookie(避开 Expires 逗号坑)
    static func parseCookies(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for name in ["remix_userid", "remix_userkey", "bsrv", "selectedSiteMode"] {
            if let v = HTMLText.firstCapture(pattern: "\(name)=([^;,\\s]+)", in: header) {
                out[name] = v
            }
        }
        return out
    }

    // MARK: - 业务接口

    func profile(domain: String, cookies: [String: String]) async throws -> (downloadsToday: Int, downloadsLimit: Int) {
        guard let url = URL(string: "https://\(domain)/eapi/user/profile") else {
            throw SourceError.network("域名无效")
        }
        let json = try await fetchJSON(makeRequest(url, cookies: cookies))
        let user = HTMLText.dict(json["user"]) ?? [:]
        return (HTMLText.int(user["downloads_today"]) ?? 0, HTMLText.int(user["downloads_limit"]) ?? 10)
    }

    func search(domain: String, cookies: [String: String], query: String, limit: Int = 25) async throws -> [SourceBook] {
        guard let url = URL(string: "https://\(domain)/eapi/book/search") else {
            throw SourceError.network("域名无效")
        }
        let request = makeRequest(url, method: "POST", form: [
            "message": query,
            "limit": String(limit),
            "extensions": "epub",
        ], cookies: cookies)
        let json = try await fetchJSON(request)
        guard HTMLText.flag(json["success"]) else {
            throw SourceError.network("搜索被拒绝(登录可能已过期)")
        }
        let items = HTMLText.array(json["books"]) ?? []
        return items.compactMap { item in
            guard let b = HTMLText.dict(item) else { return nil }
            return Self.mapSearchItem(b, domain: domain)
        }
    }

    func detail(domain: String, cookies: [String: String], bookID: String) async throws -> SourceBook {
        let (id, hash) = Self.splitBookID(bookID)
        guard let url = URL(string: "https://\(domain)/eapi/book/\(id)/\(hash)") else {
            throw SourceError.network("域名无效")
        }
        let json = try await fetchJSON(makeRequest(url, cookies: cookies))
        guard let b = HTMLText.dict(json["book"]) else {
            throw SourceError.decode("详情数据缺失")
        }
        return Self.mapBookDetail(b, domain: domain, bookID: bookID)
    }

    /// 取下载链(/file 返回 JSON,内含签名 URL;网络抖动自动重试)
    func downloadLink(domain: String, cookies: [String: String], bookID: String) async throws -> String {
        var lastError: Error = SourceError.network("获取下载链接失败")
        for attempt in 0..<2 {
            do {
                return try await downloadLinkOnce(domain: domain, cookies: cookies, bookID: bookID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt < 1 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }
        }
        throw lastError
    }

    private func downloadLinkOnce(domain: String, cookies: [String: String], bookID: String) async throws -> String {
        let (id, hash) = Self.splitBookID(bookID)
        guard let url = URL(string: "https://\(domain)/eapi/book/\(id)/\(hash)/file") else {
            throw SourceError.network("域名无效")
        }
        let json = try await fetchJSON(makeRequest(url, cookies: cookies))
        guard HTMLText.flag(json["success"]),
              let file = HTMLText.dict(json["file"]),
              let link = file["downloadLink"] as? String, !link.isEmpty else {
            throw SourceError.network("下载被拒绝(今日配额可能已用完,或登录已过期)")
        }
        return link
    }

    /// 下载文件(自动跟重定向;带进度回调;网络抖动自动重试)
    func download(from link: String, onProgress: @escaping @MainActor (Double) -> Void) async throws -> Data {
        var lastError: Error = SourceError.network("下载失败")
        for attempt in 0..<3 {
            do {
                return try await downloadOnce(from: link, onProgress: onProgress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError
    }

    private func downloadOnce(from link: String, onProgress: @escaping @MainActor (Double) -> Void) async throws -> Data {
        guard let url = URL(string: link) else { throw SourceError.network("下载地址无效") }
        var req = URLRequest(url: url)
        req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        let delegate = ZLibDownloadDelegate(onProgress: onProgress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        let dlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        activeDownloadSession = dlSession
        defer {
            dlSession.invalidateAndCancel()
            activeDownloadSession = nil
        }
        return try await delegate.run(session: dlSession, request: req)
    }

    /// 取消进行中的下载(用户点「取消」)
    func cancelDownload() {
        activeDownloadSession?.invalidateAndCancel()
        activeDownloadSession = nil
    }

    // MARK: - 映射(可测)

    static func splitBookID(_ bookID: String) -> (String, String) {
        let parts = bookID.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return (bookID, "") }
        return (String(parts[0]), String(parts[1]))
    }

    static func normalizeCover(_ cover: String, domain: String) -> String? {
        guard !cover.isEmpty, !cover.contains("cover-not-exists") else { return nil }
        if cover.hasPrefix("http") { return cover }
        if cover.hasPrefix("/") { return "https://\(domain)\(cover)" }
        return "https://\(domain)/\(cover)"
    }

    static func mapSearchItem(_ b: [String: Any], domain: String) -> SourceBook? {
        let id = HTMLText.string(b["id"])
        let hash = HTMLText.string(b["hash"])
        guard !id.isEmpty, !hash.isEmpty else { return nil }
        var subjects: [String] = []
        let ext = HTMLText.string(b["extension"]).uppercased()
        if !ext.isEmpty { subjects.append(ext) }
        let sizeStr = HTMLText.string(b["filesizeString"])
        if !sizeStr.isEmpty {
            subjects.append(sizeStr)
        } else if let fs = HTMLText.int(b["filesize"]), fs > 0 {
            subjects.append(ByteCountFormatter.string(fromByteCount: Int64(fs), countStyle: .file))
        }
        let year = HTMLText.string(b["year"])
        if !year.isEmpty { subjects.append(year) }
        let lang = HTMLText.string(b["language"])
        if !lang.isEmpty { subjects.append(lang) }
        return SourceBook(
            sourceID: ZLibrarySource.identifier,
            sourceBookID: "\(id):\(hash)",
            title: HTMLText.string(b["title"]),
            author: HTMLText.string(b["author"]),
            cover: normalizeCover(HTMLText.string(b["cover"]), domain: domain),
            language: lang.isEmpty ? nil : lang,
            summary: nil,
            subjects: subjects
        )
    }

    static func mapBookDetail(_ b: [String: Any], domain: String, bookID: String) -> SourceBook {
        var book = mapSearchItem(b, domain: domain) ?? SourceBook(
            sourceID: ZLibrarySource.identifier,
            sourceBookID: bookID,
            title: HTMLText.string(b["title"]),
            author: HTMLText.string(b["author"]),
            cover: nil,
            language: nil,
            summary: nil,
            subjects: []
        )
        book.sourceBookID = bookID
        let desc = HTMLText.cleanInline(HTMLText.string(b["description"]))
        if !desc.isEmpty { book.summary = desc }
        return book
    }
}

/// 下载进度代理:把 URLSessionDownloadTask 的进度与结果桥接为 async
final class ZLibDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @MainActor (Double) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false

    init(onProgress: @escaping @MainActor (Double) -> Void) {
        self.onProgress = onProgress
    }

    func run(session: URLSession, request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let callback = onProgress
        Task { @MainActor in
            callback(p)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(with: .failure(SourceError.network("下载失败 HTTP \(http.statusCode)")))
            return
        }
        let data = (try? Data(contentsOf: location)) ?? Data()
        if data.count > 100 {
            finish(with: .success(data))
        } else {
            finish(with: .failure(SourceError.network("下载内容为空")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success(let data):
            continuation?.resume(returning: data)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
