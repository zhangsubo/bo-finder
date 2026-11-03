import SwiftUI
import AppKit

struct EnvView: View {
    @ObservedObject private var manager = EnvManager.shared

    @State private var searchText: String = ""
    @State private var kindFilter: String = "all"
    @State private var groupFilter: String = "all"
    @State private var revealedSecretIDs: Set<UUID> = []

    @State private var showSettingsPage: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var showScriptPreviewSheet: Bool = false

    @State private var editorContext: EnvEditorContext?
    @State private var pendingDeleteEntry: EnvEntry?

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !manager.errorMessage.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(manager.errorMessage)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("关闭") {
                        manager.errorMessage = ""
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            if showSettingsPage {
                settingsSubpage
            } else {
                mainListPage
            }
        }
        .padding(26)
        .onAppear {
            manager.refreshRuntimeStatus()
        }
        .sheet(item: $editorContext) { ctx in
            EnvEditorSheet(context: ctx)
        }
        .sheet(isPresented: $showImportSheet) {
            EnvImportSheet()
        }
        .sheet(isPresented: $showScriptPreviewSheet) {
            EnvScriptPreviewSheet()
        }
        .alert(
            "确认删除该条目？",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            )
        ) {
            Button("取消", role: .cancel) {
                pendingDeleteEntry = nil
            }
            Button("删除并刷新", role: .destructive) {
                if let target = pendingDeleteEntry {
                    revealedSecretIDs.remove(target.id)
                    manager.deleteEntry(target.id)
                }
                pendingDeleteEntry = nil
            }
        } message: {
            if let target = pendingDeleteEntry {
                Text("删除「\(target.name)」后将立即更新托管配置，并在已联动的终端与系统环境中自动取消该项。")
            }
        }
    }

    // MARK: - Main Page

    private var mainListPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar
            mountStatusBanner
            filterToolbar
            contentList
            footerStatusRow
        }
    }

    private var headerBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("环境变量")
                    .font(.system(size: 25, weight: .bold))
                Text("可视化维护环境变量、密码密钥与终端快捷操作，保存后自动刷新生效。")
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    showImportSheet = true
                } label: {
                    Label("导入…", systemImage: "square.and.arrow.down")
                }

                Menu {
                    Button {
                        openNewEditor(kind: .variable)
                    } label: {
                        Label("新建环境变量 (export)", systemImage: "terminal")
                    }
                    Button {
                        openNewEditor(kind: .secret)
                    } label: {
                        Label("新建密码与密钥 (掩码保护)", systemImage: "key.fill")
                    }
                    Button {
                        openNewEditor(kind: .alias)
                    } label: {
                        Label("新建快捷别名 (alias)", systemImage: "bolt.fill")
                    }
                    Divider()
                    ForEach(EnvPresetTemplate.all) { tpl in
                        Button {
                            manager.applyTemplate(tpl)
                        } label: {
                            Label(tpl.title, systemImage: tpl.symbolName)
                        }
                    }
                } label: {
                    Label("常用模板", systemImage: "sparkles")
                }

                Button {
                    showSettingsPage = true
                } label: {
                    Label("同步设置", systemImage: "gearshape")
                }

                Button {
                    let defaultKind: EnvEntryKind
                    switch kindFilter {
                    case EnvEntryKind.secret.rawValue: defaultKind = .secret
                    case EnvEntryKind.alias.rawValue: defaultKind = .alias
                    default: defaultKind = .variable
                    }
                    openNewEditor(kind: defaultKind)
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var mountStatusBanner: some View {
        if !manager.isZshrcMounted {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("尚未挂载到 ~/.zshrc 自动加载")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("挂载后将在 ~/.zshrc 末尾写入轻量加载钩子（首次会自动备份原文件），保存修改即可在终端无感自动刷新。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button("一键接入 ~/.zshrc") {
                    manager.mountToZshrc(showHUD: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.orange.opacity(0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(8)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                let enabledCount = manager.entries.filter(\.isEnabled).count
                Text("已接入 ~/.zshrc · 启用 \(enabledCount)/\(manager.entries.count) 项")
                    .font(.callout)
                    .fontWeight(.medium)

                if manager.activeShellCount > 0 {
                    Text("· 已实时联动 \(manager.activeShellCount) 个活动终端")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(4)
                } else {
                    Text("· 新终端自动生效")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("复制旧终端激活命令") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("source ~/.zshrc", forType: .string)
                        HUDWindowController.shared.show(
                            title: "已复制 source ~/.zshrc",
                            subtitle: "接入前已打开的旧终端执行一次后即可自动实时刷新",
                            symbolName: "terminal"
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("首次挂载前已经打开的终端窗口执行一次 source ~/.zshrc 后，后续所有保存都会自动实时刷新。")
                }

                Spacer()

                if let synced = manager.lastSyncedAt {
                    Text("上次同步 \(Self.timeFormatter.string(from: synced))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("预览脚本") {
                    showScriptPreviewSheet = true
                }
                .controlSize(.small)

                Button {
                    manager.triggerManualRefresh(showHUD: true)
                } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.07))
            .cornerRadius(8)
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            let varCount = manager.entries.filter { $0.kind == .variable }.count
            let secretCount = manager.entries.filter { $0.kind == .secret }.count
            let aliasCount = manager.entries.filter { $0.kind == .alias }.count

            Picker("类型筛选", selection: $kindFilter) {
                Text("全部 (\(manager.entries.count))").tag("all")
                Text("环境变量 (\(varCount))").tag(EnvEntryKind.variable.rawValue)
                Text("密码密钥 (\(secretCount))").tag(EnvEntryKind.secret.rawValue)
                Text("快捷别名 (\(aliasCount))").tag(EnvEntryKind.alias.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            let dynamicGroups = availableFilterGroups
            if dynamicGroups.count > 1 {
                Picker("分组", selection: $groupFilter) {
                    Text("全部分组").tag("all")
                    ForEach(dynamicGroups, id: \.self) { g in
                        Text(g).tag(g)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索名称、分组或备注…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var contentList: some View {
        if manager.entries.isEmpty {
            emptyStateView
        } else if filteredEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("没有找到匹配的环境变量或快捷操作")
                    .font(.headline)
                Button("清除筛选条件") {
                    kindFilter = "all"
                    groupFilter = "all"
                    searchText = ""
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredEntries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.radiowaves.forward")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.accentColor)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 18))

            Text("可视化维护环境变量、密码与快捷命令")
                .font(.title3)
                .fontWeight(.semibold)

            Text("将分散在配置文件里的 API Key、密码、代理开关与常用 alias 统一收纳，\n支持密码掩码防窥与可选钥匙串保护，保存后自动在所有终端与桌面生效。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button {
                    openNewEditor(kind: .secret)
                } label: {
                    Label("添加密码 / API Key", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openNewEditor(kind: .alias)
                } label: {
                    Label("添加快捷别名 (alias)", systemImage: "bolt.fill")
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label("从 ~/.zshrc 导入", systemImage: "square.and.arrow.down")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func entryRow(_ entry: EnvEntry) -> some View {
        let isRevealed = revealedSecretIDs.contains(entry.id)
        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { newVal in
                    manager.setEntryEnabled(entry.id, enabled: newVal)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(entry.isEnabled ? "点击暂停该条目并自动在终端取消生效" : "点击启用该条目并自动在终端生效")

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    kindBadge(for: entry.kind)

                    Text(entry.name)
                        .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(entry.isEnabled ? .primary : .secondary)

                    if entry.kind == .secret && entry.useKeychain {
                        HStack(spacing: 3) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 9))
                            Text("钥匙串")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                    }

                    if entry.kind == .variable && entry.allowExpansion {
                        Text("$展开")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .cornerRadius(4)
                    }

                    Text(entry.group)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)

                    if !entry.isEnabled {
                        Text("已停用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    if !entry.note.isEmpty {
                        Text("· \(entry.note)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                valuePreviewView(for: entry, isRevealed: isRevealed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(entry.isEnabled ? 1.0 : 0.62)

            HStack(spacing: 4) {
                if entry.kind == .secret {
                    Button {
                        if isRevealed {
                            revealedSecretIDs.remove(entry.id)
                        } else {
                            revealedSecretIDs.insert(entry.id)
                        }
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(isRevealed ? "隐藏明文" : "显示密码明文")
                }

                Button {
                    manager.copyEntryValue(entry)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(entry.kind == .alias ? "复制命令内容" : "一键复制值")

                Button {
                    manager.copyEntryShellCommand(entry)
                } label: {
                    Image(systemName: "terminal")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(entry.kind == .alias ? "复制完整 alias 语句" : "复制完整 export 语句")

                Button {
                    editorContext = EnvEditorContext(
                        existingEntry: entry,
                        initialKind: entry.kind,
                        initialRawValue: manager.resolvedValue(for: entry)
                    )
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("编辑")

                Button {
                    pendingDeleteEntry = entry
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("删除")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    @ViewBuilder
    private func kindBadge(for kind: EnvEntryKind) -> some View {
        let color: Color = {
            switch kind {
            case .variable: return .accentColor
            case .secret: return .orange
            case .alias: return .teal
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(kind.shortTitle)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.13))
        .cornerRadius(4)
    }

    @ViewBuilder
    private func valuePreviewView(for entry: EnvEntry, isRevealed: Bool) -> some View {
        switch entry.kind {
        case .secret:
            if isRevealed {
                let plain = manager.resolvedValue(for: entry)
                Text(plain.isEmpty ? "(空密钥)" : plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text("••••••••••••••••")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

        case .alias:
            Text("alias \(entry.name)=\(EnvShellRenderer.singleQuote(entry.value))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

        case .variable:
            let display = entry.value.isEmpty ? "(空值)" : entry.value
            Text(display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footerStatusRow: some View {
        HStack {
            Text(manager.statusMessage.isEmpty ? "托管路径：~/.config/deskside/env.zsh（权限 0600 仅当前账号可读写）" : manager.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            if !revealedSecretIDs.isEmpty {
                Button("隐藏全部已展开密码") {
                    revealedSecretIDs.removeAll()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    // MARK: - Settings Subpage

    private var settingsSubpage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("环境变量同步设置")
                            .font(.title2.bold())
                        Text("管理 ~/.zshrc 自动刷新钩子、桌面应用同步与托管文件。")
                            .foregroundColor(.secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button("返回列表") {
                        showSettingsPage = false
                    }
                }

                GroupBox(label: Label("Shell 自动加载与实时刷新 (~/.zshrc)", systemImage: "terminal")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: manager.isZshrcMounted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundColor(manager.isZshrcMounted ? .green : .orange)
                            Text(manager.isZshrcMounted ? "当前已挂载到 ~/.zshrc" : "当前未挂载到 ~/.zshrc")
                                .fontWeight(.semibold)
                            Spacer()
                            if manager.isZshrcMounted {
                                Button("从 ~/.zshrc 移除挂载") {
                                    manager.unmountFromZshrc(showHUD: true)
                                }
                                .controlSize(.small)
                            } else {
                                Button("一键挂载到 ~/.zshrc") {
                                    manager.mountToZshrc(showHUD: true)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        Toggle("新增或修改条目时自动确保 ~/.zshrc 处于挂载状态", isOn: Binding(
                            get: { manager.settings.autoMountZshrc },
                            set: { val in manager.updateSettings { $0.autoMountZshrc = val } }
                        ))

                        Text("• 托管脚本独立保存在 ~/.config/deskside/env.zsh（权限 0600），绝不混入或破坏原有 ~/.zshrc 的复杂配置。\n• 首次挂载前若 ~/.zshrc 已存在，会自动备份到 ~/.zshrc.deskside-backup。\n• 保存更改后，DeskSide 会通过轻量信号与时间戳钩子通知所有已打开的交互式 zsh 终端立即刷新（包含取消已停用/已删除的变量和别名）。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("在 Finder 中查看托管目录") {
                                let dir = manager.shellConfigDirectoryURL
                                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                                NSWorkspace.shared.activateFileViewerSelecting([manager.envZshURL])
                            }
                            .controlSize(.small)

                            Button("预览生成的 env.zsh 脚本") {
                                showScriptPreviewSheet = true
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(label: Label("桌面图形应用同步与提示反馈", systemImage: "macwindow")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("同步环境变量到 macOS 图形应用会话 (launchctl setenv)", isOn: Binding(
                            get: { manager.settings.syncLaunchctl },
                            set: { val in manager.updateSettings { $0.syncLaunchctl = val } }
                        ))
                        .fontWeight(.medium)

                        Text("开启后，不经过终端直接从 Dock / Spotlight 启动的桌面应用（如 IDE、客户端工具）也能读取你启用的环境变量；DeskSide 每次开机启动时会自动恢复同步。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("保存与自动刷新时显示屏幕悬浮提示 (HUD)", isOn: Binding(
                            get: { manager.settings.showHUDOnRefresh },
                            set: { val in manager.updateSettings { $0.showHUDOnRefresh = val } }
                        ))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Helpers

    private var availableFilterGroups: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in manager.entries {
            if !seen.contains(entry.group) {
                seen.insert(entry.group)
                out.append(entry.group)
            }
        }
        return out
    }

    private var filteredEntries: [EnvEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return manager.entries.filter { entry in
            if kindFilter != "all" && entry.kind.rawValue != kindFilter {
                return false
            }
            if groupFilter != "all" && entry.group != groupFilter {
                return false
            }
            if !query.isEmpty {
                let matchesName = entry.name.localizedCaseInsensitiveContains(query)
                let matchesGroup = entry.group.localizedCaseInsensitiveContains(query)
                let matchesNote = entry.note.localizedCaseInsensitiveContains(query)
                let matchesNonSecretVal = entry.kind != .secret && entry.value.localizedCaseInsensitiveContains(query)
                return matchesName || matchesGroup || matchesNote || matchesNonSecretVal
            }
            return true
        }
    }

    private func openNewEditor(kind: EnvEntryKind) {
        editorContext = EnvEditorContext(existingEntry: nil, initialKind: kind, initialRawValue: "")
    }
}

// MARK: - Add / Edit Sheet

struct EnvEditorContext: Identifiable {
    let id = UUID()
    let existingEntry: EnvEntry?
    let initialKind: EnvEntryKind
    let initialRawValue: String
}

private struct EnvEditorSheet: View {
    let context: EnvEditorContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = EnvManager.shared

    @State private var kind: EnvEntryKind
    @State private var name: String
    @State private var rawValue: String
    @State private var group: String
    @State private var note: String
    @State private var isEnabled: Bool
    @State private var useKeychain: Bool
    @State private var allowExpansion: Bool
    @State private var syncToGUI: Bool
    @State private var revealSecretInput: Bool = false
    @State private var saveError: String = ""
    @State private var groupWasCustomized: Bool

    init(context: EnvEditorContext) {
        self.context = context
        if let entry = context.existingEntry {
            _kind = State(initialValue: entry.kind)
            _name = State(initialValue: entry.name)
            _rawValue = State(initialValue: context.initialRawValue)
            _group = State(initialValue: entry.group)
            _note = State(initialValue: entry.note)
            _isEnabled = State(initialValue: entry.isEnabled)
            _useKeychain = State(initialValue: entry.useKeychain)
            _allowExpansion = State(initialValue: entry.allowExpansion)
            _syncToGUI = State(initialValue: entry.syncToGUI)
            _groupWasCustomized = State(initialValue: true)
        } else {
            let initialKind = context.initialKind
            _kind = State(initialValue: initialKind)
            _name = State(initialValue: "")
            _rawValue = State(initialValue: "")
            _group = State(initialValue: initialKind == .alias ? "终端快捷" : (initialKind == .secret ? "云服务与密钥" : "默认"))
            _note = State(initialValue: "")
            _isEnabled = State(initialValue: true)
            _useKeychain = State(initialValue: false)
            _allowExpansion = State(initialValue: false)
            _syncToGUI = State(initialValue: initialKind != .alias)
            _groupWasCustomized = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(context.existingEntry == nil ? "新增环境变量 / 快捷操作" : "编辑「\(context.existingEntry?.name ?? "")」")
                    .font(.title3.bold())
                Spacer()
            }

            Picker("类型", selection: $kind) {
                ForEach(EnvEntryKind.allCases) { k in
                    Text(k.title).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { _, newKind in
                saveError = ""
                if !groupWasCustomized {
                    group = EnvValidation.inferGroup(name: name, kind: newKind)
                }
                if newKind == .alias {
                    syncToGUI = false
                    useKeychain = false
                    allowExpansion = false
                } else if newKind == .secret {
                    allowExpansion = false
                } else {
                    useKeychain = false
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kind == .alias ? "别名名称" : "变量名称")
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer()
                    if kind == .variable && EnvValidation.isLikelySecretName(name) {
                        Button("检测到密钥命名，切换为「密码与密钥」") {
                            kind = .secret
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                TextField(namePlaceholder, text: $name)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, newVal in
                        saveError = ""
                        if !groupWasCustomized && !newVal.isEmpty {
                            group = EnvValidation.inferGroup(name: newVal, kind: kind)
                        }
                    }

                if !name.isEmpty, let msg = EnvValidation.validateName(name, kind: kind) {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kind == .alias ? "执行的终端命令" : (kind == .secret ? "密码 / 密钥内容" : "变量值"))
                        .font(.callout)
                        .fontWeight(.medium)
                    Spacer()
                    if kind == .secret {
                        Button(revealSecretInput ? "隐藏明文" : "显示明文") {
                            revealSecretInput.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                    Button("从剪贴板粘贴") {
                        if let str = NSPasteboard.general.string(forType: .string) {
                            rawValue = str.trimmingCharacters(in: .newlines)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                if kind == .secret && !revealSecretInput {
                    SecureField("输入密码、Token 或 API Key…", text: $rawValue)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(valuePlaceholder, text: $rawValue, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.system(size: 13, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("分组标签")
                        .font(.callout)
                        .fontWeight(.medium)
                    HStack(spacing: 6) {
                        TextField("默认", text: $group)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: group) { _, _ in groupWasCustomized = true }
                        Menu {
                            ForEach(manager.allGroups(), id: \.self) { preset in
                                Button(preset) {
                                    group = preset
                                    groupWasCustomized = true
                                }
                            }
                        } label: {
                            Image(systemName: "tag")
                        }
                        .frame(width: 32)
                        .help("选择常用分组")
                    }
                }
                .frame(width: 210)

                VStack(alignment: .leading, spacing: 6) {
                    Text("备注说明（可选）")
                        .font(.callout)
                        .fontWeight(.medium)
                    TextField("例如：OpenAI 主账号密钥 / 开启本地 Clash 代理", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用该条目（关闭后将保留记录并在终端取消生效）", isOn: $isEnabled)

                    if kind == .secret {
                        Divider()
                        Toggle("存入 macOS 系统钥匙串（Keychain，可选）", isOn: $useKeychain)
                        Text("默认关闭：保存在权限 0600 的私有托管文件中，零耗时且支持 SSH。开启后：通过系统 /usr/bin/security 免弹窗通道读写，配置文件不留明文。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if kind == .variable {
                        Divider()
                        Toggle("允许展开引用的其他变量（如 $HOME、$PATH、~/）", isOn: $allowExpansion)
                    }

                    if kind != .alias {
                        Divider()
                        Toggle("同时同步给桌面图形应用 (launchctl setenv)", isOn: $syncToGUI)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("生成语句预览：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(statementPreview)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
            }

            if !saveError.isEmpty {
                Text(saveError)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存并自动刷新") {
                    commitSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 550)
    }

    private var namePlaceholder: String {
        switch kind {
        case .variable: return "例如 HTTPS_PROXY 或 JAVA_HOME"
        case .secret: return "例如 OPENAI_API_KEY 或 DB_PASSWORD"
        case .alias: return "例如 ll、gst 或 proxy"
        }
    }

    private var valuePlaceholder: String {
        switch kind {
        case .variable: return "例如 http://127.0.0.1:7890"
        case .secret: return "输入密码或密钥内容…"
        case .alias: return "例如 git status -sb"
        }
    }

    private var statementPreview: String {
        let previewName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "EXAMPLE_NAME" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = EnvEntry(
            id: context.existingEntry?.id ?? UUID(),
            kind: kind,
            name: previewName,
            value: rawValue,
            note: note,
            group: group,
            isEnabled: isEnabled,
            useKeychain: useKeychain,
            allowExpansion: allowExpansion,
            syncToGUI: syncToGUI
        )
        return EnvShellRenderer.renderEntryCommand(
            draft,
            resolvedValue: rawValue,
            maskSecret: kind == .secret && !revealSecretInput && !useKeychain
        )
    }

    private func commitSave() {
        let draft = EnvEntry(
            id: context.existingEntry?.id ?? UUID(),
            kind: kind,
            name: name,
            value: rawValue,
            note: note,
            group: group,
            isEnabled: isEnabled,
            useKeychain: useKeychain,
            allowExpansion: allowExpansion,
            syncToGUI: syncToGUI
        )
        switch manager.saveEntry(draft, rawValue: rawValue) {
        case .success:
            dismiss()
        case .failure(let err):
            saveError = err.localizedDescription
        }
    }
}

// MARK: - Import Sheet

private struct EnvImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = EnvManager.shared

    @State private var currentFileURL: URL?
    @State private var candidates: [EnvImportedCandidate] = []
    @State private var overwriteExisting: Bool = false
    @State private var scanError: String = ""

    private var presetFiles: [(String, URL)] {
        let home = URL(fileURLWithPath: manager.homeDirectory, isDirectory: true)
        return [
            ("~/.zshrc", home.appendingPathComponent(".zshrc")),
            ("~/.zshenv", home.appendingPathComponent(".zshenv")),
            ("~/.zprofile", home.appendingPathComponent(".zprofile")),
            ("~/.bash_profile", home.appendingPathComponent(".bash_profile"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从现有配置文件导入")
                        .font(.title3.bold())
                    Text("自动识别 export 变量、疑似密码密钥与 alias 快捷别名（不会修改原配置文件中的已有行）。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(presetFiles, id: \.0) { label, url in
                    let isSelected = currentFileURL?.standardizedFileURL == url.standardizedFileURL
                    Button(label) {
                        loadFromURL(url)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? .accentColor : nil)
                    .controlSize(.small)
                }

                Spacer()

                Button("选择其他 .env / 脚本文件…") {
                    pickCustomFile()
                }
                .controlSize(.small)
            }

            if !scanError.isEmpty {
                Text(scanError)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if candidates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(currentFileURL == nil ? "请选择要扫描的配置文件" : "未在该文件中扫描到可导入的 export 或 alias 条目")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            } else {
                HStack {
                    Text("共发现 \(candidates.count) 项，已勾选 \(selectedCount) 项（点击类型标签可切换「变量 / 密钥」）：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("全选") {
                        for idx in candidates.indices where !candidates[idx].isPathVariable {
                            candidates[idx].selected = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)

                    Button("全不选") {
                        for idx in candidates.indices {
                            candidates[idx].selected = false
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach($candidates) { $item in
                            HStack(spacing: 10) {
                                Toggle("", isOn: $item.selected)
                                    .labelsHidden()

                                Button {
                                    if item.entry.kind == .variable {
                                        item.entry.kind = .secret
                                        item.entry.allowExpansion = false
                                    } else if item.entry.kind == .secret {
                                        item.entry.kind = .variable
                                    }
                                } label: {
                                    Text(item.entry.kind.shortTitle)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(item.entry.kind == .secret ? .orange : (item.entry.kind == .alias ? .teal : .accentColor))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background((item.entry.kind == .secret ? Color.orange : (item.entry.kind == .alias ? Color.teal : Color.accentColor)).opacity(0.14))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .disabled(item.entry.kind == .alias)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(item.entry.name)
                                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                        Text("第 \(item.sourceLineNumber) 行")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if item.isAlreadyManaged {
                                            Text("DeskSide 中已存在")
                                                .font(.system(size: 10))
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.12))
                                                .cornerRadius(3)
                                        }
                                        if item.isPathVariable {
                                            Text("PATH 建议保留在原文件（防重复叠加）")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Text(item.entry.kind == .secret ? "••••••••••••" : item.entry.value)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 260, maxHeight: 340)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

                Toggle("若 DeskSide 中已存在同名条目，用导入值覆盖现有条目", isOn: $overwriteExisting)
                    .font(.caption)
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("导入所选 (\(selectedCount) 项) 并自动刷新") {
                    manager.importCandidates(candidates, overwriteExisting: overwriteExisting)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear {
            if let first = presetFiles.first?.1 {
                loadFromURL(first)
            }
        }
    }

    private var selectedCount: Int {
        candidates.filter(\.selected).count
    }

    private func loadFromURL(_ url: URL) {
        currentFileURL = url
        scanError = ""
        guard FileManager.default.fileExists(atPath: url.path) else {
            candidates = []
            scanError = "文件不存在：\(url.path)"
            return
        }
        do {
            candidates = try manager.scanConfigFile(at: url)
        } catch {
            candidates = []
            scanError = "扫描失败：\(error.localizedDescription)"
        }
    }

    private func pickCustomFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: manager.homeDirectory, isDirectory: true)
        panel.prompt = "扫描此文件"
        if panel.runModal() == .OK, let url = panel.url {
            loadFromURL(url)
        }
    }
}

// MARK: - Script Preview Sheet

private struct EnvScriptPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = EnvManager.shared
    @State private var showPlainSecrets: Bool = false

    var body: some View {
        let scriptText = manager.renderedEnvScriptPreview(maskSecrets: !showPlainSecrets)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("托管脚本预览 (~/.config/deskside/env.zsh)")
                        .font(.title3.bold())
                    Text("文件权限 0600，仅当前系统用户可读写。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("显示明文密钥", isOn: $showPlainSecrets)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            ScrollView {
                Text(scriptText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 300, maxHeight: 400)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)

            HStack {
                Button("复制脚本内容") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(scriptText, forType: .string)
                    HUDWindowController.shared.show(
                        title: "已复制脚本内容",
                        subtitle: showPlainSecrets ? "包含明文配置" : "敏感项已做掩码脱敏",
                        symbolName: "doc.on.clipboard"
                    )
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
