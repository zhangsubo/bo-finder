import Cocoa
import CryptoKit
import Darwin
import Foundation

final class GatewayManager: ObservableObject {
    static let shared = GatewayManager()

    // MARK: - Published UI State

    @Published private(set) var prefs: GatewayLocalPreferences = GatewayLocalPreferences()
    @Published private(set) var config: GatewayConfig = GatewayConfig()
    @Published private(set) var daemonStatus: GatewayDaemonStatus? = nil
    @Published private(set) var events: [GatewayAuditEvent] = []
    @Published private(set) var stats: GatewayDailyStats = GatewayDailyStats()
    @Published private(set) var lastSelfTest: GatewaySelfTestResult? = nil

    @Published private(set) var isDaemonRunning: Bool = false
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var isDownloadingMitmproxy: Bool = false
    @Published private(set) var downloadProgressText: String = ""

    @Published private(set) var hasSurgeInstalled: Bool = false
    @Published private(set) var detectedMitmproxyPath: String? = nil
    @Published private(set) var isGitHookMounted: Bool = false
    @Published private(set) var isCACertTrusted: Bool = false
    @Published private(set) var agentRuleTargets: [GatewayAgentRuleFileTarget] = []

    @Published var showMitmproxyConsentSheet: Bool = false
    @Published var showSurgeGuideSheet: Bool = false
    @Published var showAgentRulesManualSheet: Bool = false
    @Published var agentRulesSheetIsMissingPrompt: Bool = false
    @Published var statusBanner: String = ""
    @Published var errorMessage: String = ""

    private var pendingAgentRulesManualSheet: Bool = false

    // MARK: - Paths

    let homeDirectory: String
    let appSupportDirURL: URL
    let preferencesFileURL: URL
    let guardStateDirURL: URL
    let sgModuleFileURL: URL
    let hopRouterJSFileURL: URL
    let mitmAddonFileURL: URL
    let gitHooksDirURL: URL
    let managedMitmproxyDirURL: URL

    private let ioQueue = DispatchQueue(label: "com.bofinder.deskside.gateway-io", qos: .userInitiated)
    private var daemonProcess: Process?
    private var mitmproxyProcess: Process?
    private var sseSocketFD: Int32 = -1
    private var sseActive: Bool = false
    private var pollTimer: Timer?

    private static let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFrac.date(from: str) { return d }
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            if let d = isoPlain.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(str)")
        }
        return dec
    }()

    private static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private init() {
        let home = PathFormatter.realHomeDirectory()
        self.homeDirectory = home
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.appSupportDirURL = appSupport.appendingPathComponent("DeskSide/Gateway", isDirectory: true)
        self.preferencesFileURL = appSupportDirURL.appendingPathComponent("preferences.json")
        self.managedMitmproxyDirURL = appSupportDirURL.appendingPathComponent("mitmproxy", isDirectory: true)

        self.guardStateDirURL = homeURL.appendingPathComponent(".config/deskside-guard", isDirectory: true)
        self.sgModuleFileURL = guardStateDirURL.appendingPathComponent("deskside-guard.sgmodule")
        self.hopRouterJSFileURL = guardStateDirURL.appendingPathComponent("hop-router.js")
        self.mitmAddonFileURL = guardStateDirURL.appendingPathComponent("deskside-mitm-addon.py")
        self.gitHooksDirURL = guardStateDirURL.appendingPathComponent("git-hooks", isDirectory: true)

        loadPreferencesFromDisk()
        loadCachedGuardConfigIfPresent()
        refreshEnvironmentCapabilities()

        EnvManager.shared.onSecretsChanged = { [weak self] in
            self?.syncEnvSecretsToDaemon()
        }
    }

    // MARK: - App Launch & Clean Exit

    func activateOnLaunchIfEnabled() {
        refreshEnvironmentCapabilities()
        guard prefs.isEnabled else {
            // Ensure Surge router stays in passthrough if leftover from previous session.
            writeSurgeArtifacts(enabled: false)
            return
        }
        startGatewayInternal(showHUD: false)
    }

    func shutdownCleanly() {
        stopSSEStream()
        pollTimer?.invalidate()
        pollTimer = nil

        // Always restore Surge router to passthrough & rollback system PAC proxy on exit.
        writeSurgeArtifacts(enabled: false)
        stopMitmproxyHelper()
        if !prefs.savedProxySnapshots.isEmpty {
            restoreSystemPACProxy()
        }

        if let proc = daemonProcess, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        daemonProcess = nil
    }

    // MARK: - Progressive 3-Tier Onboarding & Toggle

    func setGatewayEnabled(_ shouldEnable: Bool) {
        if shouldEnable {
            requestEnableGateway()
        } else {
            disableGateway(showHUD: true)
        }
    }

    /// Evaluates the 3-tier fallback order requested by the user:
    /// 1. Surge installed -> Tier 1 (`.surge`)
    /// 2. No Surge -> prompt consent to download/integrate `mitmproxy` (or use existing if already installed)
    /// 3. User declines download -> Tier 3 (`.builtinProxy`)
    func requestEnableGateway() {
        errorMessage = ""
        refreshEnvironmentCapabilities()

        if !prefs.hasCompletedOnboarding {
            let decision = GatewayTierResolver.decide(
                hasSurge: hasSurgeInstalled,
                hasExistingMitmproxy: detectedMitmproxyPath != nil,
                userConsentedMitmproxyDownload: nil
            )
            switch decision {
            case .resolved(let tier):
                prefs.selectedTier = tier
                prefs.hasCompletedOnboarding = true
                savePreferencesToDisk()
                startGatewayInternal(showHUD: true)
                if tier == .surge {
                    showSurgeGuideSheet = true
                }
            case .promptMitmproxyConsent:
                showMitmproxyConsentSheet = true
                return
            }
        } else {
            // Re-validate selected tier availability
            if prefs.selectedTier == .surge && !hasSurgeInstalled {
                prefs.hasCompletedOnboarding = false
                requestEnableGateway()
                return
            }
            if prefs.selectedTier == .mitmproxy && detectedMitmproxyPath == nil {
                showMitmproxyConsentSheet = true
                return
            }
            startGatewayInternal(showHUD: true)
        }
    }

    func confirmMitmproxyConsent(downloadAndIntegrate: Bool) {
        showMitmproxyConsentSheet = false
        let decision = GatewayTierResolver.decide(
            hasSurge: false,
            hasExistingMitmproxy: detectedMitmproxyPath != nil,
            userConsentedMitmproxyDownload: downloadAndIntegrate
        )
        guard case .resolved(let chosenTier) = decision else { return }

        if chosenTier == .mitmproxy && detectedMitmproxyPath == nil {
            downloadAndInstallMitmproxy()
        } else {
            prefs.selectedTier = chosenTier
            prefs.hasCompletedOnboarding = true
            savePreferencesToDisk()
            startGatewayInternal(showHUD: true)
        }
    }

    func switchCaptureTier(_ newTier: GatewayCaptureTier) {
        guard newTier != prefs.selectedTier || !prefs.isEnabled else { return }
        refreshEnvironmentCapabilities()

        if newTier == .surge && !hasSurgeInstalled {
            errorMessage = "未在 /Applications/Surge.app 检测到 Surge，请选择 mitmproxy 或内置代理模式。"
            return
        }
        if newTier == .mitmproxy && detectedMitmproxyPath == nil {
            showMitmproxyConsentSheet = true
            return
        }

        let wasEnabled = prefs.isEnabled
        if wasEnabled {
            deactivateCurrentTierCapture()
        }
        prefs.selectedTier = newTier
        prefs.hasCompletedOnboarding = true
        savePreferencesToDisk()

        if wasEnabled {
            activateCurrentTierCapture()
            statusBanner = "已切换流量接入模式至：\(newTier.shortBadge)"
        }
        if newTier == .surge {
            showSurgeGuideSheet = true
        }
    }

    func disableGateway(showHUD: Bool) {
        prefs.isEnabled = false
        savePreferencesToDisk()

        stopSSEStream()
        pollTimer?.invalidate()
        pollTimer = nil

        deactivateCurrentTierCapture()

        if let proc = daemonProcess, proc.isRunning {
            proc.terminate()
        }
        daemonProcess = nil
        isDaemonRunning = false
        daemonStatus = nil
        statusBanner = "安全网关已停止，所有网络分流已恢复直连"

        if showHUD && prefs.showHUDNotifications {
            HUDWindowController.shared.show(
                title: "安全网关已关闭",
                subtitle: "网络路由已恢复原状",
                symbolName: "shield.slash"
            )
        }
    }

    // MARK: - Core Start & Capture Activation

    private func startGatewayInternal(showHUD: Bool) {
        guard let binaryURL = resolveGuardBinaryURL() else {
            errorMessage = "未找到内置守护引擎 deskside-guard，请重新执行 ./build.sh 构建应用。"
            prefs.isEnabled = false
            savePreferencesToDisk()
            return
        }

        isBusy = true
        errorMessage = ""

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try FileManager.default.createDirectory(
                    at: self.guardStateDirURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                // Check if daemon is already responsive on admin.sock; if not, launch child process.
                if self.fetchStatusSync() == nil {
                    let proc = Process()
                    proc.executableURL = binaryURL
                    proc.arguments = ["serve", "--state-dir", self.guardStateDirURL.path]
                    proc.standardOutput = FileHandle.nullDevice
                    proc.standardError = FileHandle.nullDevice
                    try proc.run()
                    self.daemonProcess = proc

                    var ready = false
                    for _ in 0..<30 {
                        usleep(80_000)
                        if self.fetchStatusSync() != nil {
                            ready = true
                            break
                        }
                    }
                    if !ready {
                        throw EnvError.message("启动 deskside-guard 超时，请检查端口 \(self.config.listenAddr) 是否被占用。")
                    }
                }

                let fetchedCfg = self.fetchConfigSync() ?? self.config
                let status = self.fetchStatusSync()
                let evPayload = self.fetchEventsSync(limit: 120)

                DispatchQueue.main.async {
                    self.config = fetchedCfg
                    self.daemonStatus = status
                    if let evPayload = evPayload {
                        self.events = evPayload.events
                        self.stats = evPayload.stats
                    }
                    self.isDaemonRunning = true
                    self.prefs.isEnabled = true
                    self.savePreferencesToDisk()

                    self.syncEnvSecretsToDaemon()
                    if self.prefs.gitGuardEnabled {
                        self.installGlobalGitHooks(silent: true)
                    }
                    if self.prefs.agentSelfProtectEnabled {
                        self.syncClaudeAgentHook(enabled: true)
                    }
                    self.activateCurrentTierCapture()
                    self.startSSEStream()
                    self.startStatusPolling()
                    self.isBusy = false
                    self.statusBanner = "安全网关运行中 · \(self.prefs.selectedTier.shortBadge)"

                    if self.prefs.autoSyncAgentRulesMD {
                        self.syncGlobalAgentInstructionFiles(promptIfMissing: showHUD, showSuccessHUD: false)
                    }

                    if showHUD && self.prefs.showHUDNotifications {
                        HUDWindowController.shared.show(
                            title: "安全网关已启动",
                            subtitle: "\(self.prefs.selectedTier.shortBadge) · 双出口密钥守护生效中",
                            symbolName: "checkmark.shield.fill"
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.isDaemonRunning = false
                    self.prefs.isEnabled = false
                    self.savePreferencesToDisk()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func activateCurrentTierCapture() {
        switch prefs.selectedTier {
        case .surge:
            stopMitmproxyHelper()
            restoreSystemPACProxy()
            writeSurgeArtifacts(enabled: true)
            linkSGModuleIntoSurgeFolderIfPossible()

        case .mitmproxy:
            writeSurgeArtifacts(enabled: false)
            restoreSystemPACProxy()
            startMitmproxyHelper()

        case .builtinProxy:
            writeSurgeArtifacts(enabled: false)
            stopMitmproxyHelper()
            enableSystemPACProxy()
        }
        refreshEnvironmentCapabilities()
    }

    private func deactivateCurrentTierCapture() {
        writeSurgeArtifacts(enabled: false)
        stopMitmproxyHelper()
        restoreSystemPACProxy()
    }

    // MARK: - Tier 1: Surge Module & Atomic Hop Router

    private func readBootToken() -> String {
        let tokenURL = guardStateDirURL.appendingPathComponent("boot.token")
        return (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func writeSurgeArtifacts(enabled: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: guardStateDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let domains = config.protectedDomains
        let listenAddr = daemonStatus?.listenAddr ?? config.listenAddr
        let bootToken = enabled ? readBootToken() : ""

        let routerJS = GatewaySurgeBridge.renderHopRouterJS(
            enabled: enabled,
            listenAddr: listenAddr,
            bootToken: bootToken,
            domains: domains
        )
        try? Data(routerJS.utf8).write(to: hopRouterJSFileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hopRouterJSFileURL.path)

        let sgModule = GatewaySurgeBridge.renderSGModule(
            domains: domains,
            routerScriptPath: hopRouterJSFileURL.path
        )
        try? Data(sgModule.utf8).write(to: sgModuleFileURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sgModuleFileURL.path)
    }

    private func linkSGModuleIntoSurgeFolderIfPossible() {
        let surgeModulesDir = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Surge/Profiles/Modules", isDirectory: true)
        let surgeProfilesDir = surgeModulesDir.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: surgeProfilesDir.path) else { return }

        try? FileManager.default.createDirectory(at: surgeModulesDir, withIntermediateDirectories: true)
        let dest = surgeModulesDir.appendingPathComponent("deskside-guard.sgmodule")
        if let data = try? Data(contentsOf: sgModuleFileURL) {
            try? data.write(to: dest, options: .atomic)
        }
    }

    var surgeModuleURLString: String {
        let addr = daemonStatus?.listenAddr ?? config.listenAddr
        return GatewaySurgeBridge.moduleDownloadURL(listenAddr: addr)
    }

    func installModuleInSurge() {
        writeSurgeArtifacts(enabled: isDaemonRunning && prefs.selectedTier == .surge)
        let addr = daemonStatus?.listenAddr ?? config.listenAddr
        if let schemeURL = GatewaySurgeBridge.surgeInstallSchemeURL(listenAddr: addr) {
            NSWorkspace.shared.open(schemeURL)
            HUDWindowController.shared.show(
                title: "已唤起 Surge 安装模块",
                subtitle: "请在弹出的 Surge 窗口点击确认并勾选启用",
                symbolName: "bolt.shield.fill",
                duration: 2.4
            )
        }
    }

    func copySurgeModuleURL() {
        writeSurgeArtifacts(enabled: isDaemonRunning && prefs.selectedTier == .surge)
        let urlStr = surgeModuleURLString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
        HUDWindowController.shared.show(
            title: "已复制 Surge 模块安装 URL",
            subtitle: urlStr,
            symbolName: "doc.on.clipboard"
        )
    }

    func revealSGModuleInFinder() {
        writeSurgeArtifacts(enabled: isDaemonRunning && prefs.selectedTier == .surge)
        NSWorkspace.shared.activateFileViewerSelecting([sgModuleFileURL])
    }

    func copySGModulePath() {
        writeSurgeArtifacts(enabled: isDaemonRunning && prefs.selectedTier == .surge)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sgModuleFileURL.path, forType: .string)
        HUDWindowController.shared.show(
            title: "已复制 Surge 模块路径",
            subtitle: sgModuleFileURL.lastPathComponent,
            symbolName: "doc.on.clipboard"
        )
    }

    // MARK: - Tier 2: Open-Source mitmproxy Download & Local Capture

    func downloadAndInstallMitmproxy() {
        guard !isDownloadingMitmproxy else { return }
        isDownloadingMitmproxy = true
        downloadProgressText = "正在获取开源 mitmproxy 官方签名组件…"
        errorMessage = ""

        let version = "11.1.3"
        #if arch(arm64)
        let archSlug = "arm64"
        #else
        let archSlug = "x86_64"
        #endif
        let archiveURLString = "https://downloads.mitmproxy.org/\(version)/mitmproxy-\(version)-macos-\(archSlug).tar.gz"
        guard let downloadURL = URL(string: archiveURLString) else {
            isDownloadingMitmproxy = false
            return
        }

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, err in
            guard let self = self else { return }
            if let err = err {
                DispatchQueue.main.async {
                    self.isDownloadingMitmproxy = false
                    self.downloadProgressText = ""
                    self.errorMessage = "下载 mitmproxy 失败（\(err.localizedDescription)）。您可以重试，或直接切换为「内置按需代理」模式。"
                }
                return
            }
            guard let tempURL = tempURL,
                  let httpResp = response as? HTTPURLResponse,
                  (200..<300).contains(httpResp.statusCode) else {
                DispatchQueue.main.async {
                    self.isDownloadingMitmproxy = false
                    self.downloadProgressText = ""
                    self.errorMessage = "下载 mitmproxy 返回异常状态码，您可以直接切换为「内置按需代理」模式。"
                }
                return
            }

            do {
                let fm = FileManager.default
                try fm.createDirectory(at: self.managedMitmproxyDirURL, withIntermediateDirectories: true)
                let tarPath = self.managedMitmproxyDirURL.appendingPathComponent("mitmproxy.tar.gz")
                try? fm.removeItem(at: tarPath)
                try fm.moveItem(at: tempURL, to: tarPath)

                let untar = Process()
                untar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                untar.arguments = ["-xzf", tarPath.path, "-C", self.managedMitmproxyDirURL.path]
                try untar.run()
                untar.waitUntilExit()
                try? fm.removeItem(at: tarPath)

                guard untar.terminationStatus == 0,
                      let resolved = self.findMitmproxyExecutable() else {
                    throw EnvError.message("解压 mitmproxy 组件失败。")
                }

                // Verify Apple Developer ID signature before running!
                let verify = Process()
                verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verify.arguments = ["--verify", "--strict", resolved]
                verify.standardOutput = FileHandle.nullDevice
                verify.standardError = FileHandle.nullDevice
                try verify.run()
                verify.waitUntilExit()
                guard verify.terminationStatus == 0 else {
                    try? fm.removeItem(at: self.managedMitmproxyDirURL)
                    throw EnvError.message("mitmproxy 代码签名校验未通过，已拒绝加载。")
                }

                DispatchQueue.main.async {
                    self.isDownloadingMitmproxy = false
                    self.downloadProgressText = ""
                    self.detectedMitmproxyPath = resolved
                    self.prefs.mitmproxyBinaryPath = resolved
                    self.prefs.selectedTier = .mitmproxy
                    self.prefs.hasCompletedOnboarding = true
                    self.savePreferencesToDisk()
                    self.startGatewayInternal(showHUD: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDownloadingMitmproxy = false
                    self.downloadProgressText = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        task.resume()
    }

    private func startMitmproxyHelper() {
        stopMitmproxyHelper()
        guard let binPath = detectedMitmproxyPath ?? findMitmproxyExecutable() else {
            errorMessage = "未找到 mitmdump 可执行文件，请重新安装或切换为内置代理模式。"
            return
        }

        let listenAddr = daemonStatus?.listenAddr ?? config.listenAddr
        let bootToken = readBootToken()
        let addonPy = GatewayMitmproxyBridge.renderAddonPy(
            listenAddr: listenAddr,
            bootToken: bootToken,
            domains: config.protectedDomains
        )
        try? Data(addonPy.utf8).write(to: mitmAddonFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mitmAddonFileURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.arguments = [
            "--mode", "local",
            "--quiet",
            "-s", mitmAddonFileURL.path
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            mitmproxyProcess = proc
        } catch {
            errorMessage = "启动 mitmproxy 本地捕获失败：\(error.localizedDescription)"
        }
    }

    private func stopMitmproxyHelper() {
        if let proc = mitmproxyProcess {
            if proc.isRunning {
                proc.terminate()
            }
            mitmproxyProcess = nil
        }
    }

    // MARK: - Tier 3: Built-in Selective MITM Proxy + PAC + Local Root CA

    private func enableSystemPACProxy() {
        let listenAddr = daemonStatus?.listenAddr ?? config.listenAddr
        let pacURL = "http://\(listenAddr)/proxy.pac"
        let services = activeNetworkServices()
        guard !services.isEmpty else { return }

        if prefs.savedProxySnapshots.isEmpty {
            var snaps: [GatewayNetworkServiceProxySnapshot] = []
            for svc in services {
                let info = runCommandOutput("/usr/sbin/networksetup", ["-getautoproxyurl", svc]) ?? ""
                var prevURL = ""
                var prevEnabled = false
                for line in info.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().hasPrefix("url:") {
                        prevURL = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                        if prevURL == "(null)" { prevURL = "" }
                    } else if trimmed.lowercased().hasPrefix("enabled:") {
                        let val = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces).lowercased()
                        prevEnabled = (val == "yes" || val == "1" || val == "true")
                    }
                }
                if !prevURL.contains("/proxy.pac") {
                    snaps.append(GatewayNetworkServiceProxySnapshot(
                        serviceName: svc,
                        autoProxyURL: prevURL,
                        autoProxyEnabled: prevEnabled
                    ))
                }
            }
            prefs.savedProxySnapshots = snaps
            savePreferencesToDisk()
        }

        for svc in services {
            _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxyurl", svc, pacURL])
            _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxystate", svc, "on"])
        }
    }

    private func restoreSystemPACProxy() {
        let snapshots = prefs.savedProxySnapshots
        let services = snapshots.isEmpty ? activeNetworkServices() : snapshots.map(\.serviceName)

        for svc in services {
            if let snap = snapshots.first(where: { $0.serviceName == svc }) {
                if snap.autoProxyEnabled && !snap.autoProxyURL.isEmpty {
                    _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxyurl", svc, snap.autoProxyURL])
                    _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxystate", svc, "on"])
                } else {
                    _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
                }
            } else {
                // Only turn off if currently pointing to our own PAC URL.
                let info = runCommandOutput("/usr/sbin/networksetup", ["-getautoproxyurl", svc]) ?? ""
                if info.contains("19840/proxy.pac") {
                    _ = runCommandOutput("/usr/sbin/networksetup", ["-setautoproxystate", svc, "off"])
                }
            }
        }

        if !prefs.savedProxySnapshots.isEmpty {
            prefs.savedProxySnapshots = []
            savePreferencesToDisk()
        }
    }

    func trustLocalRootCA() {
        let caPath = daemonStatus?.caCertPath ?? guardStateDirURL.appendingPathComponent("ca-cert.pem").path
        guard FileManager.default.fileExists(atPath: caPath) else {
            errorMessage = "尚未生成本地根证书，请先启动一次安全网关。"
            return
        }
        let userKeychain = (homeDirectory as NSString).appendingPathComponent("Library/Keychains/login.keychain-db")
        let proc = Process()
        let errPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["add-trusted-cert", "-r", "trustRoot", "-k", userKeychain, caPath]
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            refreshEnvironmentCapabilities()
            if proc.terminationStatus == 0 {
                statusBanner = "已在登录钥匙串信任 DeskSide 本地根证书"
                HUDWindowController.shared.show(
                    title: "根证书已信任",
                    subtitle: "内置按需代理与 CLI 现可无缝拦截解密",
                    symbolName: "checkmark.seal.fill"
                )
            } else {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if !msg.lowercased().contains("canceled") {
                    errorMessage = "信任根证书未完成：\(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Git Global Hooks & Agent Self-Protection

    func setGitGuardEnabled(_ enabled: Bool) {
        prefs.gitGuardEnabled = enabled
        savePreferencesToDisk()
        if enabled {
            installGlobalGitHooks(silent: false)
        } else {
            uninstallGlobalGitHooks()
        }
    }

    func installGlobalGitHooks(silent: Bool) {
        guard let guardBin = resolveGuardBinaryURL()?.path else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: gitHooksDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

            let prePushURL = gitHooksDirURL.appendingPathComponent("pre-push")
            let preCommitURL = gitHooksDirURL.appendingPathComponent("pre-commit")

            let prePushScript = GatewayGitHookRenderer.renderHookScript(
                subcommand: "git-pre-push",
                guardBinaryPath: guardBin,
                stateDirPath: guardStateDirURL.path
            )
            let preCommitScript = GatewayGitHookRenderer.renderHookScript(
                subcommand: "git-pre-commit",
                guardBinaryPath: guardBin,
                stateDirPath: guardStateDirURL.path
            )

            try Data(prePushScript.utf8).write(to: prePushURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prePushURL.path)

            try Data(preCommitScript.utf8).write(to: preCommitURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preCommitURL.path)

            let currentGlobal = runCommandOutput("/usr/bin/git", ["config", "--global", "--get", "core.hooksPath"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let targetPath = gitHooksDirURL.path

            if currentGlobal != targetPath {
                if !prefs.didOverrideGitHooksPath {
                    prefs.previousGitHooksPath = currentGlobal.isEmpty ? nil : currentGlobal
                    prefs.didOverrideGitHooksPath = true
                    savePreferencesToDisk()
                }
                _ = runCommandOutput("/usr/bin/git", ["config", "--global", "core.hooksPath", targetPath])
            }
            refreshEnvironmentCapabilities()
            if !silent {
                statusBanner = "已挂载全局 Git pre-push / pre-commit 密钥拦截钩子"
            }
        } catch {
            errorMessage = "安装 Git 全局钩子失败：\(error.localizedDescription)"
        }
    }

    func uninstallGlobalGitHooks() {
        let currentGlobal = runCommandOutput("/usr/bin/git", ["config", "--global", "--get", "core.hooksPath"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentGlobal == gitHooksDirURL.path {
            if let prev = prefs.previousGitHooksPath, !prev.isEmpty {
                _ = runCommandOutput("/usr/bin/git", ["config", "--global", "core.hooksPath", prev])
            } else {
                _ = runCommandOutput("/usr/bin/git", ["config", "--global", "--unset", "core.hooksPath"])
            }
        }
        prefs.didOverrideGitHooksPath = false
        prefs.previousGitHooksPath = nil
        savePreferencesToDisk()
        refreshEnvironmentCapabilities()
        statusBanner = "已卸载全局 Git 拦截钩子并恢复原有配置"
    }

    func setAgentSelfProtectEnabled(_ enabled: Bool) {
        prefs.agentSelfProtectEnabled = enabled
        savePreferencesToDisk()
        syncClaudeAgentHook(enabled: enabled)
    }

    func setAutoSyncAgentRulesMD(_ enabled: Bool) {
        prefs.autoSyncAgentRulesMD = enabled
        savePreferencesToDisk()
        if enabled && prefs.isEnabled {
            syncGlobalAgentInstructionFiles(promptIfMissing: true, showSuccessHUD: true)
        } else {
            refreshEnvironmentCapabilities()
        }
    }

    @discardableResult
    func syncGlobalAgentInstructionFiles(promptIfMissing: Bool, showSuccessHUD: Bool) -> GatewayAgentRulesSyncOutcome {
        let outcome = GatewayAgentRulesSyncer.syncExistingFiles(homeDirectory: homeDirectory)
        agentRuleTargets = outcome.targets

        if !outcome.foundAnyGlobalFile {
            statusBanner = "未检测到全局 CLAUDE.md 或 AGENTS.md，请手动写入安全网关协作规范"
            if promptIfMissing {
                openAgentRulesSheet(missingPrompt: true)
            }
            return outcome
        }

        if !outcome.failedPaths.isEmpty {
            errorMessage = "部分全局 Agent 规则文件写入失败：\(outcome.failedPaths.joined(separator: ", "))"
        }

        if !outcome.newlySyncedPaths.isEmpty {
            let joined = outcome.newlySyncedPaths.joined(separator: "、")
            statusBanner = "已向全局 Agent 文档追加白名单预检规范：\(joined)"
            if showSuccessHUD && prefs.showHUDNotifications {
                HUDWindowController.shared.show(
                    title: "已同步全局 Agent 规范",
                    subtitle: joined,
                    symbolName: "doc.badge.gearshape.fill"
                )
            }
        } else if showSuccessHUD {
            let joined = outcome.alreadySyncedPaths.joined(separator: "、")
            statusBanner = "全局 Agent 规范已是最新（\(joined)）"
            if prefs.showHUDNotifications {
                HUDWindowController.shared.show(
                    title: "全局 Agent 规范已就绪",
                    subtitle: joined,
                    symbolName: "checkmark.circle.fill"
                )
            }
        }

        return outcome
    }

    func removeGlobalAgentInstructionBlock() {
        let removed = GatewayAgentRulesSyncer.removeFromExistingFiles(homeDirectory: homeDirectory)
        refreshEnvironmentCapabilities()
        if removed > 0 {
            statusBanner = "已从 \(removed) 个全局 Agent 文档中移除安全网关规范区块"
            if prefs.showHUDNotifications {
                HUDWindowController.shared.show(
                    title: "已移除全局 Agent 规范区块",
                    subtitle: "共清理 \(removed) 个全局规则文件",
                    symbolName: "trash"
                )
            }
        }
    }

    func openAgentRulesSheet(missingPrompt: Bool) {
        agentRulesSheetIsMissingPrompt = missingPrompt
        if showSurgeGuideSheet || showMitmproxyConsentSheet {
            pendingAgentRulesManualSheet = true
            return
        }
        if !SettingsWindowController.shared.isWindowVisible {
            SettingsWindowController.shared.showWindow(page: "gateway")
        }
        showAgentRulesManualSheet = true
    }

    func presentDeferredAgentRulesSheetIfNeeded() {
        guard pendingAgentRulesManualSheet else { return }
        pendingAgentRulesManualSheet = false
        DispatchQueue.main.async {
            self.showAgentRulesManualSheet = true
        }
    }

    func copyAgentRulesMarkdownToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(GatewayAgentRulesSyncer.renderManagedBlock(), forType: .string)
        if prefs.showHUDNotifications {
            HUDWindowController.shared.show(
                title: "已复制 Agent 协作规范",
                subtitle: "可直接粘贴至您的全局 CLAUDE.md 或 AGENTS.md",
                symbolName: "doc.on.doc.fill"
            )
        }
    }

    private func syncClaudeAgentHook(enabled: Bool) {
        guard let guardBin = resolveGuardBinaryURL()?.path else { return }
        let claudeDir = URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        let settingsFile = claudeDir.appendingPathComponent("settings.json")
        let fm = FileManager.default

        if !enabled && !fm.fileExists(atPath: settingsFile.path) {
            return
        }

        var root: [String: Any] = [:]
        if let raw = try? Data(contentsOf: settingsFile),
           let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            root = parsed
        } else if !enabled {
            return
        }

        let marker = "deskside-guard\" agent-hook"
        let cmdLine = "\"\(guardBin)\" agent-hook --state-dir \"\(guardStateDirURL.path)\""

        var hooksDict = (root["hooks"] as? [String: Any]) ?? [:]
        var preToolList = (hooksDict["PreToolUse"] as? [[String: Any]]) ?? []
        preToolList.removeAll { item in
            guard let innerHooks = item["hooks"] as? [[String: Any]] else { return false }
            return innerHooks.contains { ($0["command"] as? String)?.contains("deskside-guard") == true }
        }

        if enabled {
            let entry: [String: Any] = [
                "matcher": "Bash|Edit|Write|MultiEdit",
                "hooks": [
                    [
                        "type": "command",
                        "command": cmdLine
                    ]
                ]
            ]
            _ = marker
            preToolList.append(entry)
        }

        if preToolList.isEmpty {
            hooksDict.removeValue(forKey: "PreToolUse")
        } else {
            hooksDict["PreToolUse"] = preToolList
        }
        if hooksDict.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooksDict
        }

        do {
            try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: settingsFile, options: .atomic)
        } catch {
            errorMessage = "更新 ~/.claude/settings.json 钩子失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Config, Allowlist, Secrets Sync & Diagnostics

    func updateConfig(_ mutate: (inout GatewayConfig) -> Void) {
        var next = config
        mutate(&next)
        config = next

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isDaemonRunning {
                if let body = try? Self.jsonEncoder.encode(next),
                   let resp = self.unixRequestSync(method: "PUT", path: "/v1/config", body: body),
                   resp.status == 200,
                   let updated = try? Self.jsonDecoder.decode(GatewayConfig.self, from: resp.body) {
                    DispatchQueue.main.async {
                        self.config = updated
                        if self.prefs.selectedTier == .surge {
                            self.writeSurgeArtifacts(enabled: true)
                            self.linkSGModuleIntoSurgeFolderIfPossible()
                        } else if self.prefs.selectedTier == .mitmproxy {
                            self.startMitmproxyHelper()
                        }
                        if !updated.syncEnvSecrets {
                            self.syncEnvSecretsToDaemon()
                        } else {
                            self.syncEnvSecretsToDaemon()
                        }
                    }
                    return
                }
            }
            // Persist directly to config.json when daemon is stopped.
            try? FileManager.default.createDirectory(at: self.guardStateDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let cfgPath = self.guardStateDirURL.appendingPathComponent("config.json")
            if let data = try? Self.jsonEncoder.encode(next) {
                try? data.write(to: cfgPath, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cfgPath.path)
            }
        }
    }

    func addFingerprintToAllowlist(from event: GatewayAuditEvent) {
        guard !event.fingerprint.isEmpty else { return }
        if config.allowlist.contains(where: { $0.kind == "fingerprint" && $0.value == event.fingerprint }) {
            return
        }
        updateConfig { cfg in
            cfg.allowlist.append(GatewayAllowlistEntry(
                kind: "fingerprint",
                value: event.fingerprint,
                note: "\(event.ruleName) (\(event.maskedPreview))"
            ))
        }
        HUDWindowController.shared.show(
            title: "已加入指纹白名单",
            subtitle: "\(event.ruleName) · \(event.maskedPreview)",
            symbolName: "checkmark.circle.fill"
        )
    }

    func removeAllowlistEntry(id: String) {
        updateConfig { cfg in
            cfg.allowlist.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func addAllowlistBatch(rawText: String) -> (added: Int, repaired: Int, skippedDuplicates: Int) {
        var outcome = (added: 0, repaired: 0, skippedDuplicates: 0)
        updateConfig { cfg in
            outcome = GatewayAllowlistBatchParser.mergeIntoAllowlist(&cfg.allowlist, rawText: rawText)
        }
        if outcome.added > 0 || outcome.repaired > 0 {
            var details: [String] = []
            if outcome.added > 0 {
                details.append("新增 \(outcome.added) 条")
            }
            if outcome.repaired > 0 {
                details.append("修正 \(outcome.repaired) 条指纹类型")
            }
            if outcome.skippedDuplicates > 0 {
                details.append("跳过重复 \(outcome.skippedDuplicates) 条")
            }
            HUDWindowController.shared.show(
                title: "已更新豁免白名单",
                subtitle: details.joined(separator: " · "),
                symbolName: "checkmark.circle.fill"
            )
        }
        return outcome
    }

    func syncEnvSecretsToDaemon() {
        guard isDaemonRunning else { return }
        let entries = EnvManager.shared.entries
        let shouldSync = config.syncEnvSecrets

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            var inputs: [GatewayKnownSecretInput] = []
            if shouldSync {
                for entry in entries where entry.isEnabled && entry.kind == .secret {
                    let val = EnvManager.shared.resolvedValue(for: entry)
                    if !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        inputs.append(GatewayKnownSecretInput(name: entry.name, value: val))
                    }
                }
            }
            let payload = ["secrets": inputs]
            if let body = try? Self.jsonEncoder.encode(payload) {
                _ = self.unixRequestSync(method: "POST", path: "/v1/secrets/sync", body: body)
                if let st = self.fetchStatusSync() {
                    DispatchQueue.main.async {
                        self.daemonStatus = st
                    }
                }
            }
        }
    }

    func clearAuditEvents() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isDaemonRunning {
                _ = self.unixRequestSync(method: "DELETE", path: "/v1/events", body: nil)
            } else {
                try? FileManager.default.removeItem(at: self.guardStateDirURL.appendingPathComponent("audit.jsonl"))
            }
            DispatchQueue.main.async {
                self.events = []
                self.stats = GatewayDailyStats()
            }
        }
    }

    func runDiagnosticSelfTest() {
        guard isDaemonRunning else {
            errorMessage = "请先启动安全网关后再执行端到端自检。"
            return
        }
        isBusy = true
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let resp = self.unixRequestSync(method: "POST", path: "/v1/self-test", body: Data("{}".utf8))
            var result: GatewaySelfTestResult? = nil
            if let resp = resp, resp.status == 200 {
                result = try? Self.jsonDecoder.decode(GatewaySelfTestResult.self, from: resp.body)
            }
            let evPayload = self.fetchEventsSync(limit: 120)
            DispatchQueue.main.async {
                self.isBusy = false
                self.lastSelfTest = result
                if let evPayload = evPayload {
                    self.events = evPayload.events
                    self.stats = evPayload.stats
                }
                if let r = result {
                    HUDWindowController.shared.show(
                        title: r.passed ? "安全网关自检通过" : "安全网关自检异常",
                        subtitle: r.message,
                        symbolName: r.passed ? "checkmark.shield.fill" : "exclamationmark.triangle.fill"
                    )
                }
            }
        }
    }

    func refreshDashboard() {
        refreshEnvironmentCapabilities()
        guard prefs.isEnabled || isDaemonRunning else { return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let st = self.fetchStatusSync()
            let ev = self.fetchEventsSync(limit: 120)
            DispatchQueue.main.async {
                self.daemonStatus = st
                self.isDaemonRunning = (st != nil)
                if let ev = ev {
                    self.events = ev.events
                    self.stats = ev.stats
                }
            }
        }
    }

    func setShowHUDNotifications(_ show: Bool) {
        prefs.showHUDNotifications = show
        savePreferencesToDisk()
    }

    // MARK: - Environment Probing

    func refreshEnvironmentCapabilities() {
        let fm = FileManager.default
        let surgeExists = fm.fileExists(atPath: "/Applications/Surge.app")
        let mitmPath = findMitmproxyExecutable()

        let currentGitHooks = runCommandOutput("/usr/bin/git", ["config", "--global", "--get", "core.hooksPath"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gitMounted = (currentGitHooks == gitHooksDirURL.path)
            && fm.isExecutableFile(atPath: gitHooksDirURL.appendingPathComponent("pre-push").path)

        let caPath = guardStateDirURL.appendingPathComponent("ca-cert.pem").path
        var caTrusted = false
        if fm.fileExists(atPath: caPath) {
            let verifyProc = Process()
            verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            verifyProc.arguments = ["verify-cert", "-c", caPath]
            verifyProc.standardOutput = FileHandle.nullDevice
            verifyProc.standardError = FileHandle.nullDevice
            try? verifyProc.run()
            verifyProc.waitUntilExit()
            caTrusted = (verifyProc.terminationStatus == 0)
        }

        let discoveredAgentTargets = GatewayAgentRulesSyncer.discoverTargets(homeDirectory: homeDirectory, fileManager: fm)

        let assign = {
            self.hasSurgeInstalled = surgeExists
            self.detectedMitmproxyPath = mitmPath
            self.isGitHookMounted = gitMounted
            self.isCACertTrusted = caTrusted
            self.agentRuleTargets = discoveredAgentTargets
        }
        if Thread.isMainThread {
            assign()
        } else {
            DispatchQueue.main.async(execute: assign)
        }
    }

    private func findMitmproxyExecutable() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let saved = prefs.mitmproxyBinaryPath, !saved.isEmpty {
            candidates.append(saved)
        }
        candidates.append(contentsOf: [
            managedMitmproxyDirURL.appendingPathComponent("mitmproxy.app/Contents/MacOS/mitmdump").path,
            managedMitmproxyDirURL.appendingPathComponent("mitmdump").path,
            "/Applications/mitmproxy.app/Contents/MacOS/mitmdump",
            "/opt/homebrew/bin/mitmdump",
            "/usr/local/bin/mitmdump"
        ])
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func resolveGuardBinaryURL() -> URL? {
        let fm = FileManager.default
        if let bundleExec = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("deskside-guard"),
           fm.isExecutableFile(atPath: bundleExec.path) {
            return bundleExec
        }
        let fallback = URL(fileURLWithPath: "/Applications/DeskSide.app/Contents/MacOS/deskside-guard")
        if fm.isExecutableFile(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    private func activeNetworkServices() -> [String] {
        guard let out = runCommandOutput("/usr/sbin/networksetup", ["-listallnetworkservices"]) else {
            return []
        }
        var result: [String] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("An asterisk") || trimmed.hasPrefix("*") {
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    private func runCommandOutput(_ launchPath: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Local Preferences Persistence

    private func loadPreferencesFromDisk() {
        guard let data = try? Data(contentsOf: preferencesFileURL),
              let decoded = try? JSONDecoder().decode(GatewayLocalPreferences.self, from: data) else {
            return
        }
        self.prefs = decoded
    }

    private func savePreferencesToDisk() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportDirURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Self.jsonEncoder.encode(prefs) {
            try? data.write(to: preferencesFileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesFileURL.path)
        }
    }

    private func loadCachedGuardConfigIfPresent() {
        let cfgURL = guardStateDirURL.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfgURL),
           let decoded = try? Self.jsonDecoder.decode(GatewayConfig.self, from: data) {
            self.config = decoded
        }
    }

    // MARK: - Unix Domain Socket Client & Live SSE Push Listener

    private func adminSocketPath() -> String {
        let direct = guardStateDirURL.appendingPathComponent("admin.sock").path
        if direct.utf8.count <= 96 {
            return direct
        }
        let clean = (guardStateDirURL.path as NSString).standardizingPath
        let digest = SHA256.hash(data: Data(clean.utf8))
        let hexPrefix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "/tmp/dg-\(getuid())-\(hexPrefix).sock"
    }

    private func connectUnixSocket(timeoutMs: Int32 = 1500) -> Int32 {
        let sockPath = adminSocketPath()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(sockPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return -1
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for i in 0..<pathBytes.count {
                    dst[i] = pathBytes[i]
                }
            }
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard res == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func unixRequestSync(method: String, path: String, body: Data?) -> (status: Int, body: Data)? {
        let fd = connectUnixSocket(timeoutMs: 2500)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let bodyBytes = body ?? Data()
        var header = "\(method) \(path) HTTP/1.1\r\nHost: unix\r\nConnection: close\r\n"
        if !bodyBytes.isEmpty {
            header += "Content-Type: application/json\r\nContent-Length: \(bodyBytes.count)\r\n"
        }
        header += "\r\n"

        var reqPacket = Data(header.utf8)
        reqPacket.append(bodyBytes)

        let wroteAll = reqPacket.withUnsafeBytes { rawBuf -> Bool in
            guard let base = rawBuf.baseAddress else { return true }
            var sent = 0
            while sent < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: sent), rawBuf.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
        guard wroteAll else { return nil }

        var rawResp = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                rawResp.append(buf, count: n)
            } else {
                break
            }
        }

        guard let sepRange = rawResp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let hdrData = rawResp.subdata(in: 0..<sepRange.lowerBound)
        let respBody = rawResp.subdata(in: sepRange.upperBound..<rawResp.count)
        guard let hdrStr = String(data: hdrData, encoding: .utf8),
              let firstLine = hdrStr.split(separator: "\r\n").first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
        return (code, respBody)
    }

    private func fetchStatusSync() -> GatewayDaemonStatus? {
        guard let resp = unixRequestSync(method: "GET", path: "/v1/status", body: nil),
              resp.status == 200 else {
            return nil
        }
        return try? Self.jsonDecoder.decode(GatewayDaemonStatus.self, from: resp.body)
    }

    private func fetchConfigSync() -> GatewayConfig? {
        guard let resp = unixRequestSync(method: "GET", path: "/v1/config", body: nil),
              resp.status == 200 else {
            return nil
        }
        return try? Self.jsonDecoder.decode(GatewayConfig.self, from: resp.body)
    }

    private func fetchEventsSync(limit: Int) -> GatewayEventsPayload? {
        guard let resp = unixRequestSync(method: "GET", path: "/v1/events?limit=\(limit)", body: nil),
              resp.status == 200 else {
            return nil
        }
        return try? Self.jsonDecoder.decode(GatewayEventsPayload.self, from: resp.body)
    }

    private func startStatusPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            self?.refreshDashboard()
        }
    }

    private func startSSEStream() {
        stopSSEStream()
        sseActive = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            while self.sseActive {
                let fd = self.connectUnixSocket(timeoutMs: 0) // blocking stream read
                if fd < 0 {
                    usleep(800_000)
                    continue
                }
                var zeroTv = timeval(tv_sec: 0, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zeroTv, socklen_t(MemoryLayout<timeval>.size))
                self.sseSocketFD = fd

                let req = "GET /v1/events/stream HTTP/1.1\r\nHost: unix\r\nAccept: text/event-stream\r\n\r\n"
                _ = req.withCString { ptr in
                    Darwin.write(fd, ptr, strlen(ptr))
                }

                var lineBuf = Data()
                var readChunk = [UInt8](repeating: 0, count: 4096)
                while self.sseActive {
                    let n = Darwin.read(fd, &readChunk, readChunk.count)
                    if n <= 0 { break }
                    lineBuf.append(readChunk, count: n)

                    while let nl = lineBuf.firstIndex(of: 0x0A) {
                        let lineData = lineBuf.subdata(in: 0..<nl)
                        lineBuf.removeSubrange(0...nl)
                        guard let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              line.hasPrefix("data:") else {
                            continue
                        }
                        let jsonStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if let evData = jsonStr.data(using: .utf8),
                           let ev = try? Self.jsonDecoder.decode(GatewayAuditEvent.self, from: evData) {
                            DispatchQueue.main.async {
                                self.handleIncomingLiveEvent(ev)
                            }
                        }
                    }
                }
                close(fd)
                if self.sseSocketFD == fd {
                    self.sseSocketFD = -1
                }
                if self.sseActive {
                    usleep(500_000)
                }
            }
        }
    }

    private func stopSSEStream() {
        sseActive = false
        let fd = sseSocketFD
        sseSocketFD = -1
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func handleIncomingLiveEvent(_ ev: GatewayAuditEvent) {
        if !events.contains(where: { $0.id == ev.id }) {
            events.insert(ev, at: 0)
            if events.count > 200 {
                events.removeLast(events.count - 200)
            }
        }
        if ev.action == "masked" {
            stats.maskedCount += ev.count
        } else if ev.action == "blocked" {
            stats.blockedCount += ev.count
            if ev.channel == "git" {
                stats.gitBlockedCount += ev.count
            }
        }

        guard prefs.showHUDNotifications, ev.channel != "self-test" else { return }
        if ev.isBlocked {
            HUDWindowController.shared.show(
                title: "已拦截密钥外泄 (\(ev.channelLabel))",
                subtitle: "\(ev.ruleName) · \(ev.maskedPreview)",
                symbolName: "exclamationmark.shield.fill",
                duration: 2.6
            )
        } else {
            HUDWindowController.shared.show(
                title: "已无感脱敏并还原密钥",
                subtitle: "\(ev.client) → \(ev.target) · \(ev.ruleName)",
                symbolName: "checkmark.shield.fill",
                duration: 2.0
            )
        }
    }
}
