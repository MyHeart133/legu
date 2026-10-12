import CryptoKit
import Foundation

/// 微软 Edge 神经音色引擎(免费在线通道,社区同款协议)
///
/// 协议要点:
/// - WebSocket 带 Sec-MS-GEC 时钟校验令牌(SHA256)+ 浏览器请求头(裸连 403)
/// - 2026-10 微软灰度迁移:新端点 api.msedgeservices.com(Edge 155 起);
///   旧端点 speech.platform.bing.com 在已灰度地区会被 403 —— 双端点自动互为备胎
/// - 先发 speech.config(输出 mp3),再发 SSML;二进制帧前 2 字节为大端头长度
/// - 收到 Path:turn.end 文本帧表示合成完毕;失败自动重试 + 切换端点
final class EdgeTTSEngine: TTSEngine {
    let identifier = "edge"
    let displayName = "微软神经音色(在线)"
    let isRemote = true

    static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let secMsGecVersion = "1-143.0.3650.75"
    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"

    /// 新端点(2026-10 起微软迁移目标;实测:新主机 + 现有令牌可用)
    static let wssURLNew = "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1?Ocp-Apim-Subscription-Key=\(trustedToken)"
    /// 旧端点(灰度期未迁移地区仍可用)
    static let wssURLLegacy = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)"
    /// 端点偏好(失败自动切换,进程内记忆)
    private static var preferNewEndpoint = true

    /// 内置音色(14 个中文;动态列表失败时兜底)
    static let builtinVoices: [TTSVoice] = [
        TTSVoice(id: "zh-CN-XiaoxiaoNeural", name: "晓晓", detail: "普通话 · 女 · 自然"),
        TTSVoice(id: "zh-CN-XiaoyiNeural", name: "晓伊", detail: "普通话 · 女 · 年轻"),
        TTSVoice(id: "zh-CN-YunxiNeural", name: "云希", detail: "普通话 · 男 · 阳光"),
        TTSVoice(id: "zh-CN-YunjianNeural", name: "云健", detail: "普通话 · 男 · 浑厚"),
        TTSVoice(id: "zh-CN-YunxiaNeural", name: "云夏", detail: "普通话 · 男 · 少年"),
        TTSVoice(id: "zh-CN-YunyangNeural", name: "云扬", detail: "普通话 · 男 · 播报"),
        TTSVoice(id: "zh-CN-liaoning-XiaobeiNeural", name: "晓北", detail: "东北话 · 女"),
        TTSVoice(id: "zh-CN-shaanxi-XiaoniNeural", name: "晓妮", detail: "陕西话 · 女"),
        TTSVoice(id: "zh-HK-HiuGaaiNeural", name: "HiuGaai", detail: "粤语 · 女"),
        TTSVoice(id: "zh-HK-HiuMaanNeural", name: "HiuMaan", detail: "粤语 · 女"),
        TTSVoice(id: "zh-HK-WanLungNeural", name: "WanLung", detail: "粤语 · 男"),
        TTSVoice(id: "zh-TW-HsiaoChenNeural", name: "曉臻", detail: "台湾 · 女"),
        TTSVoice(id: "zh-TW-HsiaoYuNeural", name: "曉雨", detail: "台湾 · 女"),
        TTSVoice(id: "zh-TW-YunJheNeural", name: "雲哲", detail: "台湾 · 男"),
    ]

    func availableVoices() async -> [TTSVoice] {
        Self.builtinVoices
    }

    // MARK: - 合成

    /// 对外入口:失败自动重试,并在新旧端点间切换(灰度期两端可用性不同)
    func synthesize(text: String, voiceID: String, rate: Float) async throws -> Data? {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await synthesizeOnce(
                    text: text, voiceID: voiceID, rate: rate,
                    useNewEndpoint: Self.preferNewEndpoint
                )
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                Self.preferNewEndpoint.toggle()
                if attempt < 2 {
                    // 稍缓的重试间隔(避免对限流 / 抖动雪上加霜)
                    try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
                    if Task.isCancelled { throw CancellationError() }
                }
            }
        }
        throw lastError ?? SourceError.network("语音合成失败")
    }

    private func synthesizeOnce(text: String, voiceID: String, rate: Float, useNewEndpoint: Bool) async throws -> Data? {
        let pool = EdgeConnectionPool.shared
        var connection = await pool.borrow(isNewEndpoint: useNewEndpoint)
        let isReused = connection != nil
        if connection == nil {
            connection = Self.makeConnection(isNewEndpoint: useNewEndpoint)
        }
        guard let conn = connection else {
            throw SourceError.network("语音服务连接失败")
        }

        do {
            let audio = try await Self.runRequest(on: conn, text: text, voiceID: voiceID, rate: rate)
            var updated = conn
            updated.configSent = true
            await pool.giveBack(updated)
            if isReused {
                await pool.noteBorrowedSuccess()
            }
            return audio
        } catch {
            conn.task.cancel(with: .normalClosure, reason: nil)
            conn.session.invalidateAndCancel()
            if isReused, !Task.isCancelled, !(error is CancellationError) {
                await pool.noteBorrowedFailure()
            }
            throw error
        }
    }

    private static func makeConnection(isNewEndpoint: Bool) -> EdgeConnectionPool.Entry? {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let base = isNewEndpoint ? wssURLNew : wssURLLegacy
        let urlString = "\(base)&Sec-MS-GEC=\(secMsGec())&Sec-MS-GEC-Version=\(secMsGecVersion)&ConnectionId=\(connectionID)"
        guard let url = URL(string: urlString) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: handshakeRequest(url: url))
        task.resume()
        return EdgeConnectionPool.Entry(
            task: task, session: session,
            isNewEndpoint: isNewEndpoint, configSent: false, createdAt: Date()
        )
    }

    private static func runRequest(
        on connection: EdgeConnectionPool.Entry,
        text: String,
        voiceID: String,
        rate: Float
    ) async throws -> Data {
        let task = connection.task

        // 1. 配置帧(每条连接只发一次;复用时跳过)
        if !connection.configSent {
            let config = "X-Timestamp:\(timestampString())\r\n"
                + "Content-Type:application/json; charset=utf-8\r\n"
                + "Path:speech.config\r\n\r\n"
                + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
                + "\r\n"
            try await task.send(.string(config))
        }

        // 2. SSML 帧
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let ssml = makeSSML(text: text, voice: voiceID, rate: rate)
        let ssmlMessage = "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestampString())Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
        try await task.send(.string(ssmlMessage))

        // 3. 收音频(必须收到 turn.end,否则连接作废交由上层重试)
        var audio = Data()
        var reachedEnd = false
        let deadline = Date().addingTimeInterval(40)
        while Date() <= deadline, !reachedEnd {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                break
            }
            switch message {
            case .string(let textMessage):
                if textMessage.contains("Path:turn.end") {
                    reachedEnd = true
                }
            case .data(let data):
                let bytes = [UInt8](data)
                guard bytes.count >= 2 else { continue }
                let headerLength = Int(bytes[0]) << 8 | Int(bytes[1])
                let audioStart = 2 + headerLength
                if audioStart < bytes.count {
                    audio.append(contentsOf: bytes[audioStart...])
                }
            @unknown default:
                break
            }
        }
        guard reachedEnd else { throw SourceError.decode("语音合成超时(连接作废)") }
        guard !audio.isEmpty else { throw SourceError.decode("语音合成失败(空音频)") }
        return audio
    }

    // MARK: - 握手(可测)

    /// WebSocket 握手请求:必须伪装成 Edge 浏览器,否则服务端 403
    static func handshakeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(randomMuid());", forHTTPHeaderField: "Cookie")
        return request
    }

    /// 随机 MUID(32 位大写十六进制,edge-tts 同款)
    static func randomMuid() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - 协议工具(可测)

    /// Sec-MS-GEC:自 1601 年起的 100ns 计时(向下取整到 5 分钟)+ token 的 SHA256 大写十六进制
    static func secMsGec(now: Date = Date()) -> String {
        var ticks = now.timeIntervalSince1970 + 11644473600.0
        ticks -= ticks.truncatingRemainder(dividingBy: 300.0)
        let value = Int64((ticks * 10_000_000.0).rounded())
        let input = "\(value)\(trustedToken)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func timestampString(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: now)
    }

    static func makeSSML(text: String, voice: String, rate: Float) -> String {
        let percent = Int(((rate - 1.0) * 100).rounded())
        let rateString = percent >= 0 ? "+\(percent)%" : "\(percent)%"
        let escaped = escapeXML(text)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody pitch='+0Hz' rate='\(rateString)' volume='+0%'>"
            + escaped
            + "</prosody></voice></speak>"
    }

    static func escapeXML(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'", with: "&apos;")
        return s
    }
}

/// 共享 WebSocket 连接池:复用连接省去每句一次的 TLS 握手(省电 + 降低被限流概率)
/// 安全退化:复用连接连续失败 3 次 → 判定服务端不支持复用,本次进程内不再池化
actor EdgeConnectionPool {
    static let shared = EdgeConnectionPool()

    struct Entry {
        let task: URLSessionWebSocketTask
        let session: URLSession
        let isNewEndpoint: Bool
        var configSent: Bool
        let createdAt: Date
    }

    /// 空闲连接最长保留时间(避开服务端空闲断开)
    private static let maxIdleAge: TimeInterval = 90

    private var idle: Entry?
    private var reuseDisabled = false
    private var borrowedFailures = 0
    private var idleCloseTask: Task<Void, Never>?

    func borrow(isNewEndpoint: Bool) -> Entry? {
        idleCloseTask?.cancel()
        idleCloseTask = nil
        guard !reuseDisabled else { return nil }
        guard let entry = idle else { return nil }
        idle = nil
        if entry.isNewEndpoint != isNewEndpoint || Date().timeIntervalSince(entry.createdAt) > Self.maxIdleAge {
            entry.task.cancel(with: .normalClosure, reason: nil)
            entry.session.invalidateAndCancel()
            return nil
        }
        return entry
    }

    func giveBack(_ entry: Entry) {
        guard !reuseDisabled, idle == nil else {
            entry.task.cancel(with: .normalClosure, reason: nil)
            entry.session.invalidateAndCancel()
            return
        }
        idle = entry
        scheduleIdleClose()
    }

    /// 空闲超时自动关闭连接(避免闲置时被服务端心跳持续唤醒,省电)
    private func scheduleIdleClose() {
        idleCloseTask?.cancel()
        idleCloseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.closeIdle()
        }
    }

    private func closeIdle() {
        if let entry = idle {
            entry.task.cancel(with: .normalClosure, reason: nil)
            entry.session.invalidateAndCancel()
            idle = nil
        }
    }

    func noteBorrowedSuccess() {
        borrowedFailures = 0
    }

    func noteBorrowedFailure() {
        borrowedFailures += 1
        if borrowedFailures >= 3 {
            reuseDisabled = true
            idleCloseTask?.cancel()
            idleCloseTask = nil
            closeIdle()
        }
    }
}
