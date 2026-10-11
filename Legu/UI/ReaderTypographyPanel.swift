import SwiftUI
import UniformTypeIdentifiers

/// 阅读内嵌排版面板:字体 / 排版 / 主题 三个页签
struct ReaderTypographyPanel: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var fontRegistry = FontRegistry.shared

    @State private var tab = 0
    @State private var showFontImporter = false
    @State private var importMessage: String?

    private var typo: ReaderTypography { settings.typography }
    private var resolved: ResolvedFont { fontRegistry.resolve(typo.fontID, bold: typo.bold) }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                Text("字体").tag(0)
                Text("排版").tag(1)
                Text("主题").tag(2)
                Text("翻页").tag(3)
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case 0:
                    ScrollView { fontTab }.scrollIndicators(.hidden)
                case 1:
                    ScrollView { layoutTab }.scrollIndicators(.hidden)
                case 2:
                    ScrollView { themeTab }.scrollIndicators(.hidden)
                default:
                    ScrollView { pageTab }.scrollIndicators(.hidden)
                }
            }
            .frame(height: 172)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fileImporter(isPresented: $showFontImporter, allowedContentTypes: Self.fontTypes) { result in
            handleImport(result)
        }
    }

    // MARK: - 字体

    private var fontTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FontRegistry.builtinOptions) { opt in
                        chip(opt.label, selected: typo.fontID == opt.id) {
                            settings.typography.fontID = opt.id
                        }
                    }
                    ForEach(fontRegistry.customFonts) { cf in
                        chip(cf.displayName, selected: typo.fontID == cf.id) {
                            settings.typography.fontID = cf.id
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                fontRegistry.deleteCustomFont(id: cf.id)
                                if typo.fontID == cf.id {
                                    settings.typography.fontID = "system"
                                }
                            } label: {
                                Label("删除字体", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                Text("字重")
                    .font(.caption)
                chip("常规", selected: !typo.bold) { settings.typography.bold = false }
                chip("加粗", selected: typo.bold) { settings.typography.bold = true }
                Spacer()
                Button {
                    showFontImporter = true
                } label: {
                    Label("导入字体", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let importMessage {
                Text(importMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text("实际字体:\(resolved.displayName)\(resolved.isFallback ? "(替代)" : "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 排版

    private var layoutTab: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text("字号")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                Button { adjustFont(-1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.borderless)
                Slider(value: $settings.typography.fontSize,
                       in: ReaderTypography.minFont...ReaderTypography.maxFont, step: 1)
                Button { adjustFont(1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.borderless)
                Text("\(Int(typo.fontSize))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("行距")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                chip("紧凑", selected: abs(typo.lineSpacing - 1.3) < 0.05) { settings.typography.lineSpacing = 1.3 }
                chip("标准", selected: abs(typo.lineSpacing - 1.6) < 0.05) { settings.typography.lineSpacing = 1.6 }
                chip("宽松", selected: abs(typo.lineSpacing - 2.0) < 0.05) { settings.typography.lineSpacing = 2.0 }
                Slider(value: $settings.typography.lineSpacing,
                       in: ReaderTypography.minLine...ReaderTypography.maxLine, step: 0.1)
                Text(String(format: "%.1f", typo.lineSpacing))
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("字距")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                Slider(value: $settings.typography.letterSpacing,
                       in: ReaderTypography.minLetter...ReaderTypography.maxLetter, step: 0.5)
                Text(String(format: "%.1f", typo.letterSpacing))
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("段距")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                Slider(value: $settings.typography.paragraphSpacing,
                       in: ReaderTypography.minPara...ReaderTypography.maxPara, step: 2)
                Text("\(Int(typo.paragraphSpacing))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Toggle(isOn: $settings.typography.firstLineIndent) {
                    Text("首行缩进(两字符)")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            }
            HStack(spacing: 8) {
                Toggle(isOn: $settings.typography.punctuationCompression) {
                    Text("标点挤压(。」等组合收紧)")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("边距")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                Text("左右")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 26, alignment: .leading)
                Slider(value: $settings.typography.horizontalPadding,
                       in: ReaderTypography.minHPad...ReaderTypography.maxHPad, step: 2)
                Text("\(Int(typo.horizontalPadding))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("")
                    .frame(width: 30, alignment: .leading)
                Text("上下")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 26, alignment: .leading)
                Slider(value: $settings.typography.verticalPadding,
                       in: ReaderTypography.minVPad...ReaderTypography.maxVPad, step: 2)
                Text("\(Int(typo.verticalPadding))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 24, alignment: .trailing)
            }
        }
    }

    // MARK: - 主题

    private var themeTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderTypography.Theme.allCases, id: \.self) { theme in
                        themeChip(theme)
                    }
                }
                .padding(.vertical, 2)
            }
            if typo.theme == .custom {
                HStack(spacing: 16) {
                    ColorPicker("背景色", selection: colorBinding($settings.typography.customBackground), supportsOpacity: false)
                        .font(.caption)
                    ColorPicker("文字色", selection: colorBinding($settings.typography.customForeground), supportsOpacity: false)
                        .font(.caption)
                }
            }
            HStack {
                Toggle(isOn: $settings.typography.hideStatusBar) {
                    Text("沉浸阅读(隐藏状态栏)")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            }
        }
    }

    // MARK: - 翻页

    private var pageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("模式")
                    .font(.caption)
                chip("上下滚动", selected: typo.readerMode == "scroll") {
                    settings.typography.readerMode = "scroll"
                }
                chip("平移翻页", selected: typo.readerMode == "page") {
                    settings.typography.readerMode = "page"
                }
                chip("仿真翻页", selected: typo.readerMode == "curl") {
                    settings.typography.readerMode = "curl"
                }
            }
            Text("翻页模式:点屏幕左/右两侧翻页,点中间呼出控制层;左右滑动整页切换。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("分页按当前字体/字号/行距/边距实时计算;修改排版后自动回到原段落位置。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func themeChip(_ theme: ReaderTypography.Theme) -> some View {
        Button {
            settings.typography.theme = theme
        } label: {
            let p = paletteFor(theme)
            Text(theme.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(hex: p.background))
                .foregroundColor(Color(hex: p.foreground))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        typo.theme == theme ? Color.accentColor : Color.gray.opacity(0.35),
                        lineWidth: typo.theme == theme ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func paletteFor(_ theme: ReaderTypography.Theme) -> ReaderTypography.Palette {
        var t = typo
        t.theme = theme
        return t.palette
    }

    private func colorBinding(_ source: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: source.wrappedValue) },
            set: { source.wrappedValue = $0.toHex() }
        )
    }

    // MARK: - 通用

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
                .foregroundColor(selected ? .accentColor : .primary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? Color.accentColor : Color.gray.opacity(0.25),
                        lineWidth: selected ? 1.5 : 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func adjustFont(_ delta: Double) {
        settings.typography.fontSize = min(
            ReaderTypography.maxFont,
            max(ReaderTypography.minFont, typo.fontSize + delta)
        )
    }

    private static var fontTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["ttf", "otf", "ttc"] {
            if let t = UTType(filenameExtension: ext) {
                types.append(t)
            }
        }
        return types
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            if let error = fontRegistry.importFont(from: url) {
                importMessage = error
            } else {
                importMessage = nil
                if let imported = fontRegistry.customFonts.first(where: { $0.fileName == url.lastPathComponent }) {
                    settings.typography.fontID = imported.id
                }
            }
        case .failure:
            importMessage = nil
        }
    }
}

extension Color {
    /// Color → #RRGGBB
    func toHex() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if ui.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X",
                          Int((r * 255).rounded()),
                          Int((g * 255).rounded()),
                          Int((b * 255).rounded()))
        }
        return "#000000"
    }
}
