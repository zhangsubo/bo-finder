import Foundation
import ServiceManagement

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    private let agentLabel = "com.bofinder.app.launcher"

    private var launchAgentPlistURL: URL {
        let home = PathFormatter.realHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    private init() {}

    var isEnabled: Bool {
        if SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
            installLaunchAgentPlist()
        } else {
            try? SMAppService.mainApp.unregister()
            removeLaunchAgentPlist()
        }
    }

    func syncWithConfig() {
        let shouldEnable = CutPasteManager.shared.state.config.launchAtLogin
        if shouldEnable {
            installLaunchAgentPlist()
        } else if FileManager.default.fileExists(atPath: launchAgentPlistURL.path) {
            removeLaunchAgentPlist()
        }
    }

    private func installLaunchAgentPlist() {
        let fm = FileManager.default
        let agentsDir = launchAgentPlistURL.deletingLastPathComponent()
        try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let appBundlePath = Bundle.main.bundleURL.path
        let plistDict: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", appBundlePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        if let data = try? PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        ) {
            try? data.write(to: launchAgentPlistURL, options: .atomic)
        }
    }

    private func removeLaunchAgentPlist() {
        try? FileManager.default.removeItem(at: launchAgentPlistURL)
    }
}
