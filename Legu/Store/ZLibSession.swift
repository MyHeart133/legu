import Foundation

/// Z-Library 账号会话:登录态 / Cookie / 域名(仅存本机 Documents/legu.zlib.json,不入任何仓库)
@MainActor
final class ZLibSession: ObservableObject {
    static let shared = ZLibSession()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var userName = ""
    @Published private(set) var downloadsToday = 0
    @Published private(set) var downloadsLimit = 10
    @Published private(set) var activeDomain = ""
    @Published private(set) var preferredDomain = "z-lib.sk"
    @Published private(set) var savedEmail = ""

    private var password = ""
    private var cookies: [String: String] = [:]
    private let fileURL: URL

    private struct Snapshot: Codable {
        var email: String
        var password: String
        var preferredDomain: String
        var activeDomain: String
        var cookies: [String: String]
        var userName: String
        var downloadsToday: Int
        var downloadsLimit: Int
    }

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("legu.zlib.json")
        load()
    }

    var savedPassword: String { password }
    var currentCookies: [String: String] { cookies }

    /// 当前生效域名(未登录时用首选)
    var domain: String {
        activeDomain.isEmpty ? preferredDomain : activeDomain
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        savedEmail = snap.email
        password = snap.password
        preferredDomain = snap.preferredDomain
        activeDomain = snap.activeDomain
        cookies = snap.cookies
        userName = snap.userName
        downloadsToday = snap.downloadsToday
        downloadsLimit = snap.downloadsLimit
        isLoggedIn = !cookies.isEmpty
    }

    private func save() {
        let snap = Snapshot(
            email: savedEmail,
            password: password,
            preferredDomain: preferredDomain,
            activeDomain: activeDomain,
            cookies: cookies,
            userName: userName,
            downloadsToday: downloadsToday,
            downloadsLimit: downloadsLimit
        )
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 登录 / 退出

    /// 登录:按「首选域名(默认 z-lib.sk)→ 官方备选域名」逐个尝试,成功即记住
    func login(email: String, password: String, preferredDomain rawDomain: String) async throws {
        let cleaned = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pref = Self.normalizeDomain(rawDomain)

        var candidates: [String] = []
        if !pref.isEmpty { candidates.append(pref) }
        for d in ["z-lib.gd", "z-lib.gl", "article.sk", "articles.sk", "z-library.sk", "1lib.sk"]
        where !candidates.contains(d) {
            candidates.append(d)
        }

        var lastError: Error = SourceError.network("登录失败")
        for d in candidates {
            do {
                let result = try await ZLibraryClient.shared.login(domain: d, email: cleaned, password: password)
                cookies = result.cookies
                userName = result.userName
                downloadsToday = result.downloadsToday
                downloadsLimit = result.downloadsLimit
                activeDomain = d
                savedEmail = cleaned
                self.password = password
                self.preferredDomain = pref.isEmpty ? d : pref
                isLoggedIn = true
                save()
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    func logout() {
        cookies = [:]
        isLoggedIn = false
        userName = ""
        activeDomain = ""
        save()
    }

    /// 刷新下载额度
    func refreshProfile() async {
        guard isLoggedIn else { return }
        if let p = try? await ZLibraryClient.shared.profile(domain: domain, cookies: cookies) {
            downloadsToday = p.downloadsToday
            downloadsLimit = p.downloadsLimit
            save()
        }
    }

    /// 认证失效(配额/过期)时调用
    func handleAuthFailure() {
        logout()
    }

    static func normalizeDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
        d = d.replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") {
            d = String(d[..<slash])
        }
        return d
    }
}
