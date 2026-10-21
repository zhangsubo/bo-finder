import Cocoa

struct FinderSyncPluginInfo: Identifiable, Equatable {
    let id: String // bundle identifier
    let version: String
    let isEnabled: Bool
    let path: String

    var displayName: String {
        let url = URL(fileURLWithPath: path)
        // Walk up to the containing .app name if possible
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current.deletingPathExtension().lastPathComponent
            }
            current.deleteLastPathComponent()
        }
        return url.deletingPathExtension().lastPathComponent
    }

    var isBoFinder: Bool {
        id == FinderExtensionDoctor.extensionBundleID
    }
}

final class FinderExtensionDoctor: ObservableObject {
    static let shared = FinderExtensionDoctor()
    static let extensionBundleID = "com.bofinder.app.FinderSync"

    @Published private(set) var plugins: [FinderSyncPluginInfo] = []
    @Published private(set) var isBoFinderExtensionEnabled: Bool = false

    private init() {
        refreshPlugins()
    }

    var builtInAppexPath: String? {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL else { return nil }
        let appexURL = plugInsURL.appendingPathComponent("BoFinderSync.appex")
        if FileManager.default.fileExists(atPath: appexURL.path) {
            return appexURL.path
        }
        return nil
    }

    func registerAndEnableOurExtension() {
        if let appexPath = builtInAppexPath {
            _ = runCommand("/usr/bin/pluginkit", args: ["-a", appexPath])
        }
        _ = runCommand("/usr/bin/pluginkit", args: ["-e", "use", "-i", Self.extensionBundleID])
        refreshPlugins()
    }

    func refreshPlugins() {
        let output = runCommand("/usr/bin/pluginkit", args: ["-m", "-p", "com.apple.FinderSync", "-v"])
        var parsed: [FinderSyncPluginInfo] = []

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("(") else { continue }

            let isEnabled = rawLine.hasPrefix("+")
            // Format: "+    bundle.id(version)\tUUID\tTimestamp\t/path/to/ext.appex"
            let parts = rawLine.components(separatedBy: "\t")
            guard let firstCol = parts.first?.trimmingCharacters(in: .whitespaces) else { continue }

            let cleanedFirst = firstCol.hasPrefix("+") || firstCol.hasPrefix("-") || firstCol.hasPrefix("!")
                ? String(firstCol.dropFirst()).trimmingCharacters(in: .whitespaces)
                : firstCol

            var bundleID = cleanedFirst
            var version = ""
            if let openParen = cleanedFirst.firstIndex(of: "("),
               let closeParen = cleanedFirst.lastIndex(of: ")"),
               openParen < closeParen {
                bundleID = String(cleanedFirst[..<openParen])
                version = String(cleanedFirst[cleanedFirst.index(after: openParen)..<closeParen])
            }

            let path = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
            parsed.append(FinderSyncPluginInfo(
                id: bundleID,
                version: version,
                isEnabled: isEnabled,
                path: path
            ))
        }

        DispatchQueue.main.async {
            self.plugins = parsed
            self.isBoFinderExtensionEnabled = parsed.first(where: { $0.isBoFinder })?.isEnabled ?? false
        }
    }

    func setPluginEnabled(_ pluginID: String, enabled: Bool) {
        let mode = enabled ? "use" : "ignore"
        _ = runCommand("/usr/bin/pluginkit", args: ["-e", mode, "-i", pluginID])
        refreshPlugins()
    }

    /// Disables conflicting global FinderSync extensions (like WPS, CleanMyMac, iRightMouse) while keeping cloud drive sidebar extensions intact.
    func prioritizeBoFinderExtension() {
        let globalConflictKeywords = [
            "CleanMyMac",
            "WPSFinderMenu",
            "iRightMouse",
            "qspace",
            "ezip",
            "DingTalk"
        ]
        let current = plugins
        for plugin in current where !plugin.isBoFinder && plugin.isEnabled {
            let shouldDisable = globalConflictKeywords.contains { keyword in
                plugin.id.localizedCaseInsensitiveContains(keyword) || plugin.path.localizedCaseInsensitiveContains(keyword)
            }
            if shouldDisable {
                _ = runCommand("/usr/bin/pluginkit", args: ["-e", "ignore", "-i", plugin.id])
            }
        }
        registerAndEnableOurExtension()
    }

    @discardableResult
    private func runCommand(_ launchPath: String, args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
