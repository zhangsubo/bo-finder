import Cocoa
import ApplicationServices

final class EventTapManager: ObservableObject {
    static let shared = EventTapManager()

    @Published private(set) var isAccessibilityTrusted: Bool = false
    @Published private(set) var isEventTapRunning: Bool = false

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?

    private init() {
        DispatchQueue.main.async { [weak self] in
            PermissionGuideOverlayController.shared.onAuthorizationDetected = { [weak self] in
                self?.checkPermissionAndStartIfPossible(promptIfNeeded: false)
            }
        }
        checkPermissionAndStartIfPossible()
        startPermissionPolling()
    }

    func checkPermissionAndStartIfPossible(promptIfNeeded: Bool = false) {
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.isAccessibilityTrusted = trusted
        }
        if trusted {
            if eventTap == nil {
                setupEventTap()
            }
        } else if promptIfNeeded {
            requestAccessibilityPermission()
        }
    }

    func requestAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.isAccessibilityTrusted = trusted
            if trusted {
                if self.eventTap == nil {
                    self.setupEventTap()
                }
                PermissionGuideOverlayController.shared.dismissImmediately()
                HUDWindowController.shared.show(
                    title: "辅助功能权限已就绪",
                    subtitle: "右键快捷栏与 Finder 快捷键已启用",
                    symbolName: "checkmark.circle.fill"
                )
                return
            }

            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open(settingsURL, configuration: config, completionHandler: nil)
            }
            PermissionGuideOverlayController.shared.show()
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.isAccessibilityTrusted {
                self.isAccessibilityTrusted = trusted
            }
            if trusted && self.eventTap == nil {
                self.setupEventTap()
            }
        }
    }

    private func setupEventTap() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            DispatchQueue.main.async {
                self.isEventTapRunning = false
            }
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        DispatchQueue.main.async {
            self.isEventTapRunning = true
        }
    }

    fileprivate func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        // Right-clicking a background/unfocused Finder window or Desktop icon opens Finder's context menu
        // even before Finder becomes `frontmostApplication`. Use system-wide AX hit-testing against Finder's PID
        // so both focused and unfocused Finder right-clicks work while Dock / other apps are ignored.
        if type == .rightMouseDown || (type == .leftMouseDown && flags == .maskControl) {
            guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
                  FinderSelectionHelper.isFinderElement(at: event.location, finderPID: finderApp.processIdentifier) else {
                return Unmanaged.passUnretained(event)
            }

            // Option + Right-Click in Finder: pop up DeskSide quick menu directly
            if type == .rightMouseDown && flags == .maskAlternate {
                let cgPoint = event.location
                DispatchQueue.main.async {
                    QuickPopupMenuController.shared.showAtMouseLocation(mouseCGPoint: cgPoint)
                }
                return nil
            }

            // Standard Right-Click (or Control + Left-Click) in Finder:
            // Query the item/folder under the cursor BEFORE Finder opens the context menu (which would occlude AX hit-testing),
            // then present the top companion quick bar right above Finder's context menu.
            let isStandardRightClick = (type == .rightMouseDown && flags.isEmpty)
                || (type == .leftMouseDown && flags == .maskControl)
            if isStandardRightClick {
                let cgPoint = event.location
                let screenPoint = NSEvent.mouseLocation
                let alwaysShowTopBar = CutPasteManager.shared.state.config.showTopQuickBarOnRightClick
                let (selected, folder) = FinderSelectionHelper.currentSelectionOrFolderURLs(mouseCGPoint: cgPoint)
                if let url = selected.first ?? folder {
                    if alwaysShowTopBar || FinderSelectionHelper.isCloudFolder(url) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                            CloudQuickBarController.shared.showAboveCursor(
                                at: screenPoint,
                                selectedURLs: selected,
                                folderURL: folder
                            )
                        }
                    }
                } else {
                    // Fallback: if Finder had not yet exposed AX attributes on an unfocused window at mouseDown,
                    // re-check Finder's updated selection/window right after Finder processes the click.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        let (retrySelected, retryFolder) = FinderSelectionHelper.currentSelectionOrFolderURLs()
                        guard let retryURL = retrySelected.first ?? retryFolder else { return }
                        if alwaysShowTopBar || FinderSelectionHelper.isCloudFolder(retryURL) {
                            CloudQuickBarController.shared.showAboveCursor(
                                at: screenPoint,
                                selectedURLs: retrySelected,
                                folderURL: retryFolder
                            )
                        }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Only intercept keyboard events when Finder is the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == "com.apple.finder" else {
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Allow DeskSide's own synthetic ⌘+⇧+. events to pass straight through to Finder
        if event.getIntegerValueField(.eventSourceUserData) == HiddenFilesManager.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Control + Option + C (keyCode 8 = C) in Finder: pop up BoFinder quick menu
        if keyCode == 8 && flags == [.maskControl, .maskAlternate] {
            DispatchQueue.main.async {
                QuickPopupMenuController.shared.showAtMouseLocation()
            }
            return nil
        }

        let manager = CutPasteManager.shared
        let config = manager.state.config

        // 1. Esc (keyCode 53) without modifiers: cancel active cut mode
        if config.enableCutAndPasteKeybindings && keyCode == 53 && flags.isEmpty {
            if manager.isValidCutActive() {
                DispatchQueue.main.async {
                    manager.clearCut(showHUD: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // 2. Toggle Hidden Files shortcut in Finder
        let matchesHiddenShortcut = config.enableHiddenFilesShortcut && config.hiddenFilesShortcut.matches(
            keyCode: Int(keyCode),
            command: flags.contains(.maskCommand),
            shift: flags.contains(.maskShift),
            option: flags.contains(.maskAlternate),
            control: flags.contains(.maskControl)
        )
        let isNativeHiddenShortcut = (keyCode == 47 && flags == [.maskCommand, .maskShift])

        if matchesHiddenShortcut {
            guard !isFinderEditingText(pid: frontApp.processIdentifier) else {
                return Unmanaged.passUnretained(event)
            }
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isAutorepeat {
                return nil
            }
            if config.hiddenFilesShortcut.isNativeFinderHiddenFilesShortcut {
                DispatchQueue.main.async {
                    HiddenFilesManager.shared.recordFinderNativeToggle(showHUD: true)
                }
                return Unmanaged.passUnretained(event)
            } else {
                DispatchQueue.main.async {
                    HiddenFilesManager.shared.triggerShortcutInFrontmostFinder()
                }
                return nil
            }
        } else if isNativeHiddenShortcut {
            if !isFinderEditingText(pid: frontApp.processIdentifier),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async {
                    HiddenFilesManager.shared.recordFinderNativeToggle(showHUD: false)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard config.enableCutAndPasteKeybindings else {
            return Unmanaged.passUnretained(event)
        }

        // 3. Check if user is editing text in Finder (renaming a file, search bar, Go to Folder sheet, etc.)
        if isFinderEditingText(pid: frontApp.processIdentifier) {
            return Unmanaged.passUnretained(event)
        }

        // 3. ⌘ + X (keyCode 7 = X, only Command modifier)
        if keyCode == 7 && flags == .maskCommand {
            let prevCount = NSPasteboard.general.changeCount
            // Mutate ⌘+X into ⌘+C (keyCode 8 = C) so Finder natively copies the selected items to NSPasteboard
            event.setIntegerValueField(.keyboardEventKeycode, value: 8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                manager.handleCommandXTriggered(previousChangeCount: prevCount)
            }
            return Unmanaged.passUnretained(event)
        }

        // 4. ⌘ + C (keyCode 8 = C, only Command modifier)
        if keyCode == 8 && flags == .maskCommand {
            // User manually pressed ⌘+C, so cancel any active Cut state
            if manager.state.isCutActive {
                DispatchQueue.main.async {
                    manager.clearCut(showHUD: false)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // 5. ⌘ + V (keyCode 9 = V, only Command modifier)
        if keyCode == 9 && flags == .maskCommand {
            if manager.isValidCutActive() {
                if let targetFolder = manager.frontmostFinderFolderURL() {
                    // Move cut files directly into the active Finder folder without synthesizing ⌥+⌘+V
                    // (Avoids triggering third-party clipboard managers like Parallels Toolbox Clipboard History that bind ⌥+⌘+V)
                    DispatchQueue.main.async {
                        manager.performDirectMove(toDirectory: targetFolder)
                    }
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    /// Determines whether Finder's current focus is inside a text input (e.g., renaming a file or typing in search).
    private func isFinderEditingText(pid: pid_t) -> Bool {
        let appElem = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let focusedObj = focusedRef else {
            return false
        }
        let focusedElem = focusedObj as! AXUIElement

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focusedElem, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            let textRoles: Set<String> = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String,
                "AXSearchField"
            ]
            if textRoles.contains(role) {
                return true
            }
        }
        return false
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handleCGEvent(proxy: proxy, type: type, event: event)
}
