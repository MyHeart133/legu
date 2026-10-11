import SwiftUI

/// 书源管理:内置源 + 导入源,一键导入合集
struct SourceListView: View {
    @EnvironmentObject var sourceStore: SourceStore
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(sourceStore.grouped, id: \.group) { section in
                    Section {
                        ForEach(section.records) { record in
                            SourceRow(record: record)
                        }
                    } header: {
                        HStack {
                            Text(section.group)
                            Spacer()
                            Text("\(section.records.filter { $0.enabled }.count)/\(section.records.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Toggle("", isOn: groupBinding(section.records))
                                .labelsHidden()
                                .scaleEffect(0.8)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("书源(\(sourceStore.enabledCount)/\(sourceStore.records.count))")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            sourceStore.restoreNatives()
                        } label: {
                            Label("恢复内置源", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet()
            }
        }
    }

    /// 分组开关(整组启用/停用)
    private func groupBinding(_ records: [SourceRecord]) -> Binding<Bool> {
        Binding(
            get: { records.contains { $0.enabled } },
            set: { on in
                sourceStore.setEnabled(ids: records.map { $0.id }, on)
            }
        )
    }
}

struct SourceRow: View {
    let record: SourceRecord
    @EnvironmentObject var sourceStore: SourceStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if !record.url.isEmpty {
                    Text(record.url)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { sourceStore.setEnabled(record.id, $0) }
            ))
            .labelsHidden()
        }
        .swipeActions(edge: .trailing) {
            if !record.isNative {
                Button(role: .destructive) {
                    sourceStore.remove(ids: [record.id])
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }
}

/// 导入书源:预设合集 / 链接 / 粘贴
struct ImportSheet: View {
    @EnvironmentObject var sourceStore: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var pasteText = ""
    @State private var busy = false
    @State private var message: String?

    private let presets: [(String, String)] = [
        ("xiu2 合集(ixnic 镜像)", "https://raw.ixnic.net/XIU2/Yuedu/master/shuyuan"),
        ("xiu2 合集(bitbucket 镜像)", "https://bitbucket.org/xiu2/yuedu/raw/master/shuyuan"),
        ("yiove:25 个优质书源", "https://shuyuan-api.yiove.com/import/book-source-collection/e56632ca-d5de-4e2c-9ab1-6792a7164312"),
        ("yiove:稳定书源合集", "https://shuyuan-api.yiove.com/import/book-source-collection/eaedccd4-1252-4962-a565-c7a342f95f90"),
        ("yiove:已效验 383 个", "https://shuyuan-api.yiove.com/import/book-source-collection/b8fd3e19-08dd-4f05-a7b4-d6cc909de8e6"),
        ("yiove:星辰整理合集", "https://shuyuan-api.yiove.com/import/book-source-collection/f3f55c6e-723b-4055-b254-124c9d88c5cb"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(presets, id: \.1) { name, url in
                        Button {
                            Task { await importFromURL(url) }
                        } label: {
                            HStack {
                                Text(name)
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .disabled(busy)
                    }
                } header: {
                    Text("一键导入")
                } footer: {
                    Text("导入后可到书源列表启用/停用。合集来源:xiu2 / yiove 书源仓库。")
                }

                Section("从链接导入") {
                    TextField("https://…(书源 JSON 地址)", text: $urlText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button("导入") {
                        Task { await importFromURL(urlText) }
                    }
                    .disabled(busy || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("粘贴 JSON 导入") {
                    TextEditor(text: $pasteText)
                        .frame(minHeight: 90)
                        .font(.caption)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("导入") {
                        importFromPaste()
                    }
                    .disabled(busy || pasteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if busy {
                    Section {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("导入中…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func importFromURL(_ raw: String) async {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t) else {
            message = "链接无效"
            return
        }
        busy = true
        message = nil
        do {
            let session = HTTP.session(timeout: 45)
            let (data, _) = try await HTTP.fetchData(
                url, session: session,
                headers: ["User-Agent": HTTP.mobileUA]
            )
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let summary = sourceStore.importSources(jsonText: text)
            if summary.added == 0 && summary.skipped == 0 && summary.failed > 0 {
                message = "解析失败:该地址不是有效的书源 JSON"
            } else {
                message = "导入完成:新增 \(summary.added),跳过 \(summary.skipped),失败 \(summary.failed)"
            }
        } catch {
            message = "下载失败:\(error.localizedDescription)"
        }
        busy = false
    }

    private func importFromPaste() {
        busy = true
        let summary = sourceStore.importSources(jsonText: pasteText)
        if summary.added == 0 && summary.skipped == 0 && summary.failed > 0 {
            message = "解析失败:粘贴内容不是有效的书源 JSON"
        } else {
            message = "导入完成:新增 \(summary.added),跳过 \(summary.skipped),失败 \(summary.failed)"
        }
        busy = false
    }
}
