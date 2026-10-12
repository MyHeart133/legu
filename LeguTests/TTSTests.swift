import XCTest
@testable import Legu

/// 听书:断句 / 偏移映射 / SSML / 令牌 / 模板展开
final class TTSTests: XCTestCase {

    // MARK: 断句

    func testSentenceSplitBasic() {
        let sentences = SentenceSplitter.split("第一句。第二句!第三句?")
        XCTAssertEqual(sentences, ["第一句。", "第二句!", "第三句?"])
    }

    func testSentenceSplitKeepsClosers() {
        let sentences = SentenceSplitter.split("他说:「好。」然后走了。")
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].hasSuffix("。」"))
        XCTAssertEqual(sentences[1], "然后走了。")
    }

    func testSentenceSplitEllipsisAndQuestion() {
        let sentences = SentenceSplitter.split("真的吗……?好吧。")
        XCTAssertEqual(sentences.first, "真的吗……?")
    }

    func testSentenceSplitMaxLength() {
        let long = String(repeating: "字", count: 500)
        let sentences = SentenceSplitter.split(long, maxLength: 100)
        XCTAssertEqual(sentences.count, 5)
        XCTAssertTrue(sentences.allSatisfy { $0.count <= 100 })
    }

    func testSentenceSplitSkipsBlankLines() {
        let sentences = SentenceSplitter.split("甲。\n\n\n乙。")
        XCTAssertEqual(sentences, ["甲。", "乙。"])
    }

    func testOffsets() {
        let text = "第一句。第二句。"
        let sentences = SentenceSplitter.split(text)
        let offsets = SentenceSplitter.offsets(for: sentences, source: text)
        XCTAssertEqual(offsets, [0, 4])
    }

    // MARK: SSML / 令牌

    func testEdgeSSMLRateAndEscaping() {
        let ssml = EdgeTTSEngine.makeSSML(text: "A&B <tag> \"q\"", voice: "zh-CN-XiaoxiaoNeural", rate: 1.5)
        XCTAssertTrue(ssml.contains("rate='+50%'"))
        XCTAssertTrue(ssml.contains("&amp;"))
        XCTAssertTrue(ssml.contains("&lt;tag&gt;"))
        XCTAssertFalse(ssml.contains("<tag>"))
        XCTAssertTrue(ssml.contains("voice name='zh-CN-XiaoxiaoNeural'"))
    }

    func testEdgeSSMLRateNegative() {
        let ssml = EdgeTTSEngine.makeSSML(text: "x", voice: "v", rate: 0.8)
        XCTAssertTrue(ssml.contains("rate='-20%'"))
    }

    func testSecMsGecFormat() {
        let token = EdgeTTSEngine.secMsGec()
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(token, token.uppercased())
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }

    func testSecMsGecRoundsToFiveMinuteWindow() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let same = base.addingTimeInterval(60)
        let next = base.addingTimeInterval(300)
        XCTAssertEqual(EdgeTTSEngine.secMsGec(now: base), EdgeTTSEngine.secMsGec(now: same))
        XCTAssertNotEqual(EdgeTTSEngine.secMsGec(now: base), EdgeTTSEngine.secMsGec(now: next))
    }

    // MARK: 自定义引擎

    func testCustomEngineTemplateExpansion() {
        let url = CustomTTSEngine.expand(
            "http://127.0.0.1:9880/?text={{speakText}}&speed={{speakSpeed}}",
            text: "你好 世界",
            rate: 1.2
        )
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:9880/?text="))
        XCTAssertTrue(url.contains("speed=1.20"))
        XCTAssertFalse(url.contains("{{"))
        XCTAssertFalse(url.contains(" "))
    }

    func testVoiceIDParse() {
        let (engine, voice) = TTSVoiceID.parse("edge:zh-CN-XiaoxiaoNeural")
        XCTAssertEqual(engine, "edge")
        XCTAssertEqual(voice, "zh-CN-XiaoxiaoNeural")
        let (engine2, voice2) = TTSVoiceID.parse("custom:abc-123")
        XCTAssertEqual(engine2, "custom")
        XCTAssertEqual(voice2, "abc-123")
    }

    func testEdgeBuiltinVoiceCount() {
        XCTAssertEqual(EdgeTTSEngine.builtinVoices.count, 14)
        XCTAssertTrue(EdgeTTSEngine.builtinVoices.allSatisfy { !$0.name.isEmpty && !$0.detail.isEmpty })
    }

    // MARK: 握手头(修复:裸连被 403)

    func testEdgeHandshakeHeaders() {
        let url = URL(string: "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1")!
        let request = EdgeTTSEngine.handshakeRequest(url: url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertTrue((request.value(forHTTPHeaderField: "User-Agent") ?? "").contains("Edg/"))
        XCTAssertTrue((request.value(forHTTPHeaderField: "Accept-Language") ?? "").contains("en-US"))
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        XCTAssertTrue(cookie.hasPrefix("muid="))
        XCTAssertTrue(cookie.hasSuffix(";"))
    }

    func testEdgeMuidFormat() {
        let muid = EdgeTTSEngine.randomMuid()
        XCTAssertEqual(muid.count, 32)
        XCTAssertTrue(muid.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(muid, muid.uppercased())
    }

    // MARK: 双端点(2026-10 微软灰度迁移)

    func testEdgeEndpoints() {
        XCTAssertTrue(EdgeTTSEngine.wssURLNew.hasPrefix("wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1?Ocp-Apim-Subscription-Key="))
        XCTAssertTrue(EdgeTTSEngine.wssURLNew.hasSuffix(EdgeTTSEngine.trustedToken))
        XCTAssertTrue(EdgeTTSEngine.wssURLLegacy.hasPrefix("wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken="))
        XCTAssertTrue(EdgeTTSEngine.wssURLLegacy.hasSuffix(EdgeTTSEngine.trustedToken))
        XCTAssertNotEqual(EdgeTTSEngine.wssURLNew, EdgeTTSEngine.wssURLLegacy)
    }
}
