import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

private final class MeetingPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinished: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag { onFinished?() }
    }
}

@MainActor
final class MeetingManager: ObservableObject {
    static let shared = MeetingManager()

    @Published var records: [MeetingRecord] = []
    @Published var selected: UUID?
    @Published var config = MeetingConfiguration()
    @Published var active: UUID?
    @Published var starting = false
    @Published var stopping = false
    @Published var elapsed: Double = 0
    @Published var status = "本地零依赖实时识别就绪"
    @Published var error = ""
    @Published var busy = Set<UUID>()
    @Published var liveVolatiles: [String: String] = [:]

    var onRecordingChanged: (() -> Void)?

    var liveVolatileSummary: String {
        let mic = liveVolatiles["mic"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sys = liveVolatiles["system"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !mic.isEmpty && !sys.isEmpty {
            return "我：\(mic)  |  对方：\(sys)"
        }
        if !mic.isEmpty { return (onlineSession ? "我：" : "") + mic }
        if !sys.isEmpty { return "对方：" + sys }
        return ""
    }

    private var capture: MeetingCapture?
    private var worker: MeetingLiveWorker?
    private var appleWorker: (any MeetingAppleLiveSession)?
    private let speakerTagger = MeetingSpeakerTagger()
    private let detector = MeetingDetector()
    private var timer: Timer?
    private var began: Date?
    private var autoSession = false
    private var onlineSession = false
    private var activeUsesAppleNative = false
    private var lastFinalMeta: [String: (segmentID: UUID, wasCut: Bool, samples: [Float]?)] = [:]

    private var player: AVAudioPlayer?
    private let playbackDelegate = MeetingPlaybackDelegate()
    private var playbackRemainingChunks: [(url: URL, startOffset: Double)] = []
    private var observers: [NSObjectProtocol] = []
    private let configURL = MeetingFiles.root.appendingPathComponent("configuration.json")

    private init() {
        playbackDelegate.onFinished = { [weak self] in
            Task { @MainActor in self?.playNextQueuedChunk() }
        }
        do {
            records = try MeetingFiles.load()
            for i in records.indices {
                if ["recording", "paused", "starting"].contains(records[i].phase) {
                    records[i].phase = "interrupted"
                    records[i].issue = records[i].segments.isEmpty
                        ? "上次录音意外中断，已保存的音频可重新转录。"
                        : "上次录音意外中断，已保留实时转录记录。"
                    if !records[i].segments.isEmpty {
                        records[i].transcriptState = "ready"
                    }
                }
                if records[i].transcriptState == "working" { records[i].transcriptState = "failed" }
                if records[i].summaryState == "working" { records[i].summaryState = "failed" }
                recoverOrphans(index: i)
                try MeetingFiles.save(records[i])
            }
            if FileManager.default.fileExists(atPath: configURL.path) {
                config = try JSONDecoder().decode(MeetingConfiguration.self, from: Data(contentsOf: configURL))
            }
        } catch {
            self.error = "会议资料读取失败，请保留原文件并检查：\(error.localizedDescription)"
        }
        let build = Bundle.main.bundleURL.deletingLastPathComponent()
        if config.python.isEmpty, FileManager.default.isExecutableFile(atPath: build.appendingPathComponent("meeting-runtime/bin/python").path) {
            config.python = build.appendingPathComponent("meeting-runtime/bin/python").path
            config.models = build.appendingPathComponent("meeting-models").path
        }
    }

    func activate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.active != nil {
                    self?.error = "系统即将休眠，已结束当前录音并保存。"
                    await self?.end(process: false)
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard self?.active != nil else { return }
                self?.error = "麦克风录制中断，请检查音频设备。"
                await self?.end(process: false)
            }
        })
    }

    private func recoverOrphans(index: Int) {
        let directory = MeetingFiles.directory(records[index].id)
        let known = Set(records[index].chunks.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "wav" && !known.contains(file.lastPathComponent) {
            let parts = file.lastPathComponent.split(separator: "-")
            guard parts.count > 2, let ms = Double(parts[1]), let audio = try? AVAudioFile(forReading: file) else { continue }
            records[index].chunks.append(MeetingAudioChunk(
                file: file.lastPathComponent,
                start: ms / 1000,
                duration: Double(audio.length) / audio.processingFormat.sampleRate,
                source: String(parts[0])
            ))
        }
        records[index].chunks.sort { $0.start < $1.start }
    }

    func saveConfiguration() {
        do {
            try FileManager.default.createDirectory(at: MeetingFiles.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
            MeetingFloatingPanelController.shared.syncSharingType()
        } catch {
            self.error = "设置保存失败：\(error.localizedDescription)"
        }
    }

    private func tick() {
        if let began, active != nil { elapsed = Date().timeIntervalSince(began) }
        if elapsed >= 4 * 3600, active != nil {
            error = "已达到单次四小时录音上限，正在保存。"
            Task { await end() }
            return
        }
        guard !starting, !stopping else { return }
        if config.automatic || autoSession {
            let event = detector.poll(config: config)
            if let sourceBundle = event.started, active == nil {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized || config.microphone == "off" else {
                    detector.suppressCurrent()
                    status = "已检测到通话，但尚未授予麦克风权限。请先手动开始一次录音完成授权。"
                    return
                }
                let appName = MeetingDetector.displayName(for: sourceBundle)
                Task { await start(online: true, source: appName, automatic: true) }
            }
            if event.ended && autoSession && active != nil {
                Task { await end() }
            }
        }
    }

    func start(online: Bool, source: String = "线下会议", automatic: Bool = false) async {
        guard active == nil, !starting, !stopping else { return }
        if !online && config.microphone == "off" {
            error = "线下录音需要开启麦克风。"
            return
        }
        let settings = config
        starting = true
        error = ""
        defer { starting = false }

        var record = MeetingRecord(
            title: "\(source) · \(Date().formatted(date: .abbreviated, time: .shortened))",
            source: source
        )
        record.phase = "starting"
        do {
            try MeetingFiles.save(record)
        } catch {
            self.error = "无法创建会议记录：\(error.localizedDescription)"
            return
        }

        records.insert(record, at: 0)
        selected = record.id

        let recorder = MeetingCapture()
        recorder.onChunk = { [weak self] chunk in
            Task { @MainActor in self?.received(chunk, id: record.id) }
        }
        recorder.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.error = message
                await self?.end(process: false)
            }
        }

        capture = recorder
        active = record.id
        autoSession = automatic
        onlineSession = online && settings.systemAudio
        activeUsesAppleNative = false
        liveVolatiles = [:]
        lastFinalMeta = [:]
        speakerTagger.reset()
        began = Date()
        elapsed = 0

        var previewIssue: String?
        if settings.transcription == "local", settings.liveEngine == "apple" {
            do {
                var sources: [String] = []
                if settings.microphone != "off" { sources.append("mic") }
                if online && settings.systemAudio { sources.append("system") }
                let live = try await MeetingAppleSpeech.start(
                    locale: settings.speechLocale,
                    sources: sources,
                    captureVoice: settings.enableVoiceprint
                )
                guard active == record.id, !stopping else { await live.finish(); return }

                live.onUpdate = { [weak self] segments in
                    guard let self, self.active == record.id else { return }
                    self.update(record.id) { $0.preview = segments }
                }
                live.onVolatile = { [weak self] src, text in
                    guard let self, self.active == record.id else { return }
                    self.liveVolatiles[src] = text
                }
                live.onFinalSegment = { [weak self] finalized in
                    guard let self, self.active == record.id else { return }
                    self.handleAppleFinalized(finalized, meetingID: record.id)
                }
                live.onStatus = { [weak self] value in
                    guard self?.active == record.id else { return }
                    self?.status = value
                }
                recorder.onPCMBuffer = { [weak live] src, pcm in
                    Task { @MainActor in
                        live?.push(source: src, buffer: pcm, startTime: nil)
                    }
                }
                appleWorker = live
                activeUsesAppleNative = true
            } catch {
                previewIssue = error.localizedDescription
            }
        }

        guard active == record.id, !stopping else { return }
        do {
            try await recorder.start(
                directory: MeetingFiles.directory(record.id),
                config: settings,
                system: online && settings.systemAudio
            )
            guard active == record.id else { await recorder.stop(); return }
            update(record.id) { $0.phase = "recording" }

            if settings.transcription == "local", settings.liveEngine == "apple" {
                status = previewIssue ?? (settings.enableVoiceprint
                    ? "Apple 原生实时识别 + 内置 Core ML 声纹运行中（零 Python 依赖）"
                    : "Apple 原生实时识别运行中")
                MeetingNotesEngine.shared.begin(meetingID: record.id)
            } else if settings.transcription == "local" {
                let live = MeetingLiveWorker()
                live.onStatus = { [weak self] value in Task { @MainActor in self?.status = value } }
                do { try live.start(config: settings); worker = live } catch { status = error.localizedDescription }
            } else {
                status = "云端转录已选择；会后发送音频，实时预览仅本地模式提供。"
            }

            if settings.autoShowFloatingPanel {
                MeetingFloatingPanelController.shared.show()
            }
            onRecordingChanged?()
        } catch {
            await appleWorker?.finish()
            appleWorker = nil
            MeetingNotesEngine.shared.stopLiveTimer()
            update(record.id) {
                $0.phase = "interrupted"
                $0.issue = "录音启动失败，请检查音源与系统权限。"
            }
            self.error = error.localizedDescription
            active = nil
            capture = nil
            autoSession = false
            detector.suppressCurrent()
        }
    }

    private func handleAppleFinalized(_ item: MeetingAppleFinalizedSegment, meetingID: UUID) {
        guard let recordIndex = records.firstIndex(where: { $0.id == meetingID }) else { return }

        // In online dual-source mode, filter out microphone speakerphone echo that duplicates system audio.
        if onlineSession && item.source == "mic" {
            let recentSystem = records[recordIndex].segments.suffix(12).filter { seg in
                seg.speaker != "me"
                    && seg.start <= item.segment.end + 1.5
                    && seg.end >= item.segment.start - 1.5
            }
            if recentSystem.contains(where: { MeetingHeardText.isEcho(item.segment.text, of: $0.text) }) {
                return
            }
        }

        // Rejoin utterances split across a short micro-pause (<= 1.5s) from the same audio track.
        if let prevMeta = lastFinalMeta[item.source],
           let prevIndex = records[recordIndex].segments.firstIndex(where: { $0.id == prevMeta.segmentID }) {
            let prevSeg = records[recordIndex].segments[prevIndex]
            let gap = item.segment.start - prevSeg.end
            if MeetingHeardText.continues(prevSeg.text, item.segment.text, gap: gap, cut: prevMeta.wasCut) {
                let joinedText = MeetingHeardText.join(prevSeg.text, item.segment.text)
                let newEnd = max(prevSeg.end, item.segment.end)
                var mergedSamples: [Float]? = nil
                if prevMeta.samples != nil || item.voiceSamples != nil {
                    let combined = (prevMeta.samples ?? []) + (item.voiceSamples ?? [])
                    let maxCount = Int(MeetingVoiceprints.maxSeconds * 16_000)
                    mergedSamples = combined.count > maxCount ? Array(combined.prefix(maxCount)) : combined
                }
                lastFinalMeta[item.source] = (prevSeg.id, item.wasCut, mergedSamples)
                update(meetingID) { rec in
                    if let idx = rec.segments.firstIndex(where: { $0.id == prevSeg.id }) {
                        rec.segments[idx].text = joinedText
                        rec.segments[idx].end = newEnd
                        rec.duration = max(rec.duration, newEnd)
                    }
                }
                let needsVoice = (!onlineSession || item.source == "system") && config.enableVoiceprint
                if needsVoice, prevSeg.voiceID == nil, let samples = mergedSamples {
                    tagSegmentVoice(meetingID: meetingID, segmentID: prevSeg.id, samples: samples)
                }
                return
            }
        }

        var seg = item.segment
        if onlineSession && item.source == "mic" {
            seg.speaker = "me"
        } else if onlineSession && item.source == "system" {
            seg.speaker = "them"
        } else {
            seg.speaker = "?"
        }

        lastFinalMeta[item.source] = (seg.id, item.wasCut, item.voiceSamples)
        update(meetingID) { rec in
            rec.segments.append(seg)
            rec.segments.sort { $0.start < $1.start }
            rec.duration = max(rec.duration, seg.end)
            rec.transcriptState = "ready"
        }

        let shouldTagVoice = (!onlineSession || item.source == "system") && config.enableVoiceprint
        if shouldTagVoice, let samples = item.voiceSamples {
            tagSegmentVoice(meetingID: meetingID, segmentID: seg.id, samples: samples)
        } else {
            MeetingSpeakerNamer.shared.maybeGuess(for: meetingID)
        }
    }

    private func tagSegmentVoice(meetingID: UUID, segmentID: UUID, samples: [Float]) {
        speakerTagger.identify(samples: samples) { [weak self] voice in
            guard let self, let voice else { return }
            self.update(meetingID) { rec in
                guard let idx = rec.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                rec.segments[idx].voiceID = voice
                rec.segments[idx].speaker = "v\(voice)"
            }
            MeetingSpeakerNamer.shared.maybeGuess(for: meetingID)
        }
    }

    private func received(_ chunk: MeetingAudioChunk, id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        update(id) {
            if !$0.chunks.contains(where: { $0.file == chunk.file }) {
                $0.chunks.append(chunk)
                $0.chunks.sort { $0.start < $1.start }
            }
            $0.duration = max($0.duration, chunk.start + chunk.duration)
        }
        // When Apple Speech is active, PCM buffers already stream directly in memory via `onPCMBuffer`.
        if active == id, appleWorker != nil { return }
        guard active == id, let worker else { return }
        worker.submit(chunk, file: MeetingFiles.directory(id).appendingPathComponent(chunk.file)) { [weak self] segment, seconds in
            Task { @MainActor in
                guard let self, self.active == id else { return }
                if let segment {
                    self.update(id) { record in
                        if let index = record.preview.firstIndex(where: { $0.id == segment.id }) {
                            record.preview[index] = segment
                        } else {
                            record.preview.append(segment)
                        }
                        record.preview.sort { $0.start < $1.start }
                    }
                }
                self.status = String(format: "本地 X-ASR 识别 · 最近片段处理 %.1f 秒 · 预览会后校正", seconds)
            }
        }
    }

    func pause() {
        guard let id = active, let record = records.first(where: { $0.id == id }), !starting, !stopping else { return }
        let paused = record.phase != "paused"
        capture?.pause(paused)
        update(id) { $0.phase = paused ? "paused" : "recording" }
        onRecordingChanged?()
    }

    func end(process: Bool = true) async {
        guard let id = active, !stopping else { return }
        stopping = true
        detector.suppressCurrent()
        let usedAppleNative = activeUsesAppleNative
        MeetingNotesEngine.shared.stopLiveTimer()

        await capture?.stop()
        await Task.yield()
        await appleWorker?.finish()
        appleWorker = nil
        worker?.stop()
        worker = nil
        capture = nil
        liveVolatiles = [:]
        lastFinalMeta = [:]

        if let index = records.firstIndex(where: { $0.id == id }) {
            recoverOrphans(index: index)
        }

        update(id) { rec in
            rec.phase = process ? "ended" : "interrupted"
            rec.duration = max(rec.duration, elapsed)
            // Promote preview if a very short clip ended before final callback landed.
            if usedAppleNative && rec.segments.isEmpty && !rec.preview.isEmpty {
                rec.segments = rec.preview
            }
            if usedAppleNative && !rec.segments.isEmpty {
                rec.transcriptState = "ready"
                rec.issue = ""
            }
        }

        active = nil
        began = nil
        autoSession = false
        activeUsesAppleNative = false
        stopping = false
        status = "录音已保存"
        onRecordingChanged?()

        guard process else { return }
        if usedAppleNative {
            if let rec = records.first(where: { $0.id == id }), !rec.segments.isEmpty {
                MeetingSpeakerNamer.shared.maybeGuess(for: id, force: true)
                await summarize(id)
            } else {
                update(id) {
                    $0.transcriptState = "ready"
                    $0.issue = "本次录音未检测到清晰人声发言。"
                }
            }
        } else {
            await transcribe(id)
        }
    }

    /// Runs offline full-meeting transcription via optional Python X-ASR or Cloud ASR.
    func transcribe(_ id: UUID) async {
        guard active != id, !busy.contains(id), let record = records.first(where: { $0.id == id }), !record.chunks.isEmpty else {
            error = "当前会议没有可处理的音频，或任务正在运行。"
            return
        }
        busy.insert(id)
        let settings = config
        update(id) { $0.transcriptState = "working"; $0.issue = "" }
        do {
            let segments: [MeetingSegment]
            if settings.transcription == "local" {
                segments = try await MeetingOfflineWorker.transcribe(record: record, config: settings)
            } else {
                var result: [MeetingSegment] = []
                for chunk in record.chunks {
                    let text = try await MeetingCloud.transcribe(file: MeetingFiles.directory(id).appendingPathComponent(chunk.file), config: settings)
                    if !text.isEmpty {
                        result.append(MeetingSegment(start: chunk.start, end: chunk.start + chunk.duration, speaker: "?", text: text))
                    }
                }
                segments = result.sorted { $0.start < $1.start }
            }
            guard !segments.isEmpty else {
                throw MeetingFailure.message("未识别到可用发言。录音仍保留，请检查音源后重试。")
            }
            try archive(record)
            update(id) {
                $0.segments = segments
                $0.revision += 1
                $0.transcriptState = "ready"
                $0.speakerNames = [:]
                $0.speakerGuesses = nil
                $0.issue = settings.transcription == "local" ? "" : "云端接口未提供说话人及精确时间；当前为片段时间，需人工校对。"
            }
            busy.remove(id)
            await summarize(id)
        } catch {
            update(id) {
                $0.transcriptState = "failed"
                $0.issue = error.localizedDescription
            }
            busy.remove(id)
        }
    }

    func summarize(_ id: UUID) async {
        guard !busy.contains(id), let record = records.first(where: { $0.id == id }), !record.segments.isEmpty else { return }
        let settings = config
        guard !settings.summaryBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            update(id) { $0.summaryState = "unconfigured" }
            return
        }
        busy.insert(id)
        update(id) { $0.summaryState = "working"; $0.issue = "" }
        await MeetingNotesEngine.shared.generateFinal(for: id)
        busy.remove(id)
    }

    // MARK: - Notes & Speaker Callbacks

    func applyStructuredNotes(
        _ id: UUID,
        notes: MeetingStructuredNotes,
        model: String,
        template: String,
        final: Bool
    ) {
        update(id) { rec in
            rec.notes = notes
            if let noteTitle = notes.title, !noteTitle.isEmpty, rec.userRenamedTitle != true {
                rec.title = MeetingNotesParser.formattedAutoTitle(noteTitle: noteTitle, date: rec.date)
            }
            if final {
                let md = MeetingDocumentExport.notesMarkdown(notes)
                if !md.isEmpty {
                    rec.summaries.append(MeetingSummary(
                        transcriptRevision: rec.revision,
                        model: model,
                        template: template,
                        text: md
                    ))
                }
                rec.summaryState = "ready"
            }
        }
    }

    func applyPlainSummaryFallback(_ id: UUID, text: String, model: String, template: String) {
        update(id) { rec in
            rec.summaries.append(MeetingSummary(
                transcriptRevision: rec.revision,
                model: model,
                template: template,
                text: text
            ))
            rec.summaryState = "ready"
        }
    }

    func markSummaryUnconfigured(_ id: UUID) {
        update(id) { $0.summaryState = "unconfigured" }
    }

    func markSummaryFailed(_ id: UUID, message: String) {
        update(id) {
            $0.summaryState = "failed"
            $0.issue = message
        }
    }

    func applySpeakerGuesses(
        _ id: UUID,
        found: [String: MeetingSpeakerGuess],
        refuted: [String: String]
    ) {
        guard !found.isEmpty || !refuted.isEmpty else { return }
        update(id) { rec in
            var guesses = rec.speakerGuesses ?? [:]
            for (k, badName) in refuted where found[k] == nil && guesses[k]?.name == badName {
                guesses.removeValue(forKey: k)
            }
            for (k, guess) in found {
                guesses[k] = guess
            }
            rec.speakerGuesses = guesses.isEmpty ? nil : guesses
        }
    }

    func dismissSpeakerGuess(_ id: UUID, speaker: String) {
        update(id) { rec in
            rec.speakerNames[speaker] = ""
            rec.revision += 1
        }
    }

    func mergeSpeakers(_ id: UUID, from: String, into: String) {
        guard from != into, !busy.contains(id), let record = records.first(where: { $0.id == id }) else { return }
        try? archive(record)
        let fromVoice = from.hasPrefix("v") ? Int(from.dropFirst()) : nil
        let intoVoice = into.hasPrefix("v") ? Int(into.dropFirst()) : nil

        update(id) { rec in
            for idx in rec.segments.indices where rec.segments[idx].speaker == from {
                rec.segments[idx].speaker = into
                if let intoVoice {
                    rec.segments[idx].voiceID = intoVoice
                }
            }
            if let movedName = rec.speakerNames.removeValue(forKey: from), !movedName.isEmpty, rec.speakerNames[into] == nil {
                rec.speakerNames[into] = movedName
            }
            if var guesses = rec.speakerGuesses, let movedGuess = guesses.removeValue(forKey: from) {
                if guesses[into] == nil {
                    guesses[into] = movedGuess
                }
                rec.speakerGuesses = guesses.isEmpty ? nil : guesses
            }
            rec.revision += 1
        }

        if active == id, let f = fromVoice, let t = intoVoice {
            speakerTagger.merge(f, into: t)
        }
    }

    // MARK: - User Edits, Continuous Playback & Export

    func edit(_ id: UUID, segment: UUID, text: String, speaker: String) {
        guard !busy.contains(id), let record = records.first(where: { $0.id == id }) else { return }
        do { try archive(record) } catch { self.error = "无法备份旧转录，修改未保存。"; return }
        update(id) { record in
            guard let index = record.segments.firstIndex(where: { $0.id == segment }) else { return }
            record.segments[index].text = text
            record.segments[index].speaker = speaker
            record.revision += 1
        }
    }

    func rename(_ id: UUID, speaker: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy.contains(id), !trimmed.isEmpty,
              let record = records.first(where: { $0.id == id }) else { return }
        do { try archive(record) } catch { self.error = "无法备份旧转录，修改未保存。"; return }
        update(id) {
            $0.speakerNames[speaker] = trimmed
            $0.revision += 1
        }
    }

    func title(_ id: UUID, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) {
            $0.title = trimmed
            $0.userRenamedTitle = true
        }
    }

    func delete(_ id: UUID) {
        guard active != id, !busy.contains(id) else { return }
        do {
            try FileManager.default.trashItem(at: MeetingFiles.directory(id), resultingItemURL: nil)
            records.removeAll { $0.id == id }
            if selected == id { selected = nil }
        } catch {
            self.error = "无法移至废纸篓：\(error.localizedDescription)"
        }
    }

    /// Plays from `time` and automatically chains subsequent chunks from the same track.
    func play(_ id: UUID, at time: Double) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let sorted = record.chunks.sorted { $0.start < $1.start }
        guard let startIdx = sorted.firstIndex(where: { $0.start <= time && $0.start + $0.duration > time })
                ?? sorted.firstIndex(where: { $0.start >= time }) else {
            error = "该时间没有音频片段。"
            return
        }
        let targetSource = sorted[startIdx].source
        let dir = MeetingFiles.directory(id)
        var queue: [(url: URL, startOffset: Double)] = []
        for (idx, chunk) in sorted[startIdx...].enumerated() where chunk.source == targetSource {
            let offset = idx == 0 ? max(0, time - chunk.start) : 0
            queue.append((dir.appendingPathComponent(chunk.file), offset))
            if queue.count >= 12 { break }
        }
        playbackRemainingChunks = queue
        playNextQueuedChunk()
    }

    private func playNextQueuedChunk() {
        guard !playbackRemainingChunks.isEmpty else { return }
        let next = playbackRemainingChunks.removeFirst()
        do {
            let p = try AVAudioPlayer(contentsOf: next.url)
            p.delegate = playbackDelegate
            p.currentTime = min(max(0, next.startOffset), max(0, p.duration - 0.05))
            p.play()
            player = p
        } catch {
            playbackRemainingChunks.removeAll()
            self.error = "音频回放失败：\(error.localizedDescription)"
        }
    }

    func export(_ record: MeetingRecord, summary: Bool) {
        exportMarkdown(record, includeTranscript: !summary)
    }

    func exportMarkdown(_ record: MeetingRecord, includeTranscript: Bool = true) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let safeTitle = sanitizedFilename(record.title)
        panel.nameFieldStringValue = includeTranscript ? "\(safeTitle)-纪要与全文.md" : "\(safeTitle)-纪要.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let md = MeetingDocumentExport.markdown(for: record, includeTranscript: includeTranscript)
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "导出 Markdown 失败：\(error.localizedDescription)"
        }
    }

    func exportTranscriptOnly(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(sanitizedFilename(record.title))-纯转录.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ("# \(record.title)\n\n" + record.transcript).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "导出转录失败：\(error.localizedDescription)"
        }
    }

    func exportDocx(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        if let docxType = UTType(filenameExtension: "docx") {
            panel.allowedContentTypes = [docxType]
        }
        panel.nameFieldStringValue = "\(sanitizedFilename(record.title)).docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try MeetingDocumentExport.docx(for: record)
            try data.write(to: url, options: .atomic)
        } catch {
            self.error = "导出 Word (.docx) 失败：\(error.localizedDescription)"
        }
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "会议纪要" : cleaned
    }

    private func archive(_ record: MeetingRecord) throws {
        if record.segments.isEmpty { return }
        let file = MeetingFiles.directory(record.id).appendingPathComponent("transcript-r\(record.revision)-\(UUID().uuidString).json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }

    private func update(_ id: UUID, change: (inout MeetingRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
        do {
            try MeetingFiles.save(records[i])
        } catch {
            self.error = "会议保存失败，请检查磁盘空间：\(error.localizedDescription)"
        }
    }
}
