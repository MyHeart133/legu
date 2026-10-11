import XCTest
@testable import Legu

/// 听书音频磁盘缓存
final class TTSCacheTests: XCTestCase {

    private let voice = "zh-CN-XiaoxiaoNeural"
    private let text = "缓存测试句 \(UUID().uuidString)"

    override func tearDown() {
        try? FileManager.default.removeItem(at: TTSAudioCache.fileURL(voiceID: voice, rate: 1.0, text: text))
        super.tearDown()
    }

    func testWriteReadRoundtrip() {
        let data = Data([1, 2, 3, 4, 5, 6])
        TTSAudioCache.write(data, voiceID: voice, rate: 1.0, text: text)
        XCTAssertEqual(TTSAudioCache.read(voiceID: voice, rate: 1.0, text: text), data)
    }

    func testMissReturnsNil() {
        XCTAssertNil(TTSAudioCache.read(voiceID: voice, rate: 1.0, text: text))
        XCTAssertNil(TTSAudioCache.read(voiceID: voice, rate: 1.5, text: text))
        XCTAssertNil(TTSAudioCache.read(voiceID: "other-voice", rate: 1.0, text: text))
    }

    func testKeySeparatesVoiceRateText() {
        let base = TTSAudioCache.fileURL(voiceID: voice, rate: 1.0, text: "甲")
        XCTAssertNotEqual(base, TTSAudioCache.fileURL(voiceID: voice, rate: 1.0, text: "乙"))
        XCTAssertNotEqual(base, TTSAudioCache.fileURL(voiceID: voice, rate: 2.0, text: "甲"))
        XCTAssertNotEqual(base, TTSAudioCache.fileURL(voiceID: "v2", rate: 1.0, text: "甲"))
    }
}
