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
    var showHUDNotifications: Bool = true
    var previousGitHooksPath: String? = nil
    var didOverrideGitHooksPath: Bool = false
    var savedProxySnapshots: [GatewayNetworkServiceProxySnapshot] = []
    var mitmproxyBinaryPath: String? = nil
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
