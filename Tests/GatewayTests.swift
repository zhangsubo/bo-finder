import Cocoa
import Foundation

@main
struct GatewayTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else {
                fatalError("Failed: \(label)")
            }
            checks += 1
            print("  ✅ \(label)")
        }

        // 1. Default preferences are strictly OFF so fresh install never modifies system network or Surge
        let defaultPrefs = GatewayLocalPreferences()
        check(!defaultPrefs.isEnabled, "Gateway is disabled by default")
        check(!defaultPrefs.hasCompletedOnboarding, "Onboarding is incomplete by default")
        check(defaultPrefs.savedProxySnapshots.isEmpty, "Proxy snapshots start empty")

        // 2. Strict 3-tier progressive fallback order:
        //    Tier 1 (Surge) -> Tier 2 (mitmproxy consent / existing) -> Tier 3 (Built-in Proxy)
        check(
            GatewayTierResolver.decide(
                hasSurge: true,
                hasExistingMitmproxy: false,
                userConsentedMitmproxyDownload: nil
            ) == .resolved(.surge),
            "Uses Surge automatically when /Applications/Surge.app is present"
        )
        check(
            GatewayTierResolver.decide(
                hasSurge: false,
                hasExistingMitmproxy: false,
                userConsentedMitmproxyDownload: nil
            ) == .promptMitmproxyConsent,
            "Prompts user for mitmproxy download consent when Surge is absent"
        )
        check(
            GatewayTierResolver.decide(
                hasSurge: false,
                hasExistingMitmproxy: true,
                userConsentedMitmproxyDownload: nil
            ) == .resolved(.mitmproxy),
            "Uses existing mitmproxy immediately when Surge is absent and mitmproxy is already installed"
        )
        check(
            GatewayTierResolver.decide(
                hasSurge: false,
                hasExistingMitmproxy: false,
                userConsentedMitmproxyDownload: true
            ) == .resolved(.mitmproxy),
            "Selects Tier 2 mitmproxy when user consents to download"
        )
        check(
            GatewayTierResolver.decide(
                hasSurge: false,
                hasExistingMitmproxy: false,
                userConsentedMitmproxyDownload: false
            ) == .resolved(.builtinProxy),
            "Falls back to Tier 3 built-in proxy when user declines mitmproxy download"
        )

        // 3. Surge .sgmodule & atomic hop-router.js rendering (requires-body=0 + passthrough when stopped)
        let sgModule = GatewaySurgeBridge.renderSGModule(
            domains: ["api.anthropic.com", "api.github.com"],
            routerScriptPath: "/Users/tester/.config/deskside-guard/hop-router.js"
        )
        check(sgModule.contains("requires-body=0"), "Surge module uses requires-body=0 to preserve SSE streaming")
        check(sgModule.contains("IP-CIDR,127.0.0.1/32,DIRECT,no-resolve"), "Surge module forces 127.0.0.1 DIRECT")
        check(sgModule.contains("hostname = %APPEND% api.anthropic.com, api.github.com"), "Surge module appends MITM hostnames")
        check(
            GatewaySurgeBridge.moduleDownloadURL(listenAddr: "127.0.0.1:19840") == "http://127.0.0.1:19840/surge/deskside-guard.sgmodule",
            "Generates local HTTP Surge module URL"
        )
        check(
            GatewaySurgeBridge.surgeInstallSchemeURL(listenAddr: "127.0.0.1:19840")?.absoluteString.hasPrefix("surge:///install-module?url=http%3A%2F%2F127.0.0.1%3A19840") == true,
            "Generates surge:///install-module URL scheme"
        )

        let disabledRouter = GatewaySurgeBridge.renderHopRouterJS(
            enabled: false,
            listenAddr: "127.0.0.1:19840",
            bootToken: "tok",
            domains: ["api.anthropic.com"]
        )
        check(disabledRouter.contains("$done({});") && !disabledRouter.contains("/_guard/"), "Disabled Surge router is atomic passthrough")

        let activeRouter = GatewaySurgeBridge.renderHopRouterJS(
            enabled: true,
            listenAddr: "127.0.0.1:19840",
            bootToken: "example_placeholder",
            domains: ["api.anthropic.com", "github.com"]
        )
        check(activeRouter.contains("example_placeholder") && activeRouter.contains("/_guard/"), "Active Surge router enforces bootToken and /_guard/ hop")

        // 4. mitmproxy addon & Git hook wrapper rendering
        let mitmAddon = GatewayMitmproxyBridge.renderAddonPy(
            listenAddr: "127.0.0.1:19840",
            bootToken: "example_placeholder",
            domains: ["api.openai.com"]
        )
        check(mitmAddon.contains("flow.response.stream = True") && mitmAddon.contains("/_guard/"), "mitmproxy addon streams SSE responses unbuffered")

        let gitHook = GatewayGitHookRenderer.renderHookScript(
            subcommand: "git-pre-push",
            guardBinaryPath: "/Applications/DeskSide.app/Contents/MacOS/deskside-guard",
            stateDirPath: "/Users/tester/.config/deskside-guard"
        )
        check(gitHook.hasPrefix("#!/bin/sh") && gitHook.contains("git-pre-push") && gitHook.contains("exit 0"), "Git hook wrapper falls back safely to exit 0 if binary removed")

        // 5. Verify all SF Symbols used in GatewayView exist on macOS
        let symbols = [
            "checkmark.shield", "checkmark.shield.fill", "bolt.shield.fill",
            "network.badge.shield.half.filled", "lock.shield.fill", "shield.slash",
            "stethoscope", "waveform.path.ecg", "eye.trianglebadge.exclamationmark",
            "hand.raised.fill", "hand.raised.circle.fill", "exclamationmark.shield.fill",
            "sparkles.rectangle.stack.fill", "arrow.up.doc.on.clipboard"
        ]
        for sym in symbols {
            check(NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil, "SF Symbol '\(sym)' available")
        }

        // 6. Batch allowlist parser (one item per line, auto-classifies sha256:... vs path, deduplicates & repairs legacy path-tagged sha256)
        var existingAllowlist: [GatewayAllowlistEntry] = [
            GatewayAllowlistEntry(kind: "path", value: "SHA256:111122223333", note: "测试路径豁免")
        ]
        let batchInput = """
        # comment line to ignore

        sha256:111122223333
        sha256:AABBCCDDEEFF # custom field label
        sha256:aabbccddeeff
        Tests/Fixtures/
        Sources/Config.swift // config mapping
        """
        let mergeOutcome = GatewayAllowlistBatchParser.mergeIntoAllowlist(&existingAllowlist, rawText: batchInput)
        check(mergeOutcome.repaired == 1, "Repairs existing sha256 entry previously saved with kind=path")
        check(mergeOutcome.added == 3, "Adds unique fingerprint and path entries across lines")
        check(mergeOutcome.skippedDuplicates == 1, "Skips entry already present after repair")
        check(existingAllowlist[0].kind == "fingerprint" && existingAllowlist[0].value == "sha256:111122223333", "Repaired entry normalized to lowercase fingerprint")
        check(existingAllowlist[1].kind == "fingerprint" && existingAllowlist[1].value == "sha256:aabbccddeeff" && existingAllowlist[1].note == "custom field label", "Parses inline hash note and normalizes hex case")
        check(existingAllowlist[2].kind == "path" && existingAllowlist[2].value == "Tests/Fixtures/", "Classifies non-sha256 lines as path entries")
        check(existingAllowlist[3].kind == "path" && existingAllowlist[3].note == "config mapping", "Parses inline double-slash note for path entry")

        print("Gateway tests: \(checks) passed")
    }
}
