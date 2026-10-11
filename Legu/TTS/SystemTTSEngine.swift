import AVFoundation
import Foundation

/// 系统语音引擎(离线,AVSpeechSynthesizer)
final class SystemTTSEngine: TTSEngine {
    let identifier = "system"
    let displayName = "系统语音(离线)"
    let isRemote = false

    func availableVoices() async -> [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("cmn") }
            .map { voice in
                var detail = "\(Self.langLabel(voice.language)) · \(Self.genderLabel(voice.gender))"
                if voice.quality == .enhanced || voice.quality == .premium {
                    detail += " · 增强"
                }
                return TTSVoice(id: voice.identifier, name: voice.name, detail: detail)
            }
            .sorted { $0.name < $1.name }
    }

    func synthesize(text: String, voiceID: String, rate: Float) async throws -> Data? {
        nil  // 由 TTSService 用 AVSpeechSynthesizer 直接朗读
    }

    static func langLabel(_ code: String) -> String {
        if code.hasPrefix("zh-CN") || code.hasPrefix("cmn") { return "普通话" }
        if code.hasPrefix("zh-HK") { return "粤语" }
        if code.hasPrefix("zh-TW") { return "台湾" }
        return code
    }

    static func genderLabel(_ gender: AVSpeechSynthesisVoiceGender) -> String {
        switch gender {
        case .male: return "男"
        case .female: return "女"
        default: return "未知"
        }
    }
}
