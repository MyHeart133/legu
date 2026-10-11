import Foundation

/// 书源记录(内置源 + 导入源统一模型)
struct SourceRecord: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var url: String
    var group: String
    var enabled: Bool
    var nativeID: String?
    var legadoJSON: String?

    var isNative: Bool { nativeID != nil }
}

/// 书源仓库:持久化、导入、启用管理
@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var records: [SourceRecord] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent("legu.sources.json")
        self.fileURL = u
        if let data = try? Data(contentsOf: u),
           let list = try? JSONDecoder().decode([SourceRecord].self, from: data) {
            self.records = list
        } else {
            self.records = Self.seedRecords()
        }
        // 补齐缺失的内置源
        let missing = Self.seedRecords().filter { seed in
            !records.contains(where: { $0.id == seed.id })
        }
        if !missing.isEmpty {
            records.append(contentsOf: missing)
        }
        save()
    }

    static func seedRecords() -> [SourceRecord] {
        NativeSources.definitions.map { def in
            SourceRecord(
                id: def.id,
                name: def.name,
                url: "",
                group: def.group,
                enabled: true,
                nativeID: def.id,
                legadoJSON: nil
            )
        }
    }

    /// 内置源的站点根地址(导入去重用)
    static let nativeBaseURLs: [String: String] = [
        "qimao": "https://api-bc.wtzw.com",
        "fanqie": "https://fanqienovel.com",
        "202xs": "https://202xs.com",
        "ffzw": "https://ffzw.cc",
        "xinbiqu": "https://xinbiqu.org",
        "piaotia": "https://www.piaotia.com",
        "biquge365": "https://www.biquge365.net",
        "hetushu": "https://www.hetushu.com",
        "dmxsw": "https://m.dmxsw.org",
        "shuku52": "https://www.52shuku.net",
    ]

    // MARK: - 持久化

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - 变更

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].enabled = enabled
        save()
    }

    func remove(ids: [String]) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func restoreNatives() {
        let missing = Self.seedRecords().filter { seed in
            !records.contains(where: { $0.id == seed.id })
        }
        records.append(contentsOf: missing)
        save()
    }

    struct ImportSummary {
        var added: Int
        var skipped: Int
        var failed: Int
    }

    /// 导入 Legado JSON(数组或单对象)
    @discardableResult
    func importSources(jsonText: String) -> ImportSummary {
        let models = LegadoSource.decodeList(jsonText)
        guard !models.isEmpty else {
            return ImportSummary(added: 0, skipped: 0, failed: 1)
        }
        var added = 0
        var skipped = 0
        var failed = 0
        for model in models {
            guard let base = model.cleanBaseURL else {
                failed += 1
                continue
            }
            let id = "legado:" + LegadoContentSource.stableID(base + "|" + model.displayTitle)
            if records.contains(where: { $0.id == id }) {
                skipped += 1
                continue
            }
            // 按站点去重(同 URL 已有源则跳过)
            if records.contains(where: { existing in
                if let nativeID = existing.nativeID,
                   Self.nativeBaseURLs[nativeID] == base {
                    return true
                }
                if let json = existing.legadoJSON,
                   let em = LegadoSource.decodeList(json).first,
                   let ebase = em.cleanBaseURL {
                    return ebase == base
                }
                return false
            }) {
                skipped += 1
                continue
            }
            guard let data = try? JSONEncoder().encode(model),
                  let jsonText = String(data: data, encoding: .utf8) else {
                failed += 1
                continue
            }
            records.append(SourceRecord(
                id: id,
                name: model.displayTitle,
                url: base,
                group: model.groupTitle == "未分组" ? "导入书源" : model.groupTitle,
                enabled: model.enabled ?? true,
                nativeID: nil,
                legadoJSON: jsonText
            ))
            added += 1
        }
        save()
        return ImportSummary(added: added, skipped: skipped, failed: failed)
    }

    // MARK: - 访问

    func record(id: String) -> SourceRecord? {
        records.first { $0.id == id }
    }

    func record(forBookSourceID sourceID: String) -> SourceRecord? {
        records.first { $0.id == sourceID || $0.nativeID == sourceID }
    }

    func makeSource(_ record: SourceRecord) -> ContentSource? {
        if let nativeID = record.nativeID {
            return NativeSources.make(nativeID)
        }
        if let json = record.legadoJSON, let model = LegadoSource.decodeList(json).first {
            return LegadoContentSource(model: model)
        }
        return nil
    }

    /// 书籍来源 ID → 内容源
    func source(forBookSourceID sourceID: String) -> ContentSource? {
        guard let record = record(forBookSourceID: sourceID) else { return nil }
        return makeSource(record)
    }

    /// 启用中的内容源(搜索用)
    var enabledSources: [(id: String, name: String, source: ContentSource)] {
        records.filter { $0.enabled }.compactMap { record in
            guard let source = makeSource(record) else { return nil }
            return (id: record.id, name: record.name, source: source)
        }
    }

    var enabledCount: Int { records.filter { $0.enabled }.count }

    /// 分组展示
    var grouped: [(group: String, records: [SourceRecord])] {
        var order: [String] = []
        var map: [String: [SourceRecord]] = [:]
        for r in records {
            if map[r.group] == nil {
                order.append(r.group)
                map[r.group] = []
            }
            map[r.group]?.append(r)
        }
        // 内置组置顶
        order.sort { a, b in
            if a == NativeSources.groupName { return true }
            if b == NativeSources.groupName { return false }
            return a < b
        }
        return order.map { (group: $0, records: map[$0] ?? []) }
    }
}
