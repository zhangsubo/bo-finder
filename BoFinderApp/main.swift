import Cocoa
import Darwin

let app = NSApplication.shared

// Keep the legacy identity so extensions, permissions and preferences stay connected.
// Stop an old BoFinder instance before either process can consume the same IPC action.
let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.bofinder.app")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
for peer in peers {
    if peer.executableURL?.lastPathComponent == "DeskSide" {
        peer.activate()
        exit(0)
    }
    guard peer.terminate() else {
        let alert = NSAlert()
        alert.messageText = "请先退出 BoFinder"
        alert.informativeText = "为避免两个应用重复处理文件，请退出旧版后重新打开 DeskSide。原有设置会保留。"
        alert.runModal()
        exit(1)
    }
    let deadline = Date().addingTimeInterval(5)
    while !peer.isTerminated && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !peer.isTerminated {
        let alert = NSAlert()
        alert.messageText = "BoFinder 尚未退出"
        alert.informativeText = "DeskSide 暂不启动文件监听。请退出旧版后重试。"
        alert.runModal()
        exit(1)
    }
}

// Close the simultaneous-launch race between two DeskSide processes.
try FileManager.default.createDirectory(at: BoFinderIPC.appSupportDirectory, withIntermediateDirectories: true)
let instanceLock = open(BoFinderIPC.appSupportDirectory.appendingPathComponent("deskside.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { exit(1) }

let delegate = AppDelegate()
app.delegate = delegate
let showDock = CutPasteManager.shared.state.config.showDockIcon
app.setActivationPolicy(showDock ? .regular : .accessory)
app.run()
