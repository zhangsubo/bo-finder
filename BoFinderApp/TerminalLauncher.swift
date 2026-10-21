import Cocoa

final class TerminalLauncher {
    static let shared = TerminalLauncher()

    private init() {}

    /// Checks whether a given terminal app is installed on this Mac.
    func isInstalled(_ app: TerminalApp) -> Bool {
        return resolvedAppURL(for: app) != nil
    }

    /// Resolves the application bundle URL for a given `TerminalApp`.
    func resolvedAppURL(for app: TerminalApp) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: app.defaultAppPath) {
            return URL(fileURLWithPath: app.defaultAppPath)
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            return url
        }
        let userAppPath = (PathFormatter.realHomeDirectory() as NSString)
            .appendingPathComponent("Applications/\((app.defaultAppPath as NSString).lastPathComponent)")
        if fm.fileExists(atPath: userAppPath) {
            return URL(fileURLWithPath: userAppPath)
        }
        return nil
    }

    /// Resolves the target directory URL from Finder's selected items and/or current targeted folder.
    /// - If the user right-clicked on a folder, returns that folder's URL.
    /// - If the user right-clicked on a file, returns the parent folder URL.
    /// - If the user right-clicked on empty space in a folder, returns that folder's URL.
    func resolveTargetDirectory(selectedPaths: [String], targetDirectoryPath: String?) -> URL? {
        let fm = FileManager.default

        // 1. Check if any selected item is itself a directory (or package/folder)
        for path in selectedPaths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }

        // 2. If a file was right-clicked, use its parent directory (or targetDirectoryPath)
        if let firstPath = selectedPaths.first {
            let parent = URL(fileURLWithPath: firstPath).deletingLastPathComponent()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue {
                return parent
            }
        }

        // 3. Fallback to FinderSync's targetedURL
        if let targetDir = targetDirectoryPath, !targetDir.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: targetDir, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: targetDir)
            }
        }

        return nil
    }

    /// Opens the specified directory in the chosen `TerminalApp` (or falls back to system Terminal if not installed).
    func openTerminal(at directoryURL: URL, using preferredApp: TerminalApp? = nil) {
        let state = CutPasteManager.shared.state
        let requestedApp = preferredApp ?? state.config.defaultTerminal
        let appToUse: TerminalApp
        if isInstalled(requestedApp) {
            appToUse = requestedApp
        } else {
            appToUse = .systemTerminal
        }

        let dirPath = directoryURL.path

        if appToUse == .orca {
            openInOrca(at: directoryURL, createTerminalIfNeeded: true, forceNewTerminal: false)
            return
        }

        let appPath = resolvedAppURL(for: appToUse)?.path ?? appToUse.defaultAppPath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appPath, dirPath]

        do {
            try proc.run()
            notifyLaunchSuccess(
                title: "已在 \(appToUse.shortTitle) 中打开",
                subtitle: dirPath,
                symbolName: appToUse.symbolName
            )
        } catch {
            HUDWindowController.shared.show(
                title: "打开 \(appToUse.shortTitle) 失败",
                subtitle: error.localizedDescription,
                symbolName: "exclamationmark.triangle.fill"
            )
        }
    }

    /// Opens the specified directory as a project/workspace in Orca and focuses its terminal.
    func openInOrca(
        at directoryURL: URL,
        createTerminalIfNeeded: Bool = true,
        forceNewTerminal: Bool = false
    ) {
        guard let orcaAppURL = resolvedAppURL(for: .orca) else {
            HUDWindowController.shared.show(
                title: "未检测到 Orca.app",
                subtitle: "请确认 Orca 已安装在 /Applications/Orca.app",
                symbolName: "exclamationmark.triangle.fill"
            )
            return
        }

        let dirPath = directoryURL.standardizedFileURL.path
        let orcaAppPath = orcaAppURL.path
        let orcaBinPath = (orcaAppPath as NSString).appendingPathComponent("Contents/Resources/bin/orca")
        let orcaElectronPath = (orcaAppPath as NSString).appendingPathComponent("Contents/MacOS/Orca")
        let runtimeClientPath = (orcaAppPath as NSString).appendingPathComponent(
            "Contents/Resources/app.asar.unpacked/out/cli/runtime-client.js"
        )

        notifyLaunchSuccess(
            title: "正在 Orca 中打开「\(directoryURL.lastPathComponent)」",
            subtitle: dirPath,
            symbolName: TerminalApp.orca.symbolName
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default

            // 1. Activate Orca.app window
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = ["-a", orcaAppPath]
            try? openProc.run()
            openProc.waitUntilExit()

            // 2. Ensure Orca runtime is ready via `orca open --json` if available
            if fm.isExecutableFile(atPath: orcaBinPath) {
                let readyProc = Process()
                readyProc.executableURL = URL(fileURLWithPath: orcaBinPath)
                readyProc.arguments = ["open", "--json"]
                readyProc.standardOutput = Pipe()
                readyProc.standardError = Pipe()
                try? readyProc.run()
                readyProc.waitUntilExit()
            }

            // 3. Use Orca's RuntimeClient to add the repo/folder, activate the worktree, and focus/create a terminal
            guard fm.isExecutableFile(atPath: orcaElectronPath),
                  fm.fileExists(atPath: runtimeClientPath) else {
                return
            }

            let script = """
            const { RuntimeClient } = require(process.env.BOFINDER_ORCA_RUNTIME_CLIENT);
            const targetPath = process.env.BOFINDER_TARGET_DIR;
            const createTerm = process.env.BOFINDER_CREATE_TERM === "1";
            const forceNewTerm = process.env.BOFINDER_FORCE_NEW_TERM === "1";

            function shellQuote(s) {
              return "'" + String(s).replace(/'/g, "'\\\\''") + "'";
            }

            (async () => {
              const client = new RuntimeClient(undefined, undefined, null, null);
              let repoRes;
              try {
                repoRes = await client.call("repo.add", { path: targetPath });
              } catch (err) {
                repoRes = await client.call("repo.add", { path: targetPath, kind: "folder" });
              }
              const repo = repoRes.result.repo;
              if (repo.kind === "git") {
                try {
                  await client.call("repo.update", {
                    repo: repo.id,
                    updates: { externalWorktreeVisibility: "show" }
                  });
                } catch {}
              }

              const worktreeSelector = "path:" + repo.path;
              try {
                await client.call("worktree.activate", {
                  worktree: worktreeSelector,
                  notifyClients: true
                });
              } catch {}

              if (createTerm) {
                const isSubdir = targetPath !== repo.path;
                let existingHandle = null;
                if (!forceNewTerm && !isSubdir) {
                  try {
                    const listRes = await client.call("terminal.list", { worktree: worktreeSelector });
                    const terms = (listRes.result && listRes.result.terminals) || [];
                    const live = terms.find(t => t.connected && !t.orphaned) || terms[0];
                    if (live && live.handle) {
                      existingHandle = live.handle;
                    }
                  } catch {}
                }

                if (existingHandle) {
                  try {
                    await client.call("terminal.focus", { terminal: existingHandle });
                  } catch {
                    await client.call("terminal.create", {
                      worktree: worktreeSelector,
                      focus: true,
                      presentation: "focused"
                    });
                  }
                } else {
                  const createParams = {
                    worktree: worktreeSelector,
                    focus: true,
                    presentation: "focused"
                  };
                  if (isSubdir) {
                    createParams.command = "cd " + shellQuote(targetPath);
                  }
                  await client.call("terminal.create", createParams);
                }
              }
            })().catch(err => {
              console.error(err && err.message ? err.message : String(err));
              process.exitCode = 1;
            });
            """

            let nodeProc = Process()
            nodeProc.executableURL = URL(fileURLWithPath: orcaElectronPath)
            nodeProc.arguments = ["-e", script]
            var env = ProcessInfo.processInfo.environment
            env["ELECTRON_RUN_AS_NODE"] = "1"
            env["BOFINDER_ORCA_RUNTIME_CLIENT"] = runtimeClientPath
            env["BOFINDER_TARGET_DIR"] = dirPath
            env["BOFINDER_CREATE_TERM"] = createTerminalIfNeeded ? "1" : "0"
            env["BOFINDER_FORCE_NEW_TERM"] = forceNewTerminal ? "1" : "0"
            nodeProc.environment = env
            nodeProc.standardOutput = Pipe()
            nodeProc.standardError = Pipe()
            try? nodeProc.run()
            nodeProc.waitUntilExit()

            // Bring Orca window to front again after workspace & terminal activation
            let focusProc = Process()
            focusProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            focusProc.arguments = ["-a", orcaAppPath]
            try? focusProc.run()
        }
    }

    private func notifyLaunchSuccess(title: String, subtitle: String, symbolName: String) {
        DispatchQueue.main.async {
            let config = CutPasteManager.shared.state.config
            CutPasteManager.shared.statusMessage = title
            if config.playSoundOnAction {
                NSSound(named: "Pop")?.play()
            }
            if config.showHUDFeedback {
                HUDWindowController.shared.show(
                    title: title,
                    subtitle: subtitle,
                    symbolName: symbolName
                )
            }
        }
    }
}
