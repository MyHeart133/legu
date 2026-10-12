import SwiftUI

/// 全屏听书页:封面 / 章节 / 播放控制 / 语速 / 音色 / 定时
struct ListeningView: View {
    @EnvironmentObject var sourceStore: SourceStore
    @EnvironmentObject var ttsStore: TTSStore
    @ObservedObject private var service = TTSService.shared
    @Environment(\.dismiss) private var dismiss

    let book: SourceBook
    let chapters: [SourceChapter]
    let startChapter: Int
    let startOffset: Int?

    @State private var systemVoices: [TTSVoice] = []
    @State private var showEngineEditor = false
    @State private var testingVoice = false
    @State private var voiceTestResult: String?

    private var selectedBinding: Binding<String> {
        Binding(
            get: { ttsStore.selectedVoiceID },
            set: { newValue in
                ttsStore.selectedVoiceID = newValue
                service.applySettings()
            }
        )
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { ttsStore.rate },
            set: { newValue in
                ttsStore.rate = newValue
                service.applySettings()
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    CoverView(url: book.cover, title: book.title, width: 150, height: 200)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)

                    VStack(spacing: 6) {
                        Text(book.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(service.chapterTitle.isEmpty ? "准备中…" : service.chapterTitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if service.sentenceCount > 0 {
                            Text("第 \(service.chapterIndex + 1)/\(service.chapterCount) 章 · 第 \(service.sentenceIndex + 1)/\(service.sentenceCount) 句")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if service.state == .loading {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(spacing: 44) {
                        Button {
                            service.prevChapter()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.title2)
                        }
                        .disabled(service.chapterIndex <= 0)

                        Button {
                            service.toggle()
                        } label: {
                            Image(systemName: service.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 58))
                        }

                        Button {
                            service.nextChapter()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.title2)
                        }
                        .disabled(service.chapterIndex >= service.chapterCount - 1)
                    }
                    .foregroundColor(.primary)

                    if let error = service.errorText {
                        VStack(spacing: 8) {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                            Button("改用系统语音继续听") {
                                Task { await switchToSystemVoice() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 24)
                    }

                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Text("语速")
                                .font(.subheadline)
                                .frame(width: 40, alignment: .leading)
                            Slider(value: rateBinding, in: 0.5...2.0, step: 0.1)
                            Text(String(format: "%.1f×", ttsStore.rate))
                                .font(.footnote.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }

                        HStack(spacing: 10) {
                            Text("音色")
                                .font(.subheadline)
                                .frame(width: 40, alignment: .leading)
                            Picker("音色", selection: selectedBinding) {
                                Section("微软神经音色(在线)") {
                                    ForEach(EdgeTTSEngine.builtinVoices) { voice in
                                        Text("\(voice.name) · \(voice.detail)").tag("edge:\(voice.id)")
                                    }
                                }
                                if !systemVoices.isEmpty {
                                    Section("系统语音(离线)") {
                                        ForEach(systemVoices) { voice in
                                            Text("\(voice.name) · \(voice.detail)").tag("system:\(voice.id)")
                                        }
                                    }
                                }
                                if !ttsStore.customEngines.isEmpty {
                                    Section("自定义引擎") {
                                        ForEach(ttsStore.customEngines) { engine in
                                            Text(engine.name.isEmpty ? "自定义" : engine.name)
                                                .tag("custom:\(engine.id)")
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            Button {
                                showEngineEditor = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }

                        HStack(spacing: 10) {
                            Text("检测")
                                .font(.subheadline)
                                .frame(width: 40, alignment: .leading)
                            Button("测试当前音色") {
                                Task { await runVoiceTest() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(testingVoice)
                            if testingVoice {
                                ProgressView().controlSize(.small)
                            }
                            if let voiceTestResult {
                                Text(voiceTestResult)
                                    .font(.caption)
                                    .foregroundColor(voiceTestResult.hasPrefix("成功") ? .secondary : .red)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            Text("定时")
                                .font(.subheadline)
                                .frame(width: 40, alignment: .leading)
                            Menu {
                                Button("关闭") { service.setSleepTimer(minutes: nil) }
                                Button("15 分钟") { service.setSleepTimer(minutes: 15) }
                                Button("30 分钟") { service.setSleepTimer(minutes: 30) }
                                Button("60 分钟") { service.setSleepTimer(minutes: 60) }
                                Button("播完本章") { service.setSleepAtChapterEnd() }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(sleepLabel)
                                        .font(.subheadline)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 20)

                    Text("后台可继续播放;锁屏/控制中心可切章、暂停")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("听书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        service.stop()
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .disabled(service.state == .idle)
                }
            }
            .sheet(isPresented: $showEngineEditor) {
                TTSEngineEditor()
            }
            .onAppear {
                Task {
                    systemVoices = await SystemTTSEngine().availableVoices()
                }
                service.configure(store: ttsStore)
                if service.bookTitle != book.title || service.state == .idle {
                    service.start(
                        book: book,
                        chapters: chapters,
                        sourceStore: sourceStore,
                        startChapter: startChapter,
                        offset: startOffset ?? 0
                    )
                }
            }
        }
    }

    private var sleepLabel: String {
        if service.sleepAtChapterEnd { return "播完本章" }
        if let remaining = service.sleepTimerRemaining {
            return String(format: "%d:%02d", remaining / 60, remaining % 60)
        }
        return "关闭"
    }

    private func runVoiceTest() async {
        testingVoice = true
        voiceTestResult = nil
        defer { testingVoice = false }
        voiceTestResult = await service.testCurrentVoice()
    }

    /// 远程引擎连不上时的一键兜底:切到系统语音(离线可用)
    private func switchToSystemVoice() async {
        let voices = await SystemTTSEngine().availableVoices()
        guard let first = voices.first else { return }
        ttsStore.selectedVoiceID = "system:\(first.id)"
        service.applySettings()
        voiceTestResult = nil
    }
}

/// 朗读引擎管理(自定义引擎列表 + 添加)
struct TTSEngineEditor: View {
    @EnvironmentObject var ttsStore: TTSStore
    @ObservedObject private var service = TTSService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var urlTemplate = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("已添加的自定义引擎") {
                    if ttsStore.customEngines.isEmpty {
                        Text("暂无。内置:微软神经音色(在线)、系统语音(离线)")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(ttsStore.customEngines) { engine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.name.isEmpty ? "未命名" : engine.name)
                                .font(.subheadline)
                            Text(engine.urlTemplate)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { indexSet in
                        ttsStore.customEngines.remove(atOffsets: indexSet)
                        service.applySettings()
                    }
                }

                Section("添加自定义引擎(兼容「阅读」朗读引擎格式)") {
                    TextField("名称,如:我的克隆声线", text: $name)
                    TextField("URL 模板(含 {{speakText}})", text: $urlTemplate, axis: .vertical)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .lineLimit(2...4)
                    TextField("备注(可选)", text: $note)
                    Button("添加") {
                        add()
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }

                Section {
                    Text("模板变量:{{speakText}} 朗读文本(URL 编码)、{{speakSpeed}} 语速。\n支持 ,{\"method\":\"POST\",\"body\":\"...\"} 选项(与书源同格式)。\n\n示例(自建 GPT-SoVITS 服务):\nhttp://192.168.1.5:9880/?text={{speakText}}&text_lang=zh&ref_audio_path=D:/APP/GPT-SoVITS/refs/我的声线.wav&prompt_text=参考文本&prompt_lang=zh")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("朗读引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func add() {
        let config = CustomEngineConfig(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            note: note.trimmingCharacters(in: .whitespaces)
        )
        ttsStore.customEngines.append(config)
        name = ""
        urlTemplate = ""
        note = ""
    }
}
