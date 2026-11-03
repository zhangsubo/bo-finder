import Cocoa
import ApplicationServices

final class HiddenFilesManager: ObservableObject {
    static let shared = HiddenFilesManager()

    /// Tag placed on synthetic CGEvents so EventTapManager lets them pass straight through to Finder.
    static let syntheticEventTag: Int64 = 0x4453_4846 // "DSHF"

    private static let finderDomain: CFString = "com.apple.finder" as CFString
    private static let showAllFilesKey: CFString = "AppleShowAllFiles" as CFString

    @Published private(set) var isShowingHiddenFiles: Bool

    private init() {
        self.isShowingHiddenFiles = Self.readSystemHiddenFilesPreference()
    }

    func refreshFromSystem() {
        let current = Self.readSystemHiddenFilesPreference()
        if Thread.isMainThread {
            if isShowingHiddenFiles != current {
                isShowingHiddenFiles = current
            }
        } else {
            DispatchQueue.main.async {
                if self.isShowingHiddenFiles != current {
                    self.isShowingHiddenFiles = current
                }
            }
        }
    }

    /// Toggles hidden files from DeskSide UI or status bar menu by updating Finder preferences and refreshing Finder.
    func toggleFromUI() {
        setHiddenFilesVisible(!isShowingHiddenFiles, showHUD: true)
    }

    /// Deterministically sets Finder's `AppleShowAllFiles` preference and restarts Finder so all windows synchronize.
    func setHiddenFilesVisible(_ visible: Bool, showHUD: Bool = true) {
        Self.writeSystemHiddenFilesPreference(visible)
        isShowingHiddenFiles = visible

        restartFinderPreservingDeskSideFocus()
        presentFeedback(visible: visible, showHUD: showHUD)
    }

    /// Re-applies the current hidden-files preference and restarts Finder in case temporary session state drifted.
    func forceSyncFinder() {
        let visible = isShowingHiddenFiles
        Self.writeSystemHiddenFilesPreference(visible)
        restartFinderPreservingDeskSideFocus()

        let config = CutPasteManager.shared.state.config
        if config.playSoundOnAction {
            NSSound(named: "Tink")?.play()
        }
        if config.showHUDFeedback {
            HUDWindowController.shared.show(
                title: "已同步 Finder 隐藏文件状态",
                subtitle: visible ? "当前状态：显示以 . 开头的隐藏文件" : "当前状态：隐藏以 . 开头的隐藏文件",
                symbolName: visible ? "eye.fill" : "eye.slash.fill"
            )
        }
    }

    /// Sends Finder's native ⌘+⇧+. key equivalent (zero-flicker, preserves selection & active file copies)
    /// when the user presses a custom shortcut while Finder is frontmost.
    func triggerShortcutInFrontmostFinder() {
        if let src = CGEventSource(stateID: .privateState),
           let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 47, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 47, keyDown: false) {
            keyDown.flags = [.maskCommand, .maskShift]
            keyUp.flags = [.maskCommand, .maskShift]
            keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        recordFinderNativeToggle(showHUD: true)
    }

    /// Updates DeskSide's state and persists `AppleShowAllFiles` when Finder executes its native ⌘+⇧+. toggle.
    func recordFinderNativeToggle(showHUD: Bool) {
        let next = !isShowingHiddenFiles
        isShowingHiddenFiles = next
        Self.writeSystemHiddenFilesPreference(next)
        presentFeedback(visible: next, showHUD: showHUD)
    }

    private func presentFeedback(visible: Bool, showHUD: Bool) {
        let config = CutPasteManager.shared.state.config
        if showHUD && config.playSoundOnAction {
            NSSound(named: "Tink")?.play()
        }
        if showHUD && config.showHUDFeedback {
            HUDWindowController.shared.show(
                title: visible ? "已显示隐藏文件" : "已隐藏隐藏文件",
                subtitle: visible ? "文件名以 . 开头的系统与隐藏文件现已可见" : "文件名以 . 开头的系统与隐藏文件已隐藏",
                symbolName: visible ? "eye.fill" : "eye.slash.fill"
            )
        }
    }

    private func restartFinderPreservingDeskSideFocus() {
        let keepDeskSideFocused = NSApp.isActive && SettingsWindowController.shared.isWindowVisible

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["Finder"]
        try? proc.run()

        if keepDeskSideFocusIfNeeded(keepDeskSideFocused) {
            for delay in [0.35, 0.75] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if SettingsWindowController.shared.isWindowVisible {
                        NSApp.activate(ignoringOtherApps: true)
                        SettingsWindowController.shared.bringToFrontIfVisible()
                    }
                }
            }
        }
    }

    private func keepDeskSideFocusIfNeeded(_ flag: Bool) -> Bool {
        return flag
    }

    static func readSystemHiddenFilesPreference() -> Bool {
        CFPreferencesAppSynchronize(finderDomain)
        let raw = CFPreferencesCopyAppValue(showAllFilesKey, finderDomain)
        return HiddenFilesPreferenceParser.parse(raw)
    }

    private static func writeSystemHiddenFilesPreference(_ visible: Bool) {
        let cfVal: CFBoolean = visible ? kCFBooleanTrue : kCFBooleanFalse
        CFPreferencesSetAppValue(showAllFilesKey, cfVal, finderDomain)
        CFPreferencesAppSynchronize(finderDomain)
    }
}
