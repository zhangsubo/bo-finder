import Cocoa
import Darwin

enum EnvError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let msg) = self { return msg }
        return nil
    }
}

enum EnvKeychainStore {
    static let service = EnvShellRenderer.defaultKeychainService

    static func accountName(for id: UUID) -> String {
        return "b64:\(id.uuidString)"
    }

    /// Writes a secret via Apple-signed `/usr/bin/security -i` (stdin mode) using Base64+Hex encoding.
    /// - Avoids exposing secrets in `ps` process arguments.
    /// - Ensures `/usr/bin/security` is the item's creator so zsh subshells read it without ACL popups.
    static func writeSecret(_ value: String, for id: UUID, labelName: String) throws {
        let base64 = Data(value.utf8).base64EncodedString()
        let hex = Data(base64.utf8).map { String(format: "%02x", $0) }.joined()
        let account = accountName(for: id)
        let safeLabel = labelName
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")

        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -l \"DeskSide Env: \(safeLabel)\" -X \"\(hex)\"\n"

        let proc = Process()
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["-i"]
        proc.standardInput = stdinPipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe

        try proc.run()
        if let cmdData = command.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: cmdData)
        }
        try? stdinPipe.fileHandleForWriting.close()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw EnvError.message("写入 macOS 钥匙串失败（状态码 \(proc.terminationStatus)）\(errText.isEmpty ? "" : "：\(errText)")")
        }
    }

    static func readSecret(for id: UUID) -> String? {
        let proc = Process()
        let stdoutPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "find-generic-password",
            "-w",
            "-a", accountName(for: id),
            "-s", service
        ]
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let rawB64 = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawB64.isEmpty, let decoded = Data(base64Encoded: rawB64) else {
                return rawB64
            }
            return String(data: decoded, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func deleteSecret(for id: UUID) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "delete-generic-password",
            "-a", accountName(for: id),
            "-s", service
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}

final class EnvManager: ObservableObject {
    static let shared = EnvManager()

    @Published private(set) var entries: [EnvEntry] = []
    @Published private(set) var settings: EnvSettings = EnvSettings()
    @Published private(set) var isZshrcMounted: Bool = false
    @Published private(set) var activeShellCount: Int = 0
    @Published private(set) var lastSyncedAt: Date?
    @Published var statusMessage: String = ""
    @Published var errorMessage: String = ""

    private var secretCache: [UUID: String] = [:]
    private let syncQueue = DispatchQueue(label: "com.bofinder.deskside.env-sync", qos: .userInitiated)

    let homeDirectory: String
    let storeDirectoryURL: URL
    let storeFileURL: URL
    let shellConfigDirectoryURL: URL
    let envZshURL: URL
    let loaderZshURL: URL
    let stampURL: URL
    let pidsDirectoryURL: URL
    let zshrcURL: URL
    let zshrcBackupURL: URL

    private init() {
        let home = PathFormatter.realHomeDirectory()
        self.homeDirectory = home

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (home as NSString).appendingPathComponent("Library/Application Support"))
        self.storeDirectoryURL = appSupport.appendingPathComponent("DeskSide/Env", isDirectory: true)
        self.storeFileURL = storeDirectoryURL.appendingPathComponent("store.json")

        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        self.shellConfigDirectoryURL = homeURL.appendingPathComponent(".config/deskside", isDirectory: true)
        self.envZshURL = shellConfigDirectoryURL.appendingPathComponent("env.zsh")
        self.loaderZshURL = shellConfigDirectoryURL.appendingPathComponent("loader.zsh")
        self.stampURL = shellConfigDirectoryURL.appendingPathComponent("env.stamp")
        self.pidsDirectoryURL = shellConfigDirectoryURL.appendingPathComponent("pids", isDirectory: true)
        self.zshrcURL = homeURL.appendingPathComponent(".zshrc")
        self.zshrcBackupURL = homeURL.appendingPathComponent(".zshrc.deskside-backup")

        loadFromDisk()
        refreshRuntimeStatus()
    }

    // MARK: - Lifecycle

    func activateOnLaunch() {
        refreshRuntimeStatus()
        guard !entries.isEmpty || isZshrcMounted else { return }
        do {
            try writeShellArtifacts(bumpStamp: false)
        } catch {
            // Non-fatal on launch
        }
        syncLaunchctlAsync()
    }

    func refreshRuntimeStatus() {
        let mounted = checkZshrcMounted()
        let count = inspectRegisteredShells(sendSignal: false)
        if Thread.isMainThread {
            self.isZshrcMounted = mounted
            self.activeShellCount = count
        } else {
            DispatchQueue.main.async {
                self.isZshrcMounted = mounted
                self.activeShellCount = count
            }
        }
    }

    // MARK: - Value & Secret Resolution

    func resolvedValue(for entry: EnvEntry) -> String {
        guard entry.kind == .secret && entry.useKeychain else {
            return entry.value
        }
        if let cached = secretCache[entry.id] {
            return cached
        }
        let fetched = EnvKeychainStore.readSecret(for: entry.id) ?? ""
        secretCache[entry.id] = fetched
        return fetched
    }

    func allGroups() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for g in EnvValidation.defaultGroups {
            seen.insert(g)
            result.append(g)
        }
        for entry in entries {
            let trimmed = entry.group.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                result.append(trimmed)
            }
        }
        return result
    }

    // MARK: - CRUD & Immediate Auto-Refresh

    @discardableResult
    func saveEntry(_ draft: EnvEntry, rawValue: String) -> Result<Void, Error> {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationError = EnvValidation.validateName(trimmedName, kind: draft.kind) {
            return .failure(EnvError.message(validationError))
        }

        if draft.kind == .alias && rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(EnvError.message("快捷别名的执行命令不能为空。"))
        }

        // Check duplicate in same namespace (alias vs export)
        let isAlias = draft.kind == .alias
        if entries.contains(where: { existing in
            existing.id != draft.id
                && (existing.kind == .alias) == isAlias
                && existing.name == trimmedName
        }) {
            let typeLabel = isAlias ? "快捷别名" : "环境变量"
            return .failure(EnvError.message("已存在同名\(typeLabel)「\(trimmedName)」，请直接编辑已有条目或换用其他名称。"))
        }

        let previous = entries.first(where: { $0.id == draft.id })
        let wantsKeychain = draft.kind == .secret && draft.useKeychain

        do {
            if wantsKeychain {
                try EnvKeychainStore.writeSecret(rawValue, for: draft.id, labelName: trimmedName)
                secretCache[draft.id] = rawValue
            } else {
                if previous?.useKeychain == true {
                    EnvKeychainStore.deleteSecret(for: draft.id)
                }
                secretCache.removeValue(forKey: draft.id)
            }

            let cleanGroup = draft.group.trimmingCharacters(in: .whitespacesAndNewlines)
            let updatedEntry = EnvEntry(
                id: draft.id,
                kind: draft.kind,
                name: trimmedName,
                value: wantsKeychain ? "" : rawValue,
                note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines),
                group: cleanGroup.isEmpty ? EnvValidation.inferGroup(name: trimmedName, kind: draft.kind) : cleanGroup,
                isEnabled: draft.isEnabled,
                useKeychain: wantsKeychain,
                allowExpansion: draft.kind == .variable ? draft.allowExpansion : false,
                syncToGUI: draft.kind == .alias ? false : draft.syncToGUI,
                updatedAt: Date()
            )

            if let idx = entries.firstIndex(where: { $0.id == updatedEntry.id }) {
                entries[idx] = updatedEntry
            } else {
                entries.append(updatedEntry)
            }

            try persistAndRefresh(
                reason: previous == nil ? "已新增 \(trimmedName)" : "已更新 \(trimmedName)",
                autoMountIfNeeded: settings.autoMountZshrc,
                showHUD: true
            )
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func setEntryEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard entries[idx].isEnabled != enabled else { return }
        entries[idx].isEnabled = enabled
        entries[idx].updatedAt = Date()
        let name = entries[idx].name
        do {
            try persistAndRefresh(
                reason: enabled ? "已启用 \(name)" : "已停用 \(name)",
                autoMountIfNeeded: settings.autoMountZshrc,
                showHUD: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteEntry(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let removed = entries.remove(at: idx)
        if removed.useKeychain {
            EnvKeychainStore.deleteSecret(for: removed.id)
        }
        secretCache.removeValue(forKey: removed.id)
        do {
            try persistAndRefresh(
                reason: "已删除 \(removed.name)",
                autoMountIfNeeded: false,
                showHUD: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func applyTemplate(_ template: EnvPresetTemplate) -> Int {
        var added = 0
        for item in template.entries {
            let isAlias = item.kind == .alias
            let exists = entries.contains {
                ($0.kind == .alias) == isAlias && $0.name == item.name
            }
            if !exists {
                var fresh = item
                fresh.id = UUID()
                fresh.updatedAt = Date()
                entries.append(fresh)
                added += 1
            }
        }
        guard added > 0 else {
            statusMessage = "模板中的条目均已存在，无需重复添加。"
            return 0
        }
        do {
            try persistAndRefresh(
                reason: "已添加 \(added) 项模板配置",
                autoMountIfNeeded: settings.autoMountZshrc,
                showHUD: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        return added
    }

    // MARK: - Import from ~/.zshrc / .env

    func scanConfigFile(at url: URL) throws -> [EnvImportedCandidate] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        let fileName = url.lastPathComponent.lowercased()
        let isDotEnv = fileName == ".env" || fileName.hasPrefix(".env.") || fileName.hasSuffix(".env")

        var existingKeys = Set<String>()
        for entry in entries {
            let prefix = entry.kind == .alias ? "alias" : "env"
            existingKeys.insert("\(prefix):\(entry.name)")
        }
        return EnvShellParser.parse(content: content, isDotEnv: isDotEnv, existingNames: existingKeys)
    }

    @discardableResult
    func importCandidates(_ candidates: [EnvImportedCandidate], overwriteExisting: Bool) -> Int {
        var importedCount = 0
        for candidate in candidates where candidate.selected {
            let incoming = candidate.entry
            let isAlias = incoming.kind == .alias
            if let existingIdx = entries.firstIndex(where: { ($0.kind == .alias) == isAlias && $0.name == incoming.name }) {
                guard overwriteExisting else { continue }
                let existing = entries[existingIdx]
                if existing.useKeychain {
                    EnvKeychainStore.deleteSecret(for: existing.id)
                    secretCache.removeValue(forKey: existing.id)
                }
                var merged = incoming
                merged.id = existing.id
                merged.updatedAt = Date()
                entries[existingIdx] = merged
                importedCount += 1
            } else {
                var fresh = incoming
                fresh.id = UUID()
                fresh.updatedAt = Date()
                entries.append(fresh)
                importedCount += 1
            }
        }

        guard importedCount > 0 else { return 0 }
        do {
            try persistAndRefresh(
                reason: "已导入 \(importedCount) 项配置",
                autoMountIfNeeded: settings.autoMountZshrc,
                showHUD: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        return importedCount
    }

    // MARK: - Settings & ~/.zshrc Mounting

    func updateSettings(_ mutate: (inout EnvSettings) -> Void) {
        mutate(&settings)
        do {
            try saveStoreJSON()
            syncLaunchctlAsync()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func mountToZshrc(showHUD: Bool = true) {
        do {
            try writeShellArtifacts(bumpStamp: true)
            try installZshrcBlockIfNeeded()
            isZshrcMounted = checkZshrcMounted()
            let count = inspectRegisteredShells(sendSignal: true)
            activeShellCount = count
            lastSyncedAt = Date()
            statusMessage = "已接入 ~/.zshrc 并生成自动刷新脚本"
            if showHUD {
                HUDWindowController.shared.show(
                    title: "已接入 ~/.zshrc 自动刷新",
                    subtitle: count > 0 ? "已联动 \(count) 个活动终端" : "新开终端自动生效，旧终端执行一次 source ~/.zshrc 即可实时联动",
                    symbolName: "checkmark.seal.fill"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unmountFromZshrc(showHUD: Bool = true) {
        do {
            if FileManager.default.fileExists(atPath: zshrcURL.path) {
                let current = try String(contentsOf: zshrcURL, encoding: .utf8)
                let cleaned = ZshrcBlockManager.removingBlock(from: current)
                try cleaned.write(to: zshrcURL, atomically: true, encoding: .utf8)
            }
            settings.autoMountZshrc = false
            try saveStoreJSON()
            isZshrcMounted = checkZshrcMounted()
            statusMessage = "已从 ~/.zshrc 移除自动加载区块（托管条目仍保留在 DeskSide）"
            if showHUD {
                HUDWindowController.shared.show(
                    title: "已移除 ~/.zshrc 挂载区块",
                    subtitle: "原有 ~/.zshrc 其他配置保持不变",
                    symbolName: "link.badge.plus"
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func triggerManualRefresh(showHUD: Bool = true) {
        do {
            try persistAndRefresh(
                reason: "手动同步刷新",
                autoMountIfNeeded: settings.autoMountZshrc && !entries.isEmpty,
                showHUD: showHUD
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renderedEnvScriptPreview(maskSecrets: Bool) -> String {
        if !maskSecrets {
            var resolved: [UUID: String] = [:]
            for e in entries where e.isEnabled {
                resolved[e.id] = resolvedValue(for: e)
            }
            return EnvShellRenderer.renderEnvZsh(entries: entries, resolvedValues: resolved)
        }

        var previewEntries: [EnvEntry] = []
        var previewValues: [UUID: String] = [:]
        for var e in entries {
            if e.kind == .secret {
                e.useKeychain = false
                previewValues[e.id] = "••••••••"
            } else {
                previewValues[e.id] = e.value
            }
            previewEntries.append(e)
        }
        return EnvShellRenderer.renderEnvZsh(entries: previewEntries, resolvedValues: previewValues)
    }

    // MARK: - Copy Helpers

    func copyEntryValue(_ entry: EnvEntry) {
        let val = resolvedValue(for: entry)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(val, forType: .string)
        let label = entry.kind == .secret ? "已复制密钥值：\(entry.name)" : "已复制：\(entry.name)"
        statusMessage = label
        if settings.showHUDOnRefresh {
            HUDWindowController.shared.show(
                title: label,
                subtitle: entry.kind == .secret ? "敏感内容已复制到剪贴板" : val,
                symbolName: "doc.on.clipboard"
            )
        }
    }

    func copyEntryShellCommand(_ entry: EnvEntry) {
        let val = resolvedValue(for: entry)
        let cmd: String
        if entry.kind == .secret {
            // Copy ready-to-paste export statement with literal single-quoted value
            cmd = "export \(entry.name)=\(EnvShellRenderer.singleQuote(val))"
        } else {
            cmd = EnvShellRenderer.renderEntryCommand(entry, resolvedValue: val, maskSecret: false)
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cmd, forType: .string)
        statusMessage = "已复制终端语句：\(entry.name)"
        if settings.showHUDOnRefresh {
            HUDWindowController.shared.show(
                title: "已复制终端语句",
                subtitle: entry.kind == .secret ? "export \(entry.name)='••••••••'" : cmd,
                symbolName: "terminal"
            )
        }
    }

    // MARK: - Core Persistence & Live Refresh Engine

    private func loadFromDisk() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeFileURL)
            let store = try JSONDecoder().decode(EnvStoreData.self, from: data)
            self.entries = store.entries
            self.settings = store.settings

            // Preload Keychain-backed secrets asynchronously so UI stays snappy
            let keychainIDs = store.entries.filter { $0.kind == .secret && $0.useKeychain }.map(\.id)
            if !keychainIDs.isEmpty {
                syncQueue.async { [weak self] in
                    var loaded: [UUID: String] = [:]
                    for id in keychainIDs {
                        if let secret = EnvKeychainStore.readSecret(for: id) {
                            loaded[id] = secret
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        for (k, v) in loaded where self.secretCache[k] == nil {
                            self.secretCache[k] = v
                        }
                    }
                }
            }
        } catch {
            self.errorMessage = "读取环境变量存储失败：\(error.localizedDescription)"
        }
    }

    private func saveStoreJSON() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDirectoryURL.path)

        var sanitizedEntries: [EnvEntry] = []
        for var entry in entries {
            if entry.kind == .secret && entry.useKeychain {
                entry.value = ""
            }
            sanitizedEntries.append(entry)
        }

        let payload = EnvStoreData(version: 1, settings: settings, entries: sanitizedEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: storeFileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeFileURL.path)
    }

    private func writeShellArtifacts(bumpStamp: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: shellConfigDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shellConfigDirectoryURL.path)
        try fm.createDirectory(at: pidsDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pidsDirectoryURL.path)

        var resolvedMap: [UUID: String] = [:]
        for entry in entries where entry.isEnabled && !(entry.kind == .secret && entry.useKeychain) {
            resolvedMap[entry.id] = entry.value
        }

        let envScript = EnvShellRenderer.renderEnvZsh(entries: entries, resolvedValues: resolvedMap)
        try Data(envScript.utf8).write(to: envZshURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envZshURL.path)

        let loaderScript = EnvShellRenderer.renderLoaderZsh()
        try Data(loaderScript.utf8).write(to: loaderZshURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: loaderZshURL.path)

        if bumpStamp || !fm.fileExists(atPath: stampURL.path) {
            let stamp = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8))\n"
            try Data(stamp.utf8).write(to: stampURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stampURL.path)
        }
    }

    private func checkZshrcMounted() -> Bool {
        guard FileManager.default.fileExists(atPath: zshrcURL.path),
              let content = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
            return false
        }
        return ZshrcBlockManager.isMounted(in: content)
    }

    private func installZshrcBlockIfNeeded() throws {
        let fm = FileManager.default
        var existingContent = ""
        if fm.fileExists(atPath: zshrcURL.path) {
            existingContent = try String(contentsOf: zshrcURL, encoding: .utf8)
            if ZshrcBlockManager.isMounted(in: existingContent) {
                return
            }
            // Create a one-time backup of original ~/.zshrc before first modification
            if !fm.fileExists(atPath: zshrcBackupURL.path) {
                try? fm.copyItem(at: zshrcURL, to: zshrcBackupURL)
            }
        }
        let updated = ZshrcBlockManager.installingBlock(into: existingContent)
        try updated.write(to: zshrcURL, atomically: true, encoding: .utf8)
    }

    private func persistAndRefresh(
        reason: String,
        autoMountIfNeeded: Bool,
        showHUD: Bool
    ) throws {
        errorMessage = ""
        try saveStoreJSON()
        try writeShellArtifacts(bumpStamp: true)

        if autoMountIfNeeded {
            try installZshrcBlockIfNeeded()
        }

        isZshrcMounted = checkZshrcMounted()
        let refreshedShells = inspectRegisteredShells(sendSignal: true)
        activeShellCount = refreshedShells
        let now = Date()
        lastSyncedAt = now

        syncLaunchctlAsync()

        let shellDesc = refreshedShells > 0
            ? "已实时刷新 \(refreshedShells) 个活动终端"
            : (isZshrcMounted ? "已更新配置并同步系统环境" : "已保存至托管文件")
        statusMessage = "\(reason) · \(shellDesc)"

        if showHUD && settings.showHUDOnRefresh {
            HUDWindowController.shared.show(
                title: "环境变量已自动刷新",
                subtitle: "\(reason) · \(shellDesc)",
                symbolName: "arrow.triangle.2.circlepath.circle.fill"
            )
        }
    }

    /// Inspects `~/.config/deskside/pids/` and optionally sends `SIGUSR1` to verified interactive zsh processes.
    /// Uses `proc_pidinfo(PROC_PIDTBSDINFO)` to confirm process identity and start time before signaling.
    private func inspectRegisteredShells(sendSignal: Bool) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: pidsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let selfPid = getpid()
        var liveCount = 0

        for fileURL in items {
            guard let pidVal = Int32(fileURL.lastPathComponent), pidVal > 1, pidVal != selfPid else {
                try? fm.removeItem(at: fileURL)
                continue
            }

            if kill(pidVal, 0) != 0 {
                if errno == ESRCH {
                    try? fm.removeItem(at: fileURL)
                }
                continue
            }

            var bsdInfo = proc_bsdinfo()
            let infoSize = proc_pidinfo(
                pidVal,
                PROC_PIDTBSDINFO,
                0,
                &bsdInfo,
                Int32(MemoryLayout<proc_bsdinfo>.stride)
            )
            guard infoSize == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
                try? fm.removeItem(at: fileURL)
                continue
            }

            let comm = withUnsafePointer(to: &bsdInfo.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            guard comm == "zsh" || comm == "-zsh" else {
                try? fm.removeItem(at: fileURL)
                continue
            }

            if let vals = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = vals.contentModificationDate {
                let pidStartSec = Double(bsdInfo.pbi_start_tvsec)
                // If process started well after the PID file was written, the PID was recycled
                if pidStartSec > modDate.timeIntervalSince1970 + 10.0 {
                    try? fm.removeItem(at: fileURL)
                    continue
                }
            }

            liveCount += 1
            if sendSignal {
                _ = kill(pidVal, SIGUSR1)
            }
        }

        return liveCount
    }

    private func syncLaunchctlAsync() {
        let entriesSnapshot = entries
        let shouldSync = settings.syncLaunchctl
        let previousKeys = Set(settings.lastSyncedGUIKeys)
        let home = homeDirectory

        syncQueue.async { [weak self] in
            guard let self = self else { return }

            var desired: [String: String] = [:]
            var workingEnv = ProcessInfo.processInfo.environment

            if shouldSync {
                // Reverse iterate or preserve top-to-bottom order so later entries can reference earlier ones
                for entry in entriesSnapshot where entry.isEnabled && entry.kind != .alias && entry.syncToGUI {
                    let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Never overwrite system PATH via launchctl setenv to avoid breaking login shell path_helper
                    guard key != "PATH", EnvValidation.validateName(key, kind: entry.kind) == nil else {
                        continue
                    }
                    let rawVal: String
                    if entry.kind == .secret && entry.useKeychain {
                        rawVal = EnvKeychainStore.readSecret(for: entry.id) ?? ""
                    } else {
                        rawVal = entry.value
                    }
                    let finalVal = entry.allowExpansion
                        ? EnvShellRenderer.expandForGUI(rawVal, homeDirectory: home, environment: workingEnv)
                        : rawVal
                    desired[key] = finalVal
                    workingEnv[key] = finalVal
                }
            }

            let staleKeys = previousKeys.subtracting(desired.keys)
            for key in staleKeys where !EnvValidation.protectedFromUnset.contains(key) {
                Self.runLaunchctl(["unsetenv", key])
                unsetenv(key)
            }

            for (key, value) in desired {
                Self.runLaunchctl(["setenv", key, value])
                setenv(key, value, 1)
            }

            let syncedList = Array(desired.keys).sorted()
            DispatchQueue.main.async {
                if self.settings.lastSyncedGUIKeys != syncedList {
                    self.settings.lastSyncedGUIKeys = syncedList
                    try? self.saveStoreJSON()
                }
            }
        }
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
