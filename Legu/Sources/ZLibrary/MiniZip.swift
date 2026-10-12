import Compression
import Foundation

/// 极简 ZIP 读取器(EPUB 用):中央目录解析 + stored/deflate 解压
/// 只读、全内存;不支持 zip64(EPUB 基本见不到)
enum MiniZip {

    enum ZipError: LocalizedError {
        case notZip
        case zip64Unsupported
        case badEntry(String)
        case inflateFailed(String)

        var errorDescription: String? {
            switch self {
            case .notZip: return "不是有效的 ZIP/EPUB 文件"
            case .zip64Unsupported: return "暂不支持 zip64 压缩包"
            case .badEntry(let n): return "压缩包条目损坏:\(n)"
            case .inflateFailed(let n): return "解压失败:\(n)"
            }
        }
    }

    /// 解析时跳过的媒体类型(正文用不到)
    static let skipExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "svg", "bmp", "ico",
        "ttf", "otf", "woff", "woff2", "eot",
        "mp3", "m4a", "mp4", "ogg", "wav",
        "css", "js",
    ]

    /// 读取压缩包内所有(非媒体)文件:路径 → 内容
    static func read(_ archive: Data) throws -> [String: Data] {
        let entries = try centralDirectory(archive)
        var out: [String: Data] = [:]
        for entry in entries {
            if entry.name.hasSuffix("/") { continue }
            let ext = (entry.name as NSString).pathExtension.lowercased()
            if skipExtensions.contains(ext) { continue }
            out[entry.name] = try extract(entry, from: archive)
        }
        return out
    }

    // MARK: - 内部

    private struct CDEntry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    private static func centralDirectory(_ archive: Data) throws -> [CDEntry] {
        let b = [UInt8](archive)
        guard b.count > 22 else { throw ZipError.notZip }

        // 从尾部往前找 EOCD(0x06054b50),最多回溯 64KB+22
        var eocd = -1
        let minStart = max(0, b.count - 22 - 65535)
        var i = b.count - 22
        while i >= minStart {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let count = u16(b, eocd + 10)
        let cdOffset = u32(b, eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError.zip64Unsupported
        }

        var entries: [CDEntry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { throw ZipError.notZip }
            let method = u16(b, p + 10)
            let compSize = u32(b, p + 20)
            let uncompSize = u32(b, p + 24)
            let nameLen = u16(b, p + 28)
            let extraLen = u16(b, p + 30)
            let commentLen = u16(b, p + 32)
            let localOffset = u32(b, p + 42)
            guard p + 46 + nameLen <= b.count else { throw ZipError.notZip }
            let nameData = Data(b[(p + 46)..<(p + 46 + nameLen)])
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            entries.append(CDEntry(
                name: name,
                method: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func extract(_ entry: CDEntry, from archive: Data) throws -> Data {
        let b = [UInt8](archive)
        let p = entry.localHeaderOffset
        guard p + 30 <= b.count, u32(b, p) == 0x0403_4B50 else {
            throw ZipError.badEntry(entry.name)
        }
        let nameLen = u16(b, p + 26)
        let extraLen = u16(b, p + 28)
        let dataStart = p + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= b.count else {
            throw ZipError.badEntry(entry.name)
        }
        let compressed = Data(b[dataStart..<(dataStart + entry.compressedSize)])
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expected: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.inflateFailed(entry.name)
        }
    }

    /// 解压(defalte;Apple Compression 的 COMPRESSION_ZLIB 即裸 DEFLATE 流)
    private static func inflate(_ src: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var dst = Data(count: expected)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return src.withUnsafeBytes { srcRaw -> Int in
                guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr, expected,
                    srcPtr, src.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expected else { throw ZipError.inflateFailed(name) }
        return dst
    }
}
