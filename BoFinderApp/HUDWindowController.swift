import Cocoa

final class HUDWindowController {
    static let shared = HUDWindowController()

    private var window: NSPanel?
    private var iconView: NSImageView?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var dismissWorkItem: DispatchWorkItem?

    private init() {}

    func show(title: String, subtitle: String? = nil, symbolName: String = "checkmark.circle.fill", duration: TimeInterval = 1.6) {
        DispatchQueue.main.async {
            self.presentOnMain(title: title, subtitle: subtitle, symbolName: symbolName, duration: duration)
        }
    }

    private func presentOnMain(title: String, subtitle: String?, symbolName: String, duration: TimeInterval) {
        dismissWorkItem?.cancel()

        let panel = ensureWindow()
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            iconView?.image = img.withSymbolConfiguration(config)
            iconView?.contentTintColor = .controlAccentColor
        }
        titleLabel?.stringValue = title
        if let sub = subtitle, !sub.isEmpty {
            subtitleLabel?.stringValue = sub
            subtitleLabel?.isHidden = false
        } else {
            subtitleLabel?.stringValue = ""
            subtitleLabel?.isHidden = true
        }

        let targetScreen = NSScreen.main ?? NSScreen.screens.first
        if let screenFrame = targetScreen?.visibleFrame {
            let width: CGFloat = 340
            let height: CGFloat = (subtitle == nil || subtitle?.isEmpty == true) ? 54 : 68
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 90
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1.0
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let win = self.window else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                win.animator().alphaValue = 0.0
            }, completionHandler: {
                win.orderOut(nil)
            })
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func ensureWindow() -> NSPanel {
        if let existing = window {
            return existing
        }

        let rect = NSRect(x: 0, y: 0, width: 340, height: 64)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        visualEffect.addSubview(icon)
        visualEffect.addSubview(textStack)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),

            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),
            textStack.centerYAnchor.constraint(equalTo: visualEffect.centerYAnchor)
        ])

        panel.contentView = visualEffect
        self.window = panel
        self.iconView = icon
        self.titleLabel = title
        self.subtitleLabel = subtitle
        return panel
    }
}
