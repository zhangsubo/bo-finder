import AppKit
import SwiftUI

struct GatewayView: View {
    @ObservedObject private var manager = GatewayManager.shared
    @ObservedObject private var envManager = EnvManager.shared

    @State private var selectedTab: Int = 0
    @State private var eventFilter: String = "all"
    @State private var searchQuery: String = ""

    @State private var newDomainInput: String = ""
    @State private var newAllowPathInput: String = ""
    @State private var upstreamProxyDraft: String = ""
    @State private var showAddCustomRuleSheet: Bool = false

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            if !manager.errorMessage.isEmpty {
                errorBanner
            }
            if manager.isDownloadingMitmproxy {
                downloadingBanner
            }

            Picker("安全网关分页", selection: $selectedTab) {
                Text("总览与开关").tag(0)
                Text("拦截与脱敏记录").tag(1)
                Text("策略与规则").tag(2)
                Text("接入与诊断").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch selectedTab {
                case 1:
                    eventsTab
                case 2:
                    ScrollView { policiesTab.padding(.bottom, 12) }
                case 3:
                    ScrollView { diagnosticsTab.padding(.bottom, 12) }
                default:
                    ScrollView { overviewTab.padding(.bottom, 12) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(26)
        .onAppear {
            upstreamProxyDraft = manager.config.upstreamProxyURL
            manager.refreshDashboard()
        }
        .sheet(isPresented: $manager.showMitmproxyConsentSheet, onDismiss: {
            manager.presentDeferredAgentRulesSheetIfNeeded()
        }) {
            MitmproxyConsentSheet(manager: manager)
        }
        .sheet(isPresented: $manager.showSurgeGuideSheet, onDismiss: {
            manager.presentDeferredAgentRulesSheetIfNeeded()
        }) {
            SurgeModuleGuideSheet(manager: manager)
        }
        .sheet(isPresented: $manager.showAgentRulesManualSheet) {
            AgentRulesManualWriteSheet(manager: manager)
        }
        .sheet(isPresented: $showAddCustomRuleSheet) {
            AddCustomPatternSheet { pattern in
                manager.updateConfig { cfg in
                    cfg.customPatterns.append(pattern)
                }
            }
        }
    }

    // MARK: - Header & Banners

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("安全网关")
                        .font(.system(size: 25, weight: .bold))
                    statusPill
                }
                Text("守护大模型对话与 GitHub 代码推送双出口，零明文落盘防密钥泄漏。")
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                if manager.isDaemonRunning {
                    Button {
                        manager.runDiagnosticSelfTest()
                    } label: {
                        Label("一键自检", systemImage: "stethoscope")
                    }
                    .disabled(manager.isBusy)
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { manager.prefs.isEnabled },
                        set: { manager.setGatewayEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(manager.isBusy || manager.isDownloadingMitmproxy)
                .accessibilityLabel("启用安全网关")
            }
        }
    }

    private var statusPill: some View {
        let active = manager.isDaemonRunning && manager.prefs.isEnabled
        return HStack(spacing: 5) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(active ? "守护中 · \(manager.prefs.selectedTier.shortBadge)" : "未开启")
                .font(.caption.weight(.medium))
                .foregroundColor(active ? .green : .secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background((active ? Color.green : Color.secondary).opacity(0.12))
        .clipShape(Capsule())
    }

    private var errorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(manager.errorMessage)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !manager.hasSurgeInstalled && manager.prefs.selectedTier != .builtinProxy {
                Button("改用内置代理") {
                    manager.errorMessage = ""
                    manager.confirmMitmproxyConsent(downloadAndIntegrate: false)
                }
                .controlSize(.small)
            }
            Button("关闭") {
                manager.errorMessage = ""
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
    }

    private var downloadingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(manager.downloadProgressText.isEmpty ? "正在准备组件…" : manager.downloadProgressText)
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10))
        .cornerRadius(8)
    }

    // MARK: - Tab 0: Overview & Master Switches

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroControlCard
            kpiGrid
            dualEgressCard
        }
    }

    private var heroControlCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(manager.isDaemonRunning ? Color.green.opacity(0.14) : Color.secondary.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: manager.isDaemonRunning ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(manager.isDaemonRunning ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(manager.isDaemonRunning ? "本地双出口安全网关已就绪" : "安全网关当前处于关闭状态")
                    .font(.headline)
                if let st = manager.daemonStatus, manager.isDaemonRunning {
                    Text("监听地址 \(st.listenAddr) · 守护进程 PID \(st.pid) · 接入层：\(manager.prefs.selectedTier.title)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("默认不改动任何系统代理或 Surge 配置。开启时将按「Surge → 开源 mitmproxy → 内置按需代理」自动引导接入。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if manager.prefs.isEnabled && manager.prefs.selectedTier == .surge {
                Button("Surge 模块指引") {
                    manager.showSurgeGuideSheet = true
                }
                .controlSize(.small)
            }

            Button(manager.prefs.isEnabled ? "停止网关" : "立即开启守护") {
                manager.setGatewayEnabled(!manager.prefs.isEnabled)
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.prefs.isEnabled ? .secondary : .accentColor)
            .disabled(manager.isBusy || manager.isDownloadingMitmproxy)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var kpiGrid: some View {
        let envSecretCount = envManager.entries.filter { $0.isEnabled && $0.kind == .secret }.count
        return HStack(spacing: 12) {
            statCard(
                title: "今日扫描请求",
                value: "\(manager.stats.scannedRequests + manager.stats.gitScans)",
                subtitle: "API \(manager.stats.scannedRequests) · Git \(manager.stats.gitScans)",
                symbol: "waveform.path.ecg",
                tint: .blue
            )
            statCard(
                title: "大模型无感脱敏",
                value: "\(manager.stats.maskedCount)",
                subtitle: "替换为占位符并流式还原",
                symbol: "eye.trianglebadge.exclamationmark",
                tint: .teal
            )
            statCard(
                title: "高危外泄拦截",
                value: "\(manager.stats.blockedCount)",
                subtitle: "Git 阻断 \(manager.stats.gitBlockedCount) 次",
                symbol: "hand.raised.fill",
                tint: .red
            )
            statCard(
                title: "联动环境变量密钥",
                value: "\(envSecretCount)",
                subtitle: manager.config.syncEnvSecrets ? "纯内存精确匹配已开启" : "联动已暂停",
                symbol: "key.fill",
                tint: .orange
            )
        }
    }

    private func statCard(title: String, value: String, subtitle: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .foregroundColor(tint)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var dualEgressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("双出口防护模式")
                .font(.headline)

            // Egress 1: LLM
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text("出口一：大模型对话与编程 Agent（Claude Code / Codex / Cursor 等）")
                        .fontWeight(.medium)
                    Text("默认将请求中的真实密钥替换为 <SECRET_1> 语义占位符发往云端，并在 SSE 流式返回时跨 Token 实时还原，既不泄漏真值也不打断 Agent 工具调用。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker(
                    "",
                    selection: Binding(
                        get: { manager.config.defaultLLMAction },
                        set: { action in
                            manager.updateConfig { $0.defaultLLMAction = action }
                        }
                    )
                ) {
                    Text("无感脱敏并还原 (推荐)").tag("mask")
                    Text("发现密钥直接阻断").tag("block")
                }
                .frame(width: 195)
            }

            Divider()

            // Egress 2: Git & GitHub
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.doc.on.clipboard")
                    .foregroundColor(.red)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("出口二：Git 提交推送与 GitHub API 上传")
                            .fontWeight(.medium)
                        Text("固定为严格阻断")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Text("扫描所有待推送的新增 Commit 历史与 GitHub Contents / Packfile 请求，命中密钥立即中止上传并保留仓库原有本地 Hook 链。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 20) {
                        Toggle(
                            "启用全局 Git pre-push / pre-commit 拦截钩子",
                            isOn: Binding(
                                get: { manager.prefs.gitGuardEnabled },
                                set: { manager.setGitGuardEnabled($0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.callout)

                        Toggle(
                            "Claude Code 自保护钩子 (阻止 --no-verify 绕过)",
                            isOn: Binding(
                                get: { manager.prefs.agentSelfProtectEnabled },
                                set: { manager.setAgentSelfProtectEnabled($0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    }
                    .padding(.top, 2)

                    Divider()
                        .padding(.vertical, 4)

                    agentRulesSyncRow
                }
                Spacer()
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var agentRulesSyncRow: some View {
        let targets = manager.agentRuleTargets
        let syncedCount = targets.filter(\.isSynced).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(
                    "启用时自动向全局 CLAUDE.md / AGENTS.md 追加提交前白名单预检规范（只追加不新建）",
                    isOn: Binding(
                        get: { manager.prefs.autoSyncAgentRulesMD },
                        set: { manager.setAutoSyncAgentRulesMD($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.callout)

                Spacer()

                Button("查看规范内容") {
                    manager.openAgentRulesSheet(missingPrompt: targets.isEmpty)
                }
                .controlSize(.small)

                if !targets.isEmpty {
                    Button(syncedCount == targets.count ? "重新同步" : "立即追加") {
                        manager.syncGlobalAgentInstructionFiles(promptIfMissing: true, showSuccessHUD: true)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)

                    if syncedCount > 0 {
                        Button("移除区块") {
                            manager.removeGlobalAgentInstructionBlock()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if targets.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("未检测到全局 CLAUDE.md 或 AGENTS.md（遵循「只追加不新建」原则未自动创建文件）。")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Button("手动写入指引…") {
                        manager.openAgentRulesSheet(missingPrompt: true)
                    }
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(targets) { target in
                        HStack(spacing: 4) {
                            Image(systemName: target.isSynced ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                                .foregroundColor(target.isSynced ? .green : .orange)
                                .font(.caption2)
                            Text(target.displayPath)
                                .font(.system(.caption2, design: .monospaced))
                            if !target.linkedDisplayPaths.isEmpty {
                                Text("+\(target.linkedDisplayPaths.count) 软链")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((target.isSynced ? Color.green : Color.orange).opacity(0.11))
                        .clipShape(Capsule())
                        .help(
                            target.linkedDisplayPaths.isEmpty
                                ? target.canonicalPath
                                : "关联软链：\(target.linkedDisplayPaths.joined(separator: ", "))"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Tab 1: Audit Events

    private var eventsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("筛选", selection: $eventFilter) {
                    Text("全部").tag("all")
                    Text("已脱敏").tag("masked")
                    Text("已阻断").tag("blocked")
                    Text("Git 钩子").tag("git")
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                TextField("搜索域名、规则名或位置…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)

                Button("刷新") {
                    manager.refreshDashboard()
                }

                Button("清空记录") {
                    manager.clearAuditEvents()
                }
                .disabled(manager.events.isEmpty)
            }

            if filteredEvents.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("暂无拦截或脱敏记录")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("所有审计日志严格遵循零明文原则，仅保存不可逆指纹与首尾掩码预览。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEvents) { ev in
                            eventRow(ev)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var filteredEvents: [GatewayAuditEvent] {
        manager.events.filter { ev in
            switch eventFilter {
            case "masked": if ev.action != "masked" { return false }
            case "blocked": if ev.action != "blocked" { return false }
            case "git": if ev.channel != "git" { return false }
            default: break
            }
            let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return ev.target.lowercased().contains(q)
                || ev.ruleName.lowercased().contains(q)
                || ev.client.lowercased().contains(q)
                || ev.location.lowercased().contains(q)
        }
    }

    private func eventRow(_ ev: GatewayAuditEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ev.isBlocked ? "hand.raised.circle.fill" : "checkmark.shield.fill")
                .font(.system(size: 18))
                .foregroundColor(ev.isBlocked ? .red : .teal)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(ev.actionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(ev.isBlocked ? .red : .teal)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((ev.isBlocked ? Color.red : Color.teal).opacity(0.12))
                        .clipShape(Capsule())

                    Text(ev.channelLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("\(ev.client) → \(ev.target)")
                        .font(.callout.weight(.medium))

                    if ev.count > 1 {
                        Text("×\(ev.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(Self.timeFormatter.string(from: ev.timestamp))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    Label(ev.ruleName, systemImage: "tag.fill")
                        .font(.caption)
                    Text("掩码预览：\(ev.maskedPreview)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    if !ev.location.isEmpty {
                        Text("位置：\(ev.location)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !ev.fingerprint.isEmpty && ev.channel != "self-test" {
                        Button("加入指纹白名单") {
                            manager.addFingerprintToAllowlist(from: ev)
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Tab 2: Policies, Domains, Custom Regex & Allowlist

    private var policiesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Rule groups
            VStack(alignment: .leading, spacing: 10) {
                Text("内置多层识别引擎")
                    .font(.headline)

                Toggle(
                    "实时联动「环境变量」面板中的密钥条目（Aho-Corasick 原文 / Base64 / URL 编码零误报精确匹配）",
                    isOn: Binding(
                        get: { manager.config.syncEnvSecrets },
                        set: { v in manager.updateConfig { $0.syncEnvSecrets = v } }
                    )
                )
                Divider()

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    Toggle("国内云厂商 AK 与飞书/企微/钉钉机器人密钥", isOn: ruleBinding(\.domesticCloudAndIM))
                    Toggle("海外云、OpenAI/Anthropic/Gemini 与 GitHub Token", isOn: ruleBinding(\.internationalCloudAndAI))
                    Toggle("SSH/PEM 私钥块、JWT 与 Authorization 认证头", isOn: ruleBinding(\.privateKeysAndAuth))
                    Toggle("数据库连接串凭据（保留主机端口仅脱敏密码）", isOn: ruleBinding(\.databaseURIs))
                    Toggle("上下文敏感变量赋值、CLI 参数与嵌套 Base64", isOn: ruleBinding(\.contextualAssignments))
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Protected domains
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("受保护目标域名")
                            .font(.headline)
                        Text("仅对列表内的大模型 API、中转站与 GitHub 域名执行扫描，其余日常流量完全直通。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("恢复默认域名") {
                        manager.updateConfig { $0.protectedDomains = GatewayConfig.defaultProtectedDomains }
                    }
                    .controlSize(.small)
                }

                FlowDomainListView(domains: manager.config.protectedDomains) { toRemove in
                    manager.updateConfig { cfg in
                        cfg.protectedDomains.removeAll { $0 == toRemove }
                    }
                }

                HStack(spacing: 8) {
                    TextField("添加自定义中转站或私有 Git 域名（如 api.my-llm-proxy.com）", text: $newDomainInput)
                        .textFieldStyle(.roundedBorder)
                    Button("添加域名") {
                        let cleaned = newDomainInput
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                            .replacingOccurrences(of: "https://", with: "")
                            .replacingOccurrences(of: "http://", with: "")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        guard !cleaned.isEmpty else { return }
                        manager.updateConfig { cfg in
                            if !cfg.protectedDomains.contains(cleaned) {
                                cfg.protectedDomains.append(cleaned)
                            }
                        }
                        newDomainInput = ""
                    }
                    .disabled(newDomainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Custom Regex Patterns
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自定义正则规则 (RE2 线性时间安全引擎)")
                            .font(.headline)
                        Text("用于匹配企业内部工号密钥、私有网关前缀等专属凭据格式。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        showAddCustomRuleSheet = true
                    } label: {
                        Label("新增规则…", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                if manager.config.customPatterns.isEmpty {
                    Text("暂未添加自定义正则规则。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.config.customPatterns) { item in
                        HStack {
                            Text(item.name)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                            Text(item.pattern)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                manager.updateConfig { cfg in
                                    cfg.customPatterns.removeAll { $0.id == item.id }
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Allowlist
            VStack(alignment: .leading, spacing: 10) {
                let pendingItems = GatewayAllowlistBatchParser.parseLines(newAllowPathInput)
                let misclassifiedCount = manager.config.allowlist.filter {
                    $0.kind == "path" && GatewayAllowlistBatchParser.isFingerprintValue($0.value)
                }.count

                HStack {
                    Text("豁免白名单（指纹与测试目录路径 · 支持每行一条批量添加）")
                        .font(.headline)
                    Spacer()
                    if misclassifiedCount > 0 {
                        Button("修正 \(misclassifiedCount) 条指纹类型") {
                            _ = manager.addAllowlistBatch(rawText: "")
                        }
                        .controlSize(.small)
                    }
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newAllowPathInput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 88, maxHeight: 132)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                        )

                    if newAllowPathInput.isEmpty {
                        Text("每行一条，支持批量粘贴：\nsha256:xxxxxxxxxxxx（自动识别为指纹豁免，可附 # 备注）\nTests/fixtures/（自动识别为测试路径豁免）")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.75))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            if newAllowPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                newAllowPathInput = clip
                            } else {
                                newAllowPathInput = newAllowPathInput.trimmingCharacters(in: .newlines) + "\n" + clip
                            }
                        }
                    } label: {
                        Label("粘贴剪贴板", systemImage: "arrow.up.doc.on.clipboard")
                    }
                    .controlSize(.small)

                    if !newAllowPathInput.isEmpty {
                        Button("清空输入") {
                            newAllowPathInput = ""
                        }
                        .controlSize(.small)
                    }

                    if !pendingItems.isEmpty {
                        let fpCnt = pendingItems.filter { $0.kind == "fingerprint" }.count
                        let pathCnt = pendingItems.count - fpCnt
                        Text("已解析 \(pendingItems.count) 条（指纹 \(fpCnt) / 路径 \(pathCnt)）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(pendingItems.isEmpty ? "批量添加豁免" : "批量添加豁免 (\(pendingItems.count) 条)") {
                        _ = manager.addAllowlistBatch(rawText: newAllowPathInput)
                        newAllowPathInput = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingItems.isEmpty && misclassifiedCount == 0)
                }

                if manager.config.allowlist.isEmpty {
                    Text("暂无白名单豁免项。支持在上方每行粘贴一条 sha256:... 指纹或路径批量添加，也可在「拦截与脱敏记录」中一键放行。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.config.allowlist) { entry in
                        HStack {
                            Text(entry.kind == "fingerprint" ? "指纹" : "路径")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    (entry.kind == "fingerprint" ? Color.accentColor : Color.secondary)
                                        .opacity(0.15)
                                )
                                .clipShape(Capsule())
                            Text(entry.value)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            if !entry.note.isEmpty {
                                Text("· \(entry.note)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                manager.removeAllowlistEntry(id: entry.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func ruleBinding(_ keyPath: WritableKeyPath<GatewayRuleGroups, Bool>) -> Binding<Bool> {
        Binding(
            get: { manager.config.ruleGroups[keyPath: keyPath] },
            set: { newVal in
                manager.updateConfig { cfg in
                    cfg.ruleGroups[keyPath: keyPath] = newVal
                }
            }
        )
    }

    // MARK: - Tab 3: Capture Tiers & Diagnostics

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 3-tier selector cards
            VStack(alignment: .leading, spacing: 12) {
                Text("三级渐进网络接入架构")
                    .font(.headline)
                Text("优先复用 Surge；未安装 Surge 时经您同意可集成开源 mitmproxy；若拒绝下载则回退至 DeskSide 内置按需代理。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(GatewayCaptureTier.allCases) { tier in
                    tierOptionCard(tier)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Upstream proxy & HUD notifications
            VStack(alignment: .leading, spacing: 10) {
                Text("网络链路与通知偏好")
                    .font(.headline)

                Toggle(
                    "拦截或无感脱敏时弹出桌面轻量 HUD 提示",
                    isOn: Binding(
                        get: { manager.prefs.showHUDNotifications },
                        set: { manager.setShowHUDNotifications($0) }
                    )
                )

                Divider()

                Text("上游代理转发地址（可选，仅在使用「内置按需代理」且本机需经过 Clash/V2Ray 访问海外 API 时填写）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("例如 http://127.0.0.1:7890（使用 Surge 时请留空）", text: $upstreamProxyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("保存上游代理") {
                        let cleaned = upstreamProxyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        manager.updateConfig { $0.upstreamProxyURL = cleaned }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Self-test diagnostic card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("端到端闭环自检")
                            .font(.headline)
                        Text("使用合成测试凭据验证「请求体识别脱敏 → BPE 分片 SSE 流式跨包还原 → 零明文审计」全链路。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        manager.runDiagnosticSelfTest()
                    } label: {
                        Label("运行闭环自检", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.isDaemonRunning || manager.isBusy)
                }

                if let st = manager.lastSelfTest {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: st.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundColor(st.passed ? .green : .red)
                            Text(st.message)
                                .font(.callout.weight(.medium))
                        }
                        Text("触发规则：\(st.ruleTriggered) · 脱敏后载荷：\(st.maskedPayload)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .background((st.passed ? Color.green : Color.red).opacity(0.09))
                    .cornerRadius(8)
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func tierOptionCard(_ tier: GatewayCaptureTier) -> some View {
        let selected = manager.prefs.selectedTier == tier
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: tier.symbolName)
                .font(.system(size: 20))
                .foregroundColor(selected ? .accentColor : .secondary)
                .frame(width: 26)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(tier.title)
                        .fontWeight(.semibold)
                    if selected {
                        Text("当前选中")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    tierAvailabilityBadge(tier)
                }
                Text(tier.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if tier == .surge && manager.hasSurgeInstalled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(manager.surgeModuleURLString)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(nsColor: .windowBackgroundColor))
                                .cornerRadius(5)

                            Button("复制模块 URL") {
                                manager.copySurgeModuleURL()
                            }
                            .controlSize(.small)

                            Button("一键唤起 Surge 安装") {
                                manager.installModuleInSurge()
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(!manager.isDaemonRunning)
                        }
                        if !manager.isDaemonRunning {
                            Text("提示：请先开启安全网关，再点击「一键唤起 Surge 安装」或在 Surge 中粘贴上方 URL 安装。")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 2)
                }

                if tier == .builtinProxy {
                    HStack(spacing: 10) {
                        Button(manager.isCACertTrusted ? "本地根证书已受信任 ✓" : "一键信任本地根证书 (钥匙串)…") {
                            manager.trustLocalRootCA()
                        }
                        .controlSize(.small)
                        .disabled(manager.isCACertTrusted)

                        if let fp = manager.daemonStatus?.caFingerprint, !fp.isEmpty {
                            Text("CA SHA-256: \(fp.prefix(16))…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()

            if !selected {
                Button("切换至此方案") {
                    manager.switchCaptureTier(tier)
                }
                .controlSize(.small)
                .disabled(tier == .surge && !manager.hasSurgeInstalled)
            }
        }
        .padding(12)
        .background(selected ? Color.accentColor.opacity(0.07) : Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func tierAvailabilityBadge(_ tier: GatewayCaptureTier) -> some View {
        switch tier {
        case .surge:
            Text(manager.hasSurgeInstalled ? "已检测到 Surge.app" : "本机未安装 Surge")
                .font(.caption2)
                .foregroundColor(manager.hasSurgeInstalled ? .green : .secondary)
        case .mitmproxy:
            Text(manager.detectedMitmproxyPath != nil ? "已就绪" : "需确认后下载集成")
                .font(.caption2)
                .foregroundColor(manager.detectedMitmproxyPath != nil ? .green : .orange)
        case .builtinProxy:
            Text("内置免下载可用")
                .font(.caption2)
                .foregroundColor(.green)
        }
    }
}

// MARK: - Supporting Views & Sheets

private struct FlowDomainListView: View {
    let domains: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], spacing: 6) {
            ForEach(domains, id: \.self) { dom in
                HStack(spacing: 6) {
                    Image(systemName: dom.contains("github") ? "chevron.left.forwardslash.chevron.right" : "globe")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(dom)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        onRemove(dom)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct MitmproxyConsentSheet: View {
    @ObservedObject var manager: GatewayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("未检测到 Surge · 选择透明流量接入方案")
                        .font(.title3.weight(.bold))
                    Text("安全网关需要拦截受保护域名的 HTTPS 请求以完成密钥脱敏与阻断。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("推荐方案（Tier 2）：下载并集成开源 mitmproxy 本地捕获", systemImage: "1.circle.fill")
                    .font(.headline)
                Text("• 采用 MIT 开源协议与 Apple Developer ID 官方公证签名组件，下载后自动校验代码签名。\n• 支持 macOS 进程级透明捕获，无需改动全局 Wi-Fi 代理配置。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Label("备选方案（Tier 3）：不下载外部工具，使用 DeskSide 内置按需代理", systemImage: "2.circle.fill")
                    .font(.headline)
                    .padding(.top, 4)
                Text("• 零外部依赖，通过本地 PAC 脚本仅将大模型与 GitHub 域名路由至本地守护端口，其余流量全部直连；退出时自动回滚。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("取消") {
                    manager.showMitmproxyConsentSheet = false
                }
                Spacer()
                Button("不同意下载，使用内置代理") {
                    manager.confirmMitmproxyConsent(downloadAndIntegrate: false)
                }
                Button("同意下载并集成 mitmproxy（推荐）") {
                    manager.confirmMitmproxyConsent(downloadAndIntegrate: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 540)
    }
}

private struct SurgeModuleGuideSheet: View {
    @ObservedObject var manager: GatewayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("已检测到 Surge · 安装透明守护模块")
                        .font(.title3.weight(.bold))
                    Text("Surge 5 通过本地 URL 安装模块，首次安装一次后即可随 DeskSide 自动联动。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("模块本地安装 URL（安全网关运行中自动提供）：")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Text(manager.surgeModuleURLString)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)

                    Button("复制 URL") {
                        manager.copySurgeModuleURL()
                    }
                }

                Text("安装步骤（二选一）：")
                    .font(.callout.weight(.medium))
                    .padding(.top, 4)
                Text("• 方式一（推荐）：点击下方「一键唤起 Surge 安装模块」，在弹出的 Surge 窗口确认安装并勾选。")
                    .font(.callout)
                Text("• 方式二（手动粘贴）：在 Surge「模块 → 安装新模块…」中粘贴上方 URL 完成安装并勾选。")
                    .font(.callout)
                Text("• 同时请确保 Surge 已开启「MITM」总开关。关闭 DeskSide 网关时脚本会自动切换为直通，不影响日常上网。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("关闭") {
                    manager.showSurgeGuideSheet = false
                }
                Button("在 Finder 查看本地文件") {
                    manager.revealSGModuleInFinder()
                }
                Spacer()
                Button("一键唤起 Surge 安装模块") {
                    manager.installModuleInSurge()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct AddCustomPatternSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var pattern: String = ""
    @State private var ignoreCase: Bool = false
    @State private var validationError: String = ""

    let onSave: (GatewayCustomPattern) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新增自定义密钥正则规则")
                .font(.title3.weight(.bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("规则标识名称（2-40 位大写字母、数字或下划线）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("例如 CORP_INTERNAL_AK", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("正则表达式（Go RE2 语法）")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField(#"例如 \bcorp_live_[A-Za-z0-9]{24,}\b"#, text: $pattern)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("忽略大小写匹配", isOn: $ignoreCase)

            if !validationError.isEmpty {
                Text(validationError)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存规则") {
                    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let cleanPat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard cleanName.range(of: #"^[A-Z0-9_]{2,40}$"#, options: .regularExpression) != nil else {
                        validationError = "规则名称须为 2-40 位大写英文、数字或下划线。"
                        return
                    }
                    guard !cleanPat.isEmpty, (try? NSRegularExpression(pattern: cleanPat)) != nil else {
                        validationError = "正则表达式语法无效，请检查后重试。"
                        return
                    }
                    onSave(GatewayCustomPattern(name: cleanName, pattern: cleanPat, ignoreCase: ignoreCase))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct AgentRulesManualWriteSheet: View {
    @ObservedObject var manager: GatewayManager
    @State private var copiedFeedback: Bool = false

    var body: some View {
        let isMissing = manager.agentRulesSheetIsMissingPrompt && manager.agentRuleTargets.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "doc.badge.gearshape.fill")
                    .font(.system(size: 24))
                    .foregroundColor(isMissing ? .orange : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMissing ? "未检测到全局 CLAUDE.md / AGENTS.md，请手动写入" : "全局 Agent 安全网关协作规范")
                        .font(.title3.weight(.bold))
                    Text(
                        isMissing
                            ? "已扫描 ~/.claude/、~/.codex/、~/.agent-rules/、~/.config/*/ 与 ~/ 等全局路径，按「只追加、不新建」原则未自动新建文件。"
                            : "当检测到已有全局 CLAUDE.md 或 AGENTS.md 时，安全网关会在文件末尾幂等追加以下协作规范（软链自动去重）。"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }

            if isMissing {
                Text("请手动创建或打开您常用的全局 Agent 规则文件（例如 `~/.claude/CLAUDE.md` 或 `~/.codex/AGENTS.md`），将下方规范粘贴保存：")
                    .font(.callout)
            } else if !manager.agentRuleTargets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前已检测到的全局规则文件：")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    ForEach(manager.agentRuleTargets) { target in
                        HStack(spacing: 6) {
                            Image(systemName: target.isSynced ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
                                .foregroundColor(target.isSynced ? .green : .orange)
                                .font(.caption)
                            Text(target.displayPath)
                                .font(.system(.caption, design: .monospaced))
                            if !target.linkedDisplayPaths.isEmpty {
                                Text("（软链覆盖：\(target.linkedDisplayPaths.joined(separator: ", "))）")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            ScrollView {
                Text(GatewayAgentRulesSyncer.renderManagedBlock())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 220)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            HStack(spacing: 10) {
                Button("关闭") {
                    manager.showAgentRulesManualSheet = false
                }

                Button("我已创建文件，重新检测并追加") {
                    let outcome = manager.syncGlobalAgentInstructionFiles(promptIfMissing: false, showSuccessHUD: true)
                    if outcome.foundAnyGlobalFile {
                        manager.agentRulesSheetIsMissingPrompt = false
                    }
                }

                Spacer()

                Button(copiedFeedback ? "已复制到剪贴板 ✓" : "一键复制写入内容") {
                    manager.copyAgentRulesMarkdownToClipboard()
                    copiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        copiedFeedback = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 620)
    }
}
