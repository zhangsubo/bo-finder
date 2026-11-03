import AppKit
import Combine
import SwiftUI

// MARK: - Non-Activating First-Click Hosting View

/// Allows single-click interaction inside a `.nonactivatingPanel` without stealing focus from Zoom / Tencent Meeting / Feishu.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Floating Panel Controller (Screen-Share Hidden by Default)

@MainActor
final class MeetingFloatingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    enum LayoutMode {
        case card
        case sidebar
        case wide
    }

    enum PanelCommand {
        case focusSearch
        case layout(LayoutMode)
    }

    static let shared = MeetingFloatingPanelController()

    @Published private(set) var isVisible: Bool = false
    let commands = PassthroughSubject<PanelCommand, Never>()

    private var panel: NSPanel?

    private override init() {
        super.init()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let manager = MeetingManager.shared
        if panel == nil {
            let p = NSPanel(
                contentRect: defaultFrame(),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.isFloatingPanel = true
            p.level = .floating
            p.delegate = self
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.isReleasedWhenClosed = false
            // Screen-share & screenshot invisible by default (.none), unless user explicitly opts in (.readOnly).
            p.sharingType = manager.config.floatingPanelCapturable ? .readOnly : .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.minSize = NSSize(width: 290, height: 190)
            p.backgroundColor = .windowBackgroundColor

            let root = MeetingFloatingPanelRootView(
                commands: commands.eraseToAnyPublisher(),
                onResize: { [weak self] w, h in self?.resize(width: w, height: h) },
                onRequestKeyWindow: { [weak p] in p?.makeKey() }
            )
            p.contentView = FirstClickHostingView(rootView: root)
            p.setFrameAutosaveName("DeskSideMeetingFloatingPanel")
            if !p.setFrameUsingName("DeskSideMeetingFloatingPanel") {
                p.setFrame(defaultFrame(), display: false)
            }
            panel = p
        }
        syncSharingType()
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func syncSharingType() {
        let capturable = MeetingManager.shared.config.floatingPanelCapturable
        panel?.sharingType = capturable ? .readOnly : .none
    }

    func send(_ command: PanelCommand) {
        if !isVisible { show() }
        if case .focusSearch = command {
            panel?.makeKey()
        }
        commands.send(command)
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }

    /// Resizes between card (<360), sidebar (440), and wide split (840) keeping the top-right corner anchored.
    func resize(width: CGFloat, height: CGFloat? = nil) {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        var frame = p.frame
        let top = frame.maxY
        let right = frame.maxX
        frame.size.width = width
        if let height {
            frame.size.height = min(height, screen.visibleFrame.height - 28)
        }
        frame.origin.x = min(max(screen.visibleFrame.minX + 8, right - width), screen.visibleFrame.maxX - width - 8)
        frame.origin.y = max(screen.visibleFrame.minY + 8, top - frame.size.height)
        p.setFrame(frame, display: true, animate: true)
    }

    private func defaultFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 440
        let height: CGFloat = min(760, visible.height - 40)
        return NSRect(
            x: visible.maxX - width - 16,
            y: visible.maxY - height - 16,
            width: width,
            height: height
        )
    }
}

// MARK: - Floating Panel Root View (Card / Sidebar / Split)

private struct MeetingFloatingPanelRootView: View {
    @ObservedObject private var manager = MeetingManager.shared
    @ObservedObject private var notesEngine = MeetingNotesEngine.shared
    let commands: AnyPublisher<MeetingFloatingPanelController.PanelCommand, Never>
    let onResize: (CGFloat, CGFloat?) -> Void
    let onRequestKeyWindow: () -> Void

    @State private var tab: String = "notes"
    @State private var query: String = ""
    @State private var jumpTargetTime: Double? = nil
    @State private var jumpToken: Int = 0
    @State private var collapsedAt: Double = 0
    @State private var seenItems: Set<String> = []
    @State private var catchUpMode: Bool = false
    @State private var confirmEnd: Bool = false
    @State private var currentWidth: CGFloat = 440
    @FocusState private var searchFocused: Bool

    private var record: MeetingRecord? {
        if let activeID = manager.active {
            return manager.records.first { $0.id == activeID }
        }
        if let selectedID = manager.selected {
            return manager.records.first { $0.id == selectedID }
        }
        return manager.records.first
    }

    private var isLive: Bool {
        guard let rec = record else { return false }
        return manager.active == rec.id
    }

    private var notes: MeetingStructuredNotes {
        record?.notes ?? MeetingStructuredNotes()
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.width < 360 {
                    miniCardView
                } else {
                    expandedView(wide: geo.size.width >= 760)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { currentWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, w in currentWidth = w }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(commands) { cmd in
            switch cmd {
            case .focusSearch:
                if currentWidth < 360 { onResize(440, 720) }
                tab = "transcript"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    onRequestKeyWindow()
                    searchFocused = true
                }
            case .layout(.card):
                collapseToCard()
            case .layout(.sidebar):
                onResize(440, currentWidth < 360 ? 720 : nil)
            case .layout(.wide):
                onResize(840, currentWidth < 360 ? 720 : nil)
            }
        }
    }

    private func collapseToCard() {
        collapsedAt = isLive ? manager.elapsed : (record?.duration ?? 0)
        seenItems = collectNoteKeys()
        catchUpMode = false
        onResize(320, 230)
    }

    private func collectNoteKeys() -> Set<String> {
        var out: Set<String> = []
        for topic in notes.topics {
            out.insert(topic.title)
            for p in topic.points { out.insert(p) }
        }
        return out
    }

    private func jumpToTranscript(at seconds: Double) {
        jumpTargetTime = seconds
        jumpToken += 1
        if currentWidth < 760 {
            tab = "transcript"
        }
    }

    // MARK: Expanded Sidebar & Split View

    private func expandedView(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar(wide: wide)
            Divider()

            if confirmEnd, isLive {
                confirmEndBanner
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            statusNoticeBanner
                .padding(.horizontal, 18)
                .padding(.top, 6)

            if let rec = record {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        notesColumn(for: rec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        transcriptColumn(for: rec)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if tab == "notes" {
                    notesColumn(for: rec)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    liveBottomCaption
                } else {
                    transcriptColumn(for: rec)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                emptyMeetingPlaceholder
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func headerBar(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(isLive ? "实时纪要" : "会议纪要")
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)

                if notesEngine.state == .updating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("整理中").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }

                Spacer(minLength: 4)

                if isLive, let rec = record {
                    Button(rec.phase == "paused" ? "继续" : "暂停") {
                        manager.pause()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("结束") {
                        if rec.segments.isEmpty {
                            Task { await manager.end() }
                        } else {
                            confirmEnd = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red.opacity(0.85))
                    .controlSize(.small)
                }

                panelIconButton(
                    symbol: wide ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                    help: wide ? "切回单栏侧边窗" : "展开纪要+原话双栏并排"
                ) {
                    onResize(wide ? 440 : 840, nil)
                }

                panelIconButton(symbol: "minus", help: "收起为迷你补课小卡") {
                    collapseToCard()
                }
            }

            HStack(spacing: 6) {
                if isLive {
                    MeetingBreathingDot(color: record?.phase == "paused" ? .orange : .red)
                } else {
                    Image(systemName: manager.config.floatingPanelCapturable ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 11))
                        .foregroundColor(manager.config.floatingPanelCapturable ? .orange : .secondary)
                }

                Text(subtitleStatusText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if manager.config.floatingPanelCapturable {
                    capturableWarningBadge
                } else {
                    Text("投屏隐身")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .help("当前窗口对屏幕共享与系统录屏默认不可见（可在会议设置切换）")
                }
            }

            if !wide {
                Picker("", selection: $tab) {
                    Text("结构化纪要").tag("notes")
                    Text("文字记录" + ((record?.segments.count ?? 0) > 0 ? " · \(record!.segments.count)" : "")).tag("transcript")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 32)
        .padding(.bottom, 10)
    }

    private var subtitleStatusText: String {
        if let rec = record {
            if isLive {
                let state = rec.phase == "paused" ? "已暂停" : "录音中"
                let count = rec.segments.count
                var parts = ["\(state) \(MeetingRecord.shortClock(manager.elapsed))"]
                if count > 0 { parts.append("\(count) 句") }
                if notes.coveredCount > 0, notes.coveredCount <= rec.segments.count {
                    let coveredSec = rec.segments[notes.coveredCount - 1].end
                    parts.append("纪要至 \(MeetingRecord.shortClock(coveredSec))")
                }
                return parts.joined(separator: " · ")
            } else {
                return "\(rec.title) · 共 \(rec.segments.count) 句"
            }
        }
        return "尚无会议记录"
    }

    private var capturableWarningBadge: some View {
        Button {
            manager.config.floatingPanelCapturable = false
            manager.saveConfiguration()
            MeetingFloatingPanelController.shared.syncSharingType()
        } label: {
            HStack(spacing: 4) {
                MeetingBreathingDot(color: .orange)
                Text("共享可见 · 点击隐身")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("当前屏幕共享和录屏可以看到此悬浮窗，点击立即恢复隐身")
    }

    private var confirmEndBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("确认结束本场会议？").font(.system(size: 13, weight: .bold))
            Text("结束录音后将自动基于完整文字记录整理一份完整版结构化纪要。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("继续记录") { confirmEnd = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("结束并整理") {
                    confirmEnd = false
                    Task { await manager.end() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private var statusNoticeBanner: some View {
        switch notesEngine.state {
        case .unconfigured where (record?.segments.isEmpty == false || isLive):
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundColor(.orange)
                Text("尚未配置总结大模型，实时转录正常保存；配置后即可自动生成实时纪要。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("去配置") {
                    SettingsWindowController.shared.showWindow(page: "meetings")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        case .rateLimited:
            Text("模型接口请求较频繁，保留上一版纪要，下轮自动重试。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(8)
        case .failed(let msg) where !notes.isEmpty:
            Text(msg)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .padding(8)
        default:
            EmptyView()
        }
    }

    private func notesColumn(for rec: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !notes.isEmpty {
                    MeetingStructuredNotesView(
                        record: rec,
                        notes: notes,
                        freshItems: notesEngine.freshItems,
                        live: isLive,
                        updating: notesEngine.state == .updating,
                        onJumpToTime: { t in jumpToTranscript(at: t) },
                        onSearchTerm: { term in
                            query = term
                            if currentWidth < 760 { tab = "transcript" }
                        }
                    )
                } else if isLive && rec.segments.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 28))
                            .foregroundColor(.accentColor)
                        Text("正在聆听会议发言…")
                            .font(.system(size: 14, weight: .semibold))
                        Text("积累 3 句发言后将自动生成首版结构化速记，之后每 45 秒滚动更新。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if isLive || notesEngine.generatingID == rec.id {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("已记录 \(rec.segments.count) 句，正在提炼结构化纪要…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if let plain = rec.summaries.last {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("会议纪要").font(.headline)
                            Spacer()
                            Button("升级为结构化纪要") {
                                Task { await manager.summarize(rec.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text(plain.text)
                            .font(.system(size: 13))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("本场会议尚未生成结构化纪要")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        if !rec.segments.isEmpty {
                            Button("立即生成纪要") {
                                Task { await manager.summarize(rec.id) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(manager.busy.contains(rec.id))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                }
            }
            .padding(18)
        }
    }

    private func transcriptColumn(for rec: MeetingRecord) -> some View {
        MeetingRichTranscriptView(
            record: rec,
            live: isLive,
            volatileText: isLive ? manager.liveVolatileSummary : "",
            query: $query,
            searchFocused: $searchFocused,
            jumpTargetTime: jumpTargetTime,
            jumpToken: jumpToken,
            onRequestKeyWindow: onRequestKeyWindow
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var liveBottomCaption: some View {
        let partial = manager.liveVolatileSummary
        if isLive, !partial.isEmpty {
            HStack(spacing: 8) {
                MeetingBreathingDot(color: .green)
                Text(partial)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.82)))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 4)
        }
    }

    private var emptyMeetingPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("当前没有进行中的会议")
                .font(.system(size: 14, weight: .semibold))
            HStack(spacing: 10) {
                Button("开始线上会议") {
                    Task { await manager.start(online: true, source: "手动线上会议") }
                }
                .buttonStyle(.borderedProminent)
                Button("线下麦克风会议") {
                    Task { await manager.start(online: false) }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Mini Catch-up Card (< 360 pt)

    private var addedSinceCollapse: [(topic: MeetingNoteTopic, points: [String])] {
        notes.topics.compactMap { topic in
            let newPoints = topic.points.filter { !seenItems.contains($0) }
            return (seenItems.contains(topic.title) && newPoints.isEmpty) ? nil : (topic, newPoints)
        }
    }

    private var addedCounts: (topics: Int, points: Int) {
        let items = addedSinceCollapse
        let tCount = items.filter { !seenItems.contains($0.topic.title) }.count
        let pCount = items.reduce(0) { $0 + $1.points.count }
        return (tCount, pCount)
    }

    private var miniCardView: some View {
        let currentTopic = notes.topics.last
        let nowElapsed = isLive ? manager.elapsed : (record?.duration ?? 0)
        let spanSeconds = max(0, Int(nowElapsed - collapsedAt))
        let spanLabel = spanSeconds < 60 ? "\(spanSeconds) 秒" : "\(spanSeconds / 60) 分钟"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if catchUpMode {
                    Text("收起期间 · \(MeetingRecord.shortClock(collapsedAt)) – \(MeetingRecord.shortClock(nowElapsed))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    if isLive { MeetingBreathingDot(color: .red) }
                    Text(currentTopic.map { (isLive ? "正在讲 · " : "最近议题 · ") + MeetingRecord.shortClock($0.start) }
                         ?? (isLive ? "正在记录" : "实时纪要"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if manager.config.floatingPanelCapturable {
                    MeetingBreathingDot(color: .orange)
                }
                panelIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "展开侧边纪要窗") {
                    onResize(440, 720)
                }
            }

            if catchUpMode {
                Text("刚才这 \(spanLabel) 讲了：")
                    .font(.system(size: 15, weight: .bold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(addedSinceCollapse, id: \.topic.id) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(MeetingRecord.shortClock(entry.topic.start))
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundColor(.secondary)
                                    Text(entry.topic.title)
                                        .font(.system(size: 13, weight: .bold))
                                }
                                if !entry.points.isEmpty {
                                    Text(entry.points.joined(separator: "；"))
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if addedSinceCollapse.isEmpty {
                            Text("收起期间还没有新增议题或要点。")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button("展开完整纪要") { onResize(440, 720) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("看过了") {
                        catchUpMode = false
                        collapsedAt = nowElapsed
                        seenItems = collectNoteKeys()
                        onResize(320, 230)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text(currentTopic?.title ?? (isLive ? ((record?.segments.isEmpty ?? true) ? "正在听发言…" : "正在生成首版纪要…") : "暂无实时议题"))
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(2)

                if addedCounts.topics + addedCounts.points == 0,
                   let latestPoint = currentTopic?.points.last ?? (isLive ? manager.liveVolatileSummary : nil),
                   !latestPoint.isEmpty {
                    Text(latestPoint)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                let counts = addedCounts
                if counts.topics + counts.points > 0 {
                    Button {
                        catchUpMode = true
                        onResize(320, 400)
                    } label: {
                        HStack {
                            var parts: [String] = []
                            let _ = {
                                if counts.topics > 0 { parts.append("\(counts.topics) 个议题") }
                                if counts.points > 0 { parts.append("\(counts.points) 条要点") }
                            }()
                            Text("收起后新增 " + parts.joined(separator: "、"))
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                } else if collapsedAt > 0 || isLive {
                    Text("已收起 \(spanLabel) · " + (isLive ? "仍在当前议题" : "无新增内容"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
        .padding(.bottom, 14)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func panelIconButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Shared Structured Notes View (Used by Both Floating Panel & Main Window)

struct MeetingStructuredNotesView: View {
    let record: MeetingRecord
    let notes: MeetingStructuredNotes
    var freshItems: Set<String> = []
    var live: Bool = false
    var updating: Bool = false
    var onJumpToTime: (Double) -> Void = { _ in }
    var onSearchTerm: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !notes.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label("核心总结", systemImage: "sparkles")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        NoteTagPill(
                            text: notes.isFinal ? "完整版" : "速记版 · 已覆盖 \(notes.coveredCount) 句",
                            highlight: !notes.isFinal && live
                        )
                    }
                    Text(notes.summary)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.06)))
            }

            if !notes.conclusions.isEmpty || !notes.todos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(notes.todos.isEmpty ? "明确结论" : "结论与待办事项")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        let combined = notes.conclusions.map { (item: $0, isTodo: false) }
                            + notes.todos.map { (item: $0, isTodo: true) }
                        ForEach(Array(combined.enumerated()), id: \.offset) { idx, entry in
                            if idx > 0 { Divider() }
                            conclusionOrTodoRow(entry.item, isTodo: entry.isTodo, index: idx + 1)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.16), lineWidth: 1))
                }
            }

            if !notes.topics.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("分时议题 (\(notes.topics.count))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary)

                    ForEach(Array(notes.topics.enumerated()), id: \.element.id) { idx, topic in
                        let nextStart: Double? = idx + 1 < notes.topics.count
                            ? notes.topics[idx + 1].start
                            : (live ? nil : record.segments.last?.end)
                        MeetingTopicCardView(
                            topic: topic,
                            endTime: nextStart,
                            isCurrent: live && idx == notes.topics.count - 1,
                            isUpdating: updating && idx == notes.topics.count - 1,
                            freshItems: freshItems,
                            onJumpToTime: onJumpToTime
                        )
                    }
                }
            }

            if !notes.terms.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("人名与术语纠错表")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.secondary)
                        Text("点击可联动搜索同音错词")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    MeetingTermChipsView(terms: notes.terms, onSelect: onSearchTerm)
                }
            }
        }
    }

    private func conclusionOrTodoRow(_ item: MeetingNoteItem, isTodo: Bool, index: Int) -> some View {
        let weak = item.support == 0
        let display = item.text + (item.owner.map { "（\($0)）" } ?? "")
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            if isTodo {
                Image(systemName: "square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundColor(weak ? .secondary : .green)
            }

            Text(weak ? AttributedString(display) : MeetingFactHighlight.attributed(display, fontSize: 13.5))
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundColor(weak ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if weak {
                NoteTagPill(text: "依据较少", highlight: false)
            } else if let t = item.t {
                MeetingTimeJumpLink(
                    label: "\(MeetingRecord.shortClock(t)) · \(item.support)句",
                    seconds: t,
                    action: onJumpToTime
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct MeetingTopicCardView: View {
    let topic: MeetingNoteTopic
    let endTime: Double?
    let isCurrent: Bool
    let isUpdating: Bool
    let freshItems: Set<String>
    let onJumpToTime: (Double) -> Void
    @State private var expanded: Bool = true

    private var timeRangeText: String {
        let start = MeetingRecord.shortClock(topic.start)
        if let endTime, endTime > topic.start {
            return "\(start)–\(MeetingRecord.shortClock(endTime))"
        }
        return start
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(topic.title)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)

                if isCurrent {
                    NoteTagPill(text: "正在讲", highlight: true)
                } else if freshItems.contains(topic.title) {
                    NoteTagPill(text: "新", highlight: true)
                }

                Spacer(minLength: 4)

                MeetingTimeJumpLink(label: timeRangeText, seconds: topic.start, action: onJumpToTime)
            }

            if expanded {
                if !topic.summary.isEmpty {
                    Text(topic.summary)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(topic.points.enumerated()), id: \.offset) { i, point in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(freshItems.contains(point) ? Color.orange : Color.secondary.opacity(0.6))
                                .frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(point)
                                .font(.system(size: 13))
                                .lineSpacing(2.5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if freshItems.contains(point) {
                                NoteTagPill(text: "新", highlight: true)
                            }
                            if let pt = topic.pointTime(i) {
                                MeetingTimeJumpLink(label: MeetingRecord.shortClock(pt), seconds: pt, action: onJumpToTime)
                            }
                        }
                    }
                }

                if let fishbone = topic.fishbone {
                    MeetingFishboneView(fishbone: fishbone, onJumpToTime: onJumpToTime)
                        .padding(.top, 4)
                }

                if isUpdating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在补充最新发言…").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct MeetingFishboneView: View {
    let fishbone: MeetingFishbone
    let onJumpToTime: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                Text("根因鱼骨图：\(fishbone.question)")
                    .font(.system(size: 12.5, weight: .bold))
            }
            ForEach(fishbone.branches) { branch in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(branch.label)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
                    Text(branch.detail)
                        .font(.system(size: 12.5))
                        .foregroundColor(branch.support == 0 ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let t = branch.t {
                        MeetingTimeJumpLink(label: MeetingRecord.shortClock(t), seconds: t, action: onJumpToTime)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.05)))
    }
}

private struct MeetingTermChipsView: View {
    let terms: [MeetingNoteTerm]
    let onSelect: (String) -> Void

    var body: some View {
        let ordered = MeetingNoteTerm.ordered(terms)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ordered) { term in
                Button {
                    onSelect(term.name)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        Text(term.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.primary)
                        if !term.note.isEmpty {
                            Text("· \(term.note)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        if !term.heard.isEmpty {
                            Text("（误听：\(term.heard.joined(separator: " / "))）")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("点击在文字记录中搜索「\(term.name)」及其同音错词变体")
            }
        }
    }
}

struct MeetingTimeJumpLink: View {
    let label: String
    let seconds: Double
    let action: (Double) -> Void

    var body: some View {
        Button {
            action(seconds)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.accentColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help("点击跳转到对应原话位置")
    }
}

private struct NoteTagPill: View {
    let text: String
    let highlight: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(highlight ? .orange : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(highlight ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.12)))
    }
}

struct MeetingBreathingDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 2.0)
            let alpha = 0.45 + 0.55 * abs( cos(phase * .pi) )
            Circle()
                .fill(color.opacity(alpha))
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Speaker Strip (Inline Rename, Reject AI Guess, Merge Two Voices)

struct MeetingSpeakerStripView: View {
    @ObservedObject private var manager = MeetingManager.shared
    let record: MeetingRecord
    var onRequestKeyWindow: (() -> Void)? = nil

    @State private var selectedSpeakerKey: String? = nil
    @State private var nameDraft: String = ""

    private var speakerKeys: [String] {
        var seen: [String] = []
        for seg in record.segments {
            let key = seg.speaker
            guard key != "?" && key != "them" else { continue }
            if !seen.contains(key) { seen.append(key) }
        }
        return seen
    }

    var body: some View {
        if !speakerKeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(speakerKeys, id: \.self) { key in
                            let color = MeetingSpeakerPalette.color(for: key, in: record)
                            let isGuessed = record.speakerNames[key] == nil && record.speakerGuesses?[key] != nil
                            let selected = selectedSpeakerKey == key
                            Button {
                                if selectedSpeakerKey == key {
                                    selectedSpeakerKey = nil
                                } else {
                                    selectedSpeakerKey = key
                                    nameDraft = record.speakerName(key)
                                    onRequestKeyWindow?()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(color).frame(width: 7, height: 7)
                                    Text(record.speakerName(key))
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(color)
                                    if isGuessed {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 9))
                                            .foregroundColor(color)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Capsule().fill(color.opacity(selected ? 0.22 : 0.10)))
                                .overlay(Capsule().stroke(selected ? color : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help(key == "me" ? "本机麦克风发言" : "点击改名、核对 AI 推断或合并同一说话人")
                        }
                    }
                }

                if let key = selectedSpeakerKey, speakerKeys.contains(key) {
                    inlineSpeakerEditor(for: key)
                }
            }
        }
    }

    private func inlineSpeakerEditor(for key: String) -> some View {
        let count = record.segments.filter { $0.speaker == key }.count
        let guess = record.speakerNames[key] == nil ? record.speakerGuesses?[key] : nil
        let mergeTargets = speakerKeys.filter { $0 != key && $0 != "me" && key != "me" }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(record.speakerName(key)) · 共 \(count) 句发言")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button("收起") { selectedSpeakerKey = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                TextField("输入说话人姓名或称呼", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { saveSpeakerName(key) }
                Button("保存改名") { saveSpeakerName(key) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let guess {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("AI 从对话推断：\(guess.evidence)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("不是 TA") {
                        manager.dismissSpeakerGuess(record.id, speaker: key)
                        selectedSpeakerKey = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if !mergeTargets.isEmpty {
                HStack(spacing: 6) {
                    Text("其实是同一个人：")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    ForEach(mergeTargets, id: \.self) { target in
                        Button("并入 \(record.speakerName(target))") {
                            manager.mergeSpeakers(record.id, from: key, into: target)
                            selectedSpeakerKey = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    private func saveSpeakerName(_ key: String) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.rename(record.id, speaker: key, name: trimmed)
        selectedSpeakerKey = nil
    }
}

// MARK: - Rich Transcript View (Homophone Search + Evidence Jump + Live Follow)

struct MeetingRichTranscriptView: View {
    @ObservedObject private var manager = MeetingManager.shared
    let record: MeetingRecord
    let live: Bool
    var volatileText: String = ""
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    var jumpTargetTime: Double? = nil
    var jumpToken: Int = 0
    var onEditSegment: ((MeetingSegment) -> Void)? = nil
    var onRequestKeyWindow: (() -> Void)? = nil

    @State private var matchIndex: Int = 0
    @State private var followLatest: Bool = true
    @State private var highlightedSegmentID: UUID? = nil

    private var displayedSegments: [MeetingSegment] {
        if !record.segments.isEmpty {
            return record.segments
        }
        return record.preview
    }

    private var expandedSearchTerms: [String] {
        MeetingNoteTerm.expandQuery(query, terms: record.notes?.terms ?? [])
    }

    private var matchedIDs: [UUID] {
        let terms = expandedSearchTerms
        guard !terms.isEmpty else { return [] }
        return displayedSegments.filter { seg in
            terms.contains { seg.text.localizedCaseInsensitiveContains($0) || record.speakerName(seg.speaker).localizedCaseInsensitiveContains($0) }
        }.map(\.id)
    }

    private var safeMatchIndex: Int {
        matchedIDs.isEmpty ? 0 : min(matchIndex, matchedIDs.count - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            MeetingSpeakerStripView(record: record, onRequestKeyWindow: onRequestKeyWindow)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(displayedSegments) { seg in
                            transcriptRow(seg)
                                .id(seg.id)
                            Divider()
                        }

                        if live, !volatileText.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                MeetingBreathingDot(color: .green)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("正在说…")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    Text(volatileText)
                                        .font(.system(size: 13.5))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                            .id("volatile-tail")
                        }

                        if displayedSegments.isEmpty && volatileText.isEmpty {
                            Text(live ? "正在等待第一句发言…" : "暂无文字记录")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }

                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .padding(12)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: displayedSegments.count) { _, _ in
                    if live && followLatest && query.isEmpty {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: volatileText) { _, _ in
                    if live && followLatest && query.isEmpty {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: jumpToken) { _, _ in
                    guard let target = jumpTargetTime else { return }
                    if let hit = displayedSegments.min(by: { abs($0.start - target) < abs($1.start - target) }) {
                        followLatest = false
                        highlightedSegmentID = hit.id
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(hit.id, anchor: .center)
                        }
                        let currentID = hit.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            if highlightedSegmentID == currentID {
                                highlightedSegmentID = nil
                            }
                        }
                    }
                }
                .onChange(of: safeMatchIndex) { _, idx in
                    if matchedIDs.indices.contains(idx) {
                        followLatest = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(matchedIDs[idx], anchor: .center)
                        }
                    }
                }

                if live {
                    HStack {
                        Toggle("自动跟随最新发言", isOn: $followLatest)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .font(.system(size: 11))
                        Spacer()
                        if !followLatest {
                            Button("回到最新") {
                                followLatest = true
                                proxy.scrollTo("transcript-bottom", anchor: .bottom)
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextField("搜索原话（自动展开纪要同音错词）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused(searchFocused)
                .onTapGesture { onRequestKeyWindow?() }
                .onChange(of: query) { _, _ in matchIndex = 0 }
                .onSubmit { stepMatch(1) }

            if expandedSearchTerms.count > 1 {
                Text("+\(expandedSearchTerms.count - 1)同音词")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .help("已自动关联搜索：\(expandedSearchTerms.joined(separator: "、"))")
            }

            if !query.isEmpty {
                Text(matchedIDs.isEmpty ? "0 匹配" : "\(safeMatchIndex + 1)/\(matchedIDs.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary)
                Button { stepMatch(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .disabled(matchedIDs.isEmpty)
                Button { stepMatch(1) } label: { Image(systemName: "chevron.down").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .disabled(matchedIDs.isEmpty)
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        .background(
            Button("") {
                onRequestKeyWindow?()
                searchFocused.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
        )
    }

    private func stepMatch(_ delta: Int) {
        guard !matchedIDs.isEmpty else { return }
        matchIndex = (safeMatchIndex + delta + matchedIDs.count) % matchedIDs.count
    }

    private func transcriptRow(_ seg: MeetingSegment) -> some View {
        let speakerColor = MeetingSpeakerPalette.color(for: seg.speaker, in: record)
        let isJumpHighlight = highlightedSegmentID == seg.id
        let isActiveSearchMatch = !matchedIDs.isEmpty && matchedIDs[safeMatchIndex] == seg.id

        return HStack(alignment: .top, spacing: 10) {
            Button(MeetingRecord.shortClock(seg.start)) {
                manager.play(record.id, at: seg.start)
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5).monospacedDigit())
            .frame(width: 44, alignment: .leading)
            .help("点击回放此处录音")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(speakerColor).frame(width: 6, height: 6)
                    Text(record.speakerName(seg.speaker))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(speakerColor)
                }

                Text(highlightedText(seg.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !live, let onEditSegment {
                Button {
                    onEditSegment(seg)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(manager.busy.contains(record.id))
                .help("校对此句文字或说话人")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(
                isJumpHighlight ? Color.accentColor.opacity(0.16)
                    : (isActiveSearchMatch ? Color.orange.opacity(0.14) : Color.clear)
            )
        )
    }

    private func highlightedText(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let terms = expandedSearchTerms
        guard !terms.isEmpty else { return out }
        for term in terms where !term.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
                if let lo = AttributedString.Index(found.lowerBound, within: out),
                   let hi = AttributedString.Index(found.upperBound, within: out) {
                    out[lo..<hi].backgroundColor = Color(red: 1.0, green: 0.88, blue: 0.45)
                    out[lo..<hi].foregroundColor = .black
                }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return out
    }
}
