import Foundation

/// 阅读排版设置 v2(书内可调、自动持久化)
struct ReaderTypography: Codable, Equatable, Hashable {
    enum Theme: String, Codable, CaseIterable {
        case light, sepia, green, dark, black, custom

        var name: String {
            switch self {
            case .light: return "纸张白"
            case .sepia: return "暖纸"
            case .green: return "护眼绿"
            case .dark: return "深灰"
            case .black: return "纯黑"
            case .custom: return "自定义"
            }
        }
    }

    // MARK: 参数

    /// "system" / "songti" / "heiti" / "kaiti" / "fangsong" / "yuanti" / "custom:<psName>"
    var fontID: String = "system"
    var fontSize: Double = 18          // 12...36
    var bold: Bool = false             // 适度加粗(仅字体支持时生效)
    var lineSpacing: Double = 1.6      // 行距倍数 1.2...2.6
    var letterSpacing: Double = 0      // 字间距 0...4
    var paragraphSpacing: Double = 4   // 段距 0...24(独立于行距)
    var firstLineIndent: Bool = true   // 首行缩进两字符
    var horizontalPadding: Double = 20 // 左右边距 12...40
    var verticalPadding: Double = 14   // 上下边距 8...36
    var theme: Theme = .light
    var customBackground: String = "#F7F0DF"
    var customForeground: String = "#3A3226"
    var hideStatusBar: Bool = true     // 沉浸模式(隐藏状态栏)

    // MARK: 范围

    static let minFont: Double = 12
    static let maxFont: Double = 36
    static let minLine: Double = 1.2
    static let maxLine: Double = 2.6
    static let minLetter: Double = 0
    static let maxLetter: Double = 4
    static let minPara: Double = 0
    static let maxPara: Double = 24
    static let minHPad: Double = 12
    static let maxHPad: Double = 40
    static let minVPad: Double = 8
    static let maxVPad: Double = 36

    // MARK: 主题色板

    struct Palette {
        let background: String
        let foreground: String
        let secondary: String
    }

    var palette: Palette {
        switch theme {
        case .light:
            return Palette(background: "#FFFFFF", foreground: "#1A1A1A", secondary: "#8A8A8A")
        case .sepia:
            return Palette(background: "#F7F0DF", foreground: "#3A3226", secondary: "#9A8E74")
        case .green:
            return Palette(background: "#E3EFE3", foreground: "#22321F", secondary: "#6B7F66")
        case .dark:
            return Palette(background: "#1C1C1E", foreground: "#C8C8C8", secondary: "#7A7A7A")
        case .black:
            return Palette(background: "#000000", foreground: "#B5B5B5", secondary: "#6E6E6E")
        case .custom:
            return Palette(
                background: customBackground,
                foreground: customForeground,
                secondary: Self.mix(customForeground, customBackground, ratio: 0.5)
            )
        }
    }

    /// 两色混合(hex)
    static func mix(_ a: String, _ b: String, ratio: Double) -> String {
        func rgb(_ hex: String) -> (Double, Double, Double) {
            let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            var v: UInt64 = 0
            Scanner(string: s).scanHexInt64(&v)
            return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        }
        let (ar, ag, ab) = rgb(a)
        let (br, bg, bb) = rgb(b)
        let r = Int((ar + (br - ar) * ratio).rounded())
        let g = Int((ag + (bg - ag) * ratio).rounded())
        let bl = Int((ab + (bb - ab) * ratio).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, bl)))
    }

    // MARK: Codable(向后兼容 v1 数据)

    private enum CodingKeys: String, CodingKey {
        case fontID, fontSize, bold, lineSpacing, letterSpacing, paragraphSpacing
        case firstLineIndent, horizontalPadding, verticalPadding
        case theme, customBackground, customForeground, hideStatusBar
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontID = try c.decodeIfPresent(String.self, forKey: .fontID) ?? "system"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 18
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1.6
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing) ?? 0
        paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? 4
        firstLineIndent = try c.decodeIfPresent(Bool.self, forKey: .firstLineIndent) ?? true
        horizontalPadding = try c.decodeIfPresent(Double.self, forKey: .horizontalPadding) ?? 20
        verticalPadding = try c.decodeIfPresent(Double.self, forKey: .verticalPadding) ?? 14
        theme = try c.decodeIfPresent(Theme.self, forKey: .theme) ?? .light
        customBackground = try c.decodeIfPresent(String.self, forKey: .customBackground) ?? "#F7F0DF"
        customForeground = try c.decodeIfPresent(String.self, forKey: .customForeground) ?? "#3A3226"
        hideStatusBar = try c.decodeIfPresent(Bool.self, forKey: .hideStatusBar) ?? true
    }
}

/// 设置持久化(带防抖,滑块连续拖动不频繁写盘)
@MainActor
final class SettingsStore: ObservableObject {
    @Published var typography: ReaderTypography {
        didSet { scheduleSave() }
    }

    private let url: URL
    private var saveWork: DispatchWorkItem?

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

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveNow() {
        if let data = try? JSONEncoder().encode(typography) {
            try? data.write(to: url)
        }
    }
}
