import SwiftUI

/// 缓存管理:听书音频 / 封面与网页 / 阅读内存;下载内容入口
struct CacheManagementView: View {
    @State private var ttsBytes: Int64 = 0
    @State private var imageBytes: Int64 = 0
    @State private var memoryChapters = 0
    @State private var memoryTOCs = 0
    @State private var offlineBytes: Int64 = 0

    var body: some View {
        List {
            Section {
                cacheRow(
                    title: "听书音频缓存",
                    detail: format(ttsBytes),
                    note: "朗读合成过的音频;重复听同一段直接读缓存,不再联网合成",
                    canClear: ttsBytes > 0
                ) {
                    TTSAudioCache.clear()
                    refresh()
                }
                cacheRow(
                    title: "封面与网页缓存",
                    detail: format(imageBytes),
                    note: "书籍封面、书源网页的临时文件",
                    canClear: imageBytes > 0
                ) {
                    URLCache.shared.removeAllCachedResponses()
                    refresh()
                }
                cacheRow(
                    title: "阅读内存缓存",
                    detail: "\(memoryChapters) 章",
                    note: "本次打开期间缓存的目录(\(memoryTOCs))与正文;退出 App 自动清空",
                    canClear: memoryChapters > 0 || memoryTOCs > 0
                ) {
                    BookCache.shared.clearAll()
                    PaginationCache.shared.clearAll()
                    refresh()
                }
            } header: {
                Text("缓存")
            } footer: {
                Text("清除缓存不影响书架、书源和下载的书。")
            }

            Section("下载内容") {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("下载管理", value: format(offlineBytes))
                }
            }
        }
        .navigationTitle("缓存管理")
        .task { refresh() }
        .refreshable { refresh() }
    }

    private func cacheRow(
        title: String,
        detail: String,
        note: String,
        canClear: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                Text(detail)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
                Button("清除") { clear() }
                    .buttonStyle(.borderless)
                    .disabled(!canClear)
            }
            Text(note)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func refresh() {
        ttsBytes = TTSAudioCache.totalSize()
        let cache = URLCache.shared
        imageBytes = Int64(cache.currentDiskUsage) + Int64(cache.currentMemoryUsage)
        memoryChapters = BookCache.shared.chapterCount
        memoryTOCs = BookCache.shared.tocCount
        offlineBytes = OfflineStore.totalSize()
    }

    private func format(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "无" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
