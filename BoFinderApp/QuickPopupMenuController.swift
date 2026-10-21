import Cocoa

final class QuickPopupMenuController: NSObject {
    static let shared = QuickPopupMenuController()

    private var activeMenu: NSMenu?

    func showAtMouseLocation() {
        let (selectedURLs, folderURL) = FinderSelectionHelper.currentSelectionOrFolderURLs()
        let targetURLs = !selectedURLs.isEmpty ? selectedURLs : (folderURL != nil ? [folderURL!] : [])
        guard !targetURLs.isEmpty else {
            HUDWindowController.shared.show(
                title: "未检测到 Finder 选中文件或活动窗口",
                subtitle: "请先在 Finder 中选中文件或打开文件夹",
                symbolName: "info.circle"
            )
            return
        }

        let manager = CutPasteManager.shared
        let state = manager.state
        let formats = state.config.enabledFormats.isEmpty
            ? [.posix, .url, .windows, .terminal]
            : state.config.enabledFormats

        let menu = NSMenu(title: "BoFinder 快捷菜单")

        let headerText = !selectedURLs.isEmpty
            ? (selectedURLs.count == 1 ? "📄 \(selectedURLs[0].lastPathComponent)" : "📚 已选中 \(selectedURLs.count) 个项目")
            : "📁 当前目录：\(folderURL!.lastPathComponent)"
        let headerItem = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Copy Path items
        if state.config.useSubmenuForCopyPath {
            let subRoot = NSMenuItem(title: "复制路径", action: nil, keyEquivalent: "")
            subRoot.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            let sub = NSMenu(title: "复制路径")
            for format in formats {
                sub.addItem(makeCopyItem(format: format, urls: targetURLs, prefixCopy: false))
            }
            subRoot.submenu = sub
            menu.addItem(subRoot)
        } else {
            for format in formats {
                menu.addItem(makeCopyItem(format: format, urls: targetURLs, prefixCopy: true))
            }
        }

        // Open Terminal & Orca items
        if let destDir = TerminalLauncher.shared.resolveTargetDirectory(
            selectedPaths: selectedURLs.map(\.path),
            targetDirectoryPath: folderURL?.path
        ) {
            if state.config.enableOpenTerminalInMenu || state.config.enableOpenInOrcaInMenu {
                menu.addItem(NSMenuItem.separator())
                let dirName = destDir.lastPathComponent.isEmpty ? destDir.path : destDir.lastPathComponent

                if state.config.enableOpenTerminalInMenu {
                    let termItem = NSMenuItem(
                        title: "在此处打开终端 (\(state.config.defaultTerminal.shortTitle) · \(dirName))",
                        action: #selector(handleOpenTerminal(_:)),
                        keyEquivalent: ""
                    )
                    termItem.target = self
                    termItem.representedObject = destDir
                    termItem.image = NSImage(systemSymbolName: state.config.defaultTerminal.symbolName, accessibilityDescription: nil)
                    menu.addItem(termItem)
                }

                if state.config.enableOpenInOrcaInMenu && state.config.defaultTerminal != .orca {
                    let orcaItem = NSMenuItem(
                        title: "在 Orca 中打开「\(dirName)」",
                        action: #selector(handleOpenInOrca(_:)),
                        keyEquivalent: ""
                    )
                    orcaItem.target = self
                    orcaItem.representedObject = destDir
                    orcaItem.image = NSImage(systemSymbolName: TerminalApp.orca.symbolName, accessibilityDescription: nil)
                    menu.addItem(orcaItem)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Cut item
        if !selectedURLs.isEmpty {
            let cutTitle = selectedURLs.count > 1 ? "剪切 (\(selectedURLs.count) 个项目)" : "剪切"
            let cutItem = NSMenuItem(title: cutTitle, action: #selector(handleCut(_:)), keyEquivalent: "")
            cutItem.target = self
            cutItem.representedObject = selectedURLs
            cutItem.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
            menu.addItem(cutItem)
        }

        // Paste Move item
        if state.isCutActive && !state.cutFilePaths.isEmpty {
            let destDir: URL? = {
                if selectedURLs.count == 1 {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: selectedURLs[0].path, isDirectory: &isDir), isDir.boolValue {
                        return selectedURLs[0]
                    }
                }
                return folderURL
            }()

            if let dest = destDir {
                let moveItem = NSMenuItem(
                    title: "粘贴移动至「\(dest.lastPathComponent)」(\(state.cutFilePaths.count) 项)",
                    action: #selector(handlePasteMove(_:)),
                    keyEquivalent: ""
                )
                moveItem.target = self
                moveItem.representedObject = dest
                moveItem.image = NSImage(systemSymbolName: "arrow.right.doc.on.clipboard", accessibilityDescription: nil)
                menu.addItem(moveItem)
            }

            let cancelItem = NSMenuItem(
                title: "取消剪切状态",
                action: #selector(handleCancelCut(_:)),
                keyEquivalent: ""
            )
            cancelItem.target = self
            cancelItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            menu.addItem(cancelItem)
        }

        self.activeMenu = menu
        let mouseLoc = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: mouseLoc, in: nil)
    }

    private func makeCopyItem(format: PathFormat, urls: [URL], prefixCopy: Bool) -> NSMenuItem {
        let title = prefixCopy ? "复制 \(format.shortTitle)" : format.title
        let item = NSMenuItem(title: title, action: #selector(handleCopy(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = (format, urls)
        item.image = NSImage(systemSymbolName: format.symbolName, accessibilityDescription: nil)
        return item
    }

    @objc private func handleCopy(_ sender: NSMenuItem) {
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

    @objc private func handleOpenTerminal(_ sender: NSMenuItem) {
        guard let destURL = sender.representedObject as? URL else { return }
        TerminalLauncher.shared.openTerminal(at: destURL)
    }

    @objc private func handleOpenInOrca(_ sender: NSMenuItem) {
        guard let destURL = sender.representedObject as? URL else { return }
        TerminalLauncher.shared.openInOrca(at: destURL, createTerminalIfNeeded: true, forceNewTerminal: false)
    }

    @objc private func handleCut(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        CutPasteManager.shared.activateCutWithURLs(urls, fromNativeKeyboard: false)
    }

    @objc private func handlePasteMove(_ sender: NSMenuItem) {
        guard let destURL = sender.representedObject as? URL else { return }
        CutPasteManager.shared.performDirectMove(toDirectory: destURL)
    }

    @objc private func handleCancelCut(_ sender: NSMenuItem) {
        CutPasteManager.shared.clearCut(showHUD: true)
    }
}
