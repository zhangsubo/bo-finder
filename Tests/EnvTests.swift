import Cocoa
import Darwin

@main
struct EnvTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else {
                fatalError("Failed: \(label)")
            }
            checks += 1
            print("  ✅ \(label)")
        }

        // 1. Validation tests
        check(EnvValidation.validateName("OPENAI_API_KEY", kind: .secret) == nil, "Valid secret variable name")
        check(EnvValidation.validateName("_LOCAL_PORT_1", kind: .variable) == nil, "Valid underscore variable name")
        check(EnvValidation.validateName("1INVALID", kind: .variable) != nil, "Leading digit rejected for export")
        check(EnvValidation.validateName("BAD-NAME", kind: .variable) != nil, "Hyphen rejected for export")
        check(EnvValidation.validateName("HOME", kind: .variable) != nil, "System HOME protected from overwrite")
        check(EnvValidation.validateName("UID", kind: .variable) != nil, "Read-only UID protected from overwrite")

        check(EnvValidation.validateName("ll", kind: .alias) == nil, "Valid short alias")
        check(EnvValidation.validateName("proxy-on", kind: .alias) == nil, "Valid hyphenated alias")
        check(EnvValidation.validateName("source", kind: .alias) != nil, "Reserved builtin 'source' rejected as alias")
        check(EnvValidation.validateName("unset", kind: .alias) != nil, "Reserved builtin 'unset' rejected as alias")
        check(EnvValidation.validateName("bad alias", kind: .alias) != nil, "Whitespace rejected in alias name")

        // 2. Secret detection & group inference
        check(EnvValidation.isLikelySecretName("OPENAI_API_KEY"), "Detects API_KEY as secret")
        check(EnvValidation.isLikelySecretName("DB_PASSWORD"), "Detects PASSWORD as secret")
        check(EnvValidation.isLikelySecretName("GH_TOKEN"), "Detects TOKEN word as secret")
        check(!EnvValidation.isLikelySecretName("MAX_TOKENS"), "Does not misclassify MAX_TOKENS as secret")
        check(!EnvValidation.isLikelySecretName("TOKENIZERS_PARALLELISM"), "Does not misclassify TOKENIZERS_PARALLELISM")
        check(!EnvValidation.isLikelySecretName("HTTPS_PROXY"), "Does not misclassify HTTPS_PROXY as secret")
        check(EnvValidation.inferGroup(name: "ANTHROPIC_API_KEY", kind: .secret) == "AI 与模型", "Infers AI group")
        check(EnvValidation.inferGroup(name: "https_proxy", kind: .variable) == "代理与网络", "Infers proxy group")

        // 3. Quoting, escaping & GUI variable expansion
        let trickySecret = #"p@ss'w"rd$HOME`uname`$(id)\end!"#
        let singleQuoted = EnvShellRenderer.singleQuote(trickySecret)
        check(singleQuoted == #"'p@ss'\''w"rd$HOME`uname`$(id)\end!'"#, "Single quote escapes embedded apostrophes")

        let expandable = EnvShellRenderer.expandableDoubleQuote("~/go/bin:$PATH:$(whoami)`id`")
        check(expandable == #""$HOME/go/bin:$PATH:\$(whoami)\`id\`""#, "Expandable double quote allows $HOME/$PATH but neutralizes command substitution")

        let guiExpanded = EnvShellRenderer.expandForGUI(
            "~/sdk:${CUSTOM_ROOT}/bin:$MISSING",
            homeDirectory: "/Users/tester",
            environment: ["CUSTOM_ROOT": "/opt/custom"]
        )
        check(guiExpanded == "/Users/tester/sdk:/opt/custom/bin:", "GUI expansion resolves tilde and env references")

        // 4. Keychain command & masked preview rendering
        let kcID = UUID()
        let kcEntry = EnvEntry(id: kcID, kind: .secret, name: "PROD_SECRET", value: "", useKeychain: true)
        let kcCmd = EnvShellRenderer.renderEntryCommand(kcEntry, resolvedValue: "topsecret", maskSecret: false)
        check(kcCmd.contains("/usr/bin/security find-generic-password") && kcCmd.contains("b64:\(kcID.uuidString)") && !kcCmd.contains("topsecret"), "Keychain secret command never embeds plaintext")
        let maskedCmd = EnvShellRenderer.renderEntryCommand(kcEntry, resolvedValue: "topsecret", maskSecret: true)
        check(maskedCmd.contains("••••••••") && !maskedCmd.contains("topsecret"), "Masked preview hides secret value")

        // 5. Zshrc block mount / unmount idempotency
        let originalZshrc = "export LANG=en_US.UTF-8\nalias hi='echo hello'\n"
        check(!ZshrcBlockManager.isMounted(in: originalZshrc), "Detects unmounted zshrc")
        let mountedOnce = ZshrcBlockManager.installingBlock(into: originalZshrc)
        check(ZshrcBlockManager.isMounted(in: mountedOnce), "Detects mounted zshrc")
        let mountedTwice = ZshrcBlockManager.installingBlock(into: mountedOnce)
        check(mountedOnce == mountedTwice, "Mounting zshrc block is idempotent")
        let unmounted = ZshrcBlockManager.removingBlock(from: mountedTwice)
        check(!ZshrcBlockManager.isMounted(in: unmounted) && unmounted.contains("alias hi='echo hello'"), "Unmounting preserves user zshrc lines")

        // 6. Shell & .env import parser
        let sampleZshrc = """
        # OpenAI main key
        export OPENAI_API_KEY="sk-live-12345"
        export GOPATH="$HOME/go" # Go workspace
        export PATH="/opt/homebrew/bin:$PATH"
        alias gst='git status -sb' # Quick git status
        \(ZshrcBlockManager.managedBlock)
        """
        let parsed = EnvShellParser.parse(
            content: sampleZshrc,
            isDotEnv: false,
            existingNames: ["alias:gst"]
        )
        check(parsed.count == 4, "Parses exports and aliases while ignoring DeskSide block")
        check(parsed[0].entry.name == "OPENAI_API_KEY" && parsed[0].entry.kind == .secret && parsed[0].entry.note == "OpenAI main key", "Captures preceding comment and secret type")
        check(parsed[1].entry.name == "GOPATH" && parsed[1].entry.allowExpansion && parsed[1].entry.note == "Go workspace", "Detects $HOME expansion and inline comment")
        check(parsed[2].isPathVariable && !parsed[2].selected, "Leaves PATH unselected by default to prevent duplication")
        check(parsed[3].isAlreadyManaged && !parsed[3].selected, "Leaves existing alias unselected by default")

        let dotEnvParsed = EnvShellParser.parse(content: "REDIS_PASSWORD='s3cr\\'et'\nPORT=8080\n", isDotEnv: true)
        check(dotEnvParsed.count == 2 && dotEnvParsed[0].entry.kind == .secret && dotEnvParsed[1].entry.value == "8080", "Parses bare KEY=VALUE in .env mode")

        // 7. End-to-end real /bin/zsh auto-refresh & unset/unalias verification
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("deskside-env-test-\(UUID().uuidString)", isDirectory: true)
        let cfgDir = tempHome.appendingPathComponent(".config/deskside", isDirectory: true)
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let loaderFile = cfgDir.appendingPathComponent("loader.zsh")
        let envFile = cfgDir.appendingPathComponent("env.zsh")
        let stampFile = cfgDir.appendingPathComponent("env.stamp")

        try EnvShellRenderer.renderLoaderZsh().write(to: loaderFile, atomically: true, encoding: .utf8)

        let entryA = EnvEntry(kind: .variable, name: "DESKSIDE_ALPHA", value: "first_val")
        let entrySecret = EnvEntry(kind: .secret, name: "DESKSIDE_PW", value: trickySecret)
        let entryAlias = EnvEntry(kind: .alias, name: "ds_hello", value: "printf 'ALIAS_V1'")
        try EnvShellRenderer.renderEnvZsh(
            entries: [entryA, entrySecret, entryAlias],
            resolvedValues: [entryA.id: entryA.value, entrySecret.id: entrySecret.value, entryAlias.id: entryAlias.value]
        ).write(to: envFile, atomically: true, encoding: .utf8)
        try "stamp-1\n".write(to: stampFile, atomically: true, encoding: .utf8)

        let entryB = EnvEntry(kind: .variable, name: "DESKSIDE_BETA", value: "second_val")
        let envScriptV2 = EnvShellRenderer.renderEnvZsh(
            entries: [
                EnvEntry(id: entryA.id, kind: .variable, name: "DESKSIDE_ALPHA", value: "first_val", isEnabled: false),
                entryB
            ],
            resolvedValues: [entryB.id: entryB.value]
        )
        let envFileV2 = cfgDir.appendingPathComponent("env_v2.zsh")
        try envScriptV2.write(to: envFileV2, atomically: true, encoding: .utf8)

        let zshTestScript = """
        setopt aliases
        source "$HOME/.config/deskside/loader.zsh"
        [ "$DESKSIDE_ALPHA" = "first_val" ] || exit 11
        [ "$DESKSIDE_PW" = \(EnvShellRenderer.singleQuote(trickySecret)) ] || exit 12
        [ "$(eval ds_hello)" = "ALIAS_V1" ] || exit 13

        cp "$HOME/.config/deskside/env_v2.zsh" "$HOME/.config/deskside/env.zsh"
        printf 'stamp-2\\n' >| "$HOME/.config/deskside/env.stamp"
        _deskside_apply_env

        [ -z "${DESKSIDE_ALPHA+x}" ] || exit 14
        [ -z "${DESKSIDE_PW+x}" ] || exit 15
        ! alias ds_hello >/dev/null 2>&1 || exit 16
        [ "$DESKSIDE_BETA" = "second_val" ] || exit 17
        [ -n "$PATH" ] || exit 18
        echo "ZSH_LIVE_REFRESH_OK"
        """

        let proc = Process()
        let outPipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-f", "-c", zshTestScript]
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = tempHome.path
        proc.environment = env
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let outStr = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        check(proc.terminationStatus == 0 && outStr == "ZSH_LIVE_REFRESH_OK", "Live zsh reload sets, updates, unsets, and unaliases cleanly without touching PATH")

        // 8. Interactive zsh (.zshrc -> loader.zsh -> PID registration -> SIGUSR1 live reload -> zshexit cleanup)
        let testZshrc = tempHome.appendingPathComponent(".zshrc")
        try ZshrcBlockManager.installingBlock(into: "").write(to: testZshrc, atomically: true, encoding: .utf8)

        try EnvShellRenderer.renderEnvZsh(
            entries: [entryA, entryAlias],
            resolvedValues: [entryA.id: entryA.value, entryAlias.id: entryAlias.value]
        ).write(to: envFile, atomically: true, encoding: .utf8)
        try "sig-stamp-1\n".write(to: stampFile, atomically: true, encoding: .utf8)

        let stdinPipe = Pipe()
        let interactiveZsh = Process()
        interactiveZsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        interactiveZsh.arguments = ["-i", "+m", "+Z"]
        var izEnv = ProcessInfo.processInfo.environment
        izEnv["HOME"] = tempHome.path
        izEnv["ZDOTDIR"] = tempHome.path
        interactiveZsh.environment = izEnv
        interactiveZsh.standardInput = stdinPipe
        interactiveZsh.standardOutput = FileHandle.nullDevice
        interactiveZsh.standardError = FileHandle.nullDevice
        try interactiveZsh.run()

        let zshPid = interactiveZsh.processIdentifier
        let pidFile = cfgDir.appendingPathComponent("pids/\(zshPid)")

        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            usleep(50_000)
        }
        check(FileManager.default.fileExists(atPath: pidFile.path), "Interactive zsh auto-loads .zshrc block and registers PID file")

        // Update env.zsh + stamp, then send SIGUSR1 while zsh is waiting for next command
        try envScriptV2.write(to: envFile, atomically: true, encoding: .utf8)
        try "sig-stamp-2\n".write(to: stampFile, atomically: true, encoding: .utf8)
        _ = kill(zshPid, SIGUSR1)
        usleep(120_000)

        let resultMarkerFile = tempHome.appendingPathComponent("sig_result.txt")
        let probeCmd = "printf '%s|%s\\n' \"${DESKSIDE_ALPHA:-UNSET}\" \"${DESKSIDE_BETA:-UNSET}\" > \"$HOME/sig_result.txt\"; exit\n"
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data(probeCmd.utf8))
        try? stdinPipe.fileHandleForWriting.close()
        interactiveZsh.waitUntilExit()

        let sigResult = (try? String(contentsOf: resultMarkerFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        check(sigResult == "UNSET|second_val", "Idle interactive zsh refreshes via SIGUSR1 before next user command")
        check(!FileManager.default.fileExists(atPath: pidFile.path), "Interactive zsh cleans up PID file on exit")

        // 9. Verify all SF Symbols used in Env UI exist on macOS
        let symbols = [
            "terminal", "key.fill", "bolt.fill", "exclamationmark.triangle.fill",
            "square.and.arrow.down", "sparkles", "gearshape", "plus",
            "bolt.horizontal.circle.fill", "checkmark.circle.fill", "arrow.clockwise",
            "magnifyingglass", "xmark.circle.fill", "key.radiowaves.forward",
            "lock.shield.fill", "eye", "eye.slash", "doc.on.doc", "pencil", "trash",
            "exclamationmark.circle.fill", "macwindow", "tag", "doc.text.magnifyingglass",
            "doc.on.clipboard", "network", "globe", "shippingbox",
            "arrow.triangle.2.circlepath.circle.fill", "link.badge.plus", "slider.horizontal.3"
        ]
        for sym in symbols {
            check(NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil, "SF Symbol '\(sym)' available")
        }

        print("Env tests: \(checks) passed")
    }
}
