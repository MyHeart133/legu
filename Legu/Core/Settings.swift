import Foundation

/// 阅读排版设置(书内可调、自动持久化)
struct ReaderTypography: Codable, Equatable {
    enum Theme: String, Codable, CaseIterable {
        case light, sepia, green, dark

        var name: String {
            switch self {
            case .light: return "白"
            case .sepia: return "纸黄"
            case .green: return "豆绿"
            case .dark: return "夜间"
            }
        }

        var background: String {
            switch self {
            case .light: return "#FFFFFF"
            case .sepia: return "#F7F0DF"
            case .green: return "#E3EFE3"
            case .dark: return "#121212"
            }
        }

        var foreground: String {
            switch self {
            case .light: return "#1A1A1A"
            case .sepia: return "#3A3226"
            case .green: return "#22321F"
            case .dark: return "#C8C8C8"
            }
        }

        var secondary: String {
            switch self {
            case .light: return "#8A8A8A"
            case .sepia: return "#9A8E74"
            case .green: return "#6B7F66"
            case .dark: return "#7A7A7A"
            }
        }
    }

    var fontSize: Double = 18
    var lineSpacing: Double = 1.7
    var paragraphSpacing: Double = 10
    var theme: Theme = .light

    static let minFont: Double = 13
    static let maxFont: Double = 28
    static let minLine: Double = 1.2
    static let maxLine: Double = 2.6
    static let minPara: Double = 0
    static let maxPara: Double = 24
}

/// 设置的持久化容器
final class SettingsStore: ObservableObject {
    @Published var typography: ReaderTypography {
        didSet { save() }
    }

    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent("legu.settings.json")
        let t: ReaderTypography
        if let data = try? Data(contentsOf: u),
           let decoded = try? JSONDecoder().decode(ReaderTypography.self, from: data) {
            t = decoded
        } else {
            t = ReaderTypography()
        }
        self.url = u
        self.typography = t
    }

    private func save() {
        if let data = try? JSONEncoder().encode(typography) {
            try? data.write(to: url)
        }
    }
}
