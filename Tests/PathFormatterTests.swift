import Foundation

@main
struct PathFormatterTests {
    static func main() {
        print("Running DeskSide Unit Tests...")
        var passed = 0
        var failed = 0

        func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
            if actual == expected {
                passed += 1
                print("  ✅ \(message)")
            } else {
                failed += 1
                print("  ❌ \(message)\n     Expected: \(expected)\n     Actual:   \(actual)")
            }
        }

        let testURL = URL(fileURLWithPath: "/Users/demo/My Folder/测试 文件 (1).txt")

        // 1. POSIX path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .posix),
            "/Users/demo/My Folder/测试 文件 (1).txt",
            "POSIX path formatting"
        )

        // 2. URL path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .url),
            "file:///Users/demo/My%20Folder/%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6%20(1).txt",
            "URL path formatting with percent encoding"
        )

        // 3. Windows paths
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .backslash),
            "\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows backslash path formatting"
        )
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .driveC),
            "C:\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows C: drive path formatting"
        )
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .unc),
            "\\\\mac\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows UNC path formatting"
        )

        // 4. Terminal escaped path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .terminal),
            "/Users/demo/My\\ Folder/测试\\ 文件\\ \\(1\\).txt",
            "Terminal escaped path formatting"
        )

        // 5. Tilde path
        let home = PathFormatter.realHomeDirectory()
        let homeFileURL = URL(fileURLWithPath: "\(home)/Documents/report.pdf")
        assertEqual(
            PathFormatter.formatSingle(url: homeFileURL, as: .tilde),
            "~/Documents/report.pdf",
            "Home directory tilde (~) path formatting"
        )

        // 6. Filename only
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .filename),
            "测试 文件 (1).txt",
            "Filename only formatting"
        )

        // 7. Multi-file formatting (newline for POSIX, space for Terminal)
        let urlA = URL(fileURLWithPath: "/tmp/a b.txt")
        let urlB = URL(fileURLWithPath: "/tmp/c.txt")
        assertEqual(
            PathFormatter.format(urls: [urlA, urlB], as: .posix),
            "/tmp/a b.txt\n/tmp/c.txt",
            "Multi-file POSIX joined by newline"
        )
        assertEqual(
            PathFormatter.format(urls: [urlA, urlB], as: .terminal),
            "/tmp/a\\ b.txt /tmp/c.txt",
            "Multi-file Terminal escaped joined by space"
        )

        // Decode an existing BoFinder state without renaming fields or resetting preferences.
        let legacyJSON = #"""
        {"config":{"enabledFormats":["markdown","filename","posix"],"useSubmenuForCopyPath":false,"windowsPathStyle":"unc","enableCutAndPasteKeybindings":false,"enableContextMenuCutAndPaste":false,"showHUDFeedback":false,"playSoundOnAction":true,"showTopQuickBarOnRightClick":false,"defaultTerminal":"orca","enableOpenTerminalInMenu":false,"enableOpenInOrcaInMenu":false,"showDockIcon":false,"launchAtLogin":true},"isCutActive":false,"cutFilePaths":[],"updatedAt":12345}
        """#
        do {
            let migrated = try JSONDecoder().decode(SharedRuntimeState.self, from: Data(legacyJSON.utf8))
            let expected = BoFinderConfig(
                enabledFormats: [.markdown, .filename, .posix],
                useSubmenuForCopyPath: false, windowsPathStyle: .unc,
                enableCutAndPasteKeybindings: false, enableContextMenuCutAndPaste: false,
                showHUDFeedback: false, playSoundOnAction: true,
                showTopQuickBarOnRightClick: false, defaultTerminal: .orca,
                enableOpenTerminalInMenu: false, enableOpenInOrcaInMenu: false,
                showDockIcon: false, launchAtLogin: true)
            assertEqual(migrated.config, expected, "All legacy BoFinder configuration values and format order preserved")
            let encoded = try JSONEncoder().encode(migrated)
            let reloaded = try JSONDecoder().decode(SharedRuntimeState.self, from: encoded)
            assertEqual(reloaded, migrated, "Migrated state round-trips without losing settings")
            let early = try JSONDecoder().decode(BoFinderConfig.self, from: Data(#"{"enabledFormats":["url"],"showDockIcon":false}"#.utf8))
            assertEqual(early.enabledFormats, [.url], "Older config retains chosen formats")
            assertEqual(early.showDockIcon, false, "Older config retains hidden Dock preference")
            assertEqual(early.launchAtLogin, false, "Missing legacy option receives original default")
            assertEqual(early.enableHiddenFilesShortcut, true, "Missing hidden-files shortcut toggle defaults to enabled")
            assertEqual(early.hiddenFilesShortcut, .defaultHiddenFiles, "Missing hidden-files shortcut defaults to ⌘+⇧+.")
            assertEqual(BoFinderIPC.stateFileURL.lastPathComponent, "state.json", "Persistent state filename remains compatible")
            assertEqual(BoFinderIPC.appSupportDirectory.lastPathComponent, "BoFinder", "Legacy Application Support directory retained")
            assertEqual(BoFinderIPC.statePasteboardName.rawValue, "com.bofinder.shared.state.v1", "Finder extension IPC namespace retained")

            // 8. Hidden files shortcut formatting, matching, validation, and round-trip
            assertEqual(KeyShortcut.defaultHiddenFiles.displayString, "⌘+⇧+.", "Default hidden files shortcut display string")
            assertEqual(KeyShortcut.presetControlH.displayString, "⌃+H", "Control+H preset display string")
            assertEqual(KeyShortcut.presetOptionPeriod.displayString, "⌥+.", "Option+. preset display string")
            assertEqual(
                KeyShortcut(keyCode: 100, command: true, shift: true, option: true, control: true).displayString,
                "⌃+⌥+⌘+⇧+F8",
                "All-modifier function key display string"
            )
            assertEqual(
                KeyShortcut.presetControlH.matches(keyCode: 4, command: false, shift: false, option: false, control: true),
                true,
                "KeyShortcut matches exact keyCode and modifiers"
            )
            assertEqual(
                KeyShortcut.presetControlH.matches(keyCode: 4, command: true, shift: false, option: false, control: true),
                false,
                "KeyShortcut rejects extra modifier"
            )
            assertEqual(KeyShortcut.defaultHiddenFiles.validateForFinder(), nil, "⌘+⇧+. is valid for Finder")
            assertEqual(KeyShortcut.presetControlH.validateForFinder(), nil, "⌃+H is valid for Finder")
            assertEqual(KeyShortcut.presetOptionPeriod.validateForFinder(), nil, "⌥+. is valid for Finder")
            assertEqual(KeyShortcut(keyCode: 100).validateForFinder(), nil, "Function key F8 without modifiers is valid")
            assertEqual(
                KeyShortcut(keyCode: 4).validateForFinder() != nil,
                true,
                "Bare letter H without modifiers is rejected"
            )
            assertEqual(
                KeyShortcut(keyCode: 8, command: true).validateForFinder() != nil,
                true,
                "Reserved ⌘+C is rejected"
            )
            assertEqual(
                KeyShortcut(keyCode: 8, option: true, control: true).validateForFinder() != nil,
                true,
                "DeskSide reserved ⌃+⌥+C is rejected"
            )

            var customState = SharedRuntimeState()
            customState.config.enableHiddenFilesShortcut = false
            customState.config.hiddenFilesShortcut = .presetControlH
            let customData = try JSONEncoder().encode(customState)
            let decodedCustom = try JSONDecoder().decode(SharedRuntimeState.self, from: customData)
            assertEqual(decodedCustom.config.enableHiddenFilesShortcut, false, "Custom hidden-files shortcut toggle persists")
            assertEqual(decodedCustom.config.hiddenFilesShortcut, .presetControlH, "Custom hidden-files shortcut keyCode/modifiers persist")

            // 9. HiddenFilesPreferenceParser coverage across macOS plist value representations
            assertEqual(HiddenFilesPreferenceParser.parse(nil), false, "Nil AppleShowAllFiles defaults to false")
            assertEqual(HiddenFilesPreferenceParser.parse(true), true, "Bool true parsed as true")
            assertEqual(HiddenFilesPreferenceParser.parse(false), false, "Bool false parsed as false")
            assertEqual(HiddenFilesPreferenceParser.parse(NSNumber(value: 1)), true, "NSNumber 1 parsed as true")
            assertEqual(HiddenFilesPreferenceParser.parse(NSNumber(value: 0)), false, "NSNumber 0 parsed as false")
            assertEqual(HiddenFilesPreferenceParser.parse("TRUE"), true, "String TRUE parsed as true")
            assertEqual(HiddenFilesPreferenceParser.parse("yes"), true, "String yes parsed as true")
            assertEqual(HiddenFilesPreferenceParser.parse("1"), true, "String 1 parsed as true")
            assertEqual(HiddenFilesPreferenceParser.parse("NO"), false, "String NO parsed as false")
            assertEqual(HiddenFilesPreferenceParser.parse("0"), false, "String 0 parsed as false")
        } catch {
            failed += 1
            print("  ❌ Configuration compatibility: \(error)")
        }

        print("\nResults: \(passed) passed, \(failed) failed.")
        if failed > 0 {
            exit(1)
        }
    }
}
