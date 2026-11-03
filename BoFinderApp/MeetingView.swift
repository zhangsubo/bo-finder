import SwiftUI
import AppKit
import AVFoundation

struct MeetingView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @State private var settings = false
    @State private var search = ""
    @State private var detailTab = 0
    @State private var follow = true
    @State private var lastFollowedCount = 0
    @State private var renameSpeaker: String?
    @State private var newName = ""
    @State private var editing: MeetingSegment?
    @State private var editText = ""
    @State private var editSpeaker = ""
    @State private var confirmDelete = false
    @State private var titleText = ""
    @State private var editingTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !manager.error.isEmpty {
                HStack { Text(manager.error).font(.callout); Spacer(); Button("关闭") { manager.error = "" } }.padding(10).background(Color.orange.opacity(0.12)).cornerRadius(6)
            }
            if settings {
                HStack { Text("会议设置").font(.title2.bold()); Spacer(); Button("返回会议") { settings = false } }
                MeetingSettingsView()
            } else if let id = manager.selected, let record = manager.records.first(where: { $0.id == id }) {
                detail(record)
            } else { library }
        }.padding(24)
        .alert("移至废纸篓？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("移至废纸篓", role: .destructive) { if let id = manager.selected { manager.delete(id) } }
        } message: { Text("本会议的音频、转录和纪要将一起移至废纸篓。") }
        .sheet(isPresented: Binding(get: { renameSpeaker != nil }, set: { if !$0 { renameSpeaker = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("统一修改本会议的说话人").font(.headline)
                TextField("显示名称", text: $newName)
                HStack { Button("取消") { renameSpeaker = nil }; Spacer(); Button("保存") { if let id = manager.selected, let speaker = renameSpeaker { manager.rename(id, speaker: speaker, name: newName) }; renameSpeaker = nil }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 380)
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("校对转录片段").font(.headline)
                TextField("说话人标签，如 A / B / C", text: $editSpeaker)
                TextEditor(text: $editText).frame(height: 160)
                HStack { Button("取消") { editing = nil }; Spacer(); Button("保存") { if let id = manager.selected, let segment = editing { manager.edit(id, segment: segment.id, text: editText, speaker: editSpeaker) }; editing = nil }.disabled(editSpeaker.isEmpty || editText.isEmpty) }
            }.padding(24).frame(width: 500)
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) { Text("会议助手").font(.title.bold()); Text("记录对话，会后自动整理。").foregroundColor(.secondary) }
                Spacer()
                Button("会议设置") { settings = true }
                Menu("开始录音") {
                    Button("线下会议 · 麦克风") { Task { await manager.start(online: false) } }
                    Button("线上会议 · 麦克风与系统音频") { Task { await manager.start(online: true, source: "手动线上会议") } }
                }.disabled(manager.active != nil || manager.starting || manager.stopping)
            }
            HStack {
                Label(manager.active == nil ? (manager.config.automatic ? "自动录制已开启" : "手动录音就绪") : "正在录音", systemImage: manager.active == nil ? "waveform" : "record.circle")
                Spacer()
                if let id = manager.active { Button("查看实时全文") { manager.selected = id } }
            }.padding(14).background(Color.accentColor.opacity(0.07)).cornerRadius(8)
            TextField("搜索会议标题与转录", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(manager.records.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.transcript.localizedCaseInsensitiveContains(search) }) { record in
                        Button { manager.selected = record.id; detailTab = 0 } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "waveform").font(.title2).foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(record.title).font(.headline)
                                    Text("\(record.source) · \(record.date.formatted(date: .abbreviated, time: .shortened)) · \(MeetingRecord.timestamp(record.duration))").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(); Text(stateLabel(record)).font(.caption).foregroundColor(.secondary); Image(systemName: "chevron.right")
                            }.padding(.vertical, 18).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if manager.records.isEmpty {
                        VStack(spacing: 14) { Image(systemName: "mic").font(.largeTitle); Text("让下一次对话留下来").font(.title3); Text("先在会议设置中选择音源与模型，或直接开始录音。").foregroundColor(.secondary) }.padding(50)
                    }
                }
            }
            Text(manager.status).font(.caption).foregroundColor(.secondary)
        }
    }

    private func stateLabel(_ record: MeetingRecord) -> String {
        if manager.active == record.id { return record.phase == "paused" ? "已暂停" : "录音中" }
        if record.transcriptState == "working" { return "完整转录处理中" }
        if record.summaryState == "working" { return "纪要生成中" }
        if record.transcriptState == "failed" || record.summaryState == "failed" { return "待重试" }
        if !record.summaries.isEmpty { return "纪要已就绪" }
        return record.segments.isEmpty ? "待转录" : "完整转录已就绪"
    }

    private func detail(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if editingTitle { TextField("会议名称", text: $titleText).onSubmit { manager.title(record.id, titleText); editingTitle = false } }
                else { Text(record.title).font(.title2.bold()).lineLimit(2) }
                Spacer()
                Button(editingTitle ? "保存名称" : "改名") {
                    if editingTitle { manager.title(record.id, titleText) } else { titleText = record.title }; editingTitle.toggle()
                }
                Button("所有会议") { manager.selected = nil }
                Button("设置") { settings = true }
            }
            if manager.active == record.id {
                HStack {
                    Label(record.phase == "paused" ? "已暂停" : "录音中", systemImage: "record.circle").foregroundColor(.red)
                    Text(MeetingRecord.timestamp(manager.elapsed)).monospacedDigit()
                    Spacer()
                    Button(record.phase == "paused" ? "继续录音" : "暂停") { manager.pause() }
                    Button("结束会议") { Task { await manager.end() } }
                }.disabled(manager.starting || manager.stopping)
                Text(manager.status).font(.caption).foregroundColor(.secondary)
                transcript(record, live: true)
            } else {
                Text("\(record.source) · \(stateLabel(record))").font(.caption).foregroundColor(.secondary)
                Picker("内容", selection: $detailTab) { Text("完整转录").tag(0); Text("会议纪要").tag(1) }.pickerStyle(.segmented)
                if !record.issue.isEmpty { Text(record.issue).font(.callout).foregroundColor(.orange).textSelection(.enabled) }
                if manager.busy.contains(record.id) { HStack { ProgressView().controlSize(.small); Text(stateLabel(record)) } }
                if detailTab == 0 {
                    if record.segments.isEmpty {
                        ScrollView { Text(record.preview.isEmpty ? "录音已保存。完整转录需要本地运行环境和模型；可以在设置中配置后重试。" : "以下为会中预览，尚未完成说话人整理。\n\n" + record.preview.map { "[\(MeetingRecord.timestamp($0.start))] \($0.text)" }.joined(separator: "\n\n")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    } else { transcript(record, live: false) }
                    HStack {
                        Button(record.segments.isEmpty ? "开始完整转录" : "重新转录（保留旧版）") { Task { await manager.transcribe(record.id) } }.disabled(manager.busy.contains(record.id))
                        Button("导出转录") { manager.export(record, summary: false) }.disabled(record.segments.isEmpty)
                        Spacer(); Button("删除", role: .destructive) { confirmDelete = true }.disabled(manager.busy.contains(record.id))
                    }
                } else {
                    if let summary = record.summaries.last {
                        if summary.transcriptRevision != record.revision { Text("转录已更新，当前纪要基于旧版本。可重新生成。").foregroundColor(.orange) }
                        ScrollView { Text(summary.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        Text("\(summary.model) · 保存了 \(record.summaries.count) 个纪要版本").font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(record.summaryState == "unconfigured" ? "完整转录已就绪，请在会议设置中配置总结接口与默认模型。" : "完整转录完成后将使用默认模板与模型自动生成纪要。").foregroundColor(.secondary)
                        Spacer()
                    }
                    HStack {
                        Button("生成纪要 / 重试") { Task { await manager.summarize(record.id) } }.disabled(record.segments.isEmpty || manager.busy.contains(record.id))
                        Button("导出纪要") { manager.export(record, summary: true) }.disabled(record.summaries.isEmpty)
                    }
                }
            }
        }
    }

    private func transcript(_ record: MeetingRecord, live: Bool) -> some View {
        VStack(alignment: .leading) {
            if live { Toggle("跟随最新（回看时可关闭）", isOn: $follow).toggleStyle(.switch).controlSize(.small) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(live ? record.preview : record.segments) { segment in
                            HStack(alignment: .top, spacing: 14) {
                                Button(MeetingRecord.timestamp(segment.start)) { manager.play(record.id, at: segment.start) }.buttonStyle(.link).font(.caption).monospacedDigit()
                                VStack(alignment: .leading, spacing: 7) {
                                    if live { Text("实时预览 · 说话人待识别").font(.caption).foregroundColor(.secondary) }
                                    else { Button(record.speakerName(segment.speaker)) { renameSpeaker = segment.speaker; newName = record.speakerName(segment.speaker) }.buttonStyle(.link).font(.caption).disabled(manager.busy.contains(record.id)) }
                                    Text(segment.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !live { Button { editing = segment; editText = segment.text; editSpeaker = segment.speaker } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).disabled(manager.busy.contains(record.id)) }
                            }.id(segment.id)
                            Divider()
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(12)
                }.background(Color(nsColor: .textBackgroundColor)).cornerRadius(8)
                .background(MeetingScrollObserver {
                    if live && follow { lastFollowedCount = record.preview.count; follow = false }
                })
                .onAppear { lastFollowedCount = record.preview.count }
                .onChange(of: record.preview.count) { count in
                    if live && follow { lastFollowedCount = count; proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: record.preview.last?.text) { _ in
                    if live && follow { proxy.scrollTo("latest", anchor: .bottom) }
                }
                if live {
                    Button(follow ? "回到最新" : "回到最新 · \(max(0, record.preview.count - lastFollowedCount)) 条新内容") {
                        follow = true; lastFollowedCount = record.preview.count; proxy.scrollTo("latest", anchor: .bottom)
                    }.buttonStyle(.link)
                }
            }
        }
    }
}

/// Observe only wheel events within this transcript; never consume or synthesize input.
private struct MeetingScrollObserver: NSViewRepresentable {
    var onReview: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(onReview: onReview) }
    func updateNSView(_ view: ObserverView, context: Context) { view.onReview = onReview }
    final class ObserverView: NSView {
        var onReview: () -> Void
        private var monitor: Any?
        init(onReview: @escaping () -> Void) {
            self.onReview = onReview
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.window != nil,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY > 0 {
                    self.onReview()
                }
                return event
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct MeetingSettingsView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @State private var tab = 0
    @State private var expanded = false
    @State private var summaryKey = ""
    @State private var asrKey = ""
    @State private var message = ""
    @State private var testing = false
    @State private var preparingSpeech = false
    @State private var speechStatus = ""

    private func binding<T>(_ path: WritableKeyPath<MeetingConfiguration, T>) -> Binding<T> {
        Binding(get: { manager.config[keyPath: path] }, set: { manager.config[keyPath: path] = $0; manager.saveConfiguration() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("会议设置分类", selection: $tab) { Text("录音").tag(0); Text("转录").tag(1); Text("模型与模板").tag(2) }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if tab == 0 { recording }
                    else if tab == 1 { transcription }
                    else { summary }
                    if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
                }.padding(4)
            }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("音频设置")
            Picker("麦克风", selection: binding(\.microphone)) {
                Text("自动选择（系统默认）").tag("default")
                Text("关闭").tag("off")
                ForEach(MeetingCapture.inputDevices, id: \.uniqueID) { device in Text(device.localizedName).tag(device.uniqueID) }
            }
            Toggle("系统音频 · 线上录制其他人的声音", isOn: binding(\.systemAudio))
            Text("线下会议只使用麦克风。系统音频录制可能包含其他应用声音，请关闭无关播放。").font(.caption).foregroundColor(.secondary)
            HStack {
                Button("检查麦克风权限") { message = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "麦克风已授权" : "首次开始录音时请求麦克风权限。" }
                Button("系统音频权限") { message = CGPreflightScreenCaptureAccess() ? "系统录制权限已授权" : "首次线上录音时请求系统录制权限。" }
            }
            section("会议识别")
            DisclosureGroup("在以下应用中识别会议", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("腾讯会议", isOn: binding(\.tencent))
                    Toggle("微信通话", isOn: binding(\.wechat))
                }.padding(12)
            }
            section("录音")
            Toggle("自动录制", isOn: binding(\.automatic))
            Text("自动检测使用应用音频活动和窗口信号，需要 macOS 14.2+；当前为待实机验证功能。先手动录音完成权限授权。首次默认关闭，开启后开始监测。手动结束不会在同次通话中立即重录。").font(.caption).foregroundColor(.secondary)
            section("录音须知")
            Text("请提前告知参会者。音频与文字保存在本机；选择云端转录会发送音频，云端总结会发送转录文字。").font(.caption).foregroundColor(.secondary)
            Button("打开会议保存目录") { try? FileManager.default.createDirectory(at: MeetingFiles.root, withIntermediateDirectories: true); NSWorkspace.shared.open(MeetingFiles.root) }
        }
    }

    private var transcription: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("转录方式")
            Picker("处理方式", selection: binding(\.transcription)) { Text("本地 X-ASR + 说话人分离").tag("local"); Text("云端 MiMo 兼容音频接口").tag("cloud") }
            if manager.config.transcription == "local" {
                Picker("会中实时识别", selection: Binding(get: { manager.config.liveEngine }, set: { manager.config.liveTranscription = $0; manager.saveConfiguration() })) {
                    Text("X-ASR").tag("xasr")
                    Text("Apple 原生（实验性，macOS 26+）").tag("apple")
                }.disabled(manager.active != nil || manager.starting)
                if manager.config.liveEngine == "apple" {
                    Picker("Apple 转录语言", selection: Binding(get: { manager.config.speechLocale }, set: { manager.config.appleSpeechLocale = $0; manager.saveConfiguration(); speechStatus = "" })) {
                        Text("普通话（中国大陆）").tag("zh-CN")
                        Text("英语（美国）").tag("en-US")
                    }.disabled(preparingSpeech || manager.active != nil || manager.starting)
                    Text("会中使用 Apple 本地语音模型，首次需下载语言资源；不依赖 Apple Intelligence 总结功能。会后仍使用下方的 X-ASR 和说话人模型。模型不可用时保留录音，不自动切换到云端。").font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("检查 Apple 模型") { prepareSpeech(install: false) }
                        Button(preparingSpeech ? "准备中…" : "下载并准备 Apple 模型") { prepareSpeech(install: true) }
                    }.disabled(preparingSpeech || manager.active != nil || manager.starting || !MeetingAppleSpeech.supportedOS)
                    if !MeetingAppleSpeech.supportedOS { Text("当前系统不支持，请使用 macOS 26 或更新版本。").foregroundColor(.orange) }
                    if !speechStatus.isEmpty { Text(speechStatus).font(.callout).textSelection(.enabled) }
                }
                Text("会中约每秒送入一次音频，连续识别并更新当前句子；实际显示延迟还包括模型上下文等待和机器负载。会后重新识别并分离说话人。").font(.caption).foregroundColor(.secondary)
            } else {
                Text("音频将发送到所配置服务。当前云端接口按片段转录，不提供稳定说话人标签或精确时间；准实时预览仅本地模式提供。").font(.caption).foregroundColor(.orange)
                TextField("云端 ASR Base URL", text: binding(\.asrBase)).textFieldStyle(.roundedBorder)
                TextField("ASR 模型 ID", text: binding(\.asrModel)).textFieldStyle(.roundedBorder)
                SecureField("新的 ASR API Key（留空保留已有）", text: $asrKey)
                Button("保存 ASR 密钥") { saveSecret(asrKey, account: "asr"); asrKey = "" }.disabled(asrKey.isEmpty)
            }
            Picker("预计说话人数", selection: Binding(get: { manager.config.speakerCount ?? 0 }, set: { manager.config.speakerCount = $0; manager.saveConfiguration() })) {
                Text("自动估计（可能需校对）").tag(0)
                ForEach(1..<13) { count in Text("\(count) 人").tag(count) }
            }
            Text("已知参会人数时指定人数可减少错误拆分。说话人标签仍需校对，重叠发言可能影响准确性。").font(.caption).foregroundColor(.secondary)
            section("本地运行环境")
            TextField("Python 可执行文件", text: binding(\.python)).textFieldStyle(.roundedBorder)
            Button("选择 Python") { choose(folder: false, path: \.python) }
            TextField("模型目录", text: binding(\.models)).textFieldStyle(.roundedBorder)
            Button("选择模型目录") { choose(folder: true, path: \.models) }
            Text("需要 X-ASR encoder/decoder/joiner、tokens.txt，以及 segmentation.onnx、embedding.onnx。环境需安装 sherpa-onnx 和 numpy。配置不完整时仍可录音，稍后重试转录。").font(.caption).foregroundColor(.secondary)
            Button("检查本地文件") {
                let names = ["encoder-960ms.onnx", "decoder-960ms.onnx", "joiner-960ms.onnx", "tokens.txt", "segmentation.onnx", "embedding.onnx"]
                let missing = names.filter { !FileManager.default.fileExists(atPath: manager.config.models + "/" + $0) }
                message = !FileManager.default.isExecutableFile(atPath: manager.config.python) ? "Python 不可执行。" : missing.isEmpty ? "模型文件齐全；实际识别效果仍需录音验证。" : "缺少文件：" + missing.joined(separator: "、")
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("默认总结模型")
            TextField("OpenAI 兼容 Base URL，如 https://example.com/v1", text: binding(\.summaryBase)).textFieldStyle(.roundedBorder)
            TextField("模型 ID", text: binding(\.summaryModel)).textFieldStyle(.roundedBorder)
            SecureField("新的 API Key（留空保留已有）", text: $summaryKey)
            Button("保存总结密钥") { saveSecret(summaryKey, account: "summary"); summaryKey = "" }.disabled(summaryKey.isEmpty)
            Button(testing ? "测试中…" : "测试连接（发送简短请求）") {
                testing = true
                let config = manager.config
                Task {
                    do { _ = try await MeetingCloud.completion(base: config.summaryBase, key: MeetingSecrets.read("summary"), model: config.summaryModel, messages: [["role": "user", "content": "请回复 OK"]]); message = "连接成功" }
                    catch { message = error.localizedDescription }
                    testing = false
                }
            }.disabled(testing)
            section("默认会议纪要模板")
            TextEditor(text: binding(\.template)).frame(minHeight: 160).border(Color.secondary.opacity(0.2))
            Text("完整转录完成后自动生成一份；重新生成保留旧纪要。密钥保存在 Keychain，不写入配置文件。").font(.caption).foregroundColor(.secondary)
        }
    }
    private func section(_ title: String) -> some View { VStack(alignment: .leading) { Text(title).font(.headline).foregroundColor(.secondary); Divider() } }
    private func prepareSpeech(install: Bool) {
        preparingSpeech = true
        speechStatus = "正在检查 Apple 语音能力…"
        let locale = manager.config.speechLocale
        Task { @MainActor in
            defer { preparingSpeech = false }
            do { speechStatus = try await MeetingAppleSpeech.check(locale: locale, install: install) { speechStatus = $0 } }
            catch { speechStatus = "Apple 语音模型未就绪：\(error.localizedDescription)" }
        }
    }
    private func saveSecret(_ value: String, account: String) {
        do { try MeetingSecrets.write(value, account: account); message = "密钥已保存到 Keychain" } catch { message = error.localizedDescription }
    }
    private func choose(folder: Bool, path: WritableKeyPath<MeetingConfiguration, String>) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = folder; panel.canChooseFiles = !folder; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { manager.config[keyPath: path] = url.path; manager.saveConfiguration() }
    }
}
