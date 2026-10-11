import SwiftUI

@main
struct LeguApp: App {
    @StateObject private var sourceStore = SourceStore()
    @StateObject private var shelfStore = ShelfStore()
    @StateObject private var settingsStore = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sourceStore)
                .environmentObject(shelfStore)
                .environmentObject(settingsStore)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ShelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            SourceListView()
                .tabItem { Label("书源", systemImage: "square.stack.3d.up") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

/// 版本号
enum AppInfo {
    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - 通用小组件

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// 封面(失败时显示首字占位)
struct CoverView: View {
    let url: String?
    let title: String
    var width: CGFloat = 46
    var height: CGFloat = 62

    var body: some View {
        Group {
            if let urlString = url, let u = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: u) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.18)
            Text(String(title.prefix(1)))
                .font(.system(size: width * 0.4))
                .foregroundColor(.secondary)
        }
    }
}

/// 排版控制(阅读页与设置页共用)
struct TypographyControls: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("字号").font(.subheadline).frame(width: 32, alignment: .leading)
                Slider(value: $settings.typography.fontSize,
                       in: ReaderTypography.minFont...ReaderTypography.maxFont, step: 1)
                Text("\(Int(settings.typography.fontSize))")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("行距").font(.subheadline).frame(width: 32, alignment: .leading)
                Slider(value: $settings.typography.lineSpacing,
                       in: ReaderTypography.minLine...ReaderTypography.maxLine, step: 0.1)
                Text(String(format: "%.1f", settings.typography.lineSpacing))
                    .font(.footnote.monospacedDigit())
                    .frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text("段距").font(.subheadline).frame(width: 32, alignment: .leading)
                Slider(value: $settings.typography.paragraphSpacing,
                       in: ReaderTypography.minPara...ReaderTypography.maxPara, step: 2)
                Text("\(Int(settings.typography.paragraphSpacing))")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 8) {
                ForEach(ReaderTypography.Theme.allCases, id: \.self) { theme in
                    Button {
                        settings.typography.theme = theme
                    } label: {
                        Text(theme.name)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(hex: theme.background))
                            .foregroundColor(Color(hex: theme.foreground))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    settings.typography.theme == theme
                                        ? Color.accentColor
                                        : Color.gray.opacity(0.35),
                                    lineWidth: settings.typography.theme == theme ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
