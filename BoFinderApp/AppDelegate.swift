import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        CutPasteManager.shared.onStateUpdated = { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusItemAppearance()
            }
        }

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Register FinderSync plugin
        FinderExtensionDoctor.shared.registerAndEnableOurExtension()

        // Check Accessibility permission for ⌘+X / ⌘+V event tap
        EventTapManager.shared.checkPermissionAndStartIfPossible(promptIfNeeded: true)

        updateStatusItemAppearance()

        HUDWindowController.shared.show(
            title: "BoFinder 已启动",
            subtitle: "Finder 右键复制路径与 ⌘+X / ⌘+V 剪切已就绪",
            symbolName: "sparkles"
        )

        if !EventTapManager.shared.isAccessibilityTrusted {
            SettingsWindowController.shared.showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.showWindow()
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let state = CutPasteManager.shared.state

        if state.isCutActive && !state.cutFilePaths.isEmpty {
            let img = NSImage(systemSymbolName: "scissors", accessibilityDescription: "BoFinder Cut Active")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
            button.title = " \(state.cutFilePaths.count)"
        } else {
            let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "BoFinder")
            img?.isTemplate = true
            button.image = img
            button.title = ""
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let manager = CutPasteManager.shared
        let state = manager.state
        let eventTap = EventTapManager.shared

        // Header status
        let headerTitle = eventTap.isAccessibilityTrusted
            ? "BoFinder · 运行中"
            : "BoFinder · 需开启辅助功能权限"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if !eventTap.isAccessibilityTrusted {
            let authItem = NSMenuItem(
                title: "⚠️ 点击开启辅助功能权限 (支持 ⌘+X / ⌘+V)...",
                action: #selector(requestAccessibilityPermission(_:)),
                keyEquivalent: ""
            )
            authItem.target = self
            menu.addItem(authItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Active Cut Section
        if state.isCutActive && !state.cutFilePaths.isEmpty {
            let cutHeader = NSMenuItem(
                title: "✂️ 待剪切移动 (\(state.cutFilePaths.count) 个项目)",
                action: nil,
                keyEquivalent: ""
            )
            cutHeader.isEnabled = false
            menu.addItem(cutHeader)

            for path in state.cutFilePaths.prefix(3) {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let fileItem = NSMenuItem(title: "    • \(name)", action: nil, keyEquivalent: "")
                fileItem.isEnabled = false
                menu.addItem(fileItem)
            }
            if state.cutFilePaths.count > 3 {
                let moreItem = NSMenuItem(title: "    • ... 等共 \(state.cutFilePaths.count) 项", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                menu.addItem(moreItem)
            }

            if let frontFolder = manager.frontmostFinderFolderURL() {
                let moveNowItem = NSMenuItem(
                    title: "粘贴移动至当前 Finder 窗口「\(frontFolder.lastPathComponent)」",
                    action: #selector(moveCutItemsToFrontmostFinder(_:)),
                    keyEquivalent: ""
                )
                moveNowItem.target = self
                moveNowItem.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard", accessibilityDescription: nil)
                menu.addItem(moveNowItem)
            }

            let cancelItem = NSMenuItem(
                title: "取消剪切状态 (Esc)",
                action: #selector(cancelActiveCut(_:)),
                keyEquivalent: ""
            )
            cancelItem.target = self
            cancelItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            menu.addItem(cancelItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Quick Copy Current Finder Selection Section
        let (selectedURLs, folderURL) = FinderSelectionHelper.currentSelectionOrFolderURLs()
        let targetURLs = !selectedURLs.isEmpty ? selectedURLs : (folderURL != nil ? [folderURL!] : [])

        if !targetURLs.isEmpty {
            let label = !selectedURLs.isEmpty
                ? "复制当前 Finder 选中项 (\(selectedURLs.count) 项)"
                : "复制当前 Finder 目录 (\(folderURL!.lastPathComponent))"
            let quickCopyRoot = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            quickCopyRoot.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            let sub = NSMenu(title: label)
            for format in state.config.enabledFormats {
                let item = NSMenuItem(
                    title: format.title,
                    action: #selector(quickCopyFromMenuBar(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = (format, targetURLs)
                item.image = NSImage(systemSymbolName: format.symbolName, accessibilityDescription: nil)
                sub.addItem(item)
            }
            quickCopyRoot.submenu = sub
            menu.addItem(quickCopyRoot)

            if let destDir = TerminalLauncher.shared.resolveTargetDirectory(
                selectedPaths: selectedURLs.map(\.path),
                targetDirectoryPath: folderURL?.path
            ) {
                let dirName = destDir.lastPathComponent.isEmpty ? destDir.path : destDir.lastPathComponent
                let openTermItem = NSMenuItem(
                    title: "在此处打开终端 (\(state.config.defaultTerminal.shortTitle) · \(dirName))",
                    action: #selector(openTerminalFromMenuBar(_:)),
                    keyEquivalent: ""
                )
                openTermItem.target = self
                openTermItem.representedObject = destDir
                openTermItem.image = NSImage(systemSymbolName: state.config.defaultTerminal.symbolName, accessibilityDescription: nil)
                menu.addItem(openTermItem)

                if state.config.enableOpenInOrcaInMenu && state.config.defaultTerminal != .orca {
                    let openOrcaItem = NSMenuItem(
                        title: "在 Orca 中打开「\(dirName)」",
                        action: #selector(openInOrcaFromMenuBar(_:)),
                        keyEquivalent: ""
                    )
                    openOrcaItem.target = self
                    openOrcaItem.representedObject = destDir
                    openOrcaItem.image = NSImage(systemSymbolName: TerminalApp.orca.symbolName, accessibilityDescription: nil)
                    menu.addItem(openOrcaItem)
                }
            }

            menu.addItem(NSMenuItem.separator())
        }

        // Last Copied Path History
        if !manager.lastCopiedText.isEmpty {
            let preview = manager.lastCopiedText.replacingOccurrences(of: "\n", with: " ")
            let truncated = preview.count > 42 ? String(preview.prefix(42)) + "..." : preview
            let recentItem = NSMenuItem(
                title: "最近复制：\(truncated)",
                action: #selector(recopyLastText(_:)),
                keyEquivalent: ""
            )
            recentItem.target = self
            recentItem.toolTip = manager.lastCopiedText
            menu.addItem(recentItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Quick Toggles
        let toggleCutKey = NSMenuItem(
            title: "启用 Finder ⌘+X 剪切与 ⌘+V 粘贴",
            action: #selector(toggleCutPasteKeybindings(_:)),
            keyEquivalent: ""
        )
        toggleCutKey.target = self
        toggleCutKey.state = state.config.enableCutAndPasteKeybindings ? .on : .off
        menu.addItem(toggleCutKey)

        let fixConflictItem = NSMenuItem(
            title: "一键优先启用 BoFinder 右键扩展 (解决扩展冲突)",
            action: #selector(prioritizeFinderExtension(_:)),
            keyEquivalent: ""
        )
        fixConflictItem.target = self
        fixConflictItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        menu.addItem(fixConflictItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "设置与扩展诊断...",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "退出 BoFinder",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Menu Actions

    @objc private func requestAccessibilityPermission(_ sender: Any?) {
        EventTapManager.shared.checkPermissionAndStartIfPossible(promptIfNeeded: true)
        SettingsWindowController.shared.showWindow()
    }

    @objc private func moveCutItemsToFrontmostFinder(_ sender: Any?) {
        guard let targetFolder = CutPasteManager.shared.frontmostFinderFolderURL() else { return }
        CutPasteManager.shared.performDirectMove(toDirectory: targetFolder)
    }

    @objc private func cancelActiveCut(_ sender: Any?) {
        CutPasteManager.shared.clearCut(showHUD: true)
    }

    @objc private func quickCopyFromMenuBar(_ sender: NSMenuItem) {
        guard let (format, urls) = sender.representedObject as? (PathFormat, [URL]) else { return }
        let formatted = PathFormatter.format(
            urls: urls,
            as: format,
            windowsStyle: CutPasteManager.shared.state.config.windowsPathStyle
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(formatted, forType: .string)

        let payload = ExtensionActionPayload(
            action: .copyPath,
            format: format,
            selectedPaths: urls.map(\.path),
            copiedText: formatted
        )
        CutPasteManager.shared.processExtensionAction(payload)
    }

    @objc private func openTerminalFromMenuBar(_ sender: NSMenuItem) {
        guard let destDir = sender.representedObject as? URL else { return }
        TerminalLauncher.shared.openTerminal(at: destDir)
    }

    @objc private func openInOrcaFromMenuBar(_ sender: NSMenuItem) {
        guard let destDir = sender.representedObject as? URL else { return }
        TerminalLauncher.shared.openInOrca(at: destDir, createTerminalIfNeeded: true, forceNewTerminal: false)
    }

    @objc private func recopyLastText(_ sender: Any?) {
        let text = CutPasteManager.shared.lastCopiedText
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        HUDWindowController.shared.show(
            title: "已重新复制路径",
            subtitle: text,
            symbolName: "doc.on.clipboard"
        )
    }

    @objc private func toggleCutPasteKeybindings(_ sender: Any?) {
        CutPasteManager.shared.updateConfig { cfg in
            cfg.enableCutAndPasteKeybindings.toggle()
        }
    }

    @objc private func prioritizeFinderExtension(_ sender: Any?) {
        FinderExtensionDoctor.shared.prioritizeBoFinderExtension()
        HUDWindowController.shared.show(
            title: "已优先启用 BoFinder 右键扩展",
            subtitle: "可在 Finder 中直接右键使用",
            symbolName: "checkmark.seal.fill"
        )
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - macOS NSServices Handlers (Quick Actions / Services Menu)

    private func handleServiceCopy(_ pboard: NSPasteboard, format: PathFormat) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return
        }
        let formatted = PathFormatter.format(
            urls: urls,
            as: format,
            windowsStyle: CutPasteManager.shared.state.config.windowsPathStyle
        )
        let general = NSPasteboard.general
        general.clearContents()
        general.setString(formatted, forType: .string)

        let payload = ExtensionActionPayload(
            action: .copyPath,
            format: format,
            selectedPaths: urls.map(\.path),
            copiedText: formatted
        )
        CutPasteManager.shared.processExtensionAction(payload)
    }

    @objc func copyPosixService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceCopy(pboard, format: .posix)
    }

    @objc func copyUrlService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceCopy(pboard, format: .url)
    }

    @objc func copyWindowsService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceCopy(pboard, format: .windows)
    }

    @objc func copyTerminalService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceCopy(pboard, format: .terminal)
    }

    @objc func cutFilesService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return
        }
        CutPasteManager.shared.activateCutWithURLs(urls, fromNativeKeyboard: false)
    }
}
