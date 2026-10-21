import Cocoa
import FinderSync

@objc(FinderSync)
class FinderSync: FIFinderSync {
    private var runtimeState: SharedRuntimeState = BoFinderIPC.loadState()

    override init() {
        super.init()

        updateMonitoredVolumes()

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            self,
            selector: #selector(volumesChanged(_:)),
            name: NSWorkspace.didMountNotification,
            object: nil
        )
        wsCenter.addObserver(
            self,
            selector: #selector(volumesChanged(_:)),
            name: NSWorkspace.didUnmountNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleStateChanged(_:)),
            name: BoFinderIPC.stateChangedNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        BoFinderIPC.requestStateFromMainApp()
    }

    @objc private func volumesChanged(_ notification: Notification) {
        updateMonitoredVolumes()
    }

    private func updateMonitoredVolumes() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        if let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: [.skipHiddenVolumes]
        ) {
            for vol in mounted {
                urls.insert(vol)
            }
        }
        FIFinderSyncController.default().directoryURLs = urls
    }

    @objc private func handleStateChanged(_ notification: Notification) {
        if let updated = BoFinderIPC.decodeState(from: notification.object) {
            self.runtimeState = updated
        }
    }

    private func refreshStateIfNeeded() {
        runtimeState = BoFinderIPC.loadState()
    }

    @objc func submenuParentNoOp(_ sender: Any?) {}

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        refreshStateIfNeeded()
        let menu = NSMenu(title: "BoFinder")
        let config = runtimeState.config
        let formats = config.enabledFormats.isEmpty ? [.posix, .url, .windows, .terminal] : config.enabledFormats

        if config.showTopQuickBarOnRightClick {
            let urls = effectiveTargetURLs()
            let mouse = NSEvent.mouseLocation
            let openPayload = ExtensionActionPayload(
                action: .contextMenuOpened,
                selectedPaths: urls.map(\.path),
                targetDirectoryPath: FIFinderSyncController.default().targetedURL()?.path,
                mouseX: Double(mouse.x),
                mouseY: Double(mouse.y)
            )
            BoFinderIPC.postExtensionAction(openPayload)
        }

        // 1. Copy Path section
        if config.useSubmenuForCopyPath {
            let copyRootItem = NSMenuItem(title: "复制路径", action: #selector(submenuParentNoOp(_:)), keyEquivalent: "")
            copyRootItem.target = self
            copyRootItem.image = symbolImage("doc.on.doc")
            let submenu = NSMenu(title: "复制路径")
            for format in formats {
                let item = makeMenuItem(for: format, prefixCopy: false)
                submenu.addItem(item)
            }
            copyRootItem.submenu = submenu
            menu.addItem(copyRootItem)
        } else {
            for format in formats {
                let item = makeMenuItem(for: format, prefixCopy: true)
                menu.addItem(item)
            }
        }

        // 2. Open Terminal & Open in Orca section
        if config.enableOpenTerminalInMenu || config.enableOpenInOrcaInMenu {
            if let targetDir = effectiveDestinationDirectory() {
                menu.addItem(NSMenuItem.separator())
                let dirName = targetDir.lastPathComponent.isEmpty ? targetDir.path : targetDir.lastPathComponent

                if config.enableOpenTerminalInMenu {
                    let termTitle = "在此处打开终端 (\(config.defaultTerminal.shortTitle) · \(dirName))"
                    let openTermItem = NSMenuItem(
                        title: termTitle,
                        action: #selector(openDefaultTerminalHere(_:)),
                        keyEquivalent: ""
                    )
                    openTermItem.target = self
                    openTermItem.image = symbolImage(config.defaultTerminal.symbolName)
                    menu.addItem(openTermItem)
                }

                if config.enableOpenInOrcaInMenu && config.defaultTerminal != .orca {
                    let orcaTitle = "在 Orca 中打开「\(dirName)」"
                    let openOrcaItem = NSMenuItem(
                        title: orcaTitle,
                        action: #selector(openInOrcaHere(_:)),
                        keyEquivalent: ""
                    )
                    openOrcaItem.target = self
                    openOrcaItem.image = symbolImage(TerminalApp.orca.symbolName)
                    menu.addItem(openOrcaItem)
                }
            }
        }

        // 3. Cut & Paste Move section
        if config.enableContextMenuCutAndPaste {
            menu.addItem(NSMenuItem.separator())

            let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
            if !selected.isEmpty {
                let cutTitle = selected.count > 1 ? "剪切 (\(selected.count) 个项目)" : "剪切"
                let cutItem = NSMenuItem(title: cutTitle, action: #selector(cutSelectedItems(_:)), keyEquivalent: "")
                cutItem.target = self
                cutItem.image = symbolImage("scissors")
                menu.addItem(cutItem)
            }

            if runtimeState.isCutActive && !runtimeState.cutFilePaths.isEmpty {
                let count = runtimeState.cutFilePaths.count
                let destURL = effectiveDestinationDirectory()
                let destName = destURL?.lastPathComponent ?? "当前目录"
                let moveTitle = "粘贴移动至「\(destName)」(\(count) 项)"
                let pasteMoveItem = NSMenuItem(
                    title: moveTitle,
                    action: #selector(pasteMoveItems(_:)),
                    keyEquivalent: ""
                )
                pasteMoveItem.target = self
                pasteMoveItem.image = symbolImage("arrow.right.doc.on.clipboard")
                menu.addItem(pasteMoveItem)

                let cancelCutItem = NSMenuItem(
                    title: "取消剪切状态",
                    action: #selector(cancelCutItems(_:)),
                    keyEquivalent: ""
                )
                cancelCutItem.target = self
                cancelCutItem.image = symbolImage("xmark.circle")
                menu.addItem(cancelCutItem)
            }
        }

        return menu
    }

    private func makeMenuItem(for format: PathFormat, prefixCopy: Bool) -> NSMenuItem {
        let title = prefixCopy ? "复制 \(format.shortTitle)" : format.title
        let selector: Selector
        switch format {
        case .posix:
            selector = #selector(copyPosixPath(_:))
        case .url:
            selector = #selector(copyUrlPath(_:))
        case .windows:
            selector = #selector(copyWindowsPath(_:))
        case .terminal:
            selector = #selector(copyTerminalPath(_:))
        case .tilde:
            selector = #selector(copyTildePath(_:))
        case .filename:
            selector = #selector(copyFilename(_:))
        case .markdown:
            selector = #selector(copyMarkdown(_:))
        }

        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.image = symbolImage(format.symbolName)
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    private func effectiveTargetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let targeted = controller.targetedURL() {
            return [targeted]
        }
        return []
    }

    private func effectiveDestinationDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            for candidate in selected {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
            if let targeted = controller.targetedURL() {
                return targeted
            }
            return selected[0].deletingLastPathComponent()
        }
        return controller.targetedURL()
    }

    private func performCopy(format: PathFormat) {
        refreshStateIfNeeded()
        let urls = effectiveTargetURLs()
        guard !urls.isEmpty else { return }

        let formatted = PathFormatter.format(
            urls: urls,
            as: format,
            windowsStyle: runtimeState.config.windowsPathStyle
        )

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(formatted, forType: .string)

        let payload = ExtensionActionPayload(
            action: .copyPath,
            format: format,
            selectedPaths: urls.map(\.path),
            targetDirectoryPath: FIFinderSyncController.default().targetedURL()?.path,
            copiedText: formatted
        )
        BoFinderIPC.postExtensionAction(payload)
    }

    @objc func copyPosixPath(_ sender: Any?) {
        performCopy(format: .posix)
    }

    @objc func copyUrlPath(_ sender: Any?) {
        performCopy(format: .url)
    }

    @objc func copyWindowsPath(_ sender: Any?) {
        performCopy(format: .windows)
    }

    @objc func copyTerminalPath(_ sender: Any?) {
        performCopy(format: .terminal)
    }

    @objc func copyTildePath(_ sender: Any?) {
        performCopy(format: .tilde)
    }

    @objc func copyFilename(_ sender: Any?) {
        performCopy(format: .filename)
    }

    @objc func copyMarkdown(_ sender: Any?) {
        performCopy(format: .markdown)
    }

    @objc func openDefaultTerminalHere(_ sender: Any?) {
        refreshStateIfNeeded()
        guard let destURL = effectiveDestinationDirectory() else { return }
        let payload = ExtensionActionPayload(
            action: .openTerminal,
            terminalApp: runtimeState.config.defaultTerminal,
            selectedPaths: [destURL.path],
            targetDirectoryPath: destURL.path
        )
        BoFinderIPC.postExtensionAction(payload)
    }

    @objc func openInOrcaHere(_ sender: Any?) {
        guard let destURL = effectiveDestinationDirectory() else { return }
        let payload = ExtensionActionPayload(
            action: .openInOrca,
            terminalApp: .orca,
            selectedPaths: [destURL.path],
            targetDirectoryPath: destURL.path
        )
        BoFinderIPC.postExtensionAction(payload)
    }

    @objc func cutSelectedItems(_ sender: Any?) {
        let urls = effectiveTargetURLs()
        guard !urls.isEmpty else { return }
        let payload = ExtensionActionPayload(
            action: .cutItems,
            selectedPaths: urls.map(\.path),
            targetDirectoryPath: FIFinderSyncController.default().targetedURL()?.path
        )
        BoFinderIPC.postExtensionAction(payload)
    }

    @objc func pasteMoveItems(_ sender: Any?) {
        guard let destURL = effectiveDestinationDirectory() else { return }
        let payload = ExtensionActionPayload(
            action: .pasteMoveItems,
            selectedPaths: runtimeState.cutFilePaths,
            targetDirectoryPath: destURL.path
        )
        BoFinderIPC.postExtensionAction(payload)
    }

    @objc func cancelCutItems(_ sender: Any?) {
        let payload = ExtensionActionPayload(action: .clearCut)
        BoFinderIPC.postExtensionAction(payload)
    }
}
