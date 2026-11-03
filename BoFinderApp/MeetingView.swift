import SwiftUI
import AppKit
import AVFoundation

struct MeetingView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @ObservedObject private var notesEngine = MeetingNotesEngine.shared
    @ObservedObject private var floatingPanel = MeetingFloatingPanelController.shared

    @State private var settings = false
    @State private var search = ""
    @State private var detailTab = 0
    @State private var transcriptQuery = ""
    @State private var jumpTargetTime: Double? = nil
    @State private var jumpToken: Int = 0
    @State private var editing: MeetingSegment?
    @State private var editText = ""
    @State private var editSpeaker = ""
    @State private var confirmDelete = false
    @State private var titleText = ""
    @State private var editingTitle = false
    @FocusState private var transcriptSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !manager.error.isEmpty {
                HStack {
                    Text(manager.error).font(.callout)
                    Spacer()
                    Button("关闭") { manager.error = "" }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            if settings {
                HStack {
                    Text("会议设置").font(.title2.bold())
                    Spacer()
                    Button("返回会议") { settings = false }
                }
                MeetingSettingsView()
            } else if let id = manager.selected, let record = manager.records.first(where: { $0.id == id }) {
                detail(record)
            } else {
                library
            }
        }
        .padding(24)
        .alert("移至废纸篓？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("移至废纸篓", role: .destructive) {
                if let id = manager.selected { manager.delete(id) }
            }
        } message: {
            Text("本会议的音频、转录和纪要将一起移至废纸篓。")
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("校对转录片段").font(.headline)
                TextField("说话人标签（如 me / v0 / A）", text: $editSpeaker)
                TextEditor(text: $editText).frame(height: 160)
                HStack {
                    Button("取消") { editing = nil }
                    Spacer()
                    Button("保存") {
                        if let id = manager.selected, let segment = editing {
                            manager.edit(id, segment: segment.id, text: editText, speaker: editSpeaker)
                        }
                        editing = nil
                    }
                    .disabled(editSpeaker.isEmpty || editText.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 500)
        }
    }

    // MARK: - Meeting Library

    private var filteredRecords: [MeetingRecord] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return manager.records }
        return manager.records.filter { rec in
            rec.title.localizedCaseInsensitiveContains(search)
                || rec.transcript.localizedCaseInsensitiveContains(search)
                || (rec.notes?.summary.localizedCaseInsensitiveContains(search) == true)
                || (rec.notes?.topics.contains(where: { $0.title.localizedCaseInsensitiveContains(search) }) == true)
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("会议助手").font(.title.bold())
                    Text("零 Python 原生实时转录、Core ML 声纹分离、会中增量纪要与投屏隐身悬浮窗。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    floatingPanel.toggle()
                } label: {
                    Label(floatingPanel.isVisible ? "收起桌边纪要窗" : "打开桌边纪要窗", systemImage: "sidebar.right")
                }
                Button("会议设置") { settings = true }
                Menu("开始录音") {
                    Button("线上会议 · 麦克风 + 系统音频（推荐）") {
                        Task { await manager.start(online: true, source: "手动线上会议") }
                    }
                    Button("线下会议 · 仅麦克风（多人声纹分离）") {
                        Task { await manager.start(online: false) }
                    }
                }
                .disabled(manager.active != nil || manager.starting || manager.stopping)
            }

            HStack(spacing: 12) {
                Label(
                    manager.active == nil
                        ? (manager.config.automatic ? "自动检测录制已开启" : "本机零依赖录音就绪")
                        : "正在录音 · \(MeetingRecord.shortClock(manager.elapsed))",
                    systemImage: manager.active == nil ? "waveform" : "record.circle.fill"
                )
                .foregroundColor(manager.active == nil ? .primary : .red)

                Spacer()

                if let id = manager.active {
                    Button("桌边悬浮窗") { floatingPanel.show() }
                    Button("进入实时详情") {
                        manager.selected = id
                        detailTab = 0
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.07))
            .cornerRadius(8)

            TextField("搜索会议标题、议题或转录内容", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRecords) { record in
                        Button {
                            manager.selected = record.id
                            detailTab = (record.notes?.isEmpty == false || !record.summaries.isEmpty || manager.active == record.id) ? 0 : 1
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: manager.active == record.id ? "record.circle.fill" : "waveform")
                                    .font(.title2)
                                    .foregroundColor(manager.active == record.id ? .red : .accentColor)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title).font(.headline)
                                    Text("\(record.source) · \(record.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingRecord.timestamp(record.duration)) · \(record.segments.count) 句")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(stateLabel(record))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    if manager.records.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "person.2.wave.2").font(.largeTitle).foregroundColor(.accentColor)
                            Text("让下一次对话留下来").font(.title3.bold())
                            Text("无需配置 Python，点击右上角「开始录音」即可实时转写、区分说话人并生成投屏隐身的桌边结构化纪要。")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(50)
                    }
                }
            }
            Text(manager.status).font(.caption).foregroundColor(.secondary)
        }
    }

    private func stateLabel(_ record: MeetingRecord) -> String {
        if manager.active == record.id { return record.phase == "paused" ? "已暂停" : "录音中" }
        if record.transcriptState == "working" { return "转录处理中" }
        if record.summaryState == "working" || notesEngine.generatingID == record.id { return "纪要整理中" }
        if record.transcriptState == "failed" || record.summaryState == "failed" { return "待重试" }
        if let notes = record.notes, !notes.isEmpty { return notes.isFinal ? "结构化纪要就绪" : "速记纪要已保存" }
        if !record.summaries.isEmpty { return "纪要已就绪" }
        return record.segments.isEmpty ? "待转录" : "文字记录就绪"
    }

    // MARK: - Meeting Detail

    private func detail(_ record: MeetingRecord) -> some View {
        let isLive = manager.active == record.id

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if editingTitle {
                    TextField("会议名称", text: $titleText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            manager.title(record.id, titleText)
                            editingTitle = false
                        }
                } else {
                    Text(record.title).font(.title2.bold()).lineLimit(2)
                }
                Spacer()
                Button {
                    floatingPanel.toggle()
                } label: {
                    Label(floatingPanel.isVisible ? "隐藏悬浮窗" : "桌边悬浮窗", systemImage: "sidebar.right")
                }
                Button(editingTitle ? "保存名称" : "改名") {
                    if editingTitle {
                        manager.title(record.id, titleText)
                    } else {
                        titleText = record.title
                    }
                    editingTitle.toggle()
                }
                Button("所有会议") { manager.selected = nil }
                Button("设置") { settings = true }
            }

            if isLive {
                HStack(spacing: 12) {
                    Label(record.phase == "paused" ? "已暂停" : "录音中", systemImage: "record.circle.fill")
                        .foregroundColor(.red)
                    Text(MeetingRecord.timestamp(manager.elapsed)).monospacedDigit()
                    if notesEngine.state == .updating {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("正在滚动更新实时纪要…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(record.phase == "paused" ? "继续录音" : "暂停") { manager.pause() }
                    Button("结束会议") { Task { await manager.end() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red.opacity(0.85))
                }
                .disabled(manager.starting || manager.stopping)
                Text(manager.status).font(.caption).foregroundColor(.secondary)
            } else {
                HStack {
                    Text("\(record.source) · \(record.date.formatted(date: .abbreviated, time: .shortened)) · \(stateLabel(record))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if manager.busy.contains(record.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(stateLabel(record)).font(.caption)
                        }
                    }
                }
            }

            if !record.issue.isEmpty {
                Text(record.issue)
                    .font(.callout)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }

            Picker("内容视图", selection: $detailTab) {
                Text("结构化纪要").tag(0)
                Text("文字记录 (\(record.segments.count))").tag(1)
            }
            .pickerStyle(.segmented)

            if detailTab == 0 {
                notesDetailPane(record, isLive: isLive)
            } else {
                transcriptDetailPane(record, isLive: isLive)
            }

            if !isLive {
                footerActionBar(record)
            }
        }
    }

    @ViewBuilder
    private func notesDetailPane(_ record: MeetingRecord, isLive: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notes = record.notes, !notes.isEmpty {
                    if notes.transcriptRevision != record.revision && !isLive {
                        Text("文字记录已校对更新，可点击下方「生成/更新纪要」同步最新版本。")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    MeetingStructuredNotesView(
                        record: record,
                        notes: notes,
                        freshItems: isLive ? notesEngine.freshItems : [],
                        live: isLive,
                        updating: notesEngine.state == .updating,
                        onJumpToTime: { sec in
                            jumpTargetTime = sec
                            jumpToken += 1
                            detailTab = 1
                        },
                        onSearchTerm: { term in
                            transcriptQuery = term
                            detailTab = 1
                        }
                    )
                } else if let summary = record.summaries.last {
                    if summary.transcriptRevision != record.revision {
                        Text("转录已更新，当前纪要基于旧版本。可重新生成。")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    Text(summary.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Text("\(summary.model) · 共保存 \(record.summaries.count) 个历史纪要版本")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if isLive {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(record.segments.count < 3
                             ? "正在聆听会议发言（满 3 句后自动生成首版速记）…"
                             : "正在整理首版结构化纪要…")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    Text(record.summaryState == "unconfigured"
                         ? "文字记录已就绪。请在「会议设置 → 智能纪要模型」中配置兼容接口与默认模型后点击生成。"
                         : "点击下方「生成 / 更新纪要」即可提炼议题、结论高亮、待办与同音错词表。")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func transcriptDetailPane(_ record: MeetingRecord, isLive: Bool) -> some View {
        MeetingRichTranscriptView(
            record: record,
            live: isLive,
            volatileText: isLive ? manager.liveVolatileSummary : "",
            query: $transcriptQuery,
            searchFocused: $transcriptSearchFocused,
            jumpTargetTime: jumpTargetTime,
            jumpToken: jumpToken,
            onEditSegment: { seg in
                editing = seg
                editText = seg.text
                editSpeaker = seg.speaker
            }
        )
    }

    private func footerActionBar(_ record: MeetingRecord) -> some View {
        HStack(spacing: 10) {
            Button("生成 / 更新纪要") {
                Task { await manager.summarize(record.id) }
            }
            .disabled(record.segments.isEmpty || manager.busy.contains(record.id))

            Menu("导出文档") {
                Button("导出 Word 文档 (.docx)") {
                    manager.exportDocx(record)
                }
                .disabled(record.segments.isEmpty && record.notes == nil && record.summaries.isEmpty)

                Button("导出 Markdown（纪要 + 全文 .md）") {
                    manager.exportMarkdown(record, includeTranscript: true)
                }
                .disabled(record.segments.isEmpty && record.notes == nil && record.summaries.isEmpty)

                Button("仅导出纪要 (.md)") {
                    manager.exportMarkdown(record, includeTranscript: false)
                }
                .disabled(record.notes == nil && record.summaries.isEmpty)

                Button("仅导出纯转录 (.md)") {
                    manager.exportTranscriptOnly(record)
                }
                .disabled(record.segments.isEmpty)
            }

            if manager.config.transcription == "cloud" || manager.config.liveEngine == "xasr" || !manager.config.python.isEmpty {
                Button(record.segments.isEmpty ? "离线重转" : "用外部引擎重转") {
                    Task { await manager.transcribe(record.id) }
                }
                .disabled(record.chunks.isEmpty || manager.busy.contains(record.id))
            }

            Spacer()

            Button("删除", role: .destructive) {
                confirmDelete = true
            }
            .disabled(manager.busy.contains(record.id))
        }
    }
}

// MARK: - Meeting Settings View

private struct MeetingSettingsView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @State private var tab = 0
    @State private var appDetectionExpanded = false
    @State private var legacyEngineExpanded = false
    @State private var summaryKey = ""
    @State private var asrKey = ""
    @State private var message = ""
    @State private var testing = false
    @State private var preparingSpeech = false
    @State private var speechStatus = ""

    private func binding<T>(_ path: WritableKeyPath<MeetingConfiguration, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: path] },
            set: { manager.config[keyPath: path] = $0; manager.saveConfiguration() }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("会议设置分类", selection: $tab) {
                Text("录音与悬浮窗").tag(0)
                Text("识别与声纹").tag(1)
                Text("智能纪要模型").tag(2)
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == 0 { recordingAndPanel }
                    else if tab == 1 { transcriptionAndVoiceprint }
                    else { summarySettings }

                    if !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                    }
                }
                .padding(4)
            }
        }
    }

    private var recordingAndPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("双音源采集")
            Picker("麦克风输入", selection: binding(\.microphone)) {
                Text("自动选择（系统默认）").tag("default")
                Text("关闭麦克风").tag("off")
                ForEach(MeetingCapture.inputDevices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            Toggle("系统音频 · 线上录制参会对方的声音（免录屏权限）", isOn: binding(\.systemAudio))
            Text("线上会议使用 Core Audio 进程音频采集，仅需「系统音频录制」权限，不触发屏幕录制紫点，且自动排除 DeskSide 自身回放声音。")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("检查麦克风权限") {
                    message = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                        ? "麦克风权限已授权。"
                        : "首次开始录音时将自动弹出麦克风授权请求。"
                }
                Button("打开会议保存目录") {
                    try? FileManager.default.createDirectory(at: MeetingFiles.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(MeetingFiles.root)
                }
            }

            section("桌边实时纪要悬浮窗")
            Toggle("开始录音时自动弹出桌边实时纪要悬浮窗", isOn: binding(\.autoShowFloatingPanel))
            Toggle("允许屏幕共享与系统录屏看到纪要悬浮窗（默认关闭隐身）", isOn: binding(\.floatingPanelCapturable))
            Text("默认关闭时窗口设置 sharingType = .none，在腾讯会议、飞书、Zoom 共享整个桌面时对他人完全隐身；且点击悬浮窗不会抢走当前会议软件焦点。")
                .font(.caption)
                .foregroundColor(.secondary)

            section("自动识别会议启停")
            Toggle("检测到会议或通话时自动开始/结束录音", isOn: binding(\.automatic))
            DisclosureGroup("监控以下应用的语音通话活动", isExpanded: $appDetectionExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("腾讯会议", isOn: binding(\.tencent))
                    Toggle("飞书会议", isOn: binding(\.feishu))
                    Toggle("Zoom", isOn: binding(\.zoom))
                    Toggle("钉钉通话", isOn: binding(\.dingtalk))
                    Toggle("微信通话", isOn: binding(\.wechat))
                }
                .padding(10)
            }
            Text("提示：请提前告知参会者录音。首次使用请先手动开始一次线上录音以完成系统音频授权。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var transcriptionAndVoiceprint: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("本机零依赖实时引擎（推荐）")
            Picker("转录架构", selection: Binding(
                get: {
                    if manager.config.transcription == "cloud" { return "cloud" }
                    return manager.config.liveEngine == "xasr" ? "xasr" : "apple"
                },
                set: { choice in
                    if choice == "cloud" {
                        manager.config.transcription = "cloud"
                    } else {
                        manager.config.transcription = "local"
                        manager.config.liveTranscription = choice
                    }
                    manager.saveConfiguration()
                }
            )) {
                Text("Apple 原生实时识别 + 内置 Core ML 声纹（零 Python）").tag("apple")
                Text("外部 Python X-ASR 离线引擎（兼容旧版）").tag("xasr")
                Text("云端音频接口（MiMo 兼容）").tag("cloud")
            }
            .disabled(manager.active != nil || manager.starting)

            if manager.config.transcription == "local" && manager.config.liveEngine == "apple" {
                Picker("识别语言", selection: Binding(
                    get: { manager.config.speechLocale },
                    set: {
                        manager.config.appleSpeechLocale = $0
                        manager.saveConfiguration()
                        speechStatus = ""
                    }
                )) {
                    Text("普通话（中国大陆）").tag("zh-CN")
                    Text("自动检测（中 / 英）").tag("auto")
                    Text("英语（美国）").tag("en-US")
                }
                .disabled(preparingSpeech || manager.active != nil || manager.starting)

                Toggle("启用内置 Core ML 声纹分离与对话上下文认人名", isOn: binding(\.enableVoiceprint))
                Text("线上会议自动将麦克风标为「我」（含扬声器外放回声过滤），用内置 WeSpeaker Core ML 模型实时区分远端多位说话人；线下会议直接对麦克风做多人声纹聚类。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Button("检查 Apple 语音模型") { prepareSpeech(install: false) }
                    Button(preparingSpeech ? "准备中…" : "下载并准备 Apple 语音模型") { prepareSpeech(install: true) }
                }
                .disabled(preparingSpeech || manager.active != nil || manager.starting)

                if !speechStatus.isEmpty {
                    Text(speechStatus).font(.callout).textSelection(.enabled)
                }
            }

            if manager.config.transcription == "cloud" {
                section("云端 ASR 接口")
                Text("注意：云端音频模式会将录音分段上传至所填接口，且不含实时预览。")
                    .font(.caption)
                    .foregroundColor(.orange)
                TextField("云端 ASR Base URL", text: binding(\.asrBase)).textFieldStyle(.roundedBorder)
                TextField("ASR 模型 ID", text: binding(\.asrModel)).textFieldStyle(.roundedBorder)
                SecureField("新的 ASR API Key（留空保留已有）", text: $asrKey)
                Button("保存 ASR 密钥") { saveSecret(asrKey, account: "asr"); asrKey = "" }
                    .disabled(asrKey.isEmpty)
            }

            DisclosureGroup("高级 / 旧版外部 Python X-ASR 环境配置", isExpanded: $legacyEngineExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("预计说话人数（仅离线 X-ASR 使用）", selection: Binding(
                        get: { manager.config.speakerCount ?? 0 },
                        set: { manager.config.speakerCount = ($0 == 0 ? nil : $0); manager.saveConfiguration() }
                    )) {
                        Text("自动估计").tag(0)
                        ForEach(1..<13) { count in Text("\(count) 人").tag(count) }
                    }
                    HStack {
                        TextField("Python 可执行文件路径", text: binding(\.python)).textFieldStyle(.roundedBorder)
                        Button("选择…") { choose(folder: false, path: \.python) }
                    }
                    HStack {
                        TextField("X-ASR 模型目录", text: binding(\.models)).textFieldStyle(.roundedBorder)
                        Button("选择…") { choose(folder: true, path: \.models) }
                    }
                    Button("检查 X-ASR 本地文件") {
                        let names = ["encoder-960ms.onnx", "decoder-960ms.onnx", "joiner-960ms.onnx", "tokens.txt", "segmentation.onnx", "embedding.onnx"]
                        let missing = names.filter { !FileManager.default.fileExists(atPath: manager.config.models + "/" + $0) }
                        message = !FileManager.default.isExecutableFile(atPath: manager.config.python)
                            ? "Python 不可执行（使用默认 Apple 原生引擎时无需配置 Python）。"
                            : (missing.isEmpty ? "X-ASR 模型文件齐全。" : "缺少文件：" + missing.joined(separator: "、"))
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var summarySettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("通用 OpenAI 兼容大模型（实时纪要 + 会后完整版 + 说话人认名）")
            Toggle("会中每 45 秒自动增量更新实时结构化纪要", isOn: binding(\.enableLiveNotes))
            TextField("OpenAI 兼容 Base URL，如 https://api.deepseek.com/v1", text: binding(\.summaryBase))
                .textFieldStyle(.roundedBorder)
            TextField("模型 ID，如 deepseek-chat / gpt-4o-mini / qwen-plus", text: binding(\.summaryModel))
                .textFieldStyle(.roundedBorder)
            HStack {
                SecureField("新的 API Key（留空保留 Keychain 中已有密钥）", text: $summaryKey)
                Button("保存密钥") {
                    saveSecret(summaryKey, account: "summary")
                    summaryKey = ""
                    MeetingNotesEngine.shared.updateNow()
                }
                .disabled(summaryKey.isEmpty)
            }
            Button(testing ? "测试连接中…" : "测试模型连接") {
                testing = true
                let config = manager.config
                Task {
                    do {
                        _ = try await MeetingCloud.completion(
                            base: config.summaryBase,
                            key: MeetingSecrets.read("summary"),
                            model: config.summaryModel,
                            messages: [["role": "user", "content": "请回复 OK"]]
                        )
                        message = "连接成功！实时纪要与上下文认人名已可使用。"
                    } catch {
                        message = error.localizedDescription
                    }
                    testing = false
                }
            }
            .disabled(testing)

            section("纯文本回退纪要模板")
            TextEditor(text: binding(\.template))
                .frame(minHeight: 110)
                .border(Color.secondary.opacity(0.2))
            Text("默认优先生成带时间戳依据的结构化纪要（总结、议题、结论高亮、待办、根因鱼骨图、同音词表）；若自定义接口不支持 JSON 输出，将自动回退使用上方纯文本模板。API Key 仅保存在 macOS Keychain。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func section(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundColor(.secondary)
            Divider()
        }
    }

    private func prepareSpeech(install: Bool) {
        preparingSpeech = true
        speechStatus = "正在检查 Apple 本机语音模型…"
        let locale = manager.config.speechLocale
        Task { @MainActor in
            defer { preparingSpeech = false }
            do {
                speechStatus = try await MeetingAppleSpeech.check(locale: locale, install: install) { speechStatus = $0 }
            } catch {
                speechStatus = "Apple 语音模型未就绪：\(error.localizedDescription)"
            }
        }
    }

    private func saveSecret(_ value: String, account: String) {
        do {
            try MeetingSecrets.write(value, account: account)
            message = "密钥已安全保存到 macOS Keychain。"
        } catch {
            message = error.localizedDescription
        }
    }

    private func choose(folder: Bool, path: WritableKeyPath<MeetingConfiguration, String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            manager.config[keyPath: path] = url.path
            manager.saveConfiguration()
        }
    }
}
