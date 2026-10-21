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
        showDockIcon: Bool = true
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
