import Foundation

/// 自定义朗读引擎配置(Legado 朗读引擎格式,可对接任意自建/第三方 TTS)
struct CustomEngineConfig: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    /// URL 模板:含 {{speakText}} / {{speakSpeed}};可带 ,{"method":"POST","body":"..."} 选项
    var urlTemplate: String = ""
    var note: String = ""
}

/// 自定义 HTTP 朗读引擎
///
/// 模板变量:{{speakText}}(URL 编码) / {{speakSpeed}}(倍率,如 1.00)
/// 兼容 Legado 朗读引擎的 `url,{json}` 选项格式(与书源同一套解析器)
final class CustomTTSEngine: TTSEngine {
    let config: CustomEngineConfig

    var identifier: String { "custom:" + config.id }
    var displayName: String { config.name.isEmpty ? "自定义引擎" : config.name }
    let isRemote = true

    private let session = HTTP.session(timeout: 60)

    init(config: CustomEngineConfig) {
        self.config = config
    }

    func availableVoices() async -> [TTSVoice] {
        [TTSVoice(id: config.id, name: displayName, detail: config.note.isEmpty ? "自定义朗读引擎" : config.note)]
    }

    func synthesize(text: String, voiceID: String, rate: Float) async throws -> Data {
        let (template, options) = LegadoContentSource.parseURLOptions(config.urlTemplate)
        let expandedURL = Self.expand(template, text: text, rate: rate)
        guard let url = URL(string: expandedURL) else {
            throw SourceError.network("自定义引擎地址无效")
        }

        var method = (options.method ?? "GET").uppercased()
        var body: Data? = nil
        if let bodyTemplate = options.body, !bodyTemplate.isEmpty {
            body = Data(Self.expand(bodyTemplate, text: text, rate: rate).utf8)
            if method == "GET" { method = "POST" }
        }
        var headers: [String: String] = [:]
        if let custom = options.headers {
            headers = custom
        }
        let (data, _) = try await HTTP.fetchData(
            url, session: session, headers: headers, method: method, body: body
        )
        guard data.count > 64 else {
            throw SourceError.decode("自定义引擎未返回音频(检查服务是否已启动)")
        }
        return data
    }

    /// 模板展开(可测)
    static func expand(_ template: String, text: String, rate: Float) -> String {
        var s = template
        s = s.replacingOccurrences(of: "{{speakText}}", with: HTTP.percentEncode(text, encoding: .utf8))
        s = s.replacingOccurrences(of: "{{speakSpeed}}", with: String(format: "%.2f", rate))
        s = s.replacingOccurrences(of: "{{speakVolume}}", with: "1.00")
        return s
    }
}
