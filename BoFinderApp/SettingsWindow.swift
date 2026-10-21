import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var cutPasteManager = CutPasteManager.shared
    @ObservedObject var eventTapManager = EventTapManager.shared
    @ObservedObject var extensionDoctor = FinderExtensionDoctor.shared

    @State private var selectedTab: Int = 0

    private let sampleURL = URL(fileURLWithPath: "\(PathFormatter.realHomeDirectory())/Documents/项目资料/BoFinder 测试文件 (1).pdf")

    var body: some View {
        TabView(selection: $selectedTab) {
            copyPathTab
                .tabItem {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
                .tag(0)

            terminalAndOrcaTab
                .tabItem {
                    Label("终端与 Orca", systemImage: "terminal")
                }
                .tag(1)

            cutPasteTab
                .tabItem {
                    Label("剪切与粘贴", systemImage: "scissors")
                }
                .tag(2)

            permissionsAndDoctorTab
                .tabItem {
                    Label("通用设置", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .padding(20)
        .frame(width: 620, height: 540)
        .onAppear {
            extensionDoctor.refreshPlugins()
            eventTapManager.checkPermissionAndStartIfPossible(promptIfNeeded: false)
        }
    }

    // MARK: - Tab 1: Copy Path

    private var copyPathTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("右键菜单展示方式", systemImage: "ContextualMenuItem")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("在右键菜单顶部显示置顶快捷栏（位于「打开/复制」正上方，免下滑鼠标，且支持 iCloud 云盘）", isOn: Binding(
                            get: { cutPasteManager.state.config.showTopQuickBarOnRightClick },
                            set: { val in cutPasteManager.updateConfig { $0.showTopQuickBarOnRightClick = val } }
                        ))
                        .fontWeight(.semibold)

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

                GroupBox(label: Label("启用的路径格式（勾选后在右键及状态栏菜单中显示）", systemImage: "list.bullet.rectangle")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PathFormat.allCases) { format in
                            let isOn = cutPasteManager.state.config.enabledFormats.contains(format)
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle(isOn: Binding(
                                    get: { isOn },
                                    set: { enabled in
                                        cutPasteManager.updateConfig { cfg in
                                            if enabled {
                                                if !cfg.enabledFormats.contains(format) {
                                                    cfg.enabledFormats.append(format)
                                                }
                                            } else {
                                                if cfg.enabledFormats.count > 1 {
                                                    cfg.enabledFormats.removeAll { $0 == format }
                                                }
                                            }
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
                            }
                            if format != PathFormat.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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

                    Text("• 在 Finder 中选中文件按 ⌘+X 进入剪切状态，在目标目录按 ⌘+V 自动触发原生移动（等同于 ⌥+⌘+V）。\n• 按 Esc 键或重新按 ⌘+C 可随时取消剪切状态。\n• 智能识别重命名文件、搜索框输入等文本编辑状态，不影响文字剪切粘贴。")
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
                                title: "BoFinder 运行正常",
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

    // MARK: - Tab 4: General Settings (通用设置)

    private var permissionsAndDoctorTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Label("1. 应用图标与外观（Dock 与顶部菜单栏）", systemImage: "app.badge")) {
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

                        VStack(alignment: .leading, spacing: 6) {
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

                        Button("退出 BoFinder") {
                            NSApp.terminate(nil)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("2. 辅助功能权限（用于接管 Finder 中的 ⌘+X / ⌘+V 快捷键）", systemImage: "hand.raised.fill")) {
                    HStack(spacing: 12) {
                        Image(systemName: eventTapManager.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(eventTapManager.isAccessibilityTrusted ? .green : .orange)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(eventTapManager.isAccessibilityTrusted ? "辅助功能权限已开启（⌘+X / ⌘+V 监听运行中）" : "需要开启「辅助功能」权限以支持 ⌘+X / ⌘+V")
                                .fontWeight(.semibold)
                            Text("在「系统设置 -> 隐私与安全性 -> 辅助功能」中勾选 BoFinder。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if !eventTapManager.isAccessibilityTrusted {
                            Button("请求授权") {
                                eventTapManager.checkPermissionAndStartIfPossible(promptIfNeeded: true)
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

                GroupBox(label: Label("3. Finder 右键菜单扩展与冲突管理", systemImage: "puzzlepiece.extension.fill")) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: extensionDoctor.isBoFinderExtensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(extensionDoctor.isBoFinderExtensionEnabled ? .green : .orange)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(extensionDoctor.isBoFinderExtensionEnabled ? "BoFinder 右键扩展已启用" : "BoFinder 右键扩展未启用")
                                    .fontWeight(.semibold)
                                Text("提示：macOS Finder 同一目录仅允许一个 FinderSync 扩展显示右键菜单。如果 WPS、百度网盘、CleanMyMac 等占用了根目录，可点击下方「一键设为优先右键扩展」。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 10) {
                            Button("一键设为优先右键扩展（解决冲突）") {
                                extensionDoctor.prioritizeBoFinderExtension()
                                HUDWindowController.shared.show(
                                    title: "已优先启用 BoFinder 右键扩展",
                                    subtitle: "已关闭冲突的第三方 Finder 扩展",
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

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    var isWindowVisible: Bool {
        return window?.isVisible == true
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "BoFinder 设置 — Finder 右键复制路径与原生剪切增强"
        win.contentViewController = hostingController
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        self.window = win
    }
}
