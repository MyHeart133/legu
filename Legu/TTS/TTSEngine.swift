import Foundation

/// 朗读音色
struct TTSVoice: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String
}

/// 朗读引擎协议(与书源同思路:可插拔)
protocol TTSEngine: AnyObject {
    var identifier: String { get }
    var displayName: String { get }
    /// 系统引擎直接朗读;远程引擎返回合成音频数据
    var isRemote: Bool { get }
    func availableVoices() async -> [TTSVoice]
    /// 远程引擎:合成一句返回音频(mp3/wav);系统引擎返回 nil
    func synthesize(text: String, voiceID: String, rate: Float) async throws -> Data?
}

/// 音色 ID 解析:"system:<id>" / "edge:<shortName>" / "custom:<engineID>"
enum TTSVoiceID {
    static func parse(_ raw: String) -> (engine: String, voice: String) {
        guard let colon = raw.firstIndex(of: ":") else {
            return ("edge", raw)
        }
        return (String(raw[..<colon]), String(raw[raw.index(after: colon)...]))
    }

    static func make(engine: String, voice: String) -> String {
        "\(engine):\(voice)"
    }
}
