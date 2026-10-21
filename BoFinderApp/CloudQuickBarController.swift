import Cocoa

final class CloudQuickBarController {
    static let shared = CloudQuickBarController()

    private var panel: NSPanel?
    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var autoDismissWorkItem: DispatchWorkItem?

    private var currentTargetURLs: [URL] = []
    private var currentDestinationURL: URL?

    private init() {}

    func showAboveCursor(at screenPoint: NSPoint, selectedURLs: [URL], folderURL: URL?) {
        DispatchQueue.main.async {
            self.presentBar(at: screenPoint, selectedURLs: selectedURLs, folderURL: folderURL)
        }
    }

    func dismiss() {
        DispatchQueue.main.async {
            self.removeMonitors()
            self.autoDismissWorkItem?.cancel()
            self.panel?.orderOut(nil)
        }
    }

    private func presentBar(at screenPoint: NSPoint, selectedURLs: [URL], folderURL: URL?) {
        removeMonitors()
        autoDismissWorkItem?.cancel()

        let targets = !selectedURLs.isEmpty ? selectedURLs : (folderURL != nil ? [folderURL!] : [])
        guard !targets.isEmpty else { return }

        self.currentTargetURLs = targets

        // Determine destination directory for Paste Move
        if selectedURLs.count == 1 {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: selectedURLs[0].path, isDirectory: &isDir), isDir.boolValue {
                self.currentDestinationURL = selectedURLs[0]
            } else {
                self.currentDestinationURL = folderURL ?? selectedURLs[0].deletingLastPathComponent()
            }
        } else {
            self.currentDestinationURL = folderURL ?? targets[0].deletingLastPathComponent()
        }

        let manager = CutPasteManager.shared
        let state = manager.state
        let formats = state.config.enabledFormats.isEmpty
            ? [.posix, .url, .windows, .terminal]
            : state.config.enabledFormats

        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        // Badge icon + label
        let badgeLabel = NSTextField(labelWithString: "BoFinder")
        badgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor
        rowStack.addArrangedSubview(badgeLabel)

        rowStack.addArrangedSubview(makeVerticalDivider())

        // Copy Path format buttons
        for (idx, format) in formats.enumerated() {
            let btn = makeActionButton(
                title: format.shortTitle,
                symbolName: format.symbolName,
                tag: idx,
                action: #selector(handleCopyFormatClicked(_:))
            )
            rowStack.addArrangedSubview(btn)
        }

        // Cut & Paste Move buttons
        if state.config.enableContextMenuCutAndPaste {
            rowStack.addArrangedSubview(makeVerticalDivider())

            let cutBtn = makeActionButton(
                title: "剪切",
                symbolName: "scissors",
                tag: 100,
                action: #selector(handleCutClicked(_:))
            )
            rowStack.addArrangedSubview(cutBtn)

            if state.isCutActive && !state.cutFilePaths.isEmpty {
                let moveBtn = makeActionButton(
                    title: "粘贴移动(\(state.cutFilePaths.count))",
                    symbolName: "arrow.right.doc.on.clipboard",
                    tag: 101,
                    action: #selector(handlePasteMoveClicked(_:)),
                    prominent: true
                )
                rowStack.addArrangedSubview(moveBtn)
            }
        }

        let fittingSize = rowStack.fittingSize
        let width = max(fittingSize.width + 20, 260)
        let height: CGFloat = 38

        let win = ensurePanel(size: NSSize(width: width, height: height))
        if let effectView = win.contentView as? NSVisualEffectView {
            effectView.subviews.forEach { $0.removeFromSuperview() }
            effectView.addSubview(rowStack)
            NSLayoutConstraint.activate([
                rowStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                rowStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
                rowStack.topAnchor.constraint(equalTo: effectView.topAnchor),
                rowStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
            ])
        }

        // Position directly above the cursor so it sits neatly at the top of Finder's native right-click menu
        var x = screenPoint.x - 12
        var y = screenPoint.y + 12
        if let screenFrame = NSScreen.main?.visibleFrame {
            if x + width > screenFrame.maxX - 8 {
                x = screenFrame.maxX - width - 8
            }
            if x < screenFrame.minX + 8 {
                x = screenFrame.minX + 8
            }
            if y + height > screenFrame.maxY - 8 {
                y = screenPoint.y - height - 12
            }
        }

        win.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        win.alphaValue = 1.0
        win.orderFrontRegardless()

        installMonitors()

        let work = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func makeVerticalDivider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 1),
            v.heightAnchor.constraint(equalToConstant: 18)
        ])
        return v
    }

    private func makeActionButton(
        title: String,
        symbolName: String,
        tag: Int,
        action: Selector,
        prominent: Bool = false
    ) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.tag = tag
        btn.bezelStyle = .recessed
        btn.isBordered = true
        btn.showsBorderOnlyWhileMouseInside = !prominent
        btn.font = NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .medium)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            btn.image = img.withSymbolConfiguration(cfg)
            btn.imagePosition = .imageLeading
        }
        if prominent {
            btn.contentTintColor = .controlAccentColor
        }
        return btn
    }

    @objc private func handleCopyFormatClicked(_ sender: NSButton) {
        let formats = CutPasteManager.shared.state.config.enabledFormats.isEmpty
            ? [.posix, .url, .windows, .terminal]
            : CutPasteManager.shared.state.config.enabledFormats
        guard sender.tag >= 0 && sender.tag < formats.count else { return }
        let format = formats[sender.tag]
        let urls = currentTargetURLs
        dismiss()
        dismissFinderContextMenu()

        guard !urls.isEmpty else { return }
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

    @objc private func handleCutClicked(_ sender: NSButton) {
        let urls = currentTargetURLs
        dismiss()
        dismissFinderContextMenu()
        guard !urls.isEmpty else { return }
        CutPasteManager.shared.activateCutWithURLs(urls, fromNativeKeyboard: false)
    }

    @objc private func handlePasteMoveClicked(_ sender: NSButton) {
        let dest = currentDestinationURL
        dismiss()
        dismissFinderContextMenu()
        guard let targetDir = dest else { return }
        CutPasteManager.shared.performDirectMove(toDirectory: targetDir)
    }

    private func dismissFinderContextMenu() {
        // Send Esc (keyCode 53) to close Finder's open native context menu
        if let src = CGEventSource(stateID: .hidSystemState),
           let escDown = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true),
           let escUp = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false) {
            escDown.post(tap: .cghidEventTap)
            escUp.post(tap: .cghidEventTap)
        }
    }

    private func installMonitors() {
        let shownAt = Date().timeIntervalSince1970
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self = self, let win = self.panel else { return }
            // Ignore duplicate mouse events within 150ms of opening
            if Date().timeIntervalSince1970 - shownAt < 0.15 {
                return
            }
            let mouseLoc = NSEvent.mouseLocation
            if !win.frame.contains(mouseLoc) {
                self.dismiss()
            }
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.dismiss()
            }
        }
    }

    private func removeMonitors() {
        if let m = globalMouseMonitor {
            NSEvent.removeMonitor(m)
            globalMouseMonitor = nil
        }
        if let k = globalKeyMonitor {
            NSEvent.removeMonitor(k)
            globalKeyMonitor = nil
        }
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let existing = panel {
            return existing
        }
        let rect = NSRect(origin: .zero, size: size)
        let p = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.worksWhenModal = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let ve = NSVisualEffectView(frame: rect)
        ve.autoresizingMask = [.width, .height]
        ve.material = .menu
        ve.blendingMode = .behindWindow
        ve.state = .active
        ve.wantsLayer = true
        ve.layer?.cornerRadius = 10
        ve.layer?.masksToBounds = true
        ve.layer?.borderWidth = 0.5
        ve.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        p.contentView = ve
        self.panel = p
        return p
    }
}
