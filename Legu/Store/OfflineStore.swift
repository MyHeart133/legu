import Foundation

/// 稳定哈希(FNV-1a 64)
/// 不用 Swift 自带的 Hasher —— 它每次进程启动都带随机种子,文件名/缓存键无法跨启动复现
enum StableHash {
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func hex(_ s: String) -> String {
        String(fnv1a(s), radix: 16)
    }
}

/// 离线下载的文件存储层
/// 目录:Documents/Offline/<书目录名>/{toc.json, c_<章节>.txt}
enum OfflineStore {

    static var root: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("Offline", isDirectory: true)
    }

    static func bookKey(sourceID: String, sourceBookID: String) -> String {
        "\(sourceID)|\(sourceBookID)"
    }

    // MARK: - 路径

    static func dirName(_ bookKey: String) -> String {
        sanitize(bookKey) + "_" + StableHash.hex(bookKey)
    }

    static func bookDir(_ bookKey: String) -> URL {
        root.appendingPathComponent(dirName(bookKey), isDirectory: true)
    }

    static func tocURL(_ bookKey: String) -> URL {
        bookDir(bookKey).appendingPathComponent("toc.json")
    }

    static func chapterFileName(_ chapterID: String) -> String {
        "c_" + sanitize(chapterID) + "_" + StableHash.hex(chapterID) + ".txt"
    }

    static func chapterURL(bookKey: String, chapterID: String) -> URL {
        bookDir(bookKey).appendingPathComponent(chapterFileName(chapterID))
    }

    /// 文件名安全化:保留 [A-Za-z0-9_-],其余替换为 _
    static func sanitize(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
                || v == 45 || v == 95
            out.append(ok ? Character(scalar) : Character("_"))
            if out.count >= 60 { break }
        }
        return out.isEmpty ? "x" : out
    }

    // MARK: - 目录

    @discardableResult
    static func saveTOC(_ chapters: [SourceChapter], for bookKey: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: bookDir(bookKey), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(chapters)
            try data.write(to: tocURL(bookKey), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func loadTOC(_ bookKey: String) -> [SourceChapter]? {
        guard let data = try? Data(contentsOf: tocURL(bookKey)) else { return nil }
        return try? JSONDecoder().decode([SourceChapter].self, from: data)
    }

    // MARK: - 章节

    @discardableResult
    static func saveChapter(_ text: String, bookKey: String, chapterID: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: bookDir(bookKey), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: chapterURL(bookKey: bookKey, chapterID: chapterID), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func readChapter(bookKey: String, chapterID: String) -> String? {
        guard let data = try? Data(contentsOf: chapterURL(bookKey: bookKey, chapterID: chapterID)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func hasChapter(bookKey: String, chapterID: String) -> Bool {
        FileManager.default.fileExists(atPath: chapterURL(bookKey: bookKey, chapterID: chapterID).path)
    }

    /// 已下载章节的文件名集合(目录页打勾用)
    static func downloadedFileNames(_ bookKey: String) -> Set<String> {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: bookDir(bookKey).path) else {
            return []
        }
        return Set(items.filter { $0.hasPrefix("c_") && $0.hasSuffix(".txt") })
    }

    static func downloadedCount(_ bookKey: String) -> Int {
        downloadedFileNames(bookKey).count
    }

    // MARK: - 删除 / 统计

    static func deleteBook(_ bookKey: String) {
        try? FileManager.default.removeItem(at: bookDir(bookKey))
    }

    static func bookSize(_ bookKey: String) -> Int64 {
        sizeOf(bookDir(bookKey))
    }

    static func totalSize() -> Int64 {
        sizeOf(root)
    }

    /// 目录(或文件)占用的总字节数
    static func sizeOf(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Int64(size)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
