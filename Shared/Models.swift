import Foundation

public enum PathFormat: String, Codable, CaseIterable, Identifiable {
    case posix = "posix"
    case url = "url"
    case windows = "windows"
    case terminal = "terminal"
    case tilde = "tilde"
    case filename = "filename"
    case markdown = "markdown"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .posix:
            return "POSIX 路径 (/a/b)"
        case .url:
            return "URL 路径 (file:///a/b)"
        case .windows:
            return "Windows 路径 (\\a\\b)"
        case .terminal:
            return "终端转义路径 (Terminal)"
        case .tilde:
            return "家目录路径 (~/a/b)"
        case .filename:
            return "纯文件名 (filename)"
        case .markdown:
            return "Markdown 链接 ([name](url))"
        }
    }

    public var shortTitle: String {
        switch self {
        case .posix:
            return "POSIX 路径"
        case .url:
            return "URL 路径"
        case .windows:
            return "Windows 路径"
        case .terminal:
            return "终端转义路径"
        case .tilde:
            return "家目录路径 (~)"
        case .filename:
            return "文件名"
        case .markdown:
            return "Markdown 链接"
        }
    }

    public var symbolName: String {
        switch self {
        case .posix:
            return "slash.circle"
        case .url:
            return "link"
        case .windows:
            return "pc"
        case .terminal:
            return "terminal"
        case .tilde:
            return "house"
        case .filename:
            return "doc.text"
        case .markdown:
            return "curlybraces"
        }
    }
}

public enum WindowsPathStyle: String, Codable, CaseIterable, Identifiable {
    case backslash = "backslash"       // \Users\name\file
    case driveC = "driveC"             // C:\Users\name\file
    case unc = "unc"                   // \\mac\Users\name\file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backslash:
            return "反斜杠路径 (\\Users\\...)"
        case .driveC:
            return "带盘符路径 (C:\\Users\\...)"
        case .unc:
            return "UNC 网络路径 (\\\\mac\\Users\\...)"
        }
    }
}

public enum TerminalApp: String, Codable, CaseIterable, Identifiable {
    case iterm2 = "iterm2"
    case ghostty = "ghostty"
    case systemTerminal = "systemTerminal"
    case orca = "orca"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iterm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        case .systemTerminal:
            return "系统自带终端 (Terminal)"
        case .orca:
            return "Orca"
        }
    }

    public var shortTitle: String {
        switch self {
        case .iterm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        case .systemTerminal:
            return "系统终端"
        case .orca:
            return "Orca"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .iterm2:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .systemTerminal:
            return "com.apple.Terminal"
        case .orca:
            return "com.stablyai.orca"
        }
    }

    public var defaultAppPath: String {
        switch self {
        case .iterm2:
            return "/Applications/iTerm.app"
        case .ghostty:
            return "/Applications/Ghostty.app"
        case .systemTerminal:
            return "/System/Applications/Utilities/Terminal.app"
        case .orca:
            return "/Applications/Orca.app"
        }
    }

    public var symbolName: String {
        switch self {
        case .iterm2, .ghostty, .systemTerminal:
            return "terminal"
        case .orca:
            return "sparkles.rectangle.stack"
        }
    }
}

public struct KeyShortcut: Codable, Equatable {
    public var keyCode: Int
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(
        keyCode: Int,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// Finder's standard shortcut: ⌘+⇧+.
    public static let defaultHiddenFiles = KeyShortcut(
        keyCode: 47,
        command: true,
        shift: true,
        option: false,
        control: false
    )

    /// Ergonomic preset: ⌃+H
    public static let presetControlH = KeyShortcut(
        keyCode: 4,
        command: false,
        shift: false,
        option: false,
        control: true
    )

    /// Ergonomic preset: ⌥+.
    public static let presetOptionPeriod = KeyShortcut(
        keyCode: 47,
        command: false,
        shift: false,
        option: true,
        control: false
    )

    public var isNativeFinderHiddenFilesShortcut: Bool {
        return self == .defaultHiddenFiles
    }

    public func matches(
        keyCode: Int,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> Bool {
        return self.keyCode == keyCode
            && self.command == command
            && self.shift == shift
            && self.option == option
            && self.control == control
    }

    public var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if command { parts.append("⌘") }
        if shift { parts.append("⇧") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined(separator: "+")
    }

    /// Validates whether this shortcut is safe to bind inside Finder without breaking typing or core system shortcuts.
    /// Returns `nil` when valid, or a user-facing Chinese reason when rejected.
    public func validateForFinder() -> String? {
        if Self.isModifierKeyCode(keyCode) {
            return "请按下包含字母、数字、符号或功能键的完整组合。"
        }

        let hasPrimaryModifier = command || control || option
        if !hasPrimaryModifier && !Self.isFunctionKeyCode(keyCode) {
            return "请至少包含 ⌘、⌃ 或 ⌥ 修饰键（或使用 F1–F20 功能键），以免影响 Finder 正常输入与选择。"
        }

        // Reject DeskSide's built-in quick popup menu shortcut (⌃+⌥+C)
        if !command && !shift && option && control && keyCode == 8 {
            return "「⌃+⌥+C」已用于弹出 DeskSide 快捷菜单，请换用其他组合。"
        }

        // Reject essential single-⌘ Finder / macOS shortcuts
        if command && !shift && !option && !control {
            let reservedSingleCommandKeys: Set<Int> = [
                0,  // A - Select All
                3,  // F - Find
                6,  // Z - Undo
                7,  // X - Cut
                8,  // C - Copy
                9,  // V - Paste
                12, // Q - Quit
                13, // W - Close Window
                17, // T - New Tab
                31, // O - Open
                45, // N - New Finder Window
                48, // Tab - App Switcher
                49, // Space - Spotlight
                51  // Delete - Move to Trash
            ]
            if reservedSingleCommandKeys.contains(keyCode) {
                return "「\(displayString)」是 Finder 或系统的核心快捷键，请换用其他组合（如 ⌃+H、⌥+. 或 ⌘+⇧+.）。"
            }
        }

        return nil
    }

    public static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        return (54...63).contains(keyCode)
    }

    public static func isFunctionKeyCode(_ keyCode: Int) -> Bool {
        let functionKeyCodes: Set<Int> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
            103, 111, 105, 107, 113, 106, 64, 79, 80, 90
        ]
        return functionKeyCodes.contains(keyCode)
    }

    public static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "Esc"
        case 64: return "F17"
        case 65: return "KP."
        case 67: return "KP*"
        case 69: return "KP+"
        case 71: return "Clear"
        case 75: return "KP/"
        case 76: return "KP↩"
        case 78: return "KP-"
        case 79: return "F18"
        case 80: return "F19"
        case 81: return "KP="
        case 82: return "KP0"
        case 83: return "KP1"
        case 84: return "KP2"
        case 85: return "KP3"
        case 86: return "KP4"
        case 87: return "KP5"
        case 88: return "KP6"
        case 89: return "KP7"
        case 90: return "F20"
        case 91: return "KP8"
        case 92: return "KP9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PageDown"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key(\(keyCode))"
        }
    }
}

public enum HiddenFilesPreferenceParser {
    public static func parse(_ rawValue: Any?) -> Bool {
        guard let rawValue = rawValue else { return false }
        if let boolVal = rawValue as? Bool {
            return boolVal
        }
        if let numberVal = rawValue as? NSNumber {
            return numberVal.intValue != 0
        }
        if let strVal = rawValue as? String {
            let normalized = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "1" || normalized == "true" || normalized == "yes"
        }
        return false
    }
}

public struct BoFinderConfig: Codable, Equatable {
    public var enabledFormats: [PathFormat]
    public var useSubmenuForCopyPath: Bool
    public var windowsPathStyle: WindowsPathStyle
    public var enableCutAndPasteKeybindings: Bool
    public var enableContextMenuCutAndPaste: Bool
    public var showHUDFeedback: Bool
    public var playSoundOnAction: Bool
    public var showTopQuickBarOnRightClick: Bool
    public var defaultTerminal: TerminalApp
    public var enableOpenTerminalInMenu: Bool
    public var enableOpenInOrcaInMenu: Bool
    public var showDockIcon: Bool
    public var launchAtLogin: Bool
    public var enableHiddenFilesShortcut: Bool
    public var hiddenFilesShortcut: KeyShortcut

    public init(
        enabledFormats: [PathFormat] = [.posix, .url, .windows, .terminal, .tilde, .filename],
        useSubmenuForCopyPath: Bool = true,
        windowsPathStyle: WindowsPathStyle = .backslash,
        enableCutAndPasteKeybindings: Bool = true,
        enableContextMenuCutAndPaste: Bool = true,
        showHUDFeedback: Bool = true,
        playSoundOnAction: Bool = false,
        showTopQuickBarOnRightClick: Bool = true,
        defaultTerminal: TerminalApp = .iterm2,
        enableOpenTerminalInMenu: Bool = true,
        enableOpenInOrcaInMenu: Bool = true,
        showDockIcon: Bool = true,
        launchAtLogin: Bool = false,
        enableHiddenFilesShortcut: Bool = true,
        hiddenFilesShortcut: KeyShortcut = .defaultHiddenFiles
    ) {
        self.enabledFormats = enabledFormats
        self.useSubmenuForCopyPath = useSubmenuForCopyPath
        self.windowsPathStyle = windowsPathStyle
        self.enableCutAndPasteKeybindings = enableCutAndPasteKeybindings
        self.enableContextMenuCutAndPaste = enableContextMenuCutAndPaste
        self.showHUDFeedback = showHUDFeedback
        self.playSoundOnAction = playSoundOnAction
        self.showTopQuickBarOnRightClick = showTopQuickBarOnRightClick
        self.defaultTerminal = defaultTerminal
        self.enableOpenTerminalInMenu = enableOpenTerminalInMenu
        self.enableOpenInOrcaInMenu = enableOpenInOrcaInMenu
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.enableHiddenFilesShortcut = enableHiddenFilesShortcut
        self.hiddenFilesShortcut = hiddenFilesShortcut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabledFormats = try container.decodeIfPresent([PathFormat].self, forKey: .enabledFormats) ?? [.posix, .url, .windows, .terminal, .tilde, .filename]
        self.useSubmenuForCopyPath = try container.decodeIfPresent(Bool.self, forKey: .useSubmenuForCopyPath) ?? true
        self.windowsPathStyle = try container.decodeIfPresent(WindowsPathStyle.self, forKey: .windowsPathStyle) ?? .backslash
        self.enableCutAndPasteKeybindings = try container.decodeIfPresent(Bool.self, forKey: .enableCutAndPasteKeybindings) ?? true
        self.enableContextMenuCutAndPaste = try container.decodeIfPresent(Bool.self, forKey: .enableContextMenuCutAndPaste) ?? true
        self.showHUDFeedback = try container.decodeIfPresent(Bool.self, forKey: .showHUDFeedback) ?? true
        self.playSoundOnAction = try container.decodeIfPresent(Bool.self, forKey: .playSoundOnAction) ?? false
        self.showTopQuickBarOnRightClick = try container.decodeIfPresent(Bool.self, forKey: .showTopQuickBarOnRightClick) ?? true
        self.defaultTerminal = try container.decodeIfPresent(TerminalApp.self, forKey: .defaultTerminal) ?? .iterm2
        self.enableOpenTerminalInMenu = try container.decodeIfPresent(Bool.self, forKey: .enableOpenTerminalInMenu) ?? true
        self.enableOpenInOrcaInMenu = try container.decodeIfPresent(Bool.self, forKey: .enableOpenInOrcaInMenu) ?? true
        self.showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? true
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.enableHiddenFilesShortcut = try container.decodeIfPresent(Bool.self, forKey: .enableHiddenFilesShortcut) ?? true
        self.hiddenFilesShortcut = try container.decodeIfPresent(KeyShortcut.self, forKey: .hiddenFilesShortcut) ?? .defaultHiddenFiles
    }
}

public struct SharedRuntimeState: Codable, Equatable {
    public var config: BoFinderConfig
    public var isCutActive: Bool
    public var cutFilePaths: [String]
    public var updatedAt: TimeInterval

    public init(
        config: BoFinderConfig = BoFinderConfig(),
        isCutActive: Bool = false,
        cutFilePaths: [String] = [],
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.config = config
        self.isCutActive = isCutActive
        self.cutFilePaths = cutFilePaths
        self.updatedAt = updatedAt
    }
}

public enum ExtensionActionType: String, Codable {
    case copyPath = "copyPath"
    case cutItems = "cutItems"
    case pasteMoveItems = "pasteMoveItems"
    case clearCut = "clearCut"
    case contextMenuOpened = "contextMenuOpened"
    case openTerminal = "openTerminal"
    case openInOrca = "openInOrca"
}

public struct ExtensionActionPayload: Codable {
    public var action: ExtensionActionType
    public var format: PathFormat?
    public var terminalApp: TerminalApp?
    public var selectedPaths: [String]
    public var targetDirectoryPath: String?
    public var copiedText: String?
    public var mouseX: Double?
    public var mouseY: Double?

    public init(
        action: ExtensionActionType,
        format: PathFormat? = nil,
        terminalApp: TerminalApp? = nil,
        selectedPaths: [String] = [],
        targetDirectoryPath: String? = nil,
        copiedText: String? = nil,
        mouseX: Double? = nil,
        mouseY: Double? = nil
    ) {
        self.action = action
        self.format = format
        self.terminalApp = terminalApp
        self.selectedPaths = selectedPaths
        self.targetDirectoryPath = targetDirectoryPath
        self.copiedText = copiedText
        self.mouseX = mouseX
        self.mouseY = mouseY
    }
}
