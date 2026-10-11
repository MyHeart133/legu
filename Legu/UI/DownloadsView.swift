import SwiftUI

/// 下载管理:整本下载进度、暂停/继续/删除
struct DownloadsView: View {
    @ObservedObject private var manager = DownloadManager.shared
    @State private var pendingDelete: DownloadRecord?

    var body: some View {
        Group {
            if manager.records.isEmpty {
                ContentUnavailableView(
                    "还没有下载",
                    systemImage: "arrow.down.circle",
                    description: Text("在书籍详情页或阅读目录里点「下载」,\n整本存到本机,离线也能读")
                )
            } else {
                List {
                    Section {
                        ForEach(manager.records) { rec in
                            DownloadRow(record: rec, manager: manager) {
                                pendingDelete = rec
                            }
                        }
                    } footer: {
                        Text("共 \(manager.records.count) 本 · \(formatBytes(manager.totalBytes))\n下载的书可离线阅读;删除只影响本机副本。")
                    }
                }
                .listStyle(.plain)
                .refreshable { manager.refreshSizes() }
            }
        }
        .navigationTitle("下载管理")
        .confirmationDialog(
            "删除《\(pendingDelete?.title ?? "")》的下载?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let rec = pendingDelete {
                    manager.remove(id: rec.id)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删除本机下载的副本,不影响书架和书源。")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: max(0, bytes))
    }
}

/// 单条下载记录
private struct DownloadRow: View {
    let record: DownloadRecord
    @ObservedObject var manager: DownloadManager
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(url: record.cover, title: record.title, width: 44, height: 60)

            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(record.sourceName) · \(record.statusText)")
                    .font(.caption2)
                    .foregroundColor(record.status == .completed ? .green : .secondary)
                    .lineLimit(1)
                if record.status == .downloading || record.status == .queued {
                    ProgressView(value: record.progress)
                    Text("\(record.doneCount)/\(record.totalChapters) 章 · \(record.sizeText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Text("\(record.doneCount)/\(record.totalChapters) 章 · \(record.sizeText)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                actionButton
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch record.status {
        case .downloading, .queued:
            Button {
                manager.pause(id: record.id)
            } label: {
                Image(systemName: "pause.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
        case .paused:
            Button {
                manager.resume(id: record.id)
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .disabled(record.doneCount >= record.totalChapters)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
        }
    }
}
