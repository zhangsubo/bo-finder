import Cocoa
import Foundation

enum GatewayCaptureTier: String, Codable, CaseIterable, Identifiable {
    case surge = "surge"
    case mitmproxy = "mitmproxy"
    case builtinProxy = "builtinProxy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .surge:
            return "Tier 1 · Surge 模块透明接入"
        case .mitmproxy:
            return "Tier 2 · 开源 mitmproxy 本地捕获"
        case .builtinProxy:
            return "Tier 3 · 内置按需代理 (PAC + 本地 CA)"
        }
    }

    var shortBadge: String {
        switch self {
        case .surge: return "Surge 联动"
        case .mitmproxy: return "mitmproxy 捕获"
        case .builtinProxy: return "内置代理"
        }
    }

    var subtitle: String {
        switch self {
        case .surge:
            return "复用本机已安装的 Surge CA 与进程级分流，零系统代理改动，原生支持 SSE 流式响应。"
        case .mitmproxy:
            return "未检测到 Surge 时的推荐方案：使用 Apple 公证签名的开源 mitmproxy 本地模式透明捕获。"
        case .builtinProxy:
            return "无需额外下载：仅对受保护的 AI 与 GitHub 域名按需启用 PAC 路由与本地 0600 根证书，其余流量直连。"
        }
    }

    var symbolName: String {
        switch self {
        case .surge: return "bolt.shield.fill"
        case .mitmproxy: return "network.badge.shield.half.filled"
        case .builtinProxy: return "lock.shield.fill"
        }
    }
}

enum GatewayTierDecision: Equatable {
    case resolved(GatewayCaptureTier)
    case promptMitmproxyConsent
}

enum GatewayTierResolver {
    /// Enforces the strict 3-tier fallback order:
    /// 1. Surge installed -> `.surge`
    /// 2. No Surge -> if `mitmproxy` already present use `.mitmproxy`; else ask user consent (`nil` -> prompt, `true` -> `.mitmproxy`, `false` -> `.builtinProxy`).
    static func decide(
        hasSurge: Bool,
        hasExistingMitmproxy: Bool,
        userConsentedMitmproxyDownload: Bool?
    ) -> GatewayTierDecision {
        if hasSurge {
            return .resolved(.surge)
        }
        if hasExistingMitmproxy {
            return .resolved(.mitmproxy)
        }
        guard let consent = userConsentedMitmproxyDownload else {
            return .promptMitmproxyConsent
        }
        return consent ? .resolved(.mitmproxy) : .resolved(.builtinProxy)
    }
}

struct GatewayNetworkServiceProxySnapshot: Codable, Equatable {
    var serviceName: String
    var autoProxyURL: String
    var autoProxyEnabled: Bool
}

struct GatewayLocalPreferences: Codable, Equatable {
    var isEnabled: Bool = false
    var selectedTier: GatewayCaptureTier = .surge
    var hasCompletedOnboarding: Bool = false
    var gitGuardEnabled: Bool = true
    var agentSelfProtectEnabled: Bool = false
    var autoSyncAgentRulesMD: Bool = true
    var showHUDNotifications: Bool = true
    var previousGitHooksPath: String? = nil
    var didOverrideGitHooksPath: Bool = false
    var savedProxySnapshots: [GatewayNetworkServiceProxySnapshot] = []
    var mitmproxyBinaryPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case selectedTier
        case hasCompletedOnboarding
        case gitGuardEnabled
        case agentSelfProtectEnabled
        case autoSyncAgentRulesMD
        case showHUDNotifications
        case previousGitHooksPath
        case didOverrideGitHooksPath
        case savedProxySnapshots
        case mitmproxyBinaryPath
    }

    init(
        isEnabled: Bool = false,
        selectedTier: GatewayCaptureTier = .surge,
        hasCompletedOnboarding: Bool = false,
        gitGuardEnabled: Bool = true,
        agentSelfProtectEnabled: Bool = false,
        autoSyncAgentRulesMD: Bool = true,
        showHUDNotifications: Bool = true,
        previousGitHooksPath: String? = nil,
        didOverrideGitHooksPath: Bool = false,
        savedProxySnapshots: [GatewayNetworkServiceProxySnapshot] = [],
        mitmproxyBinaryPath: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.selectedTier = selectedTier
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.gitGuardEnabled = gitGuardEnabled
        self.agentSelfProtectEnabled = agentSelfProtectEnabled
        self.autoSyncAgentRulesMD = autoSyncAgentRulesMD
        self.showHUDNotifications = showHUDNotifications
        self.previousGitHooksPath = previousGitHooksPath
        self.didOverrideGitHooksPath = didOverrideGitHooksPath
        self.savedProxySnapshots = savedProxySnapshots
        self.mitmproxyBinaryPath = mitmproxyBinaryPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.selectedTier = try c.decodeIfPresent(GatewayCaptureTier.self, forKey: .selectedTier) ?? .surge
        self.hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        self.gitGuardEnabled = try c.decodeIfPresent(Bool.self, forKey: .gitGuardEnabled) ?? true
        self.agentSelfProtectEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentSelfProtectEnabled) ?? false
        self.autoSyncAgentRulesMD = try c.decodeIfPresent(Bool.self, forKey: .autoSyncAgentRulesMD) ?? true
        self.showHUDNotifications = try c.decodeIfPresent(Bool.self, forKey: .showHUDNotifications) ?? true
        self.previousGitHooksPath = try c.decodeIfPresent(String.self, forKey: .previousGitHooksPath)
        self.didOverrideGitHooksPath = try c.decodeIfPresent(Bool.self, forKey: .didOverrideGitHooksPath) ?? false
        self.savedProxySnapshots = try c.decodeIfPresent([GatewayNetworkServiceProxySnapshot].self, forKey: .savedProxySnapshots) ?? []
        self.mitmproxyBinaryPath = try c.decodeIfPresent(String.self, forKey: .mitmproxyBinaryPath)
    }
}

// MARK: - GuardEngine JSON Wire Models

struct GatewayRuleGroups: Codable, Equatable {
    var knownEnvSecrets: Bool = true
    var domesticCloudAndIM: Bool = true
    var internationalCloudAndAI: Bool = true
    var privateKeysAndAuth: Bool = true
    var databaseURIs: Bool = true
    var contextualAssignments: Bool = true
}

struct GatewayCustomPattern: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var pattern: String
    var ignoreCase: Bool
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        pattern: String,
        ignoreCase: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.ignoreCase = ignoreCase
        self.enabled = enabled
    }
}

struct GatewayAllowlistEntry: Codable, Equatable, Identifiable {
    var id: String
    var kind: String // "fingerprint" | "path"
    var value: String
    var note: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        kind: String,
        value: String,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.note = note
        self.createdAt = createdAt
    }
}

enum GatewayAllowlistBatchParser {
    private static let fingerprintRegex = try! NSRegularExpression(
        pattern: #"^sha256:[0-9a-fA-F]{8,64}$"#,
        options: [.caseInsensitive]
    )

    static func isFingerprintValue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return fingerprintRegex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    static func parseLines(_ rawText: String) -> [(kind: String, value: String, note: String)] {
        var results: [(kind: String, value: String, note: String)] = []
        var seen = Set<String>()

        for rawLine in rawText.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }

            var valuePart = trimmed
            var customNote = ""
            if let hashRange = trimmed.range(of: " #") {
                valuePart = String(trimmed[..<hashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                customNote = String(trimmed[hashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let slashRange = trimmed.range(of: " //") {
                valuePart = String(trimmed[..<slashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                customNote = String(trimmed[slashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            }

            guard !valuePart.isEmpty else { continue }

            let kind: String
            let normalizedValue: String
            let note: String
            if isFingerprintValue(valuePart) {
                kind = "fingerprint"
                normalizedValue = valuePart.lowercased()
                note = customNote.isEmpty ? "指纹豁免" : customNote
            } else {
                kind = "path"
                normalizedValue = valuePart
                note = customNote.isEmpty ? "测试路径豁免" : customNote
            }

            let dedupeKey = "\(kind):\(normalizedValue)"
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            results.append((kind: kind, value: normalizedValue, note: note))
        }

        return results
    }

    @discardableResult
    static func mergeIntoAllowlist(
        _ existing: inout [GatewayAllowlistEntry],
        rawText: String,
        now: Date = Date()
    ) -> (added: Int, repaired: Int, skippedDuplicates: Int) {
        var repaired = 0
        for idx in existing.indices {
            if existing[idx].kind == "path" && isFingerprintValue(existing[idx].value) {
                existing[idx].kind = "fingerprint"
                existing[idx].value = existing[idx].value.lowercased()
                if existing[idx].note.isEmpty || existing[idx].note == "测试路径豁免" {
                    existing[idx].note = "指纹豁免"
                }
                repaired += 1
            }
        }

        let parsed = parseLines(rawText)
        var added = 0
        var skipped = 0
        for item in parsed {
            if existing.contains(where: { $0.kind == item.kind && $0.value == item.value }) {
                skipped += 1
                continue
            }
            existing.append(
                GatewayAllowlistEntry(
                    kind: item.kind,
                    value: item.value,
                    note: item.note,
                    createdAt: now
                )
            )
            added += 1
        }
        return (added: added, repaired: repaired, skippedDuplicates: skipped)
    }
}

struct GatewayConfig: Codable, Equatable {
    var listenAddr: String = "127.0.0.1:19840"
    var defaultLLMAction: String = "mask" // "mask" | "block"
    var syncEnvSecrets: Bool = true
    var protectedDomains: [String] = GatewayConfig.defaultProtectedDomains
    var upstreamProxyURL: String = ""
    var ruleGroups: GatewayRuleGroups = GatewayRuleGroups()
    var customPatterns: [GatewayCustomPattern] = []
    var allowlist: [GatewayAllowlistEntry] = []

    static let defaultProtectedDomains: [String] = [
        "api.anthropic.com",
        "api.openai.com",
        "chatgpt.com",
        "generativelanguage.googleapis.com",
        "api.deepseek.com",
        "openrouter.ai",
        "api.moonshot.cn",
        "open.bigmodel.cn",
        "dashscope.aliyuncs.com",
        "api.siliconflow.cn",
        "api.github.com",
        "github.com"
    ]
}

struct GatewayDailyStats: Codable, Equatable {
    var date: String = ""
    var scannedRequests: Int = 0
    var maskedCount: Int = 0
    var blockedCount: Int = 0
    var gitScans: Int = 0
    var gitBlockedCount: Int = 0
}

struct GatewayAuditEvent: Codable, Equatable, Identifiable {
    var id: String
    var timestamp: Date
    var channel: String       // "llm" | "github" | "git" | "self-test"
    var action: String        // "masked" | "blocked"
    var target: String
    var client: String
    var category: String
    var ruleName: String
    var maskedPreview: String
    var fingerprint: String
    var location: String
    var count: Int

    var isBlocked: Bool { action == "blocked" }

    var channelLabel: String {
        switch channel {
        case "llm": return "大模型请求"
        case "github": return "GitHub API"
        case "git": return "Git 钩子"
        case "self-test": return "诊断自检"
        default: return channel
        }
    }

    var actionLabel: String {
        action == "blocked" ? "已拦截" : "已脱敏并流式还原"
    }
}

struct GatewayDaemonStatus: Codable, Equatable {
    var running: Bool
    var version: String
    var pid: Int
    var uptimeSeconds: Int64
    var listenAddr: String
    var defaultLLMAction: String
    var knownSecretCount: Int
    var activeVaultItems: Int
    var caCertPath: String
    var caFingerprint: String
    var stats: GatewayDailyStats
}

struct GatewayEventsPayload: Codable {
    var events: [GatewayAuditEvent]
    var stats: GatewayDailyStats
}

struct GatewaySelfTestResult: Codable, Equatable {
    var passed: Bool
    var maskedPayload: String
    var restoredText: String
    var ruleTriggered: String
    var gitCheckReady: Bool
    var message: String
}

struct GatewayKnownSecretInput: Codable, Equatable {
    var name: String
    var value: String
}

// MARK: - Surge / mitmproxy / Git Hook Artifact Renderers

enum GatewaySurgeBridge {
    static func moduleDownloadURL(listenAddr: String) -> String {
        let addr = listenAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1:19840"
            : listenAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "http://\(addr)/surge/deskside-guard.sgmodule"
    }

    static func surgeInstallSchemeURL(listenAddr: String) -> URL? {
        let dl = moduleDownloadURL(listenAddr: listenAddr)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = dl.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "surge:///install-module?url=\(encoded)")
    }

    static func renderSGModule(domains: [String], routerScriptPath: String) -> String {
        let cleaned = domains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let regexEscaped = cleaned
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = "^https:\\/\\/(?:[a-z0-9-]+\\.)?(?:\(regexEscaped))(?:\\/|$)"
        let hostnameAppend = cleaned.joined(separator: ", ")

        return """
        #!name=DeskSide 安全网关 (LLM & GitHub 密钥防泄漏)
        #!desc=由 DeskSide 自动维护：对大模型请求执行密钥脱敏与流式还原，对 GitHub 上传执行密钥硬阻断。网关停止时自动回退为直通。
        #!category=Security

        [Rule]
        IP-CIDR,127.0.0.1/32,DIRECT,no-resolve

        [Script]
        deskside-guard-hop = type=http-request,pattern=\(pattern),requires-body=0,timeout=5,script-path=\(routerScriptPath)

        [MITM]
        hostname = %APPEND% \(hostnameAppend)
        """ + "\n"
    }

    /// Generates `hop-router.js` atomically.
    /// When `enabled == false`, immediately calls `$done({})` so Surge traffic passes straight through even if `.sgmodule` stays enabled.
    static func renderHopRouterJS(
        enabled: Bool,
        listenAddr: String,
        bootToken: String,
        domains: [String]
    ) -> String {
        guard enabled, !bootToken.isEmpty else {
            return """
            // DeskSide Security Gateway - Passthrough Mode (Gateway Stopped)
            $done({});
            """ + "\n"
        }

        let jsDomains = domains
            .map { "\"\($0.lowercased().replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: ", ")
        let safeToken = bootToken.replacingOccurrences(of: "\"", with: "")
        let safeListen = listenAddr.replacingOccurrences(of: "\"", with: "")

        return """
        // DeskSide Security Gateway - Atomic Hop Router (requires-body=0, preserves SSE streaming)
        (function () {
          var BOOT_TOKEN = "\(safeToken)";
          var GUARD_ADDR = "http://\(safeListen)";
          var DOMAINS = [\(jsDomains)];

          var headers = $request.headers || {};
          var hop = headers["X-Guard-Hop"] || headers["x-guard-hop"] || "";
          if (hop === BOOT_TOKEN) {
            delete headers["X-Guard-Hop"];
            delete headers["x-guard-hop"];
            $done({ headers: headers });
            return;
          }

          var rawURL = $request.url || "";
          var m = rawURL.match(/^(https?):\\/\\/([^\\/?#]+)(\\/[\\s\\S]*)?$/i);
          if (!m) {
            $done({});
            return;
          }
          var scheme = m[1].toLowerCase();
          var hostPort = m[2];
          var hostOnly = hostPort.split(":")[0].toLowerCase();
          var pathAndQuery = m[3] || "/";

          var matched = false;
          for (var i = 0; i < DOMAINS.length; i++) {
            var d = DOMAINS[i];
            if (hostOnly === d || hostOnly.slice(-(d.length + 1)) === "." + d) {
              matched = true;
              break;
            }
          }
          if (!matched) {
            $done({});
            return;
          }

          delete headers["X-Guard-Hop"];
          delete headers["x-guard-hop"];
          var nextURL = GUARD_ADDR + "/_guard/" + scheme + "/" + hostPort + pathAndQuery;
          $done({ url: nextURL, headers: headers });
        })();
        """ + "\n"
    }
}

enum GatewayMitmproxyBridge {
    static func renderAddonPy(listenAddr: String, bootToken: String, domains: [String]) -> String {
        let pyDomains = domains
            .map { "\"\($0.lowercased().replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: ", ")
        let safeHostPort = listenAddr.split(separator: ":")
        let guardHost = safeHostPort.first.map(String.init) ?? "127.0.0.1"
        let guardPort = safeHostPort.count > 1 ? (Int(safeHostPort[1]) ?? 19840) : 19840
        let safeToken = bootToken.replacingOccurrences(of: "\"", with: "")

        return """
        # DeskSide Security Gateway - mitmproxy Local Capture Addon
        from mitmproxy import http

        BOOT_TOKEN = "\(safeToken)"
        GUARD_HOST = "\(guardHost)"
        GUARD_PORT = \(guardPort)
        PROTECTED_DOMAINS = {\(pyDomains)}

        def _is_protected(host: str) -> bool:
            h = (host or "").lower().strip(".")
            if h in PROTECTED_DOMAINS:
                return True
            return any(h.endswith("." + d) for d in PROTECTED_DOMAINS)

        def requestheaders(flow: http.HTTPFlow) -> None:
            if flow.request.headers.get("X-Guard-Hop") == BOOT_TOKEN:
                del flow.request.headers["X-Guard-Hop"]
                return

        def request(flow: http.HTTPFlow) -> None:
            if flow.request.headers.get("X-Guard-Hop") == BOOT_TOKEN:
                del flow.request.headers["X-Guard-Hop"]
                return
            orig_host = flow.request.pretty_host
            if orig_host in ("127.0.0.1", "localhost") or not _is_protected(orig_host):
                return
            orig_scheme = flow.request.scheme
            orig_port = flow.request.port
            host_seg = orig_host if (orig_scheme == "https" and orig_port == 443) or (orig_scheme == "http" and orig_port == 80) else f"{orig_host}:{orig_port}"
            orig_path = flow.request.path if flow.request.path.startswith("/") else ("/" + flow.request.path)
            flow.request.scheme = "http"
            flow.request.host = GUARD_HOST
            flow.request.port = GUARD_PORT
            flow.request.path = f"/_guard/{orig_scheme}/{host_seg}{orig_path}"

        def responseheaders(flow: http.HTTPFlow) -> None:
            # Never buffer SSE responses!
            ctype = flow.response.headers.get("content-type", "").lower()
            if "text/event-stream" in ctype:
                flow.response.stream = True
        """ + "\n"
    }
}

enum GatewayGitHookRenderer {
    static func renderHookScript(subcommand: String, guardBinaryPath: String, stateDirPath: String) -> String {
        let escapedBin = guardBinaryPath.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedState = stateDirPath.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        #!/bin/sh
        # Managed by DeskSide Security Gateway.
        # Falls back cleanly to exit 0 if DeskSide.app is moved or uninstalled.
        GUARD_BIN="\(escapedBin)"
        if [ ! -x "$GUARD_BIN" ] && [ -x "/Applications/DeskSide.app/Contents/MacOS/deskside-guard" ]; then
          GUARD_BIN="/Applications/DeskSide.app/Contents/MacOS/deskside-guard"
        fi
        if [ -x "$GUARD_BIN" ]; then
          exec "$GUARD_BIN" \(subcommand) --state-dir "\(escapedState)" "$@"
        fi
        exit 0
        """ + "\n"
    }
}

// MARK: - Global CLAUDE.md / AGENTS.md Append-Only Syncer

struct GatewayAgentRuleFileTarget: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case claude = "claude"
        case agents = "agents"
    }

    var id: String { canonicalPath }
    var kind: Kind
    var canonicalPath: String
    var displayPath: String
    var linkedDisplayPaths: [String]
    var isSynced: Bool
}

struct GatewayAgentRulesSyncOutcome: Equatable {
    var targets: [GatewayAgentRuleFileTarget]
    var newlySyncedPaths: [String]
    var alreadySyncedPaths: [String]
    var failedPaths: [String]

    var foundAnyGlobalFile: Bool { !targets.isEmpty }
}

enum GatewayAgentRulesSyncer {
    static let startMarker = "<!-- >>> DeskSide Security Gateway >>> -->"
    static let endMarker = "<!-- <<< DeskSide Security Gateway <<< -->"

    private static let globalDotDirs: [String] = [
        ".agent-rules",
        ".claude",
        ".codex",
        ".gemini",
        ".kimi",
        ".cursor",
        ".windsurf",
        ".factory",
        ".amp",
        ".goose",
        ".continue",
        ".aider"
    ]

    private static let topLevelCandidateNames: [String] = [
        "CLAUDE.md", "claude.md",
        "AGENTS.md", "agents.md",
        "AGENT.md", "agent.md"
    ]

    private static let skippedConfigSubdirs: Set<String> = [
        "deskside-guard", "git", "gh", "gcloud", "configstore"
    ]

    static func renderManagedBlock() -> String {
        return """
        \(startMarker)
        ## DeskSide 安全网关协作规范

        本机已启用 **DeskSide 安全网关**（全局 Git `pre-commit` / `pre-push` 密钥防泄漏拦截与双出口守护），编写与提交代码时请严格遵守：

        1. **提交前白名单预检与主动提示**：当新增或修改的代码、单测 Fixture、文档示例、敏感语义字段或枚举值（如含 `Secret` / `Token` / `Password` / `Key` 字样的常量赋值、假密钥样例、示例数据库 URI 等）可能触发安全网关拦截且确需豁免时，**必须在执行 `git commit` / `git push` 提交代码前主动暂停，提示用户先将其加入白名单**，待用户确认后再执行提交。
        2. **提供可直接粘贴的豁免项**：提示用户加白名单时，请一并列出待豁免的**相对文件路径**（如 `Tests/Fixtures/`）或扫描输出的 **`sha256:...` 指纹**（每行一条，引导用户粘贴至 `DeskSide -> 安全网关 -> 策略与规则 -> 白名单豁免` 批量添加；若本机存在 `/Applications/DeskSide.app/Contents/MacOS/deskside-guard`，可先执行 `deskside-guard scan <文件路径>` 预检获取指纹）。
        3. **严禁绕过安全网关**：禁止使用 `git commit --no-verify`（`-n`）、`git push --no-verify`、篡改 `core.hooksPath` 或拆分硬编码真实密钥来规避检查；真实凭据一律迁移至环境变量读取。
        \(endMarker)
        """
    }

    static func classifyFileName(_ fileName: String) -> GatewayAgentRuleFileTarget.Kind? {
        switch fileName.lowercased() {
        case "claude.md":
            return .claude
        case "agent.md", "agents.md":
            return .agents
        default:
            return nil
        }
    }

    static func containsCurrentManagedBlock(_ content: String) -> Bool {
        let block = renderManagedBlock()
        return content.contains(block)
    }

    static func applyManagedBlock(to originalContent: String) -> (updated: String, changed: Bool) {
        let block = renderManagedBlock()
        if let startRange = originalContent.range(of: startMarker),
           let endRange = originalContent.range(of: endMarker),
           startRange.lowerBound < endRange.upperBound {
            var updated = originalContent
            updated.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: block)
            return (updated, updated != originalContent)
        }

        if originalContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let updated = block + "\n"
            return (updated, updated != originalContent)
        }

        let updated: String
        if originalContent.hasSuffix("\n\n") {
            updated = originalContent + block + "\n"
        } else if originalContent.hasSuffix("\n") {
            updated = originalContent + "\n" + block + "\n"
        } else {
            updated = originalContent + "\n\n" + block + "\n"
        }
        return (updated, true)
    }

    static func removeManagedBlock(from originalContent: String) -> (updated: String, changed: Bool) {
        guard let startRange = originalContent.range(of: startMarker),
              let endRange = originalContent.range(of: endMarker),
              startRange.lowerBound < endRange.upperBound else {
            return (originalContent, false)
        }

        var lower = startRange.lowerBound
        while lower > originalContent.startIndex {
            let prev = originalContent.index(before: lower)
            if originalContent[prev] == "\n" || originalContent[prev] == "\r" {
                lower = prev
            } else {
                break
            }
        }

        var upper = endRange.upperBound
        while upper < originalContent.endIndex && (originalContent[upper] == "\n" || originalContent[upper] == "\r") {
            upper = originalContent.index(after: upper)
        }

        var updated = originalContent
        let replacement: String
        if lower == originalContent.startIndex {
            replacement = ""
        } else if upper == originalContent.endIndex {
            replacement = "\n"
        } else {
            replacement = "\n\n"
        }
        updated.replaceSubrange(lower..<upper, with: replacement)
        return (updated, updated != originalContent)
    }

    static func shortenHomePath(_ path: String, homeDirectory: String) -> String {
        let cleanHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        if path == cleanHome { return "~" }
        if path.hasPrefix(cleanHome + "/") {
            return "~" + String(path.dropFirst(cleanHome.count))
        }
        return path
    }

    /// Discovers existing global `CLAUDE.md` and `AGENTS.md` (`agent.md`) files without touching TCC-protected user folders
    /// and without creating any files. Deduplicates symlinked paths onto their canonical target file.
    static func discoverTargets(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [GatewayAgentRuleFileTarget] {
        let homeURL = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let resolvedHomePath = homeURL.resolvingSymlinksInPath().standardizedFileURL.path
        var rawCandidates: [(url: URL, kind: GatewayAgentRuleFileTarget.Kind)] = []

        func scanShallowDirectory(_ dirURL: URL) {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { return }
            guard let items = try? fileManager.contentsOfDirectory(atPath: dirURL.path) else { return }
            for item in items.sorted() {
                if let kind = classifyFileName(item) {
                    rawCandidates.append((dirURL.appendingPathComponent(item), kind))
                }
            }
        }

        // 1. Standard global AI agent dot-directories under ~/
        for dotDir in globalDotDirs {
            scanShallowDirectory(homeURL.appendingPathComponent(dotDir, isDirectory: true))
        }

        // 2. ~/.config and 1-level ~/.config/<tool>/
        let dotConfigURL = homeURL.appendingPathComponent(".config", isDirectory: true)
        var configIsDir: ObjCBool = false
        if fileManager.fileExists(atPath: dotConfigURL.path, isDirectory: &configIsDir), configIsDir.boolValue {
            scanShallowDirectory(dotConfigURL)
            if let subdirs = try? fileManager.contentsOfDirectory(atPath: dotConfigURL.path) {
                for sub in subdirs.sorted() where !sub.hasPrefix(".") && !skippedConfigSubdirs.contains(sub.lowercased()) {
                    scanShallowDirectory(dotConfigURL.appendingPathComponent(sub, isDirectory: true))
                }
            }
        }

        // 3. Direct top-level ~/CLAUDE.md, ~/AGENTS.md, ~/AGENT.md (exact check, no directory listing on $HOME)
        var seenTopCaseInsensitive = Set<String>()
        for name in topLevelCandidateNames {
            let candidateURL = homeURL.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDir), !isDir.boolValue {
                let canonical = candidateURL.resolvingSymlinksInPath().standardizedFileURL.path
                if seenTopCaseInsensitive.insert(canonical).inserted, let kind = classifyFileName(name) {
                    rawCandidates.append((candidateURL, kind))
                }
            }
        }

        // Group by canonical target file path so symlink aliases never cause duplicate writes.
        struct Bucket {
            var kind: GatewayAgentRuleFileTarget.Kind
            var canonicalPath: String
            var discoveredDisplayPaths: [String]
        }

        var orderedCanonicalKeys: [String] = []
        var buckets: [String: Bucket] = [:]

        for (candidateURL, kind) in rawCandidates {
            let canonicalURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: canonicalURL.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            let disp = shortenHomePath(candidateURL.standardizedFileURL.path, homeDirectory: homeURL.path)
            let canonicalDisp = shortenHomePath(canonicalURL.path, homeDirectory: resolvedHomePath)
            let key = canonicalURL.path

            if var existing = buckets[key] {
                if !existing.discoveredDisplayPaths.contains(disp) {
                    existing.discoveredDisplayPaths.append(disp)
                }
                // If canonical file itself is named claude.md or agents.md, prefer canonical's kind
                if let canonicalKind = classifyFileName(canonicalURL.lastPathComponent) {
                    existing.kind = canonicalKind
                }
                buckets[key] = existing
            } else {
                orderedCanonicalKeys.append(key)
                let resolvedKind = classifyFileName(canonicalURL.lastPathComponent) ?? kind
                var displays = [disp]
                if canonicalDisp != disp && !displays.contains(canonicalDisp) {
                    displays.insert(canonicalDisp, at: 0)
                }
                buckets[key] = Bucket(
                    kind: resolvedKind,
                    canonicalPath: key,
                    discoveredDisplayPaths: displays
                )
            }
        }

        var targets: [GatewayAgentRuleFileTarget] = []
        for key in orderedCanonicalKeys {
            guard let bucket = buckets[key] else { continue }
            let canonicalShort = shortenHomePath(bucket.canonicalPath, homeDirectory: resolvedHomePath)
            let primaryDisplay: String
            if bucket.discoveredDisplayPaths.contains(canonicalShort) {
                primaryDisplay = canonicalShort
            } else {
                primaryDisplay = bucket.discoveredDisplayPaths.first ?? canonicalShort
            }
            let aliases = bucket.discoveredDisplayPaths.filter { $0 != primaryDisplay }
            let content = (try? String(contentsOfFile: bucket.canonicalPath, encoding: .utf8)) ?? ""
            let synced = containsCurrentManagedBlock(content)

            targets.append(GatewayAgentRuleFileTarget(
                kind: bucket.kind,
                canonicalPath: bucket.canonicalPath,
                displayPath: primaryDisplay,
                linkedDisplayPaths: aliases,
                isSynced: synced
            ))
        }

        return targets
    }

    /// Strictly append-only sync: updates ONLY existing global `CLAUDE.md` / `AGENTS.md` files and NEVER creates missing files.
    @discardableResult
    static func syncExistingFiles(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> GatewayAgentRulesSyncOutcome {
        let initialTargets = discoverTargets(homeDirectory: homeDirectory, fileManager: fileManager)
        guard !initialTargets.isEmpty else {
            return GatewayAgentRulesSyncOutcome(
                targets: [],
                newlySyncedPaths: [],
                alreadySyncedPaths: [],
                failedPaths: []
            )
        }

        var newlySynced: [String] = []
        var alreadySynced: [String] = []
        var failed: [String] = []

        for target in initialTargets {
            var isDir: ObjCBool = false
            // Enforce strict append-only: never create if file disappeared.
            guard fileManager.fileExists(atPath: target.canonicalPath, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            do {
                let original = try String(contentsOfFile: target.canonicalPath, encoding: .utf8)
                let (updated, changed) = applyManagedBlock(to: original)
                if !changed {
                    alreadySynced.append(target.displayPath)
                    continue
                }

                let existingPerms = (try? fileManager.attributesOfItem(atPath: target.canonicalPath)[.posixPermissions]) as? NSNumber
                try Data(updated.utf8).write(to: URL(fileURLWithPath: target.canonicalPath), options: .atomic)
                if let perms = existingPerms {
                    try? fileManager.setAttributes([.posixPermissions: perms.intValue], ofItemAtPath: target.canonicalPath)
                }
                newlySynced.append(target.displayPath)
            } catch {
                failed.append(target.displayPath)
            }
        }

        let refreshed = discoverTargets(homeDirectory: homeDirectory, fileManager: fileManager)
        return GatewayAgentRulesSyncOutcome(
            targets: refreshed,
            newlySyncedPaths: newlySynced,
            alreadySyncedPaths: alreadySynced,
            failedPaths: failed
        )
    }

    /// Removes the managed DeskSide Security Gateway block from existing global instruction files while preserving all user content.
    @discardableResult
    static func removeFromExistingFiles(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> Int {
        let targets = discoverTargets(homeDirectory: homeDirectory, fileManager: fileManager)
        var removedCount = 0
        for target in targets {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: target.canonicalPath, isDirectory: &isDir), !isDir.boolValue,
                  let original = try? String(contentsOfFile: target.canonicalPath, encoding: .utf8) else {
                continue
            }
            let (updated, changed) = removeManagedBlock(from: original)
            guard changed else { continue }
            let existingPerms = (try? fileManager.attributesOfItem(atPath: target.canonicalPath)[.posixPermissions]) as? NSNumber
            if (try? Data(updated.utf8).write(to: URL(fileURLWithPath: target.canonicalPath), options: .atomic)) != nil {
                if let perms = existingPerms {
                    try? fileManager.setAttributes([.posixPermissions: perms.intValue], ofItemAtPath: target.canonicalPath)
                }
                removedCount += 1
            }
        }
        return removedCount
    }
}
