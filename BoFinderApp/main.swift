import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let showDock = CutPasteManager.shared.state.config.showDockIcon
app.setActivationPolicy(showDock ? .regular : .accessory)
app.run()
