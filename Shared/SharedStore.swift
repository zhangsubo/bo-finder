import Cocoa

public enum BoFinderIPC {
    public static let stateChangedNotification = Notification.Name("com.bofinder.ipc.stateChanged")
    public static let requestStateNotification = Notification.Name("com.bofinder.ipc.requestState")
    public static let extensionActionNotification = Notification.Name("com.bofinder.ipc.extensionAction")

    public static let statePasteboardName = NSPasteboard.Name("com.bofinder.shared.state.v1")
    public static let actionPasteboardName = NSPasteboard.Name("com.bofinder.shared.action.v1")
    private static let pasteboardDataType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    public static var appSupportDirectory: URL {
        let home = PathFormatter.realHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/BoFinder", isDirectory: true)
    }

    public static var stateFileURL: URL {
        appSupportDirectory.appendingPathComponent("state.json", isDirectory: false)
    }

    public static var tmpStateFileURL: URL {
        URL(fileURLWithPath: "/tmp/bofinder-state.json", isDirectory: false)
    }

    public static func loadState() -> SharedRuntimeState {
        let decoder = JSONDecoder()
        var candidates: [SharedRuntimeState] = []

        // 1. Check shared named pasteboard (works across App Sandbox even with strict SIP and zero file exceptions)
        let pb = NSPasteboard(name: statePasteboardName)
        if let jsonStr = pb.string(forType: .string),
           let data = jsonStr.data(using: .utf8),
           let state = try? decoder.decode(SharedRuntimeState.self, from: data) {
            candidates.append(state)
        }

        // 2. Check disk files
        for url in [stateFileURL, tmpStateFileURL] {
            if let data = try? Data(contentsOf: url),
               let state = try? decoder.decode(SharedRuntimeState.self, from: data) {
                candidates.append(state)
            }
        }

        // Return the newest state by updatedAt timestamp
        if let newest = candidates.max(by: { $0.updatedAt < $1.updatedAt }) {
            return newest
        }
        return SharedRuntimeState()
    }

    public static func saveAndBroadcastState(_ state: SharedRuntimeState) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        // 1. Write to named pasteboard
        let pb = NSPasteboard(name: statePasteboardName)
        pb.clearContents()
        pb.setString(jsonString, forType: .string)

        // 2. Write to disk files
        try? FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: stateFileURL, options: .atomic)
        try? data.write(to: tmpStateFileURL, options: .atomic)

        // 3. Broadcast notification
        DistributedNotificationCenter.default().postNotificationName(
            stateChangedNotification,
            object: jsonString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func decodeState(from notificationObject: Any?) -> SharedRuntimeState? {
        if let jsonString = notificationObject as? String,
           let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SharedRuntimeState.self, from: data) {
            return decoded
        }
        return loadState()
    }

    public static func postExtensionAction(_ payload: ExtensionActionPayload) {
        guard let data = try? JSONEncoder().encode(payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        // Write action to named pasteboard so even if sandbox strips notification object, main app can read it
        let pb = NSPasteboard(name: actionPasteboardName)
        pb.clearContents()
        pb.setString(jsonString, forType: .string)

        DistributedNotificationCenter.default().postNotificationName(
            extensionActionNotification,
            object: jsonString,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    public static func decodeExtensionAction(from notificationObject: Any?) -> ExtensionActionPayload? {
        if let jsonString = notificationObject as? String,
           let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ExtensionActionPayload.self, from: data) {
            return payload
        }
        let pb = NSPasteboard(name: actionPasteboardName)
        if let jsonString = pb.string(forType: .string),
           let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ExtensionActionPayload.self, from: data) {
            return payload
        }
        return nil
    }

    public static func requestStateFromMainApp() {
        DistributedNotificationCenter.default().postNotificationName(
            requestStateNotification,
            object: "request",
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
