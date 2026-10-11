import Foundation

/// 听书设置(音色 / 语速 / 自定义引擎)持久化
@MainActor
final class TTSStore: ObservableObject {
    @Published var selectedVoiceID: String = "edge:zh-CN-XiaoxiaoNeural" {
        didSet { scheduleSave() }
    }
    @Published var rate: Double = 1.0 {
        didSet { scheduleSave() }
    }
    @Published var customEngines: [CustomEngineConfig] = [] {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveWork: DispatchWorkItem?

    private struct Snapshot: Codable {
        var selectedVoiceID: String
        var rate: Double
        var customEngines: [CustomEngineConfig]
    }

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent("legu.tts.json")
        let loaded: Snapshot?
        if let data = try? Data(contentsOf: u),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            loaded = snapshot
        } else {
            loaded = nil
        }
        self.url = u
        if let snapshot = loaded {
            selectedVoiceID = snapshot.selectedVoiceID
            rate = snapshot.rate
            customEngines = snapshot.customEngines
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        let snapshot = Snapshot(
            selectedVoiceID: selectedVoiceID,
            rate: rate,
            customEngines: customEngines
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url)
        }
    }
}
