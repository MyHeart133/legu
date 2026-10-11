import CoreText
import Foundation
import UIKit

/// 字体解析结果
struct ResolvedFont: Equatable {
    /// PostScript 名;nil = 系统字体
    let postScriptName: String?
    /// 实际渲染字体的可读名(与真实渲染对应)
    let displayName: String
    /// 请求的字体不可用、已回退
    let isFallback: Bool
}

/// 字体注册与可用性检测
///
/// - 内置风格:系统 / 宋体 / 黑体 / 楷体 / 仿宋 / 圆体
///   每台设备字体不同 → 逐个检测可用性,提供回退链,并如实报告实际渲染字体
/// - 自定义字体:Documents/Fonts 下的 ttf / otf / ttc,启动时注册(CTFontManager)
final class FontRegistry: ObservableObject {
    static let shared = FontRegistry()

    struct FontOption: Identifiable, Equatable {
        let id: String
        let label: String
    }

    struct CustomFont: Identifiable, Equatable {
        let id: String          // "custom:<postScriptName>"
        let displayName: String
        let postScriptName: String
        let fileName: String
    }

    /// 内置风格(UI 选项)
    static let builtinOptions: [FontOption] = [
        FontOption(id: "system", label: "系统"),
        FontOption(id: "songti", label: "宋体"),
        FontOption(id: "heiti", label: "黑体"),
        FontOption(id: "kaiti", label: "楷体"),
        FontOption(id: "fangsong", label: "仿宋"),
        FontOption(id: "yuanti", label: "圆体"),
    ]

    /// 回退链(按优先级;最后一个兜底为系统)
    private static let chains: [String: (label: String, names: [String])] = [
        "songti": ("宋体", ["Songti SC", "STSongti-SC-Regular", "STSong", "SimSun"]),
        "heiti": ("黑体", ["PingFang SC", "Hiragino Sans GB", "Heiti SC", "STHeiti"]),
        "kaiti": ("楷体", ["Kaiti SC", "STKaiti", "KaiTi"]),
        "fangsong": ("仿宋", ["FangSong", "STFangsong", "FangSong_GB2312"]),
        "yuanti": ("圆体", ["Yuanti SC", "STYuanti"]),
    ]

    @Published private(set) var customFonts: [CustomFont] = []

    private var fontsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("Fonts", isDirectory: true)
    }

    private init() {
        registerCustomFonts()
    }

    // MARK: - 解析

    func resolve(_ fontID: String, bold: Bool = false) -> ResolvedFont {
        // 系统
        if fontID == "system" {
            return ResolvedFont(postScriptName: nil, displayName: "系统默认(苹方)", isFallback: false)
        }
        // 自定义
        if fontID.hasPrefix("custom:") {
            let ps = String(fontID.dropFirst("custom:".count))
            if let font = UIFont(name: ps, size: 12) {
                return ResolvedFont(postScriptName: ps, displayName: font.familyName, isFallback: false)
            }
            return ResolvedFont(postScriptName: nil, displayName: "自定义字体不可用(回退系统)", isFallback: true)
        }
        // 内置风格
        guard let chain = Self.chains[fontID] else {
            return ResolvedFont(postScriptName: nil, displayName: "系统默认", isFallback: true)
        }
        for (index, candidate) in chain.names.enumerated() {
            if let ps = Self.findVariant(candidate, bold: bold) {
                let family = UIFont(name: ps, size: 12)?.familyName ?? candidate
                return ResolvedFont(
                    postScriptName: ps,
                    displayName: family,
                    isFallback: index > 0
                )
            }
        }
        return ResolvedFont(postScriptName: nil, displayName: "\(chain.label)不可用(回退系统)", isFallback: true)
    }

    /// 按候选名找字体,优先取指定字重变体
    private static func findVariant(_ candidate: String, bold: Bool) -> String? {
        // 1. 直接可用(名称 / 家族名)
        if let font = UIFont(name: candidate, size: 12) {
            return pickVariant(family: font.familyName, fallback: font.fontName, bold: bold)
        }
        // 2. 家族名匹配
        let families = UIFont.familyNames
        if let family = families.first(where: {
            $0.caseInsensitiveCompare(candidate) == .orderedSame
                || $0.localizedCaseInsensitiveContains(candidate)
        }) {
            return pickVariant(family: family, fallback: nil, bold: bold)
        }
        return nil
    }

    private static func pickVariant(family: String, fallback: String?, bold: Bool) -> String? {
        let names = UIFont.fontNames(forFamilyName: family)
        if bold {
            if let b = names.first(where: {
                let l = $0.lowercased()
                return l.contains("bold") || l.contains("heavy") || l.contains("black") || l.contains("semibold")
            }) {
                return b
            }
        }
        if let regular = names.first(where: { $0.lowercased().contains("regular") }) {
            return regular
        }
        if let fallback, UIFont(name: fallback, size: 12) != nil {
            return fallback
        }
        return names.first
    }

    // MARK: - 自定义字体

    func registerCustomFonts() {
        let dir = fontsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            customFonts = []
            return
        }
        var found: [CustomFont] = []
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else {
                continue
            }
            for d in descriptors {
                let ps = (CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String) ?? ""
                guard !ps.isEmpty else { continue }
                let display = UIFont(name: ps, size: 12)?.familyName ?? ps
                found.append(CustomFont(
                    id: "custom:" + ps,
                    displayName: display,
                    postScriptName: ps,
                    fileName: file.lastPathComponent
                ))
            }
        }
        customFonts = found.sorted { $0.displayName < $1.displayName }
    }

    /// 导入字体文件(ttf / otf / ttc)。返回 nil 表示成功,否则为错误说明
    func importFont(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc"].contains(ext) else {
            return "不支持的字体格式(仅支持 ttf / otf / ttc)"
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let dir = fontsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return "字体拷贝失败:\(error.localizedDescription)"
        }
        registerCustomFonts()
        let name = url.lastPathComponent
        if customFonts.contains(where: { $0.fileName == name }) {
            return nil
        }
        try? FileManager.default.removeItem(at: dest)
        return "无法解析该字体文件(可能不是有效的字体)"
    }

    func deleteCustomFont(id: String) {
        guard let font = customFonts.first(where: { $0.id == id }) else { return }
        let url = fontsDirectory.appendingPathComponent(font.fileName)
        try? FileManager.default.removeItem(at: url)
        registerCustomFonts()
    }
}
