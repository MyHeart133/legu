import Foundation

/// 听书合成音频的磁盘缓存(Library/Caches/legu-tts)
/// 键 = 音色 + 语速 + 文本;内容寻址,换音色不会串
enum TTSAudioCache {

    static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("legu-tts", isDirectory: true)
    }

    static func fileURL(voiceID: String, rate: Double, text: String) -> URL {
        dir.appendingPathComponent(StableHash.hex("\(voiceID)|\(rate)|\(text)") + ".bin")
    }

    static func read(voiceID: String, rate: Double, text: String) -> Data? {
        try? Data(contentsOf: fileURL(voiceID: voiceID, rate: rate, text: text))
    }

    static func write(_ data: Data, voiceID: String, rate: Double, text: String) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL(voiceID: voiceID, rate: rate, text: text), options: .atomic)
        } catch {
            // 缓存写失败不影响播放
        }
    }

    static func totalSize() -> Int64 {
        OfflineStore.sizeOf(dir)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}
