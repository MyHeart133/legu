import CommonCrypto
import CryptoKit
import Foundation

/// 七猫免费小说适配器
///
/// - 接口:`api-bc.wtzw.com` / `api-ks.wtzw.com`(客户端同款公开接口)
/// - 签名:参数按 key 排序拼接 + 固定 salt 的 MD5(`sign` 字段/请求头各一份)
/// - 正文:AES-128-CBC 加密(base64 → 前 16 字节为 IV),密钥为 16 位 ASCII 口令
final class QimaoSource: ContentSource {
    let identifier = "qimao"
    let displayName = "七猫免费小说"
    let capabilities = SourceCapabilities(
        search: true, metadata: true, onlineReading: true,
        requiresAccount: false, allowsOffline: true
    )

    // MARK: 常量

    static let signKey = "d3dGiJc651gSQ8w1"
    static let appVersion = "73720"

    private let apiSearch = "https://api-bc.wtzw.com/search/v1/words"
    private let apiDetail = "https://api-bc.wtzw.com/api/v1/reader/detail"
    private let apiCatalog = "https://api-ks.wtzw.com/api/v1/chapter/chapter-list"
    private let apiContent = "https://api-ks.wtzw.com/api/v1/chapter/content"

    private let session = HTTP.session(timeout: 25)

    // MARK: - ContentSource

    func search(_ query: String) async throws -> [SourceBook] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let json = try await getJSON(apiSearch, [
            "extend": "", "tab": "0", "gender": "0", "refresh_state": "8",
            "page": "1", "wd": trimmed, "is_short_story_user": "0",
        ])
        let data = HTMLText.dict(json["data"])
        let books = HTMLText.array(data?["books"]) ?? []
        return books.compactMap { Self.mapSearchBook(HTMLText.dict($0)) }
    }

    func fetchDetail(_ bookID: String) async throws -> SourceBook {
        let json = try await getJSON(apiDetail, ["id": bookID])
        guard let d = HTMLText.dict(json["data"]), !d.isEmpty else {
            throw SourceError.notFound
        }
        return Self.mapDetail(d)
    }

    func fetchChapterList(_ bookID: String) async throws -> [SourceChapter] {
        let json = try await getJSON(apiCatalog, ["chapter_ver": "0", "id": bookID])
        let data = HTMLText.dict(json["data"])
        let list = HTMLText.array(data?["chapter_lists"]) ?? []
        let chapters = list.compactMap { item -> SourceChapter? in
            guard let c = HTMLText.dict(item) else { return nil }
            let cid = HTMLText.string(c["id"])
            guard !cid.isEmpty else { return nil }
            return SourceChapter(
                id: cid,
                index: 0,
                title: HTMLText.cleanInline(HTMLText.string(c["title"])),
                isFree: true
            )
        }
        return chapters.enumerated().map { i, c in
            var c = c
            c.index = i + 1
            if c.title.isEmpty { c.title = "第\(i + 1)章" }
            return c
        }
    }

    func fetchChapterContent(_ bookID: String, chapterID: String) async throws -> String {
        let json = try await getJSON(apiContent, ["id": bookID, "chapterId": chapterID])
        let data = HTMLText.dict(json["data"])
        let base64 = HTMLText.string(data?["content"])
        guard !base64.isEmpty else {
            throw SourceError.unsupported("该章暂无内容(可能需登录或已下架)")
        }
        return try Self.decryptChapter(base64)
    }

    // MARK: - 请求

    private func getJSON(_ url: String, _ params: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: url)
        comps?.queryItems = Self.signedQuery(params).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let finalURL = comps?.url else {
            throw SourceError.network("请求参数无效")
        }
        let json = try await HTTP.fetchJSON(finalURL, session: session, headers: Self.signedHeaders())
        if let err = HTMLText.dict(json["errors"]) {
            let code = HTMLText.string(err["code"])
            let title = HTMLText.string(err["title"])
            throw SourceError.network("七猫接口错误 \(code) \(title)")
        }
        return json
    }

    // MARK: - 签名(可测)

    /// 参数签名:按 key 升序 `k=v` 拼接 + salt,MD5 后写入 `sign`
    static func signedQuery(_ params: [String: String]) -> [String: String] {
        var out = params
        let raw = params.keys.sorted().map { "\($0)=\(params[$0]!)" }.joined() + signKey
        out["sign"] = md5Hex(raw)
        return out
    }

    /// 请求头签名:同规则,外加 User-Agent
    static func signedHeaders() -> [String: String] {
        var h: [String: String] = [
            "AUTHORIZATION": "",
            "app-version": appVersion,
            "application-id": "com.kmxs.reader",
            "channel": "unknown",
            "net-env": "1",
            "platform": "android",
            "qm-params": "",
            "reg": "0",
        ]
        let raw = h.keys.sorted().map { "\($0)=\(h[$0]!)" }.joined() + signKey
        h["sign"] = md5Hex(raw)
        h["User-Agent"] = "okhttp/4.9.3"
        return h
    }

    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 正文解密(可测)

    /// base64 → [16 字节 IV][密文],AES-128-CBC/PKCS7,密钥为 ASCII 口令
    static func decryptChapter(_ base64: String) throws -> String {
        guard let raw = Data(base64Encoded: base64), raw.count > 16 else {
            throw SourceError.decode("章节内容格式异常")
        }
        let iv = Data(raw.prefix(16))
        let cipher = Data(raw.dropFirst(16))
        let key = Data("242ccb8230d709e1".utf8)

        var out = Data(count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            cipher.withUnsafeBytes { cipherBuf -> CCCryptorStatus in
                iv.withUnsafeBytes { ivBuf -> CCCryptorStatus in
                    key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            cipherBuf.baseAddress, cipher.count,
                            outBuf.baseAddress, outBuf.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved > 0,
              let text = String(data: out.prefix(moved), encoding: .utf8) else {
            throw SourceError.decode("章节内容解密失败")
        }
        return text
    }

    // MARK: - 映射(可测)

    static func mapSearchBook(_ d: [String: Any]?) -> SourceBook? {
        guard let d else { return nil }
        let id = HTMLText.string(d["id"])
        let title = HTMLText.cleanInline(HTMLText.string(d["title"]))
        let original = HTMLText.cleanInline(HTMLText.string(d["original_title"]))
        let finalTitle = title.isEmpty ? original : title
        guard !id.isEmpty, !finalTitle.isEmpty else { return nil }
        let tags = HTMLText.cleanInline(HTMLText.string(d["ptags"]))
        return SourceBook(
            sourceID: "qimao",
            sourceBookID: id,
            title: finalTitle,
            author: HTMLText.cleanInline(HTMLText.string(d["author"])),
            cover: HTMLText.string(d["image_link"]).nonEmpty,
            language: "zh",
            summary: HTMLText.cleanInline(HTMLText.string(d["intro"])).nonEmpty,
            subjects: tags.isEmpty ? [] : tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }

    static func mapDetail(_ d: [String: Any]) -> SourceBook {
        let id = HTMLText.string(d["id"])
        let tags = HTMLText.cleanInline(HTMLText.string(d["label"]))
        var subjects = tags.isEmpty ? [] : tags.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if HTMLText.flag(d["is_over"]) {
            subjects.append("完结")
        }
        let latest = HTMLText.cleanInline(HTMLText.string(d["latest_chapter_title"]))
        if !latest.isEmpty {
            subjects.append("最新:\(latest)")
        }
        return SourceBook(
            sourceID: "qimao",
            sourceBookID: id,
            title: HTMLText.cleanInline(HTMLText.string(d["title"])),
            author: HTMLText.cleanInline(HTMLText.string(d["author"])),
            cover: HTMLText.string(d["image_link"]).nonEmpty,
            language: "zh",
            summary: HTMLText.cleanInline(HTMLText.string(d["intro"])).nonEmpty,
            subjects: subjects
        )
    }
}

// MARK: - 小工具

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
