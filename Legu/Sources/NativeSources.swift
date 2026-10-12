import Foundation

/// 内置原生书源注册表
enum NativeSources {
    struct Definition {
        let id: String
        let name: String
        let group: String
    }

    static let groupName = "内置书源"

    static let definitions: [Definition] = [
        Definition(id: "zlib", name: "Z-Library", group: "网络书库"),
        Definition(id: "qimao", name: "七猫免费小说", group: groupName),
        Definition(id: "fanqie", name: "番茄小说", group: groupName),
        Definition(id: "202xs", name: "202小说网", group: groupName),
        Definition(id: "ffzw", name: "非凡中文", group: groupName),
        Definition(id: "xinbiqu", name: "新笔趣阁", group: groupName),
        Definition(id: "piaotia", name: "飘天文学", group: groupName),
        Definition(id: "biquge365", name: "笔趣阁365", group: groupName),
        Definition(id: "hetushu", name: "和图书", group: groupName),
        Definition(id: "dmxsw", name: "耽美小说", group: groupName),
        Definition(id: "shuku52", name: "52书库", group: groupName),
    ]

    static func definition(_ id: String) -> Definition? {
        definitions.first { $0.id == id }
    }

    static func make(_ id: String) -> ContentSource? {
        switch id {
        case "zlib": return ZLibrarySource()
        case "qimao": return QimaoSource()
        case "fanqie": return FanqieSource()
        case "202xs": return Template202Source(.init(id: "202xs", name: "202小说网", base: "https://202xs.com"))
        case "ffzw": return Template202Source(.init(id: "ffzw", name: "非凡中文", base: "https://ffzw.cc"))
        case "xinbiqu": return Template202Source(.init(id: "xinbiqu", name: "新笔趣阁", base: "https://xinbiqu.org"))
        case "piaotia": return PiaotiaSource()
        case "biquge365": return Biquge365Source()
        case "hetushu": return HetushuSource()
        case "dmxsw": return DmxswSource()
        case "shuku52": return Shuku52Source()
        default: return nil
        }
    }
}
