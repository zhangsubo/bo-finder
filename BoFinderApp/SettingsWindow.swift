import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var cutPasteManager = CutPasteManager.shared
    @ObservedObject var eventTapManager = EventTapManager.shared
    @ObservedObject var extensionDoctor = FinderExtensionDoctor.shared
    @ObservedObject var hiddenFilesManager = HiddenFilesManager.shared
    @ObservedObject var appUpdater = AppUpdater.shared
    @StateObject private var shortcutRecorder = ShortcutRecorderController()

    @State private var selectedTab: Int = 0
    @State private var draggingPathFormat: PathFormat? = nil
    @State private var dragSourceIndex: Int? = nil
    @State private var dragTargetIndex: Int? = nil
    @State private var dragTranslationY: CGFloat = 0
    @State private var settlingFormat: PathFormat? = nil
    @State private var settleOffsetY: CGFloat = 0
    @GestureState private var isFormatDragGestureActive: Bool = false

    private let formatRowHeight: CGFloat = 54

    private let sampleURL = URL(fileURLWithPath: "\(PathFormatter.realHomeDirectory())/Documents/项目资料/DeskSide 测试文件 (1).pdf")

    @AppStorage("deskside.selectedPage") private var selectedPage = "files"
    @AppStorage("deskside.appearance") private var appearance = "system"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(pageTitle).font(.headline)
                    Spacer()
                    if selectedPage == "files" {
                        Label("文件工具", systemImage: "folder").foregroundColor(.secondary)
                    } else if selectedPage == "env" {
                        Label("环境变量", systemImage: "terminal").foregroundColor(.secondary)
                    } else if selectedPage == "gateway" {
                        Label("安全网关", systemImage: "checkmark.shield").foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 28).frame(height: 48)
                Divider()
                Group {
                    switch selectedPage {
                    case "env":
                        EnvView()
                    case "gateway":
                        GatewayView()
                    case "meetings":
                        MeetingView()
                    case "settings": globalSettings
                    default: fileTools
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text("设置自动保存到这台 Mac").font(.caption)
                    Spacer()
                    Text("DeskSide").font(.caption)
                }
                .foregroundColor(.secondary).padding(.horizontal, 28).frame(height: 30)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            if !["files", "env", "gateway", "meetings", "settings"].contains(selectedPage) { selectedPage = "files" }
            refreshStatus()
            applyAppearance()
        }
        .onDisappear { shortcutRecorder.stopRecording() }
        .onChange(of: selectedPage) { _, _ in shortcutRecorder.stopRecording() }
        .onChange(of: selectedTab) { _, _ in shortcutRecorder.stopRecording() }
        .onChange(of: appearance) { _, _ in applyAppearance() }
    }

    private var pageTitle: String {
        switch selectedPage {
        case "env": return "环境变量"
        case "gateway": return "安全网关"
        case "meetings": return "会议助手"
        case "settings": return "设置与关于"
        default: return "文件工具"
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                appLogo(size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DeskSide").font(.system(size: 18, weight: .semibold))
                    Text("桌边，随手好用。").font(.caption2).foregroundColor(.secondary)
                }
            }.padding(.vertical, 24).padding(.horizontal, 8)
            Text("我的工具").font(.caption).foregroundColor(.secondary).padding(.horizontal, 10).padding(.bottom, 5)
            sidebarButton("文件工具", symbol: "folder", page: "files")
            sidebarButton("环境变量", symbol: "terminal", page: "env")
            sidebarButton("会议助手", symbol: "mic", page: "meetings")
            sidebarButton("安全网关", symbol: "checkmark.shield", page: "gateway")
            Spacer(minLength: 20)
            Divider().padding(.bottom, 6)
            sidebarButton("设置与关于", symbol: "gearshape", page: "settings")
            Label("运行在这台 Mac 上", systemImage: "desktopcomputer")
                .font(.caption2).foregroundColor(.secondary).padding(10)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("全局侧边栏")
    }

    private func sidebarButton(_ title: String, symbol: String, page: String, upcoming: Bool = false) -> some View {
        Button {
            selectedPage = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18).foregroundColor(.accentColor)
                Text(title).fontWeight(selectedPage == page ? .semibold : .regular)
                Spacer(minLength: 0)
                if upcoming { Text("即将推出").font(.system(size: 9)).foregroundColor(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(selectedPage == page ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedPage == page ? .isSelected : [])
    }

    @ViewBuilder private func appLogo(size: CGFloat) -> some View {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23))
                .accessibilityLabel("DeskSide")
        }
    }

    private var fileTools: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("文件工具").font(.system(size: 25, weight: .bold))
                Text("让 Finder 里的每一步，都更顺手。").foregroundColor(.secondary)
            }
            Picker("文件工具分类", selection: $selectedTab) {
                Text("路径复制").tag(0)
                Text("剪切与移动").tag(1)
                Text("快捷打开").tag(2)
                Text("显示与增强").tag(3)
                Text("权限与诊断").tag(4)
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch selectedTab {
                case 1: ScrollView { cutPasteTab }
                case 2: terminalAndOrcaTab
                case 3: displayAndEnhanceTab
                case 4: permissionsAndDoctorTab
                default: copyPathTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(26)
    }

    private func comingSoon(title: String, symbol: String, detail: String, note: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light))
                .foregroundColor(.secondary).frame(width: 76, height: 76)
                .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 18))
            Text(title).font(.system(size: 25, weight: .semibold))
            Text(detail).foregroundColor(.secondary)
            Text("即将推出").font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
            Text(note).font(.caption).foregroundColor(.secondary).padding(.top, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshStatus() {
        extensionDoctor.refreshPlugins()
        eventTapManager.checkPermissionAndStartIfPossible(promptIfNeeded: false)
        hiddenFilesManager.refreshFromSystem()
    }

    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Tab 1: Copy Path

    private var copyPathTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("右键菜单展示方式", systemImage: "cursorarrow")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("在右键菜单顶部显示置顶快捷栏（位于「打开/复制」正上方，免下滑鼠标，且支持 iCloud 云盘）", isOn: Binding(
                            get: { cutPasteManager.state.config.showTopQuickBarOnRightClick },
                            set: { val in cutPasteManager.updateConfig { $0.showTopQuickBarOnRightClick = val } }
                        ))
                        .fontWeight(.semibold)

                        if !eventTapManager.isAccessibilityTrusted || !eventTapManager.isEventTapRunning {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("macOS 在 iCloud 云盘（含开启 iCloud 同步的「桌面」与「文稿」）中禁用了原生 Finder 扩展，需开启「辅助功能」权限方可弹出置顶快捷栏。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button("打开系统授权") {
                                    selectedTab = 4
                                    eventTapManager.requestAccessibilityPermission()
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        }

                        Divider()

                        Picker("原生右键菜单结构：", selection: Binding(
                            get: { cutPasteManager.state.config.useSubmenuForCopyPath },
                            set: { val in cutPasteManager.updateConfig { $0.useSubmenuForCopyPath = val } }
                        )) {
                            Text("二级子菜单（右键显示「复制路径 ▸」，展开选择格式）").tag(true)
                            Text("一级菜单平铺（直接在右键一级菜单显示各格式）").tag(false)
                        }
                        .pickerStyle(.radioGroup)

                        Divider()

                        Picker("Windows 路径样式：", selection: Binding(
                            get: { cutPasteManager.state.config.windowsPathStyle },
                            set: { val in cutPasteManager.updateConfig { $0.windowsPathStyle = val } }
                        )) {
                            ForEach(WindowsPathStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("启用的路径格式（勾选后在右键及状态栏菜单中显示，越往上越靠前）", systemImage: "list.bullet.rectangle")) {
                    let orderedFormats = BoFinderConfig.normalizedFormatOrder(
                        startingWith: cutPasteManager.state.config.formatOrder
                    )
                    let previewFormats = previewReorderedFormats(orderedFormats)
                    let enabledSet = Set(cutPasteManager.state.config.enabledFormats)
                    let previewDisplayFormats = previewFormats.filter { enabledSet.contains($0) }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("按住左侧手柄上下拖动整行（或点击右侧上下按钮）调整顺序，越往上展示越靠前。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if orderedFormats != PathFormat.allCases {
                                Button("恢复默认顺序") {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        cutPasteManager.updateConfig { $0.resetFormatOrder() }
                                    }
                                }
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(orderedFormats) { format in
                                let index = orderedFormats.firstIndex(of: format) ?? 0
                                let isOn = enabledSet.contains(format)
                                let enabledRank = previewDisplayFormats.firstIndex(of: format).map { $0 + 1 }
                                let isDraggingThis = (draggingPathFormat == format)
                                let isElevated = isDraggingThis || (settlingFormat == format)
                                let rowOffset = formatRowVisualOffset(for: index, format: format)
                                let dragGesture = makeFormatReorderGesture(for: format, orderedFormats: orderedFormats)

                                HStack(alignment: .center, spacing: 8) {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(isDraggingThis ? .accentColor : .secondary.opacity(0.75))
                                        .frame(width: 26, height: formatRowHeight - 4)
                                        .contentShape(Rectangle())
                                        .help("按住上下拖动整行调整顺序")
                                        .gesture(dragGesture)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 0) {
                                            Toggle(isOn: Binding(
                                                get: { isOn },
                                                set: { enabled in
                                                    cutPasteManager.updateConfig { cfg in
                                                        cfg.setFormatEnabled(format, enabled: enabled)
                                                    }
                                                }
                                            )) {
                                                HStack(spacing: 6) {
                                                    Image(systemName: format.symbolName)
                                                        .frame(width: 18)
                                                        .foregroundColor(.accentColor)
                                                    Text(format.title)
                                                        .fontWeight(.medium)
                                                }
                                            }

                                            Spacer(minLength: 8)
                                                .frame(height: 20)
                                                .contentShape(Rectangle())
                                                .gesture(dragGesture)
                                        }

                                        let preview = PathFormatter.formatSingle(
                                            url: sampleURL,
                                            as: format,
                                            windowsStyle: cutPasteManager.state.config.windowsPathStyle
                                        )
                                        Text("示例：\(preview)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .padding(.leading, 26)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                            .gesture(dragGesture)
                                    }

                                    if isOn, let rank = enabledRank {
                                        Text("第 \(rank) 位")
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.12))
                                            .clipShape(Capsule())
                                            .gesture(dragGesture)
                                    }

                                    HStack(spacing: 4) {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.16)) {
                                                cutPasteManager.updateConfig { $0.moveFormat(format, by: -1) }
                                            }
                                        } label: {
                                            Image(systemName: "chevron.up")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 22, height: 20)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(index == 0 || draggingPathFormat != nil)
                                        .help("上移（展示更靠前）")

                                        Button {
                                            withAnimation(.easeInOut(duration: 0.16)) {
                                                cutPasteManager.updateConfig { $0.moveFormat(format, by: 1) }
                                            }
                                        } label: {
                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 11, weight: .semibold))
                                                .frame(width: 22, height: 20)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(index == orderedFormats.count - 1 || draggingPathFormat != nil)
                                        .help("下移（展示更靠后）")
                                    }
                                }
                                .padding(.horizontal, 6)
                                .frame(height: formatRowHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isDraggingThis ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isDraggingThis ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                                )
                                .overlay(alignment: .bottom) {
                                    if index < orderedFormats.count - 1 && !isDraggingThis {
                                        Divider()
                                    }
                                }
                                .shadow(
                                    color: isDraggingThis ? Color.black.opacity(0.14) : Color.clear,
                                    radius: isDraggingThis ? 8 : 0,
                                    x: 0,
                                    y: isDraggingThis ? 3 : 0
                                )
                                .offset(y: rowOffset)
                                .zIndex(isElevated ? 10 : 0)
                                .animation(
                                    isDraggingThis ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.86),
                                    value: dragTargetIndex
                                )
                                .contextMenu {
                                    Button("移至最前（置顶）") {
                                        guard let first = orderedFormats.first else { return }
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            cutPasteManager.updateConfig { $0.moveFormat(format, to: first) }
                                        }
                                    }
                                    .disabled(index == 0)

                                    Button("上移一位") {
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            cutPasteManager.updateConfig { $0.moveFormat(format, by: -1) }
                                        }
                                    }
                                    .disabled(index == 0)

                                    Button("下移一位") {
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            cutPasteManager.updateConfig { $0.moveFormat(format, by: 1) }
                                        }
                                    }
                                    .disabled(index == orderedFormats.count - 1)

                                    Button("移至最后") {
                                        guard let last = orderedFormats.last else { return }
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            cutPasteManager.updateConfig { $0.moveFormat(format, to: last) }
                                        }
                                    }
                                    .disabled(index == orderedFormats.count - 1)
                                }
                            }
                        }
                        .coordinateSpace(name: "pathFormatList")
                        .onChange(of: isFormatDragGestureActive) { _, active in
                            if !active, draggingPathFormat != nil {
                                finishFormatReorderDrag(orderedFormats: orderedFormats)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func previewReorderedFormats(_ base: [PathFormat]) -> [PathFormat] {
        guard let src = dragSourceIndex,
              let dst = dragTargetIndex,
              src != dst,
              base.indices.contains(src),
              base.indices.contains(dst) else {
            return base
        }
        var copy = base
        let item = copy.remove(at: src)
        copy.insert(item, at: dst)
        return copy
    }

    private func formatRowVisualOffset(for index: Int, format: PathFormat) -> CGFloat {
        if draggingPathFormat == format {
            return dragTranslationY
        }
        if settlingFormat == format {
            return settleOffsetY
        }
        guard let src = dragSourceIndex, let dst = dragTargetIndex, src != dst else {
            return 0
        }
        if src < dst, index > src, index <= dst {
            return -formatRowHeight
        }
        if src > dst, index >= dst, index < src {
            return formatRowHeight
        }
        return 0
    }

    private func makeFormatReorderGesture(
        for format: PathFormat,
        orderedFormats: [PathFormat]
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("pathFormatList"))
            .updating($isFormatDragGestureActive) { _, state, _ in
                state = true
            }
            .onChanged { value in
                guard let currentIndex = orderedFormats.firstIndex(of: format) else { return }
                if draggingPathFormat == nil {
                    settlingFormat = nil
                    settleOffsetY = 0
                    draggingPathFormat = format
                    dragSourceIndex = currentIndex
                    dragTargetIndex = currentIndex
                }
                guard draggingPathFormat == format, let src = dragSourceIndex else { return }
                let minTranslation = -CGFloat(src) * formatRowHeight - 6
                let maxTranslation = CGFloat(orderedFormats.count - 1 - src) * formatRowHeight + 6
                let clamped = min(max(value.translation.height, minTranslation), maxTranslation)
                dragTranslationY = clamped

                let projectedSlot = (CGFloat(src) * formatRowHeight + clamped) / formatRowHeight
                let nextTarget = min(max(Int(projectedSlot.rounded()), 0), orderedFormats.count - 1)
                if nextTarget != dragTargetIndex {
                    dragTargetIndex = nextTarget
                }
            }
            .onEnded { _ in
                finishFormatReorderDrag(orderedFormats: orderedFormats)
            }
    }

    private func finishFormatReorderDrag(orderedFormats: [PathFormat]) {
        guard let dragged = draggingPathFormat else { return }
        let src = dragSourceIndex ?? (orderedFormats.firstIndex(of: dragged) ?? 0)
        let dst = dragTargetIndex ?? src
        let residual = dragTranslationY - CGFloat(dst - src) * formatRowHeight

        var noAnim = Transaction()
        noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            if src != dst, orderedFormats.indices.contains(dst) {
                let targetFormat = orderedFormats[dst]
                cutPasteManager.updateConfig { $0.moveFormat(dragged, to: targetFormat) }
            }
            draggingPathFormat = nil
            dragSourceIndex = nil
            dragTargetIndex = nil
            dragTranslationY = 0
            settlingFormat = dragged
            settleOffsetY = residual
        }

        withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) {
            settleOffsetY = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if draggingPathFormat == nil {
                settlingFormat = nil
            }
        }
    }

    // MARK: - Tab 2: Terminal & Orca

    private var terminalAndOrcaTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("右键「在此处打开终端」设置", systemImage: "terminal")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("在右键菜单及置顶快捷栏中显示「在此处打开终端」", isOn: Binding(
                            get: { cutPasteManager.state.config.enableOpenTerminalInMenu },
                            set: { val in cutPasteManager.updateConfig { $0.enableOpenTerminalInMenu = val } }
                        ))
                        .fontWeight(.semibold)

                        Text("• 在文件夹上右键：直接在该文件夹地址上打开终端。\n• 在文件夹空白处或文件上右键：在当前所在目录打开终端。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Text("选择默认终端应用：")
                            .fontWeight(.medium)

                        ForEach(TerminalApp.allCases) { app in
                            let installed = TerminalLauncher.shared.isInstalled(app)
                            let isSelected = cutPasteManager.state.config.defaultTerminal == app
                            HStack(spacing: 10) {
                                Button(action: {
                                    cutPasteManager.updateConfig { $0.defaultTerminal = app }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                            .foregroundColor(isSelected ? .accentColor : .secondary)
                                        Image(systemName: app.symbolName)
                                            .frame(width: 18)
                                            .foregroundColor(.accentColor)
                                        Text(app.title)
                                            .fontWeight(isSelected ? .semibold : .regular)
                                            .foregroundColor(.primary)
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                if installed {
                                    Text("已安装")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.12))
                                        .cornerRadius(4)
                                } else {
                                    Text("未安装")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.gray.opacity(0.12))
                                        .cornerRadius(4)
                                }

                                if installed {
                                    Button("测试打开") {
                                        let homeURL = URL(fileURLWithPath: PathFormatter.realHomeDirectory())
                                        TerminalLauncher.shared.openTerminal(at: homeURL, using: app)
                                    }
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("在 Orca 中打开 (Orca.app 深度集成)", systemImage: "sparkles.rectangle.stack")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("在右键菜单及置顶快捷栏中独立显示「在 Orca 中打开」按钮", isOn: Binding(
                            get: { cutPasteManager.state.config.enableOpenInOrcaInMenu },
                            set: { val in cutPasteManager.updateConfig { $0.enableOpenInOrcaInMenu = val } }
                        ))
                        .fontWeight(.semibold)

                        Text("• 支持将任意 Git 仓库或普通文件夹一键导入并激活到 Orca 工作区，同时自动打开并聚焦该目录的终端面板。\n• 当默认终端已设为 iTerm2 / Ghostty / 系统终端时，开启此项可同时拥有「终端」和「Orca」两个快捷入口。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            let orcaInstalled = TerminalLauncher.shared.isInstalled(.orca)
                            Image(systemName: orcaInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(orcaInstalled ? .green : .orange)
                            Text(orcaInstalled ? "已检测到 /Applications/Orca.app" : "未检测到 /Applications/Orca.app")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if orcaInstalled {
                                Button("测试在 Orca 中打开当前用户目录") {
                                    let homeURL = URL(fileURLWithPath: PathFormatter.realHomeDirectory())
                                    TerminalLauncher.shared.openInOrca(at: homeURL)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Tab 3: Cut & Paste

    private var cutPasteTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Label("原生剪切与粘贴 (⌘+X / ⌘+V)", systemImage: "keyboard")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("启用 Finder 中 ⌘+X 剪切文件、⌘+V 粘贴移动", isOn: Binding(
                        get: { cutPasteManager.state.config.enableCutAndPasteKeybindings },
                        set: { val in cutPasteManager.updateConfig { $0.enableCutAndPasteKeybindings = val } }
                    ))
                    .fontWeight(.medium)

                    if cutPasteManager.state.config.enableCutAndPasteKeybindings && !eventTapManager.isAccessibilityTrusted {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("⌘+X / ⌘+V 文件剪切粘贴需要开启「辅助功能」权限后方可在 Finder 中生效。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("打开系统授权") {
                                selectedTab = 4
                                eventTapManager.requestAccessibilityPermission()
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(6)
                    }

                    Text("• 在 Finder 中选中文件按 ⌘+X 进入剪切状态，在目标目录按 ⌘+V 直接执行文件移动。\n• 按 Esc 键或重新按 ⌘+C 可随时取消剪切状态。\n• 智能识别重命名文件、搜索框输入等文本编辑状态，不影响文字剪切粘贴。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    Toggle("在 Finder 右键菜单中同时显示「剪切」与「粘贴移动」选项", isOn: Binding(
                        get: { cutPasteManager.state.config.enableContextMenuCutAndPaste },
                        set: { val in cutPasteManager.updateConfig { $0.enableContextMenuCutAndPaste = val } }
                    ))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("交互反馈", systemImage: "bell.badge")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("显示屏幕轻量悬浮提示 (HUD Toast)", isOn: Binding(
                        get: { cutPasteManager.state.config.showHUDFeedback },
                        set: { val in cutPasteManager.updateConfig { $0.showHUDFeedback = val } }
                    ))

                    Toggle("操作完成时播放轻柔提示音", isOn: Binding(
                        get: { cutPasteManager.state.config.playSoundOnAction },
                        set: { val in cutPasteManager.updateConfig { $0.playSoundOnAction = val } }
                    ))

                    HStack {
                        Button("测试悬浮提示 (HUD)") {
                            HUDWindowController.shared.show(
                                title: "DeskSide 运行正常",
                                subtitle: "右键复制路径与 ⌘+X / ⌘+V 剪切已就绪",
                                symbolName: "checkmark.seal.fill"
                            )
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Label("当前剪贴板剪切状态", systemImage: "clipboard")) {
                HStack {
                    if cutPasteManager.state.isCutActive {
                        Image(systemName: "scissors.circle.fill")
                            .foregroundColor(.orange)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前处于待剪切移动状态（共 \(cutPasteManager.state.cutFilePaths.count) 个项目）")
                                .fontWeight(.semibold)
                            if let first = cutPasteManager.state.cutFilePaths.first {
                                Text(first)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button("取消剪切") {
                            cutPasteManager.clearCut(showHUD: true)
                        }
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("当前无待移动的剪切项目")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
    }

    // MARK: - Tab 4: Display & Enhancements (显示与增强)

    private var displayAndEnhanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("显示隐藏文件（以 . 开头的系统与隐藏文件）", systemImage: "eye")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Toggle("在 Finder 中显示隐藏文件（如 .git、.env、.zshrc 等）", isOn: Binding(
                                get: { hiddenFilesManager.isShowingHiddenFiles },
                                set: { visible in
                                    hiddenFilesManager.setHiddenFilesVisible(visible, showHUD: true)
                                }
                            ))
                            .fontWeight(.semibold)

                            Spacer()

                            if hiddenFilesManager.isShowingHiddenFiles {
                                Text("当前已显示")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.12))
                                    .cornerRadius(4)
                            } else {
                                Text("当前已隐藏")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.gray.opacity(0.12))
                                    .cornerRadius(4)
                            }
                        }

                        Text("• 开启后，Finder 窗口与桌面将显示文件名以「.」开头的隐藏文件及系统隐藏目录（如 .git、.ssh、.DS_Store、~/Library 等）。\n• 也可通过顶部状态栏图标右键菜单随时查看与切换状态。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("重新同步并刷新 Finder") {
                                hiddenFilesManager.forceSyncFinder()
                            }
                            .controlSize(.small)

                            Text("若 Finder 窗口临时状态不一致，可点击强制同步。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("快捷键快速开关（仅在 Finder 前台生效）", systemImage: "command")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用在 Finder 中按快捷键快速打开 / 关闭隐藏文件显示", isOn: Binding(
                            get: { cutPasteManager.state.config.enableHiddenFilesShortcut },
                            set: { val in
                                shortcutRecorder.stopRecording()
                                cutPasteManager.updateConfig { $0.enableHiddenFilesShortcut = val }
                            }
                        ))
                        .fontWeight(.medium)

                        Divider()

                        HStack(spacing: 10) {
                            Text("当前快捷键：")
                                .fontWeight(.medium)

                            let currentShortcut = cutPasteManager.state.config.hiddenFilesShortcut
                            Text(shortcutRecorder.isRecording ? "请按下快捷键组合…" : currentShortcut.displayString)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(shortcutRecorder.isRecording ? .accentColor : .primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(shortcutRecorder.isRecording ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(shortcutRecorder.isRecording ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                                )

                            if shortcutRecorder.isRecording {
                                Button("取消 (Esc)") {
                                    shortcutRecorder.stopRecording()
                                }
                            } else {
                                Button("录制快捷键…") {
                                    shortcutRecorder.startRecording { recorded in
                                        cutPasteManager.updateConfig { cfg in
                                            cfg.hiddenFilesShortcut = recorded
                                            cfg.enableHiddenFilesShortcut = true
                                        }
                                    }
                                }
                            }

                            if currentShortcut != .defaultHiddenFiles {
                                Button("恢复默认") {
                                    shortcutRecorder.stopRecording()
                                    cutPasteManager.updateConfig { $0.hiddenFilesShortcut = .defaultHiddenFiles }
                                }
                                .controlSize(.small)
                            }

                            Spacer()
                        }

                        HStack(spacing: 8) {
                            Text("一键预设：")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            shortcutPresetButton(title: "⌘+⇧+.（系统默认）", shortcut: .defaultHiddenFiles)
                            shortcutPresetButton(title: "⌃+H", shortcut: .presetControlH)
                            shortcutPresetButton(title: "⌥+.", shortcut: .presetOptionPeriod)
                        }

                        if let validationMsg = shortcutRecorder.validationMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(validationMsg)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }

                        if !eventTapManager.isAccessibilityTrusted {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("快捷键监听需要开启「辅助功能」权限后方可在 Finder 中触发。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("打开系统授权") {
                                    selectedTab = 4
                                    eventTapManager.requestAccessibilityPermission()
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(6)
                        }

                        Text("• 仅当 Finder 处于前台时触发，不会影响其他应用的快捷键。\n• 在 Finder 中按快捷键采用原生零闪烁即时切换，不中断文件复制，同时自动持久化设置并弹出 HUD 提示。\n• 智能识别文件重命名、搜索框与路径跳转输入状态，不影响正常文字输入。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func shortcutPresetButton(title: String, shortcut: KeyShortcut) -> some View {
        let isCurrent = cutPasteManager.state.config.hiddenFilesShortcut == shortcut
        return Button(title) {
            shortcutRecorder.stopRecording()
            cutPasteManager.updateConfig { cfg in
                cfg.hiddenFilesShortcut = shortcut
                cfg.enableHiddenFilesShortcut = true
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(isCurrent ? .accentColor : nil)
    }

    // MARK: - Tab 5: Permissions & Doctor (权限与诊断)

    private var permissionsAndDoctorTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("辅助功能权限（用于支持 iCloud 右键快捷栏、剪切粘贴与隐藏文件快捷键）", systemImage: "hand.raised.fill")) {
                    HStack(spacing: 12) {
                        Image(systemName: eventTapManager.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(eventTapManager.isAccessibilityTrusted ? .green : .orange)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(eventTapManager.isAccessibilityTrusted ? (eventTapManager.isEventTapRunning ? "辅助功能已授权，右键快捷栏与快捷键监听运行中" : "辅助功能已授权，事件监听尚未启动") : "需要开启「辅助功能」权限以支持 iCloud 右键快捷栏与 Finder 快捷键")
                                .fontWeight(.semibold)
                            Text("点击「打开系统授权」会自动清理旧版失效授权记录并在「辅助功能」列表下方弹出引导浮层，直接按住 DeskSide 胶囊卡片上拖至列表并确认开关开启即可生效（无需手动先删旧记录；建议固定从 /Applications/DeskSide.app 启动）。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if !eventTapManager.isAccessibilityTrusted {
                            Button("打开系统授权") {
                                eventTapManager.requestAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("刷新状态") {
                                eventTapManager.checkPermissionAndStartIfPossible(promptIfNeeded: false)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("Finder 右键菜单扩展与冲突管理", systemImage: "puzzlepiece.extension.fill")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: extensionDoctor.isBoFinderExtensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(extensionDoctor.isBoFinderExtensionEnabled ? .green : .orange)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(extensionDoctor.isBoFinderExtensionEnabled ? "DeskSide 右键扩展已启用" : "DeskSide 右键扩展未启用")
                                    .fontWeight(.semibold)
                                Text("提示：macOS Finder 同一目录仅允许一个 FinderSync 扩展显示右键菜单。如果 WPS、百度网盘、CleanMyMac 等占用了根目录，可点击下方「一键设为优先右键扩展」。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 10) {
                            Button("一键设为优先右键扩展（解决冲突）") {
                                guard extensionDoctor.prioritizeBoFinderExtension() else { return }
                                HUDWindowController.shared.show(
                                    title: "已请求优先启用 DeskSide 右键扩展",
                                    subtitle: "请在下方列表检查扩展状态",
                                    symbolName: "sparkles"
                                )
                            }
                            .buttonStyle(.borderedProminent)

                            Button("重新注册并刷新") {
                                extensionDoctor.registerAndEnableOurExtension()
                            }

                            Button("恢复 Finder 边栏与工具栏") {
                                restoreFinderSidebar()
                            }
                        }

                        Divider()

                        Text("当前系统已安装的 Finder 右键扩展列表：")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)

                        ForEach(extensionDoctor.plugins) { plugin in
                            HStack {
                                Circle()
                                    .fill(plugin.isEnabled ? Color.green : Color.gray.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                Text(plugin.displayName)
                                    .fontWeight(plugin.isBoFinder ? .bold : .regular)
                                if plugin.isBoFinder {
                                    Text("当前应用")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                Text("(\(plugin.id))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { plugin.isEnabled },
                                    set: { newVal in
                                        extensionDoctor.setPluginEnabled(plugin.id, enabled: newVal)
                                    }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var globalSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("设置与关于").font(.system(size: 25, weight: .bold))
                Text("让桌边按照你的习惯工作。").foregroundColor(.secondary)
                GroupBox(label: Label("窗口与常驻", systemImage: "app.badge")) {
                    HStack(spacing: 14) {
                        if let logoURL = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
                           let nsImg = NSImage(contentsOf: logoURL) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 1)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("开机自动启动 DeskSide", isOn: Binding(
                                get: { cutPasteManager.state.config.launchAtLogin },
                                set: { val in
                                    cutPasteManager.updateConfig { $0.launchAtLogin = val }
                                    LaunchAtLoginManager.shared.setEnabled(val)
                                }
                            ))
                            .fontWeight(.semibold)

                            Toggle("在 Dock 栏显示应用图标", isOn: Binding(
                                get: { cutPasteManager.state.config.showDockIcon },
                                set: { val in cutPasteManager.updateConfig { $0.showDockIcon = val } }
                            ))
                            .fontWeight(.semibold)

                            Text("• 左键点击 Dock 图标或顶部菜单栏 Logo，可直接打开此设置面板。\n• 右键（或 ⌃+左键）点击顶部菜单栏 Logo，可弹出快捷操作菜单。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button("退出 DeskSide") {
                            NSApp.terminate(nil)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


                GroupBox("外观") {
                    Picker("界面外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.padding(12)
                }

                GroupBox("应用更新（GitHub Release 自动同步）") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("发现新版本时自动下载并安装（录音期间自动延后）", isOn: Binding(
                                get: { appUpdater.autoInstallEnabled },
                                set: { appUpdater.autoInstallEnabled = $0 }
                            ))
                            .fontWeight(.semibold)
                            Spacer()
                            if appUpdater.isInstalling {
                                ProgressView(value: appUpdater.downloadProgress)
                                    .frame(width: 110)
                            } else if let update = appUpdater.availableUpdate {
                                Button("立即更新至 v\(update.version)") {
                                    Task { await appUpdater.install(update, silentRelaunch: false) }
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                Button(appUpdater.isChecking ? "检查中…" : "检查更新") {
                                    Task { await appUpdater.checkForUpdates(manual: true) }
                                }
                                .disabled(appUpdater.isChecking)
                            }
                        }
                        if !appUpdater.statusMessage.isEmpty {
                            Text(appUpdater.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if !appUpdater.errorMessage.isEmpty {
                            Text(appUpdater.errorMessage)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        Text("GitHub Action 每次构建发布新版本后，安装在 /Applications/DeskSide.app 的应用会自动校验 SHA-256 与代码签名并完成热替换更新。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 18) {
                    appLogo(size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("桌边 · DeskSide").font(.title2).fontWeight(.semibold)
                        Text("需要的时候，就在手边。").foregroundColor(.secondary)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0")")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }.padding(.vertical, 12)
                Text("文件工具承接 BoFinder，原有功能与设置继续保留。关闭窗口后，DeskSide 仍在菜单栏运行。\n会议助手内置声纹识别模型基于 WeSpeaker ResNet34-LM（VoxCeleb 数据集训练，CC BY 4.0 许可），实时纪要与悬浮窗设计参考开源项目 Cicada（MIT）。")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func restoreFinderSidebar() {
        let script = """
        tell application "Finder"
            set winCount to count of Finder windows
            repeat with i from 1 to winCount
                set w to Finder window i
                set toolbar visible of w to true
                if sidebar width of w is 0 then
                    set sidebar width of w to 180
                end if
            end repeat
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}

final class ShortcutRecorderController: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published var validationMessage: String?

    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    deinit {
        cleanupMonitors()
    }

    func startRecording(onCapture: @escaping (KeyShortcut) -> Void) {
        cleanupMonitors()
        validationMessage = nil
        isRecording = true

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopRecording()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let code = Int(event.keyCode)
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            if code == 53 && mods.isEmpty {
                self.stopRecording()
                return nil
            }

            if KeyShortcut.isModifierKeyCode(code) {
                return nil
            }

            let candidate = KeyShortcut(
                keyCode: code,
                command: mods.contains(.command),
                shift: mods.contains(.shift),
                option: mods.contains(.option),
                control: mods.contains(.control)
            )

            if let errorReason = candidate.validateForFinder() {
                self.validationMessage = errorReason
                NSSound.beep()
                return nil
            }

            self.validationMessage = nil
            self.stopRecording()
            onCapture(candidate)
            return nil
        }
    }

    func stopRecording() {
        cleanupMonitors()
        if isRecording {
            isRecording = false
        }
    }

    private func cleanupMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let obs = resignObserver {
            NotificationCenter.default.removeObserver(obs)
            resignObserver = nil
        }
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    var isWindowVisible: Bool {
        return window?.isVisible == true
    }

    func bringToFrontIfVisible() {
        guard let existing = window, existing.isVisible else { return }
        existing.makeKeyAndOrderFront(nil)
    }

    func showWindow(page: String? = nil) {
        if let page { UserDefaults.standard.set(page, forKey: "deskside.selectedPage") }
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 730),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "桌边 · DeskSide"
        win.minSize = NSSize(width: 860, height: 650)
        win.contentViewController = hostingController
        win.setContentSize(NSSize(width: 1020, height: 730))
        win.center()
        win.setFrameAutosaveName("DeskSide.MainWindow")
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}
