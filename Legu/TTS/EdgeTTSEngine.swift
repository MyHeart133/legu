import CryptoKit
import Foundation

/// 微软 Edge 神经音色引擎(免费在线通道,社区同款协议)
///
/// 协议要点:
/// - WebSocket 到 speech.platform.bing.com,带 Sec-MS-GEC 时钟校验令牌(SHA256)
/// - 先发 speech.config(输出 mp3),再发 SSML;二进制帧前 2 字节为大端头长度
/// - 收到 Path:turn.end 文本帧表示合成完毕
final class EdgeTTSEngine: TTSEngine {
    let identifier = "edge"
    let displayName = "微软神经音色(在线)"
    let isRemote = true

    static let trustedToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let secMsGecVersion = "1-143.0.3650.75"
    static let wssURL = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedToken)"

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

    func synthesize(text: String, voiceID: String, rate: Float) async throws -> Data? {
        let connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let urlString = "\(Self.wssURL)&Sec-MS-GEC=\(Self.secMsGec())&Sec-MS-GEC-Version=\(Self.secMsGecVersion)&ConnectionId=\(connectionID)"
        guard let url = URL(string: urlString) else {
            throw SourceError.network("语音服务地址无效")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        // 1. 配置帧
        let config = "X-Timestamp:\(Self.timestampString())\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + #"{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}"#
        try await task.send(.string(config))

        // 2. SSML 帧
        let ssml = Self.makeSSML(text: text, voice: voiceID, rate: rate)
        let ssmlMessage = "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(Self.timestampString())Z\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml
        try await task.send(.string(ssmlMessage))

        // 3. 收音频
        var audio = Data()
        let deadline = Date().addingTimeInterval(40)
        while true {
            if Date() > deadline {
                break
            }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                break
            }
            switch message {
            case .string(let textMessage):
                if textMessage.contains("Path:turn.end") {
                    guard !audio.isEmpty else { throw SourceError.decode("语音合成失败(空音频)") }
                    return audio
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
        guard !audio.isEmpty else { throw SourceError.decode("语音合成失败(无响应)") }
        return audio
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
