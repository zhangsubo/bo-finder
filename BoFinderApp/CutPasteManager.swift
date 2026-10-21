import Cocoa
import Combine
import ApplicationServices

final class CutPasteManager: ObservableObject {
    static let shared = CutPasteManager()

    @Published private(set) var state: SharedRuntimeState
    @Published var lastCopiedText: String = ""
    @Published var lastCopiedFormat: PathFormat?
    @Published var statusMessage: String = "就绪"

    /// Tracks the pasteboard changeCount at the moment Cut was activated.
    private(set) var cutPasteboardChangeCount: Int?
    /// Indicates whether Finder itself placed the file items onto NSPasteboard (so ⌥+⌘+V works natively).
    private(set) var isNativeFinderClipboardCut: Bool = false

    private var clipboardMonitorTimer: Timer?
    private var lastActionPasteboardCount: Int = NSPasteboard(name: BoFinderIPC.actionPasteboardName).changeCount
    var onStateUpdated: (() -> Void)?

    private init() {
        var loaded = BoFinderIPC.loadState()
        // Reset ephemeral cut state on fresh app launch
        loaded.isCutActive = false
        loaded.cutFilePaths = []
        loaded.updatedAt = Date().timeIntervalSince1970
        self.state = loaded

        setupIPCObservers()
        startClipboardMonitor()
        BoFinderIPC.saveAndBroadcastState(loaded)
    }

    private func setupIPCObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleExtensionActionNotification(_:)),
            name: BoFinderIPC.extensionActionNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleRequestStateNotification(_:)),
            name: BoFinderIPC.requestStateNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func startClipboardMonitor() {
        clipboardMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Check if extension posted a new action via shared action pasteboard
            let actionPB = NSPasteboard(name: BoFinderIPC.actionPasteboardName)
            if actionPB.changeCount != self.lastActionPasteboardCount {
                self.lastActionPasteboardCount = actionPB.changeCount
                if let payload = BoFinderIPC.decodeExtensionAction(from: nil) {
                    self.processExtensionAction(payload)
                }
            }
        }
    }

    @objc private func handleRequestStateNotification(_ notification: Notification) {
        BoFinderIPC.saveAndBroadcastState(state)
    }

    @objc private func handleExtensionActionNotification(_ notification: Notification) {
        let actionPB = NSPasteboard(name: BoFinderIPC.actionPasteboardName)
        guard actionPB.changeCount != lastActionPasteboardCount else {
            return
        }
        lastActionPasteboardCount = actionPB.changeCount
        guard let payload = BoFinderIPC.decodeExtensionAction(from: notification.object) else {
            return
        }
        DispatchQueue.main.async {
            self.processExtensionAction(payload)
        }
    }

    func processExtensionAction(_ payload: ExtensionActionPayload) {
        switch payload.action {
        case .copyPath:
            let format = payload.format ?? .posix
            let text: String
            if let existing = payload.copiedText, !existing.isEmpty {
                text = existing
            } else {
                let urls = payload.selectedPaths.map { URL(fileURLWithPath: $0) }
                text = PathFormatter.format(urls: urls, as: format, windowsStyle: state.config.windowsPathStyle)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
            lastCopiedText = text
            lastCopiedFormat = format
            statusMessage = "已复制 \(format.shortTitle)"
            if state.config.playSoundOnAction {
                NSSound(named: "Tink")?.play()
            }
            if state.config.showHUDFeedback {
                HUDWindowController.shared.show(
                    title: "已复制 \(format.shortTitle)",
                    subtitle: text.replacingOccurrences(of: "\n", with: "  "),
                    symbolName: format.symbolName
                )
            }
            onStateUpdated?()

        case .cutItems:
            let urls = payload.selectedPaths.map { URL(fileURLWithPath: $0) }
            activateCutWithURLs(urls, fromNativeKeyboard: false)

        case .pasteMoveItems:
            if let targetDir = payload.targetDirectoryPath {
                performDirectMove(toDirectory: URL(fileURLWithPath: targetDir))
            }

        case .clearCut:
            clearCut(showHUD: true)

        case .contextMenuOpened:
            guard state.config.showTopQuickBarOnRightClick else { return }
            let urls = payload.selectedPaths.map { URL(fileURLWithPath: $0) }
            let folderURL = payload.targetDirectoryPath.map { URL(fileURLWithPath: $0) }
            let screenPt: NSPoint
            if let mx = payload.mouseX, let my = payload.mouseY {
                screenPt = NSPoint(x: mx, y: my)
            } else {
                screenPt = NSEvent.mouseLocation
            }
            CloudQuickBarController.shared.showAboveCursor(
                at: screenPt,
                selectedURLs: urls,
                folderURL: folderURL
            )
        }
    }

    // MARK: - Config Management

    func updateConfig(_ transform: (inout BoFinderConfig) -> Void) {
        var nextState = state
        transform(&nextState.config)
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState
        BoFinderIPC.saveAndBroadcastState(nextState)
        onStateUpdated?()
    }

    // MARK: - Cut & Paste Core

    func isValidCutActive() -> Bool {
        return state.isCutActive && !state.cutFilePaths.isEmpty
    }

    /// Called ~70ms after EventTapManager converts ⌘+X into ⌘+C in Finder (or reads selection directly).
    func handleCommandXTriggered(previousChangeCount: Int) {
        let pb = NSPasteboard.general
        var urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty {
            urls = FinderSelectionHelper.currentSelectionOrFolderURLs().selected
        }
        guard !urls.isEmpty else {
            return
        }

        var nextState = state
        nextState.isCutActive = true
        nextState.cutFilePaths = urls.map(\.path)
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState

        cutPasteboardChangeCount = pb.changeCount
        isNativeFinderClipboardCut = true

        BoFinderIPC.saveAndBroadcastState(nextState)
        statusMessage = "待剪切移动 (\(urls.count) 项)"

        if state.config.playSoundOnAction {
            NSSound(named: "Pop")?.play()
        }
        if state.config.showHUDFeedback {
            let subtitle = urls.count == 1
                ? "\(urls[0].lastPathComponent) · 按 ⌘+V 粘贴移动"
                : "共 \(urls.count) 个项目 · 按 ⌘+V 粘贴移动"
            HUDWindowController.shared.show(
                title: "已剪切 \(urls.count) 个项目",
                subtitle: subtitle,
                symbolName: "scissors"
            )
        }
        onStateUpdated?()
    }

    /// Called when user initiates Cut from Finder right-click menu or popup menu.
    func activateCutWithURLs(_ urls: [URL], fromNativeKeyboard: Bool) {
        guard !urls.isEmpty else { return }

        // Also write file URLs to NSPasteboard so Finder sees them
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])

        var nextState = state
        nextState.isCutActive = true
        nextState.cutFilePaths = urls.map(\.path)
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState

        cutPasteboardChangeCount = pb.changeCount
        isNativeFinderClipboardCut = fromNativeKeyboard

        BoFinderIPC.saveAndBroadcastState(nextState)
        statusMessage = "待剪切移动 (\(urls.count) 项)"

        if state.config.playSoundOnAction {
            NSSound(named: "Pop")?.play()
        }
        if state.config.showHUDFeedback {
            let subtitle = urls.count == 1
                ? "\(urls[0].lastPathComponent) · 按 ⌘+V 或右键粘贴移动"
                : "共 \(urls.count) 个项目 · 按 ⌘+V 或右键粘贴移动"
            HUDWindowController.shared.show(
                title: "已剪切 \(urls.count) 个项目",
                subtitle: subtitle,
                symbolName: "scissors"
            )
        }
        onStateUpdated?()
    }

    /// Called when ⌘+V is pressed in Finder while Cut mode is active.
    func handleCommandVTriggeredForNativeCut() {
        let count = state.cutFilePaths.count
        var nextState = state
        nextState.isCutActive = false
        nextState.cutFilePaths = []
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState
        cutPasteboardChangeCount = nil
        isNativeFinderClipboardCut = false

        BoFinderIPC.saveAndBroadcastState(nextState)
        statusMessage = "已移动 \(count) 个项目"

        if state.config.playSoundOnAction {
            NSSound(named: "Glass")?.play()
        }
        if state.config.showHUDFeedback && count > 0 {
            HUDWindowController.shared.show(
                title: "已粘贴移动 \(count) 个项目",
                subtitle: "已完成文件移动",
                symbolName: "arrow.right.doc.on.clipboard"
            )
        }
        onStateUpdated?()
    }

    /// Moves cut files directly into `targetDirectory` using FileManager (used by right-click "粘贴移动" and non-native cut fallback).
    func performDirectMove(toDirectory targetDirectory: URL) {
        let sourcePaths = state.cutFilePaths
        guard !sourcePaths.isEmpty else { return }

        let fm = FileManager.default
        var movedCount = 0
        var lastError: String?

        for srcPath in sourcePaths {
            let srcURL = URL(fileURLWithPath: srcPath)
            guard fm.fileExists(atPath: srcURL.path) else { continue }

            let srcParent = srcURL.deletingLastPathComponent().standardizedFileURL
            let dstDir = targetDirectory.standardizedFileURL
            if srcParent == dstDir {
                continue
            }

            var dstURL = dstDir.appendingPathComponent(srcURL.lastPathComponent)
            if fm.fileExists(atPath: dstURL.path) {
                let resolution = promptConflictResolution(fileName: srcURL.lastPathComponent, targetFolder: dstDir.lastPathComponent)
                switch resolution {
                case .skip:
                    continue
                case .replace:
                    do {
                        try fm.removeItem(at: dstURL)
                    } catch {
                        lastError = error.localizedDescription
                        continue
                    }
                case .keepBoth:
                    dstURL = uniqueDestinationURL(for: dstURL)
                }
            }

            do {
                try fm.moveItem(at: srcURL, to: dstURL)
                movedCount += 1
            } catch {
                lastError = error.localizedDescription
            }
        }

        var nextState = state
        nextState.isCutActive = false
        nextState.cutFilePaths = []
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState
        cutPasteboardChangeCount = nil
        isNativeFinderClipboardCut = false
        BoFinderIPC.saveAndBroadcastState(nextState)

        if movedCount > 0 {
            statusMessage = "已移动 \(movedCount) 个项目"
            if state.config.playSoundOnAction {
                NSSound(named: "Glass")?.play()
            }
            if state.config.showHUDFeedback {
                HUDWindowController.shared.show(
                    title: "已移动 \(movedCount) 个项目",
                    subtitle: "目标目录：\(targetDirectory.lastPathComponent)",
                    symbolName: "arrow.right.doc.on.clipboard"
                )
            }
        } else if let err = lastError {
            HUDWindowController.shared.show(
                title: "移动失败",
                subtitle: err,
                symbolName: "exclamationmark.triangle.fill"
            )
        } else {
            HUDWindowController.shared.show(
                title: "无需移动",
                subtitle: "源目录与目标目录相同",
                symbolName: "info.circle"
            )
        }
        onStateUpdated?()
    }

    func clearCut(showHUD: Bool) {
        guard state.isCutActive else { return }
        var nextState = state
        nextState.isCutActive = false
        nextState.cutFilePaths = []
        nextState.updatedAt = Date().timeIntervalSince1970
        state = nextState
        cutPasteboardChangeCount = nil
        isNativeFinderClipboardCut = false
        BoFinderIPC.saveAndBroadcastState(nextState)
        statusMessage = "已取消剪切"

        if showHUD && state.config.showHUDFeedback {
            HUDWindowController.shared.show(
                title: "已取消剪切状态",
                subtitle: nil,
                symbolName: "xmark.circle"
            )
        }
        onStateUpdated?()
    }

    private enum ConflictResolution {
        case keepBoth
        case replace
        case skip
    }

    private func promptConflictResolution(fileName: String, targetFolder: String) -> ConflictResolution {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "目标文件夹「\(targetFolder)」中已存在同名项目「\(fileName)」"
        alert.informativeText = "请选择如何处理此同名文件："
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "跳过")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .replace
        default:
            return .skip
        }
    }

    private func uniqueDestinationURL(for originalURL: URL) -> URL {
        let fm = FileManager.default
        let dir = originalURL.deletingLastPathComponent()
        let ext = originalURL.pathExtension
        let baseName = originalURL.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let newName = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            let candidate = dir.appendingPathComponent(newName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Finder Inspection Helpers

    /// Reads the current frontmost Finder target directory via Accessibility (including iCloud Drive root), with AppleScript & Desktop fallbacks.
    func frontmostFinderFolderURL() -> URL? {
        if let folder = FinderSelectionHelper.currentSelectionOrFolderURLs().currentFolder {
            return folder
        }

        // Fallback: query Finder insertion location via AppleScript
        if let script = NSAppleScript(source: "tell application \"Finder\" to get POSIX path of (insertion location as alias)") {
            var errDict: NSDictionary?
            let desc = script.executeAndReturnError(&errDict)
            if let path = desc.stringValue, !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }

        // Final fallback: Desktop directory
        let desktopPath = (PathFormatter.realHomeDirectory() as NSString).appendingPathComponent("Desktop")
        return URL(fileURLWithPath: desktopPath)
    }
}
