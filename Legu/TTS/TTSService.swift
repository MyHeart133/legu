import AVFoundation
import Foundation
import MediaPlayer

/// 听书服务:朗读调度 + 播放 + 后台/锁屏 + 定时停止 + 听读同步
@MainActor
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    enum State: Equatable {
        case idle, loading, playing, paused
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var bookTitle = ""
    @Published private(set) var chapterTitle = ""
    @Published private(set) var chapterIndex = 0
    @Published private(set) var chapterCount = 0
    @Published private(set) var sentenceIndex = 0
    @Published private(set) var sentenceCount = 0
    @Published private(set) var errorText: String?
    @Published private(set) var sleepTimerRemaining: Int?
    @Published private(set) var sleepAtChapterEnd = false

    /// 听读同步回调(章索引, 章内字符偏移)
    var onProgress: ((Int, Int) -> Void)?

    private var book: SourceBook?
    private var chapters: [SourceChapter] = []
    private weak var sourceStore: SourceStore?
    private var store: TTSStore?

    private var sentences: [String] = []
    private var sentenceOffsets: [Int] = []
    private var audioCache: [Int: Data] = [:]
    private var synthTasks: [Int: Task<Data?, Error>] = [:]

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var pipelineTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var generation = 0
    private var consecutiveFailures = 0
    private var remoteCommandsWired = false

    private var engine: TTSEngine?
    private var voiceRaw = "edge:zh-CN-XiaoxiaoNeural"
    private var rate: Float = 1.0

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 配置

    func configure(store: TTSStore) {
        self.store = store
        applySettings()
    }

    /// 应用音色/语速设置(播放中则从当前句重启)
    func applySettings() {
        guard let store else { return }
        voiceRaw = store.selectedVoiceID
        rate = Float(store.rate)
        let (engineID, voicePart) = TTSVoiceID.parse(voiceRaw)
        switch engineID {
        case "system":
            engine = SystemTTSEngine()
        case "custom":
            if let config = store.customEngines.first(where: { $0.id == voicePart }) {
                engine = CustomTTSEngine(config: config)
            } else {
                engine = EdgeTTSEngine()
                voiceRaw = "edge:zh-CN-XiaoxiaoNeural"
            }
        default:
            engine = EdgeTTSEngine()
        }
        if state == .playing || state == .paused {
            restartCurrentSentence()
        }
    }

    // MARK: - 播放控制

    func start(
        book: SourceBook,
        chapters: [SourceChapter],
        sourceStore: SourceStore,
        startChapter: Int,
        offset: Int
    ) {
        self.book = book
        self.chapters = chapters
        self.sourceStore = sourceStore
        self.bookTitle = book.title
        self.chapterCount = chapters.count
        sleepAtChapterEnd = false
        loadAndPlay(chapter: max(0, min(startChapter, max(0, chapters.count - 1))), offset: max(0, offset))
    }

    func stop() {
        generation += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerRemaining = nil
        sleepAtChapterEnd = false
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        cancelSynthTasks()
        state = .idle
        deactivateSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .immediate)
        }
        state = .paused
        updateNowPlaying(playing: false)
    }

    func resume() {
        guard state == .paused else { return }
        if let player {
            player.play()
        }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        }
        state = .playing
        updateNowPlaying(playing: true)
    }

    func toggle() {
        if state == .playing {
            pause()
        } else if state == .paused {
            resume()
        }
    }

    func nextChapter() {
        guard chapterIndex + 1 < chapters.count else {
            stop()
            return
        }
        sleepAtChapterEnd = false
        loadAndPlay(chapter: chapterIndex + 1, offset: 0)
    }

    func prevChapter() {
        guard chapterIndex > 0 else { return }
        sleepAtChapterEnd = false
        loadAndPlay(chapter: chapterIndex - 1, offset: 0)
    }

    /// 定时停止(minutes = nil 取消)
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerRemaining = nil
        sleepAtChapterEnd = false
        guard let minutes else { return }
        sleepTimerRemaining = minutes * 60
        sleepTask = Task { @MainActor in
            var remaining = minutes * 60
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                remaining -= 1
                self.sleepTimerRemaining = remaining
            }
            self.sleepTimerRemaining = nil
            self.pause()
        }
    }

    /// 播完本章停止
    func setSleepAtChapterEnd() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimerRemaining = nil
        sleepAtChapterEnd = true
    }

    // MARK: - 内部流程

    private func loadAndPlay(chapter: Int, offset: Int) {
        guard let book, let sourceStore, chapter >= 0, chapter < chapters.count else { return }
        generation += 1
        let gen = generation
        pipelineTask?.cancel()
        cancelSynthTasks()
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        chapterIndex = chapter
        chapterTitle = chapters[chapter].title
        sentenceIndex = 0
        sentenceCount = 0
        state = .loading
        errorText = nil
        activateSession()

        pipelineTask = Task { @MainActor in
            do {
                let text = try await ChapterLoader.load(
                    sourceStore: sourceStore, book: book, chapter: self.chapters[chapter]
                )
                guard gen == self.generation else { return }
                self.sentences = SentenceSplitter.split(text)
                self.sentenceOffsets = SentenceSplitter.offsets(for: self.sentences, source: text)
                self.sentenceCount = self.sentences.count
                self.audioCache = [:]
                self.consecutiveFailures = 0
                guard !self.sentences.isEmpty else {
                    throw SourceError.decode("本章无可朗读内容")
                }
                self.sentenceIndex = self.sentenceIndex(forOffset: offset)
                self.state = .playing
                self.playCurrentSentence()
            } catch {
                guard gen == self.generation else { return }
                self.errorText = error.localizedDescription
                self.state = .paused
            }
        }
    }

    private func sentenceIndex(forOffset offset: Int) -> Int {
        guard !sentenceOffsets.isEmpty else { return 0 }
        var index = 0
        for (i, start) in sentenceOffsets.enumerated() where start <= offset {
            index = i
        }
        return index
    }

    private func playCurrentSentence() {
        guard let engine else { return }
        guard sentenceIndex >= 0, sentenceIndex < sentences.count else { return }
        let gen = generation
        let text = sentences[sentenceIndex]
        onProgress?(chapterIndex, sentenceOffsets.indices.contains(sentenceIndex) ? sentenceOffsets[sentenceIndex] : 0)
        prefetchUpcoming()

        if engine.isRemote {
            if let cached = audioCache[sentenceIndex] {
                consecutiveFailures = 0
                playAudio(cached)
                return
            }
            Task { @MainActor in
                do {
                    let data = try await self.synthesize(index: self.sentenceIndex, text: text, gen: gen)
                    guard gen == self.generation, self.state == .playing else { return }
                    self.consecutiveFailures = 0
                    self.playAudio(data)
                } catch {
                    guard gen == self.generation else { return }
                    self.handleSynthFailure(error)
                }
            }
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: TTSVoiceID.parse(voiceRaw).voice)
            utterance.rate = min(1.0, max(0.1, 0.5 * rate))
            synthesizer.speak(utterance)
            updateNowPlaying(playing: true)
        }
    }

    private func synthesize(index: Int, text: String, gen: Int) async throws -> Data {
        guard let engine else {
            throw SourceError.unsupported("未配置朗读引擎")
        }
        if let existing = synthTasks[index] {
            if let data = try await existing.value {
                return data
            }
        }
        let (_, voice) = TTSVoiceID.parse(voiceRaw)
        let currentRate = rate
        let task = Task<Data?, Error> {
            try await engine.synthesize(text: text, voiceID: voice, rate: currentRate)
        }
        synthTasks[index] = task
        let result = try await task.value
        synthTasks[index] = nil
        guard let data = result else {
            throw SourceError.decode("朗读引擎未返回音频")
        }
        audioCache[index] = data
        return data
    }

    private func prefetchUpcoming() {
        guard let engine, engine.isRemote else { return }
        let gen = generation
        for delta in 1...2 {
            let index = sentenceIndex + delta
            guard index < sentences.count else { continue }
            guard audioCache[index] == nil, synthTasks[index] == nil else { continue }
            let text = sentences[index]
            let (_, voice) = TTSVoiceID.parse(voiceRaw)
            let currentRate = rate
            synthTasks[index] = Task<Data?, Error> {
                let data = try await engine.synthesize(text: text, voiceID: voice, rate: currentRate)
                await MainActor.run {
                    guard gen == self.generation else { return }
                    self.audioCache[index] = data
                }
                return data
            }
        }
    }

    private func playAudio(_ data: Data) {
        do {
            let newPlayer = try AVAudioPlayer(data: data)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player?.stop()
            player = newPlayer
            newPlayer.play()
            updateNowPlaying(playing: true)
        } catch {
            handleSynthFailure(error)
        }
    }

    private func handleSynthFailure(_ error: Error) {
        consecutiveFailures += 1
        if consecutiveFailures >= 4 {
            errorText = "朗读失败:\(error.localizedDescription)"
            state = .paused
            consecutiveFailures = 0
            return
        }
        // 跳过这一句继续
        sentenceIndex += 1
        if sentenceIndex >= sentenceCount {
            advanceToNextChapter()
        } else {
            playCurrentSentence()
        }
    }

    private func advance() {
        guard state == .playing else { return }
        if sleepAtChapterEnd, sentenceIndex >= sentenceCount - 1 {
            stop()
            return
        }
        sentenceIndex += 1
        if sentenceIndex >= sentenceCount {
            advanceToNextChapter()
            return
        }
        playCurrentSentence()
    }

    private func advanceToNextChapter() {
        guard chapterIndex + 1 < chapters.count else {
            stop()
            return
        }
        loadAndPlay(chapter: chapterIndex + 1, offset: 0)
    }

    private func restartCurrentSentence() {
        generation += 1
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
        cancelSynthTasks()
        audioCache = [:]
        state = .playing
        playCurrentSentence()
    }

    private func cancelSynthTasks() {
        for (_, task) in synthTasks {
            task.cancel()
        }
        synthTasks = [:]
    }

    // MARK: - 会话 / 锁屏

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        wireRemoteCommands()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func wireRemoteCommands() {
        guard !remoteCommandsWired else { return }
        remoteCommandsWired = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            Task { @MainActor in self.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in self.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in self.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in self.nextChapter() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in self.prevChapter() }
            return .success
        }
    }

    private func updateNowPlaying(playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: bookTitle,
            MPMediaItemPropertyArtist: chapterTitle,
            MPMediaItemPropertyAlbumTitle: "乐读 · 听书",
            MPNowPlayingInfoPropertyPlaybackRate: playing ? rate : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if sentenceCount > 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
            info[MPMediaItemPropertyPlaybackDuration] = 0.0
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

// MARK: - 播放完成回调

extension TTSService: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.advance()
        }
    }
}

// MARK: - 系统语音完成回调

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.engine?.isRemote == false else { return }
            self.advance()
        }
    }
}
