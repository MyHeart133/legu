import SwiftUI

/// 设置:数据概览 / 关于(阅读排版已移入阅读页「排版」面板)
struct SettingsView: View {
    @EnvironmentObject var sourceStore: SourceStore
    @EnvironmentObject var shelf: ShelfStore

    var body: some View {
        NavigationStack {
            Form {
                Section("数据") {
                    LabeledContent("书源", value: "\(sourceStore.enabledCount) 启用 / \(sourceStore.records.count) 总数")
                    LabeledContent("书架", value: "\(shelf.books.count) 本")
                }

                Section("存储") {
                    NavigationLink {
                        CacheManagementView()
                    } label: {
                        Label("缓存管理", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Label("下载管理", systemImage: "arrow.down.circle")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: AppInfo.version)
                    Text("乐读(Legu)— 书源式小说阅读器\n\n· 内置七猫、番茄等原生书源\n· 支持导入 Legado 书源(JSON),兼容大部分阅读书源规则\n· 搜索 / 目录 / 正文全部在线读取,自动记录阅读进度\n· 阅读排版在阅读页底部「排版」按钮中调整(字体/字号/行距/段距/缩进/主题)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
