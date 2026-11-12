import Cocoa
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

            // 10. iCloud & CloudStorage detection (including iCloud-synced ~/Desktop & ~/Documents)
            let mobileDocsURL = URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/个人/a.png")
            assertEqual(
                PathFormatter.isCloudBackedURL(mobileDocsURL, ubiquitousLookup: { _ in false }),
                true,
                "Classic iCloud Drive Mobile Documents path detected as cloud"
            )
            let cloudStorageURL = URL(fileURLWithPath: "\(home)/Library/CloudStorage/OneDrive-Personal/doc.docx")
            assertEqual(
                PathFormatter.isCloudBackedURL(cloudStorageURL, ubiquitousLookup: { _ in false }),
                true,
                "FileProvider CloudStorage path detected as cloud"
            )
            let syncedDesktopNestedURL = URL(fileURLWithPath: "\(home)/Desktop/图片文件/20211206101844_407ff.jpeg")
            assertEqual(
                PathFormatter.isCloudBackedURL(syncedDesktopNestedURL, ubiquitousLookup: { candidate in
                    candidate.path == "\(home)/Desktop"
                }),
                true,
                "iCloud-synced ~/Desktop nested file detected via ancestor ubiquitous status"
            )
            assertEqual(
                PathFormatter.isCloudBackedURL(syncedDesktopNestedURL, ubiquitousLookup: { candidate in
                    candidate.path == syncedDesktopNestedURL.path
                }),
                true,
                "Direct ubiquitous item under ~/Desktop detected as cloud"
            )
            let localDownloadsURL = URL(fileURLWithPath: "\(home)/Downloads/archive.zip")
            assertEqual(
                PathFormatter.isCloudBackedURL(localDownloadsURL, ubiquitousLookup: { candidate in
                    candidate.path == home
                }),
                false,
                "Local ~/Downloads file is not falsely flagged as cloud and stops at home directory"
            )

            // 11. Conflict alert "全部按此进行" checkbox & batch direct-move resolution
            let conflictAlert = CutMoveBatchRunner.makeConflictAlert(fileName: "杨佳乐.pdf", targetFolder: "面试")
            conflictAlert.layout()
            assertEqual(conflictAlert.showsSuppressionButton, true, "Conflict alert enables suppression checkbox")
            assertEqual(conflictAlert.suppressionButton?.title, "全部按此进行", "Conflict alert checkbox title is 全部按此进行")
            assertEqual(conflictAlert.suppressionButton?.state, .off, "Conflict alert checkbox defaults to unchecked")
            assertEqual(conflictAlert.buttons.map(\.title), ["保留两者", "替换", "跳过"], "Conflict alert preserves button order")
            assertEqual(
                CutMoveBatchRunner.resolveConflictChoice(response: .alertFirstButtonReturn, suppressionState: .on),
                FileConflictChoice(resolution: .keepBoth, applyToAll: true),
                "First button with checkbox on maps to keepBoth + applyToAll"
            )
            assertEqual(
                CutMoveBatchRunner.resolveConflictChoice(response: .alertSecondButtonReturn, suppressionState: .off),
                FileConflictChoice(resolution: .replace, applyToAll: false),
                "Second button with checkbox off maps to replace without applyToAll"
            )
            assertEqual(
                CutMoveBatchRunner.resolveConflictChoice(response: .alertThirdButtonReturn, suppressionState: .on),
                FileConflictChoice(resolution: .skip, applyToAll: true),
                "Third button with checkbox on maps to skip + applyToAll"
            )

            let fm = FileManager.default
            let tempRoot = fm.temporaryDirectory.appendingPathComponent("deskside-conflict-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempRoot) }
            let srcDir = tempRoot.appendingPathComponent("src")
            let dstDir = tempRoot.appendingPathComponent("面试")
            try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

            for name in ["杨佳乐.pdf", "张三.pdf", "李四.pdf"] {
                try Data("new-\(name)".utf8).write(to: srcDir.appendingPathComponent(name))
                try Data("old-\(name)".utf8).write(to: dstDir.appendingPathComponent(name))
            }
            var keepBothPrompts = 0
            let keepBothOutcome = CutMoveBatchRunner.executeDirectMove(
                sourcePaths: ["杨佳乐.pdf", "张三.pdf", "李四.pdf"].map { srcDir.appendingPathComponent($0).path },
                toDirectory: dstDir,
                fileManager: fm,
                conflictHandler: { _, _ in
                    keepBothPrompts += 1
                    return FileConflictChoice(resolution: .keepBoth, applyToAll: true)
                }
            )
            assertEqual(keepBothPrompts, 1, "applyToAll keepBoth prompts only once for 3 conflicts")
            assertEqual(keepBothOutcome, DirectMoveOutcome(movedCount: 3, skippedCount: 0, lastError: nil), "All 3 files moved when keeping both")
            assertEqual(fm.fileExists(atPath: srcDir.appendingPathComponent("杨佳乐.pdf").path), false, "Source files removed after batch keepBoth move")
            assertEqual(
                try String(contentsOf: dstDir.appendingPathComponent("李四 2.pdf"), encoding: .utf8),
                "new-李四.pdf",
                "Batch keepBoth creates numbered copy with incoming content"
            )

            for name in ["a.txt", "b.txt", "c.txt"] {
                try Data("incoming-\(name)".utf8).write(to: srcDir.appendingPathComponent(name))
                try Data("existing-\(name)".utf8).write(to: dstDir.appendingPathComponent(name))
            }
            var mixedPrompts = 0
            let mixedOutcome = CutMoveBatchRunner.executeDirectMove(
                sourcePaths: ["a.txt", "b.txt", "c.txt"].map { srcDir.appendingPathComponent($0).path },
                toDirectory: dstDir,
                fileManager: fm,
                conflictHandler: { _, _ in
                    mixedPrompts += 1
                    if mixedPrompts == 1 {
                        return FileConflictChoice(resolution: .skip, applyToAll: false)
                    }
                    return FileConflictChoice(resolution: .replace, applyToAll: true)
                }
            )
            assertEqual(mixedPrompts, 2, "Unchecked first conflict asks again, checked second conflict applies to remaining")
            assertEqual(mixedOutcome, DirectMoveOutcome(movedCount: 2, skippedCount: 1, lastError: nil), "Mixed skip then applyToAll replace counts both moved and skipped")
            assertEqual(fm.fileExists(atPath: srcDir.appendingPathComponent("a.txt").path), true, "Skipped file remains in source folder")
            assertEqual(
                try String(contentsOf: dstDir.appendingPathComponent("c.txt"), encoding: .utf8),
                "incoming-c.txt",
                "Remaining conflicting file replaced automatically via applyToAll"
            )

            // 12. Accessibility permission guide overlay layout & stationary capsule invariants
            let pickedBounds = PermissionGuideLayout.selectSystemSettingsBounds(from: [
                (layer: 3, bounds: CGRect(x: 300, y: 20, width: 900, height: 700)),
                (layer: 0, bounds: CGRect(x: 520, y: 180, width: 420, height: 300)), // auth sheet
                (layer: 0, bounds: CGRect(x: 413, y: 30, width: 740, height: 625))   // main System Settings window
            ])
            assertEqual(
                pickedBounds,
                CGRect(x: 413, y: 30, width: 740, height: 625),
                "Selects main System Settings window over modal sheets and non-layer-0 windows"
            )
            let snappedHUDFrame = PermissionGuideLayout.overlayFrame(
                forSystemSettingsCGFrame: CGRect(x: 413, y: 30, width: 740, height: 625),
                primaryScreenHeight: 900
            )
            assertEqual(
                snappedHUDFrame,
                NSRect(x: 647, y: 255, width: 488, height: 154),
                "Centers stationary HUD over bottom of System Settings right-hand Accessibility pane"
            )
            let pillView = DraggableAppPillNSView(frame: NSRect(x: 0, y: 0, width: 316, height: 54))
            pillView.layoutSubtreeIfNeeded()
            assertEqual(pillView.mouseDownCanMoveWindow, false, "Capsule view never drags parent HUD window")
            assertEqual(pillView.acceptsFirstMouse(for: nil), true, "Capsule view accepts first-mouse drag without focus switch")
            assertEqual(pillView.hitTest(NSPoint(x: 24, y: 27)) === pillView, true, "Clicking app icon routes directly to capsule drag view")
            assertEqual(pillView.hitTest(NSPoint(x: 120, y: 27)) === pillView, true, "Clicking app title routes directly to capsule drag view")

            // 13. Stale Accessibility TCC cleanup & silent-update re-authorization policy
            var resetCalls: [String] = []
            let skippedTrusted = PermissionGuideLayout.resetAccessibilityTCCEntryIfNeeded(
                isCurrentlyTrusted: true,
                bundleIdentifier: "com.bofinder.app",
                runner: { id in resetCalls.append(id); return true }
            )
            assertEqual(skippedTrusted, false, "Never resets Accessibility TCC record when already trusted")
            assertEqual(resetCalls.isEmpty, true, "Runner not invoked when Accessibility is already trusted")

            let cleanedUntrusted = PermissionGuideLayout.resetAccessibilityTCCEntryIfNeeded(
                isCurrentlyTrusted: false,
                bundleIdentifier: "com.bofinder.app",
                runner: { id in resetCalls.append(id); return true }
            )
            assertEqual(cleanedUntrusted, true, "Auto-cleans stale Accessibility TCC record before opening guide when untrusted")
            assertEqual(resetCalls, ["com.bofinder.app"], "Passes exact bundle ID to TCC reset runner")

            assertEqual(
                PermissionGuideLayout.shouldAutoPromptReauthorizationAfterSilentUpdate(
                    isSilentRelaunch: true,
                    isCurrentlyTrusted: false,
                    hasEverGrantedAccessibility: true
                ),
                true,
                "Prompts re-authorization after silent ad-hoc update when user previously granted Accessibility"
            )
            assertEqual(
                PermissionGuideLayout.shouldAutoPromptReauthorizationAfterSilentUpdate(
                    isSilentRelaunch: true,
                    isCurrentlyTrusted: true,
                    hasEverGrantedAccessibility: true
                ),
                false,
                "Does not prompt after silent update when local-cert re-signing kept Accessibility trusted"
            )
            assertEqual(
                PermissionGuideLayout.shouldAutoPromptReauthorizationAfterSilentUpdate(
                    isSilentRelaunch: true,
                    isCurrentlyTrusted: false,
                    hasEverGrantedAccessibility: false
                ),
                false,
                "Does not nag users who never enabled Accessibility on silent update"
            )
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
