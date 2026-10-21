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
        checkPermissionAndStartIfPossible()
        startPermissionPolling()
    }

    func checkPermissionAndStartIfPossible(promptIfNeeded: Bool = false) {
        var trusted = AXIsProcessTrusted()
        if !trusted && promptIfNeeded {
            // Clear any stale CDHash entry from previous ad-hoc builds before prompting
            let resetProc = Process()
            resetProc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            resetProc.arguments = ["reset", "Accessibility", "com.bofinder.app"]
            try? resetProc.run()
            resetProc.waitUntilExit()

            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString: true]
            trusted = AXIsProcessTrustedWithOptions(options)
        }
        DispatchQueue.main.async {
            self.isAccessibilityTrusted = trusted
        }
        if trusted && eventTap == nil {
            setupEventTap()
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

        // Only intercept events when Finder is the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == "com.apple.finder" else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])

        // Option + Right-Click in Finder: pop up BoFinder quick menu directly
        if type == .rightMouseDown && flags == .maskAlternate {
            DispatchQueue.main.async {
                QuickPopupMenuController.shared.showAtMouseLocation()
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
            let checkURL = selected.first ?? folder
            if let url = checkURL, (alwaysShowTopBar || FinderSelectionHelper.isCloudFolder(url)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    CloudQuickBarController.shared.showAboveCursor(
                        at: screenPoint,
                        selectedURLs: selected,
                        folderURL: folder
                    )
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
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
        guard manager.state.config.enableCutAndPasteKeybindings else {
            return Unmanaged.passUnretained(event)
        }

        // 1. Esc (keyCode 53) without modifiers: cancel active cut mode
        if keyCode == 53 && flags.isEmpty {
            if manager.isValidCutActive() {
                DispatchQueue.main.async {
                    manager.clearCut(showHUD: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // 2. Check if user is editing text in Finder (renaming a file, search bar, Go to Folder sheet, etc.)
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
