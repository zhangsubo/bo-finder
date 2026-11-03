import Foundation

public enum EnvEntryKind: String, Codable, CaseIterable, Identifiable {
    case variable = "variable"
    case secret = "secret"
    case alias = "alias"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .variable:
            return "环境变量 (export)"
        case .secret:
            return "密码与密钥 (export)"
        case .alias:
            return "快捷别名 (alias)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .variable:
            return "环境变量"
        case .secret:
            return "密码密钥"
        case .alias:
            return "快捷别名"
        }
    }

    public var badgeTitle: String {
        switch self {
        case .variable:
            return "EXPORT"
        case .secret:
            return "SECRET"
        case .alias:
            return "ALIAS"
        }
    }

    public var symbolName: String {
        switch self {
        case .variable:
            return "terminal"
        case .secret:
            return "key.fill"
        case .alias:
            return "bolt.fill"
        }
    }
}

public struct EnvEntry: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: EnvEntryKind
    public var name: String
    /// Persisted value on disk when `useKeychain` is false. Empty on disk when stored in macOS Keychain.
    public var value: String
    public var note: String
    public var group: String
    public var isEnabled: Bool
    /// Optional per-entry macOS Keychain storage (used only when `kind == .secret`).
    public var useKeychain: Bool
    /// Allows `$VAR` / `~/` expansion inside double quotes (used only when `kind == .variable`).
    public var allowExpansion: Bool
    /// Whether to also push via `launchctl setenv` for macOS GUI applications.
    public var syncToGUI: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: EnvEntryKind = .variable,
        name: String,
        value: String,
        note: String = "",
        group: String = "默认",
        isEnabled: Bool = true,
        useKeychain: Bool = false,
        allowExpansion: Bool = false,
        syncToGUI: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.value = value
        self.note = note
        self.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认" : group
        self.isEnabled = isEnabled
        self.useKeychain = kind == .secret ? useKeychain : false
        self.allowExpansion = kind == .variable ? allowExpansion : false
        self.syncToGUI = kind == .alias ? false : syncToGUI
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedKind = try container.decodeIfPresent(EnvEntryKind.self, forKey: .kind) ?? .variable
        self.kind = decodedKind
        self.name = try container.decode(String.self, forKey: .name)
        self.value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        self.note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        let rawGroup = try container.decodeIfPresent(String.self, forKey: .group) ?? "默认"
        self.group = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "默认" : rawGroup
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let rawKeychain = try container.decodeIfPresent(Bool.self, forKey: .useKeychain) ?? false
        self.useKeychain = decodedKind == .secret ? rawKeychain : false
        let rawExpansion = try container.decodeIfPresent(Bool.self, forKey: .allowExpansion) ?? false
        self.allowExpansion = decodedKind == .variable ? rawExpansion : false
        let rawSyncGUI = try container.decodeIfPresent(Bool.self, forKey: .syncToGUI) ?? (decodedKind != .alias)
        self.syncToGUI = decodedKind == .alias ? false : rawSyncGUI
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

public struct EnvSettings: Codable, Equatable {
    public var autoMountZshrc: Bool
    public var syncLaunchctl: Bool
    public var showHUDOnRefresh: Bool
    public var lastSyncedGUIKeys: [String]

    public init(
        autoMountZshrc: Bool = true,
        syncLaunchctl: Bool = true,
        showHUDOnRefresh: Bool = true,
        lastSyncedGUIKeys: [String] = []
    ) {
        self.autoMountZshrc = autoMountZshrc
        self.syncLaunchctl = syncLaunchctl
        self.showHUDOnRefresh = showHUDOnRefresh
        self.lastSyncedGUIKeys = lastSyncedGUIKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoMountZshrc = try container.decodeIfPresent(Bool.self, forKey: .autoMountZshrc) ?? true
        self.syncLaunchctl = try container.decodeIfPresent(Bool.self, forKey: .syncLaunchctl) ?? true
        self.showHUDOnRefresh = try container.decodeIfPresent(Bool.self, forKey: .showHUDOnRefresh) ?? true
        self.lastSyncedGUIKeys = try container.decodeIfPresent([String].self, forKey: .lastSyncedGUIKeys) ?? []
    }
}

public struct EnvStoreData: Codable, Equatable {
    public var version: Int
    public var settings: EnvSettings
    public var entries: [EnvEntry]

    public init(
        version: Int = 1,
        settings: EnvSettings = EnvSettings(),
        entries: [EnvEntry] = []
    ) {
        self.version = version
        self.settings = settings
        self.entries = entries
    }
}

public enum EnvValidation {
    public static let defaultGroups: [String] = [
        "默认",
        "AI 与模型",
        "代理与网络",
        "云服务与密钥",
        "开发与构建",
        "终端快捷"
    ]

    /// Core session/system variables that should never be unset when disabled or removed.
    public static let protectedFromUnset: Set<String> = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM",
        "TMPDIR", "SSH_AUTH_SOCK", "ZDOTDIR", "LANG", "LC_ALL", "PWD", "OLDPWD"
    ]

    /// Read-only or core shell session variables that users should not overwrite via export.
    public static let reservedVariableNames: Set<String> = [
        "HOME", "USER", "LOGNAME", "SHELL", "UID", "EUID", "GID", "EGID",
        "PPID", "PWD", "OLDPWD", "IFS", "SHLVL", "RANDOM", "SECONDS",
        "LINENO", "HISTCHARS", "TTY", "_"
    ]

    /// Zsh reserved keywords & critical builtins that must not be shadowed by aliases.
    public static let reservedAliasNames: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "select", "function", "time", "coproc", "foreach", "end",
        "export", "unset", "unalias", "alias", "source", "builtin", "command", "typeset", "local", "return", "exit"
    ]

    public static func validateName(_ rawName: String, kind: EnvEntryKind) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return kind == .alias ? "请输入快捷别名名称（如 ll、gst、proxy）。" : "请输入环境变量名称（如 OPENAI_API_KEY）。"
        }

        switch kind {
        case .variable, .secret:
            let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
            guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
                return "变量名仅支持字母、数字与下划线，且不能以数字开头（例如 API_KEY）。"
            }
            if reservedVariableNames.contains(trimmed) {
                return "「\(trimmed)」是系统核心会话或只读变量，不允许覆盖。"
            }
            return nil

        case .alias:
            let pattern = #"^[A-Za-z0-9_.:+-]+$"#
            guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
                return "别名仅支持字母、数字及 _ . : + - 字符，不能包含空格或引号。"
            }
            if reservedAliasNames.contains(trimmed) {
                return "「\(trimmed)」是 Shell 保留关键字或核心内建命令，不能用作别名。"
            }
            return nil
        }
    }

    public static func isLikelySecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        // Exclude non-secret settings like TOKENIZERS_PARALLELISM or MAX_TOKENS
        let nonSecretExclusions = [
            "MAX_TOKENS", "TOKENIZERS_PARALLELISM", "KEYBIND", "KEYBOARD", "PASSIVE", "KEYMAP"
        ]
        if nonSecretExclusions.contains(where: { upper.contains($0) }) {
            return false
        }
        let tokens = [
            "API_KEY", "APIKEY", "SECRET", "PASSWORD", "PASSWD", "ACCESS_KEY",
            "PRIVATE_KEY", "AUTH_TOKEN", "BEARER", "CLIENT_SECRET", "CREDENTIAL"
        ]
        if tokens.contains(where: { upper.contains($0) }) {
            return true
        }
        let parts = Set(upper.split(separator: "_").map(String.init))
        let exactWordMatches: Set<String> = ["TOKEN", "PASS", "PWD", "KEY", "SK", "PAT"]
        return !parts.isDisjoint(with: exactWordMatches)
    }

    public static func inferGroup(name: String, kind: EnvEntryKind) -> String {
        if kind == .alias {
            let lower = name.lowercased()
            if lower.contains("proxy") || lower.contains("vpn") {
                return "代理与网络"
            }
            return "终端快捷"
        }
        let upper = name.uppercased()
        if ["OPENAI", "ANTHROPIC", "CLAUDE", "GEMINI", "DEEPSEEK", "DASHSCOPE", "OLLAMA", "HUGGINGFACE", "HF_", "MIMO", "MINIMAX", "MOONSHOT"].contains(where: { upper.contains($0) }) {
            return "AI 与模型"
        }
        if ["PROXY", "NO_PROXY", "SOCKS"].contains(where: { upper.contains($0) }) {
            return "代理与网络"
        }
        if ["AWS_", "ALIYUN", "OSS_", "COS_", "CLOUDFLARE", "SUPABASE", "DATABASE", "DB_", "REDIS", "MONGO", "POSTGRES", "MYSQL", "GITHUB_TOKEN", "GH_TOKEN"].contains(where: { upper.contains($0) }) {
            return "云服务与密钥"
        }
        if ["HOMEBREW", "GOPATH", "GOROOT", "JAVA_HOME", "ANDROID", "NODE", "NPM", "NVM", "PNPM", "CARGO", "RUSTUP", "PYENV", "UV_", "PIP_", "PATH", "EDITOR"].contains(where: { upper.contains($0) }) {
            return "开发与构建"
        }
        return kind == .secret ? "云服务与密钥" : "默认"
    }
}

public enum EnvShellRenderer {
    public static let defaultKeychainService = "com.bofinder.env"

    /// Safely wraps any literal string in POSIX/zsh single quotes (`'...'`).
    /// Nothing inside single quotes is ever expanded or executed by zsh.
    public static func singleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Safely wraps an expandable variable value in double quotes (`"..."`),
    /// allowing `$VAR` / `${VAR}` and leading `~/` expansion while escaping command substitutions `$(` and `` ` ``.
    public static func expandableDoubleQuote(_ value: String) -> String {
        var working = value
        if working == "~" {
            working = "$HOME"
        } else if working.hasPrefix("~/") {
            working = "$HOME/" + working.dropFirst(2)
        }
        var result = "\""
        let chars = Array(working)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                result.append("\\\\")
            } else if ch == "\"" {
                result.append("\\\"")
            } else if ch == "`" {
                result.append("\\`")
            } else if ch == "$" && i + 1 < chars.count && chars[i + 1] == "(" {
                result.append("\\$(")
                i += 2
                continue
            } else {
                result.append(ch)
            }
            i += 1
        }
        result.append("\"")
        return result
    }

    /// Resolves leading `~/` and `$VAR` / `${VAR}` references for macOS `launchctl setenv` GUI sync.
    public static func expandForGUI(
        _ value: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> String {
        var working = value
        if working == "~" {
            working = homeDirectory
        } else if working.hasPrefix("~/") {
            working = homeDirectory + "/" + working.dropFirst(2)
        }

        let nsString = working as NSString
        let pattern = #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return working
        }
        let matches = regex.matches(in: working, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return working }

        var output = working
        for match in matches.reversed() {
            let keyRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let varName = nsString.substring(with: keyRange)
            let replacement: String
            if varName == "HOME" {
                replacement = homeDirectory
            } else {
                replacement = environment[varName] ?? ""
            }
            if let swiftRange = Range(match.range, in: output) {
                output.replaceSubrange(swiftRange, with: replacement)
            }
        }
        return output
    }

    public static func renderEntryCommand(
        _ entry: EnvEntry,
        resolvedValue: String,
        keychainService: String = defaultKeychainService,
        maskSecret: Bool = false
    ) -> String {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch entry.kind {
        case .variable:
            let rhs = entry.allowExpansion
                ? expandableDoubleQuote(resolvedValue)
                : singleQuote(resolvedValue)
            return "export \(name)=\(rhs)"

        case .secret:
            if maskSecret {
                let suffix = entry.useKeychain ? " # Keychain" : ""
                return "export \(name)='••••••••'\(suffix)"
            }
            if entry.useKeychain {
                let acct = "b64:\(entry.id.uuidString)"
                return "export \(name)=\"$(/usr/bin/security find-generic-password -w -a \(singleQuote(acct)) -s \(singleQuote(keychainService)) 2>/dev/null | /usr/bin/base64 -d)\""
            }
            return "export \(name)=\(singleQuote(resolvedValue))"

        case .alias:
            return "alias \(name)=\(singleQuote(resolvedValue))"
        }
    }

    public static func renderEnvZsh(
        entries: [EnvEntry],
        resolvedValues: [UUID: String] = [:],
        keychainService: String = defaultKeychainService
    ) -> String {
        let enabledEntries = entries.filter(\.isEnabled)
        var lines: [String] = [
            "# Generated by DeskSide — Environment Variables & Quick Aliases",
            "# File mode: 0600. Do not edit manually; changes in DeskSide overwrite this file.",
            ""
        ]

        let touchesPath = enabledEntries.contains { $0.kind != .alias && $0.name == "PATH" }
        if touchesPath {
            lines.append("typeset -U path PATH")
        }

        for entry in enabledEntries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard EnvValidation.validateName(name, kind: entry.kind) == nil else { continue }
            let val = resolvedValues[entry.id] ?? entry.value
            if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let cleanNote = entry.note.replacingOccurrences(of: "\n", with: " ")
                lines.append("# [\(entry.group)] \(cleanNote)")
            }
            lines.append(renderEntryCommand(entry, resolvedValue: val, keychainService: keychainService, maskSecret: false))
            switch entry.kind {
            case .variable, .secret:
                if !EnvValidation.protectedFromUnset.contains(name) {
                    lines.append("_DESKSIDE_MANAGED_EXPORTS+=(\(singleQuote(name)))")
                }
            case .alias:
                lines.append("_DESKSIDE_MANAGED_ALIASES+=(\(singleQuote(name)))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    public static func renderLoaderZsh() -> String {
        return """
        # Generated by DeskSide — Automatic environment & alias live-refresh loader
        typeset -ga _DESKSIDE_MANAGED_EXPORTS
        typeset -ga _DESKSIDE_MANAGED_ALIASES

        _deskside_apply_env() {
          local dir="$HOME/.config/deskside"
          local env_file="$dir/env.zsh"
          local stamp_file="$dir/env.stamp"
          local current_stamp=""
          if [ -r "$stamp_file" ]; then
            IFS= read -r current_stamp < "$stamp_file" || true
          elif [ -r "$env_file" ]; then
            current_stamp="init"
          fi
          if [ "$current_stamp" = "${_DESKSIDE_ENV_STAMP:-}" ]; then
            return 0
          fi
          local _item
          for _item in "${_DESKSIDE_MANAGED_EXPORTS[@]}"; do
            [ -n "$_item" ] && unset "$_item" 2>/dev/null || true
          done
          for _item in "${_DESKSIDE_MANAGED_ALIASES[@]}"; do
            [ -n "$_item" ] && unalias "$_item" 2>/dev/null || true
          done
          _DESKSIDE_MANAGED_EXPORTS=()
          _DESKSIDE_MANAGED_ALIASES=()
          if [ -r "$env_file" ]; then
            source "$env_file"
          fi
          _DESKSIDE_ENV_STAMP="$current_stamp"
        }

        _deskside_apply_env

        if [[ -o interactive ]]; then
          TRAPUSR1() {
            _deskside_apply_env
          }
          _deskside_register_shell() {
            local pid_dir="$HOME/.config/deskside/pids"
            command mkdir -p -m 700 "$pid_dir" 2>/dev/null || true
            builtin print -r -- "$$" >| "$pid_dir/$$" 2>/dev/null || true
          }
          _deskside_cleanup_shell() {
            command rm -f "$HOME/.config/deskside/pids/$$" 2>/dev/null || true
          }
          _deskside_precmd() {
            local _ret=$?
            _deskside_apply_env
            return $_ret
          }
          _deskside_register_shell
          autoload -Uz add-zsh-hook
          add-zsh-hook -d precmd _deskside_precmd 2>/dev/null || true
          add-zsh-hook precmd _deskside_precmd
          add-zsh-hook -d zshexit _deskside_cleanup_shell 2>/dev/null || true
          add-zsh-hook zshexit _deskside_cleanup_shell
        fi
        """ + "\n"
    }
}

public enum ZshrcBlockManager {
    public static let startMarker = "# >>> DeskSide Env >>>"
    public static let endMarker = "# <<< DeskSide Env <<<"

    public static var managedBlock: String {
        return """
        \(startMarker)
        # Managed by DeskSide. Keeps environment variables and quick aliases auto-refreshed.
        if [ -f "$HOME/.config/deskside/loader.zsh" ]; then
          source "$HOME/.config/deskside/loader.zsh"
        fi
        \(endMarker)
        """
    }

    public static func isMounted(in content: String) -> Bool {
        guard let startRange = content.range(of: startMarker),
              let endRange = content.range(of: endMarker),
              startRange.lowerBound < endRange.lowerBound else {
            return false
        }
        return true
    }

    public static func installingBlock(into content: String) -> String {
        if let startRange = content.range(of: startMarker),
           let endRange = content.range(of: endMarker),
           startRange.lowerBound < endRange.upperBound {
            var updated = content
            updated.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: managedBlock)
            if !updated.hasSuffix("\n") {
                updated.append("\n")
            }
            return updated
        }

        let trimmedRight = content.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        if trimmedRight.isEmpty {
            return managedBlock + "\n"
        }
        return trimmedRight + "\n\n" + managedBlock + "\n"
    }

    public static func removingBlock(from content: String) -> String {
        guard let startRange = content.range(of: startMarker),
              let endRange = content.range(of: endMarker),
              startRange.lowerBound < endRange.upperBound else {
            return content
        }
        var updated = content
        var lower = startRange.lowerBound
        while lower > updated.startIndex {
            let prev = updated.index(before: lower)
            if updated[prev] == "\n" {
                lower = prev
                break
            } else if updated[prev] == " " || updated[prev] == "\t" {
                lower = prev
            } else {
                break
            }
        }
        var upper = endRange.upperBound
        if upper < updated.endIndex && updated[upper] == "\n" {
            upper = updated.index(after: upper)
        }
        updated.removeSubrange(lower..<upper)
        return updated
    }
}

public struct EnvImportedCandidate: Identifiable, Equatable {
    public var id: UUID
    public var entry: EnvEntry
    public var sourceLineNumber: Int
    public var isAlreadyManaged: Bool
    public var isPathVariable: Bool
    public var selected: Bool

    public init(
        id: UUID = UUID(),
        entry: EnvEntry,
        sourceLineNumber: Int,
        isAlreadyManaged: Bool = false,
        isPathVariable: Bool = false,
        selected: Bool = true
    ) {
        self.id = id
        self.entry = entry
        self.sourceLineNumber = sourceLineNumber
        self.isAlreadyManaged = isAlreadyManaged
        self.isPathVariable = isPathVariable
        self.selected = selected
    }
}

public enum EnvShellParser {
    public static func parse(
        content: String,
        isDotEnv: Bool = false,
        existingNames: Set<String> = []
    ) -> [EnvImportedCandidate] {
        let lines = content.components(separatedBy: .newlines)
        var candidates: [EnvImportedCandidate] = []
        var insideDeskSideBlock = false
        var pendingComment: String = ""

        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed == ZshrcBlockManager.startMarker {
                insideDeskSideBlock = true
                pendingComment = ""
                continue
            }
            if trimmed == ZshrcBlockManager.endMarker {
                insideDeskSideBlock = false
                pendingComment = ""
                continue
            }
            if insideDeskSideBlock {
                continue
            }

            if trimmed.isEmpty {
                pendingComment = ""
                continue
            }

            if trimmed.hasPrefix("#") {
                let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                // Ignore decorative separator comments or shebangs
                if !body.hasPrefix("!") && body.range(of: #"^[-=*#><_]{3,}$"#, options: .regularExpression) == nil {
                    pendingComment = body
                }
                continue
            }

            if let parsed = parseExportOrDotEnv(line: trimmed, allowBareAssignment: isDotEnv, precedingNote: pendingComment) {
                let isDuplicate = existingNames.contains("\(parsed.kind == .alias ? "alias" : "env"):\(parsed.name)")
                let isPath = parsed.name == "PATH"
                candidates.append(
                    EnvImportedCandidate(
                        entry: parsed,
                        sourceLineNumber: lineNo,
                        isAlreadyManaged: isDuplicate,
                        isPathVariable: isPath,
                        selected: !isDuplicate && !isPath
                    )
                )
                pendingComment = ""
                continue
            }

            if !isDotEnv, let parsedAlias = parseAlias(line: trimmed, precedingNote: pendingComment) {
                let isDuplicate = existingNames.contains("alias:\(parsedAlias.name)")
                candidates.append(
                    EnvImportedCandidate(
                        entry: parsedAlias,
                        sourceLineNumber: lineNo,
                        isAlreadyManaged: isDuplicate,
                        isPathVariable: false,
                        selected: !isDuplicate
                    )
                )
                pendingComment = ""
                continue
            }

            pendingComment = ""
        }

        return candidates
    }

    private static func parseExportOrDotEnv(
        line: String,
        allowBareAssignment: Bool,
        precedingNote: String
    ) -> EnvEntry? {
        var rest = line
        if rest.hasPrefix("export ") || rest.hasPrefix("export\t") {
            rest = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if !allowBareAssignment {
            return nil
        }

        guard let eqIndex = rest.firstIndex(of: "=") else { return nil }
        let rawName = String(rest[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        guard EnvValidation.validateName(rawName, kind: .variable) == nil else { return nil }

        let rhs = String(rest[rest.index(after: eqIndex)...])
        let (value, hasExpansion, inlineComment) = unquoteShellRHS(rhs)
        let isSecret = EnvValidation.isLikelySecretName(rawName)
        let kind: EnvEntryKind = isSecret ? .secret : .variable
        let finalNote = !inlineComment.isEmpty ? inlineComment : precedingNote

        return EnvEntry(
            kind: kind,
            name: rawName,
            value: value,
            note: finalNote,
            group: EnvValidation.inferGroup(name: rawName, kind: kind),
            isEnabled: true,
            useKeychain: false,
            allowExpansion: kind == .variable ? hasExpansion : false,
            syncToGUI: rawName != "PATH"
        )
    }

    private static func parseAlias(line: String, precedingNote: String) -> EnvEntry? {
        guard line.hasPrefix("alias ") || line.hasPrefix("alias\t") else { return nil }
        var rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("-- ") {
            rest = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        guard let eqIndex = rest.firstIndex(of: "=") else { return nil }
        let rawName = String(rest[..<eqIndex]).trimmingCharacters(in: .whitespaces)
        guard EnvValidation.validateName(rawName, kind: .alias) == nil else { return nil }

        let rhs = String(rest[rest.index(after: eqIndex)...])
        let (value, _, inlineComment) = unquoteShellRHS(rhs)
        guard !value.isEmpty else { return nil }
        let finalNote = !inlineComment.isEmpty ? inlineComment : precedingNote

        return EnvEntry(
            kind: .alias,
            name: rawName,
            value: value,
            note: finalNote,
            group: EnvValidation.inferGroup(name: rawName, kind: .alias),
            isEnabled: true,
            useKeychain: false,
            allowExpansion: false,
            syncToGUI: false
        )
    }

    private static func unquoteShellRHS(_ rawRHS: String) -> (value: String, hasExpansion: Bool, inlineComment: String) {
        let trimmed = rawRHS.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ("", false, "") }

        if trimmed.first == "'" {
            // Parse single-quoted string including '\'' sequences
            let chars = Array(trimmed)
            var i = 1
            var out = ""
            while i < chars.count {
                if chars[i] == "'" {
                    // Check for '\'' continuation
                    if i + 3 < chars.count && chars[i + 1] == "\\" && chars[i + 2] == "'" && chars[i + 3] == "'" {
                        out.append("'")
                        i += 4
                        continue
                    }
                    let tail = i + 1 < chars.count ? String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces) : ""
                    let comment = extractLeadingComment(tail)
                    return (out, false, comment)
                }
                out.append(chars[i])
                i += 1
            }
            return (out, false, "")
        }

        if trimmed.first == "\"" {
            let chars = Array(trimmed)
            var i = 1
            var out = ""
            var sawExpansion = false
            while i < chars.count {
                let c = chars[i]
                if c == "\\" && i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "\"" || next == "\\" || next == "$" || next == "`" {
                        out.append(next)
                        i += 2
                        continue
                    }
                }
                if c == "\"" {
                    let tail = i + 1 < chars.count ? String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces) : ""
                    let comment = extractLeadingComment(tail)
                    return (out, sawExpansion, comment)
                }
                if c == "$" && i + 1 < chars.count && (chars[i + 1] == "{" || chars[i + 1].isLetter || chars[i + 1] == "_") {
                    sawExpansion = true
                }
                out.append(c)
                i += 1
            }
            return (out, sawExpansion, "")
        }

        // Unquoted value: read until unescaped `#` preceded by whitespace
        let chars = Array(trimmed)
        var out = ""
        var comment = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "#" && (i == 0 || chars[i - 1].isWhitespace) {
                comment = String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                break
            }
            out.append(chars[i])
            i += 1
        }
        let cleaned = out.trimmingCharacters(in: .whitespaces)
        let hasExpansion = cleaned == "~"
            || cleaned.hasPrefix("~/")
            || cleaned.range(of: #"\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) != nil
        return (cleaned, hasExpansion, comment)
    }

    private static func extractLeadingComment(_ tail: String) -> String {
        guard tail.hasPrefix("#") else { return "" }
        return String(tail.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}

public struct EnvPresetTemplate: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let entries: [EnvEntry]

    public static let all: [EnvPresetTemplate] = [
        EnvPresetTemplate(
            id: "proxy_aliases",
            title: "终端代理快捷命令 (proxy / unproxy)",
            subtitle: "在终端输入 proxy 一键开启代理、unproxy 一键关闭",
            symbolName: "network",
            entries: [
                EnvEntry(
                    kind: .alias,
                    name: "proxy",
                    value: "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890 && echo 'Proxy ON (127.0.0.1:7890)'",
                    note: "一键开启当前终端 HTTP/SOCKS 代理",
                    group: "代理与网络"
                ),
                EnvEntry(
                    kind: .alias,
                    name: "unproxy",
                    value: "unset https_proxy http_proxy all_proxy HTTPS_PROXY HTTP_PROXY ALL_PROXY && echo 'Proxy OFF'",
                    note: "一键关闭当前终端代理变量",
                    group: "代理与网络"
                )
            ]
        ),
        EnvPresetTemplate(
            id: "global_proxy_vars",
            title: "常驻 HTTP / HTTPS 代理变量",
            subtitle: "添加 https_proxy 与 http_proxy，可通过开关随时一键启停",
            symbolName: "globe",
            entries: [
                EnvEntry(
                    kind: .variable,
                    name: "https_proxy",
                    value: "http://127.0.0.1:7890",
                    note: "本地代理 HTTPS 端口（默认暂停，按需开启）",
                    group: "代理与网络",
                    isEnabled: false
                ),
                EnvEntry(
                    kind: .variable,
                    name: "http_proxy",
                    value: "http://127.0.0.1:7890",
                    note: "本地代理 HTTP 端口（默认暂停，按需开启）",
                    group: "代理与网络",
                    isEnabled: false
                )
            ]
        ),
        EnvPresetTemplate(
            id: "git_shell_aliases",
            title: "常用目录与 Git 快捷别名 (ll / gst / glog)",
            subtitle: "添加高频终端快捷命令，减少日常重复输入",
            symbolName: "bolt.fill",
            entries: [
                EnvEntry(kind: .alias, name: "ll", value: "ls -laFhG", note: "彩色详细目录列表", group: "终端快捷"),
                EnvEntry(kind: .alias, name: "gst", value: "git status -sb", note: "精简查看 Git 状态", group: "终端快捷"),
                EnvEntry(kind: .alias, name: "glog", value: "git log --oneline --graph --decorate -n 20", note: "查看最近 20 条分支提交图", group: "终端快捷")
            ]
        ),
        EnvPresetTemplate(
            id: "homebrew_mirror",
            title: "Homebrew API 加速与无自动更新",
            subtitle: "关闭每次 brew install 时的缓慢自动更新检查",
            symbolName: "shippingbox",
            entries: [
                EnvEntry(
                    kind: .variable,
                    name: "HOMEBREW_NO_AUTO_UPDATE",
                    value: "1",
                    note: "执行 brew install 时跳过漫长的自动更新",
                    group: "开发与构建"
                )
            ]
        )
    ]
}
