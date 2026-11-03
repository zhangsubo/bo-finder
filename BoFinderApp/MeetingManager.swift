import AppKit
import AVFoundation
import Combine

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
    @Published var status = "本地录音就绪"
    @Published var error = ""
    @Published var busy = Set<UUID>()
    var onRecordingChanged: (() -> Void)?
    private var capture: MeetingCapture?
    private var worker: MeetingLiveWorker?
    private var appleWorker: (any MeetingAppleLiveSession)?
    private let detector = MeetingDetector()
    private var timer: Timer?
    private var began: Date?
    private var autoSession = false
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private let configURL = MeetingFiles.root.appendingPathComponent("configuration.json")

    private init() {
        do {
            records = try MeetingFiles.load()
            for i in records.indices {
                if ["recording", "paused", "starting"].contains(records[i].phase) { records[i].phase = "interrupted"; records[i].issue = "上次录音意外中断，已保存的音频可重新转录。" }
                if records[i].transcriptState == "working" { records[i].transcriptState = "failed" }
                if records[i].summaryState == "working" { records[i].summaryState = "failed" }
                recoverOrphans(index: i)
                try MeetingFiles.save(records[i])
            }
            if FileManager.default.fileExists(atPath: configURL.path) { config = try JSONDecoder().decode(MeetingConfiguration.self, from: Data(contentsOf: configURL)) }
        } catch { self.error = "会议资料读取失败，请保留原文件并检查：\(error.localizedDescription)" }
        // Build-local defaults only when they actually exist; installed builds can choose their own runtime.
        let build = Bundle.main.bundleURL.deletingLastPathComponent()
        if config.python.isEmpty, FileManager.default.isExecutableFile(atPath: build.appendingPathComponent("meeting-runtime/bin/python").path) {
            config.python = build.appendingPathComponent("meeting-runtime/bin/python").path
            config.models = build.appendingPathComponent("meeting-models").path
        }
    }

    func activate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.active != nil { self?.error = "系统即将休眠，已结束当前录音并保存。"; await self?.end(process: false) } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard self?.active != nil else { return }; self?.error = "麦克风录制中断，请检查音频设备。"; await self?.end(process: false) }
        })
    }

    private func recoverOrphans(index: Int) {
        let directory = MeetingFiles.directory(records[index].id)
        let known = Set(records[index].chunks.map(\.file))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "wav" && !known.contains(file.lastPathComponent) {
            let parts = file.lastPathComponent.split(separator: "-")
            guard parts.count > 2, let ms = Double(parts[1]), let audio = try? AVAudioFile(forReading: file) else { continue }
            records[index].chunks.append(MeetingAudioChunk(file: file.lastPathComponent, start: ms / 1000, duration: Double(audio.length) / audio.processingFormat.sampleRate, source: String(parts[0])))
        }
        records[index].chunks.sort { $0.start < $1.start }
    }

    func saveConfiguration() {
        do {
            try FileManager.default.createDirectory(at: MeetingFiles.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        } catch { self.error = "设置保存失败：\(error.localizedDescription)" }
    }

    private func tick() {
        if let began, active != nil { elapsed = Date().timeIntervalSince(began) }
        if elapsed >= 4 * 3600, active != nil { error = "已达到单次四小时录音上限，正在保存。"; Task { await end() }; return }
        guard !starting, !stopping else { return }
        // Continue observing an active auto-session even when its toggle is switched off.
        if config.automatic || autoSession {
            let event = detector.poll(config: config)
            if let source = event.started, active == nil {
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized || config.microphone == "off", !config.systemAudio || CGPreflightScreenCaptureAccess() else {
                    detector.suppressCurrent(); status = "已检测到通话，但缺少录音权限。请先手动录音完成授权。"; return
                }
                Task { await start(online: true, source: source == "com.tencent.meeting" ? "腾讯会议" : "微信通话", automatic: true) }
            }
            if event.ended && autoSession && active != nil { Task { await end() } }
        }
    }

    func start(online: Bool, source: String = "线下会议", automatic: Bool = false) async {
        guard active == nil, !starting, !stopping else { return }
        if !online && config.microphone == "off" { error = "线下录音需要开启麦克风。"; return }
        let settings = config
        starting = true; error = ""
        defer { starting = false }
        var record = MeetingRecord(title: "\(source) · \(Date().formatted(date: .abbreviated, time: .shortened))", source: source)
        record.phase = "starting"
        do { try MeetingFiles.save(record) } catch { self.error = "无法创建会议记录：\(error.localizedDescription)"; starting = false; return }
        records.insert(record, at: 0); selected = record.id
        let recorder = MeetingCapture()
        recorder.onChunk = { [weak self] chunk in Task { @MainActor in self?.received(chunk, id: record.id) } }
        recorder.onFailure = { [weak self] message in Task { @MainActor in self?.error = message; await self?.end(process: false) } }
        capture = recorder; active = record.id; autoSession = automatic; began = Date(); elapsed = 0
        var previewIssue: String?
        if settings.transcription == "local", settings.liveEngine == "apple" {
            do {
                var sources: [String] = []
                if settings.microphone != "off" { sources.append("mic") }
                if online && settings.systemAudio { sources.append("system") }
                let live = try await MeetingAppleSpeech.start(locale: settings.speechLocale, sources: sources)
                guard active == record.id, !stopping else { await live.finish(); return }
                live.onUpdate = { [weak self] segments in
                    guard let self, self.active == record.id else { return }
                    self.update(record.id) { $0.preview = segments }
                }
                live.onStatus = { [weak self] value in
                    guard self?.active == record.id else { return }
                    self?.status = value
                }
                appleWorker = live
            } catch { previewIssue = error.localizedDescription }
        }
        guard active == record.id, !stopping else { return }
        do {
            try await recorder.start(directory: MeetingFiles.directory(record.id), config: settings, system: online && settings.systemAudio)
            guard active == record.id else { await recorder.stop(); return }
            update(record.id) { $0.phase = "recording" }
            status = "录音中，音频保存在本机"
            if settings.transcription == "local", settings.liveEngine == "apple" {
                status = previewIssue ?? "Apple 原生实时识别 · 预览会后由 X-ASR 校正并分离说话人"
            } else if settings.transcription == "local" {
                let live = MeetingLiveWorker()
                live.onStatus = { [weak self] value in Task { @MainActor in self?.status = value } }
                do { try live.start(config: settings); worker = live } catch { status = error.localizedDescription }
            } else { status = "云端转录已选择；会后发送音频，实时预览仅本地模式提供。" }
            onRecordingChanged?()
        } catch {
            await appleWorker?.finish(); appleWorker = nil
            update(record.id) { $0.phase = "interrupted"; $0.issue = "录音启动失败，请检查音源与系统权限。" }
            self.error = error.localizedDescription
            active = nil; capture = nil; autoSession = false; detector.suppressCurrent()
        }
        starting = false
    }

    private func received(_ chunk: MeetingAudioChunk, id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        update(id) { if !$0.chunks.contains(where: { $0.file == chunk.file }) { $0.chunks.append(chunk) }; $0.duration = max($0.duration, chunk.start + chunk.duration) }
        if active == id, let appleWorker {
            appleWorker.submit(chunk, file: MeetingFiles.directory(id).appendingPathComponent(chunk.file))
            return
        }
        guard active == id, let worker else { return }
        worker.submit(chunk, file: MeetingFiles.directory(id).appendingPathComponent(chunk.file)) { [weak self] segment, seconds in
            Task { @MainActor in
                guard let self, self.active == id else { return }
                if let segment {
                    self.update(id) { record in
                        if let index = record.preview.firstIndex(where: { $0.id == segment.id }) { record.preview[index] = segment }
                        else { record.preview.append(segment) }
                        record.preview.sort { $0.start < $1.start }
                    }
                }
                self.status = String(format: "本地识别 · 最近片段处理 %.1f 秒 · 预览会后校正", seconds)
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
        stopping = true; detector.suppressCurrent()
        await capture?.stop()
        // onChunk callbacks are queued to MainActor; yield before freezing the manifest.
        await Task.yield()
        await appleWorker?.finish(); appleWorker = nil
        worker?.stop(); worker = nil; capture = nil
        if let index = records.firstIndex(where: { $0.id == id }) { recoverOrphans(index: index) }
        update(id) { $0.phase = process ? "ended" : "interrupted"; $0.duration = max($0.duration, elapsed) }
        active = nil; began = nil; autoSession = false; stopping = false
        status = "录音已保存"; onRecordingChanged?()
        if process { await transcribe(id) }
    }

    func transcribe(_ id: UUID) async {
        guard active != id, !busy.contains(id), let record = records.first(where: { $0.id == id }), !record.chunks.isEmpty else { error = "当前会议没有可处理的音频，或任务正在运行。"; return }
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
                    if !text.isEmpty { result.append(MeetingSegment(start: chunk.start, end: chunk.start + chunk.duration, speaker: "?", text: text)) }
                }
                segments = result.sorted { $0.start < $1.start }
            }
            guard !segments.isEmpty else { throw MeetingFailure.message("未识别到可用发言。录音仍保留，请检查音源后重试。") }
            // Preserve the previous transcript before any reprocessing or human revision.
            try archive(record)
            update(id) {
                $0.segments = segments; $0.revision += 1; $0.transcriptState = "ready"
                // Fresh clustering IDs cannot inherit identities from the old clustering.
                $0.speakerNames = [:]
                $0.issue = settings.transcription == "local" ? "" : "云端接口未提供说话人及精确时间；当前为片段时间，需人工校对。"
            }
            busy.remove(id)
            await summarize(id)
        } catch {
            update(id) { $0.transcriptState = "failed"; $0.issue = error.localizedDescription }
            busy.remove(id)
        }
    }

    func summarize(_ id: UUID) async {
        guard !busy.contains(id), let record = records.first(where: { $0.id == id }), !record.segments.isEmpty else { return }
        let settings = config
        guard !settings.summaryBase.isEmpty, !settings.summaryModel.isEmpty else { update(id) { $0.summaryState = "unconfigured" }; return }
        busy.insert(id); update(id) { $0.summaryState = "working" }
        do {
            let text = try await MeetingCloud.summarize(record, config: settings)
            update(id) { $0.summaries.append(MeetingSummary(transcriptRevision: record.revision, model: settings.summaryModel, template: settings.template, text: text)); $0.summaryState = "ready" }
        } catch { update(id) { $0.summaryState = "failed"; $0.issue = error.localizedDescription } }
        busy.remove(id)
    }

    func edit(_ id: UUID, segment: UUID, text: String, speaker: String) {
        guard !busy.contains(id), let record = records.first(where: { $0.id == id }) else { return }
        do { try archive(record) } catch { self.error = "无法备份旧转录，修改未保存。"; return }
        update(id) { record in
            guard let index = record.segments.firstIndex(where: { $0.id == segment }) else { return }
            record.segments[index].text = text; record.segments[index].speaker = speaker; record.revision += 1
        }
    }
    func rename(_ id: UUID, speaker: String, name: String) {
        guard !busy.contains(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let record = records.first(where: { $0.id == id }) else { return }
        do { try archive(record) } catch { self.error = "无法备份旧转录，修改未保存。"; return }
        update(id) { $0.speakerNames[speaker] = name; $0.revision += 1 }
    }
    func title(_ id: UUID, _ title: String) { if !title.trimmingCharacters(in: .whitespaces).isEmpty { update(id) { $0.title = title } } }
    func delete(_ id: UUID) {
        guard active != id, !busy.contains(id) else { return }
        do { try FileManager.default.trashItem(at: MeetingFiles.directory(id), resultingItemURL: nil); records.removeAll { $0.id == id }; selected = nil }
        catch { self.error = "无法移至废纸篓：\(error.localizedDescription)" }
    }
    func play(_ id: UUID, at time: Double) {
        guard let record = records.first(where: { $0.id == id }),
              let chunk = record.chunks.first(where: { $0.start <= time && $0.start + $0.duration > time }) else { error = "该时间没有音频片段。"; return }
        do { player = try AVAudioPlayer(contentsOf: MeetingFiles.directory(id).appendingPathComponent(chunk.file)); player?.currentTime = max(0, time - chunk.start); player?.play() }
        catch { self.error = "音频回放失败：\(error.localizedDescription)" }
    }
    func export(_ record: MeetingRecord, summary: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = summary ? "会议纪要.md" : "完整转录.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ("# \(record.title)\n\n" + (summary ? record.summaries.last?.text ?? "尚未生成纪要" : record.transcript)).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "导出失败：\(error.localizedDescription)" }
    }
    private func archive(_ record: MeetingRecord) throws {
        if record.segments.isEmpty { return }
        let file = MeetingFiles.directory(record.id).appendingPathComponent("transcript-r\(record.revision)-\(UUID().uuidString).json")
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }
    private func update(_ id: UUID, change: (inout MeetingRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
        do { try MeetingFiles.save(records[i]) } catch { self.error = "会议保存失败，请检查磁盘空间：\(error.localizedDescription)" }
    }
}
