import Cocoa
import SwiftUI
import ApplicationServices
import CoreGraphics
import QuartzCore

// MARK: - Pure Layout & Window Selection Helpers

enum PermissionGuideLayout {
    static let defaultPanelSize = NSSize(width: 488, height: 154)

    /// Selects the main System Settings window bounds in Quartz global coordinates,
    /// ignoring non-layer-0 overlays and smaller modal authentication sheets.
    static func selectSystemSettingsBounds(from candidates: [(layer: Int, bounds: CGRect)]) -> CGRect? {
        let valid = candidates.filter { $0.layer == 0 && $0.bounds.width >= 400 && $0.bounds.height >= 280 }
        let mainCandidates = valid.filter { $0.bounds.width >= 560 && $0.bounds.height >= 360 }
        let pool = mainCandidates.isEmpty ? valid : mainCandidates
        return pool.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) })?.bounds
    }

    /// Computes the Cocoa frame centered horizontally over System Settings' right-hand detail list pane.
    static func overlayFrame(
        forSystemSettingsCGFrame cgBounds: CGRect,
        primaryScreenHeight: CGFloat,
        panelSize: NSSize = defaultPanelSize
    ) -> NSRect {
        let sysCocoaMinX = cgBounds.origin.x
        let sysCocoaMinY = primaryScreenHeight - (cgBounds.origin.y + cgBounds.height)
        let sysWidth = cgBounds.width

        // System Settings left sidebar is ~215pt; center the HUD inside the right-hand list pane.
        let sidebarWidth: CGFloat = sysWidth > 560 ? 215.0 : 0.0
        let rightPaneMinX = sysCocoaMinX + sidebarWidth
        let rightPaneWidth = sysWidth - sidebarWidth

        let targetWidth = min(panelSize.width, max(360, rightPaneWidth - 18))
        let targetX = rightPaneMinX + (rightPaneWidth - targetWidth) / 2.0
        let targetY = sysCocoaMinY + 10.0

        return NSRect(
            x: round(targetX),
            y: round(targetY),
            width: round(targetWidth),
            height: panelSize.height
        )
    }

    static func makeAppIcon(pointSize: CGFloat = 36) -> NSImage {
        if let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png"),
           let src = NSImage(contentsOf: url) {
            let size = NSSize(width: pointSize, height: pointSize)
            let radius = pointSize * 0.23
            let img = NSImage(size: size, flipped: false) { rect in
                NSGraphicsContext.current?.imageInterpolation = .high
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
                src.draw(in: rect, from: NSRect(origin: .zero, size: src.size), operation: .sourceOver, fraction: 1.0)
                return true
            }
            img.isTemplate = false
            return img
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    /// Returns `true` only when Accessibility is currently untrusted and a valid bundle ID exists.
    /// Never resets an already-trusted permission.
    static func shouldResetStaleEntryBeforeRequest(
        isCurrentlyTrusted: Bool,
        bundleIdentifier: String?
    ) -> Bool {
        guard !isCurrentlyTrusted,
              let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            return false
        }
        return true
    }

    /// Returns `true` when an ad-hoc silent update invalidated a previously granted Accessibility permission.
    static func shouldAutoPromptReauthorizationAfterSilentUpdate(
        isSilentRelaunch: Bool,
        isCurrentlyTrusted: Bool,
        hasEverGrantedAccessibility: Bool
    ) -> Bool {
        isSilentRelaunch && !isCurrentlyTrusted && hasEverGrantedAccessibility
    }

    /// Clears stale Accessibility TCC records for `bundleIdentifier` when untrusted so dragging into
    /// System Settings -> Accessibility works immediately without manually deleting the old entry first.
    @discardableResult
    static func resetAccessibilityTCCEntryIfNeeded(
        isCurrentlyTrusted: Bool,
        bundleIdentifier: String?,
        runner: (String) -> Bool = runTCCUtilResetAccessibility
    ) -> Bool {
        guard shouldResetStaleEntryBeforeRequest(
            isCurrentlyTrusted: isCurrentlyTrusted,
            bundleIdentifier: bundleIdentifier
        ),
        let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return runner(id)
    }

    private static func runTCCUtilResetAccessibility(_ bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            done.signal()
        }
        do {
            try process.run()
        } catch {
            return false
        }
        if done.wait(timeout: .now() + 1.5) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

// MARK: - Stationary Non-Activating Panel & Views

private final class GuideHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class StationaryVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class StationaryHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Overlay Controller

/// Manages the stationary frosted-glass guide overlay positioned over System Settings -> Accessibility.
@MainActor
final class PermissionGuideOverlayController: NSObject, ObservableObject, NSWindowDelegate {
    enum StaleCleanState: Equatable {
        case idle
        case autoCleaned
        case cleaning
        case manuallyCleaned
    }

    static let shared = PermissionGuideOverlayController()

    @Published fileprivate var isAuthorizedSuccess: Bool = false
    @Published fileprivate var staleCleanState: StaleCleanState = .idle

    private var panel: GuideHUDPanel?
    private var trackingTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private var lastTrackedSysBounds: CGRect = .zero
    private var isDraggingCapsule: Bool = false
    private var didObserveSystemSettings: Bool = false
    private var missingSystemSettingsTicks: Int = 0

    var onAuthorizationDetected: (() -> Void)?

    private let panelSize = PermissionGuideLayout.defaultPanelSize

    func show(didAutoCleanStaleRecord: Bool = false) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isAuthorizedSuccess = false
        staleCleanState = didAutoCleanStaleRecord ? .autoCleaned : .idle
        isDraggingCapsule = false
        didObserveSystemSettings = false
        missingSystemSettingsTicks = 0
        lastTrackedSysBounds = .zero

        if panel == nil {
            createPanel()
        }

        guard let panel = panel else { return }
        panel.alphaValue = 1.0
        panel.ignoresMouseEvents = false

        if snapToSystemSettingsWindow(animated: false) {
            didObserveSystemSettings = true
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let fallbackOrigin = NSPoint(
                x: round(visible.midX - panelSize.width / 2 + 90),
                y: round(visible.minY + 80)
            )
            panel.setFrame(NSRect(origin: fallbackOrigin, size: panelSize), display: true)
        }

        panel.orderFrontRegardless()
        startTrackingTimer()
    }

    func dismissImmediately() {
        stopTrackingTimer()
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isDraggingCapsule = false
        panel?.ignoresMouseEvents = false
        panel?.orderOut(nil)
    }

    fileprivate func setDraggingPassThrough(_ dragging: Bool) {
        isDraggingCapsule = dragging
        // Keep the floating HUD completely stationary & opaque; only pass mouse drops through to System Settings.
        panel?.ignoresMouseEvents = dragging
    }

    fileprivate func triggerManualCleanStaleRecord() {
        guard !isAuthorizedSuccess, staleCleanState != .cleaning else { return }
        staleCleanState = .cleaning
        let bundleID = Bundle.main.bundleIdentifier
        let trusted = AXIsProcessTrusted()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cleaned = PermissionGuideLayout.resetAccessibilityTCCEntryIfNeeded(
                isCurrentlyTrusted: trusted,
                bundleIdentifier: bundleID
            )
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.staleCleanState = cleaned ? .manuallyCleaned : .idle
            }
        }
    }

    // MARK: - Panel Construction

    private func createPanel() {
        let hud = GuideHUDPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hud.title = ""
        hud.titleVisibility = .hidden
        hud.titlebarAppearsTransparent = true
        hud.isMovable = false
        hud.isMovableByWindowBackground = false
        hud.hidesOnDeactivate = false
        hud.becomesKeyOnlyIfNeeded = true
        hud.level = .floating
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isReleasedWhenClosed = false
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.appearance = NSAppearance(named: .vibrantDark)
        hud.delegate = self

        hud.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        hud.standardWindowButton(.zoomButton)?.isEnabled = false

        let visualEffect = StationaryVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        visualEffect.material = .hudWindow
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        visualEffect.autoresizingMask = [.width, .height]

        let rootView = PermissionGuideContentView(controller: self)
        let hostingView = StationaryHostingView(rootView: rootView)
        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        hud.contentView = visualEffect
        self.panel = hud
    }

    func windowWillClose(_ notification: Notification) {
        stopTrackingTimer()
    }

    // MARK: - System Settings Window Tracking & Permission Polling

    private func startTrackingTimer() {
        stopTrackingTimer()
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTrackingTimer() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func tickTracking() {
        guard panel?.isVisible == true else {
            stopTrackingTimer()
            return
        }

        if !isAuthorizedSuccess && AXIsProcessTrusted() {
            handleAuthorizationSucceeded()
            return
        }

        // Freeze HUD position completely while user is dragging the capsule card.
        guard !isAuthorizedSuccess && !isDraggingCapsule else { return }

        if snapToSystemSettingsWindow(animated: true) {
            didObserveSystemSettings = true
            missingSystemSettingsTicks = 0
        } else if didObserveSystemSettings {
            missingSystemSettingsTicks += 1
            if missingSystemSettingsTicks >= 4 {
                fadeOutPanel()
            }
        }
    }

    private func handleAuthorizationSucceeded() {
        stopTrackingTimer()
        isDraggingCapsule = false
        panel?.ignoresMouseEvents = false
        onAuthorizationDetected?()

        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            isAuthorizedSuccess = true
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOutPanel()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func fadeOutPanel() {
        stopTrackingTimer()
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0.0
        }, completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.alphaValue = 1.0
            }
        })
    }

    @discardableResult
    private func snapToSystemSettingsWindow(animated: Bool) -> Bool {
        guard let panel = panel else { return false }
        guard let cgBounds = findSystemSettingsWindowCGFrame() else { return false }

        let isFirstSnap = (lastTrackedSysBounds == .zero)
        lastTrackedSysBounds = cgBounds

        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        let primaryHeight = primaryScreen?.frame.height ?? 900.0
        let targetFrame = PermissionGuideLayout.overlayFrame(
            forSystemSettingsCGFrame: cgBounds,
            primaryScreenHeight: primaryHeight,
            panelSize: panelSize
        )

        if abs(panel.frame.origin.x - targetFrame.origin.x) > 1 ||
            abs(panel.frame.origin.y - targetFrame.origin.y) > 1 ||
            abs(panel.frame.width - targetFrame.width) > 1 {
            panel.setFrame(targetFrame, display: true, animate: animated && !isFirstSnap)
        }
        return true
    }

    private func findSystemSettingsWindowCGFrame() -> CGRect? {
        let settingsBundleIDs: Set<String> = [
            "com.apple.systempreferences",
            "com.apple.Preferences"
        ]
        let matchingPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { settingsBundleIDs.contains($0.bundleIdentifier ?? "") }
                .map(\.processIdentifier)
        )
        guard !matchingPIDs.isEmpty,
              let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let candidates: [(layer: Int, bounds: CGRect)] = windowList.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  matchingPIDs.contains(pid),
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                return nil
            }
            return (layer: layer, bounds: rect)
        }
        return PermissionGuideLayout.selectSystemSettingsBounds(from: candidates)
    }
}

// MARK: - SwiftUI Overlay Content

private struct PermissionGuideContentView: View {
    @ObservedObject var controller: PermissionGuideOverlayController
    @State private var arrowUp = false

    var body: some View {
        ZStack {
            if controller.isAuthorizedSuccess {
                successStateView
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                dragGuideStateView
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .padding(.horizontal, 20)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                arrowUp = true
            }
        }
    }

    private var dragGuideStateView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: arrowUp ? -3.5 : 2.0)

                Text("将 DeskSide 拖到上方列表，以启用快捷栏与快捷键")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.top, 4)

            DraggableAppPillRepresentable { isDragging in
                controller.setDraggingPassThrough(isDragging)
            }
            .frame(width: 316, height: 54)

            HStack(spacing: 8) {
                if controller.staleCleanState == .manuallyCleaned {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.25, green: 0.92, blue: 0.52))
                    Text("已清理旧记录，现在直接上拖卡片并确认开关开启即可")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.55, green: 0.96, blue: 0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else if controller.staleCleanState == .autoCleaned {
                    Text("已自动清理旧版失效记录 · 直接上拖并确保开关开启")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text("若列表中已有旧记录导致拖入无效，可先一键清理旧记录")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Button {
                    controller.triggerManualCleanStaleRecord()
                } label: {
                    Text(controller.staleCleanState == .cleaning ? "清理中…" : "清理旧记录")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.14))
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(controller.staleCleanState == .cleaning)
            }
        }
    }

    private var successStateView: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.22))
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color(red: 0.25, green: 0.92, blue: 0.52))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("辅助功能授权成功！")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Text("DeskSide 快捷栏与快捷键已就绪，此引导浮层将自动关闭…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Native AppKit Draggable App Pill (NSDraggingSource for .app Bundle URL)

private struct DraggableAppPillRepresentable: NSViewRepresentable {
    let onDraggingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> DraggableAppPillNSView {
        let view = DraggableAppPillNSView()
        view.onDraggingChanged = onDraggingChanged
        return view
    }

    func updateNSView(_ nsView: DraggableAppPillNSView, context: Context) {
        nsView.onDraggingChanged = onDraggingChanged
    }
}

final class DraggableAppPillNSView: NSView, NSDraggingSource {
    var onDraggingChanged: ((Bool) -> Void)?

    private var isHovered = false
    private var isLiftedForDrag = false
    private var mouseDownEvent: NSEvent?
    private var didStartDragInCurrentClick = false
    private var didPushClosedHandCursor = false
    private var trackingAreaRef: NSTrackingArea?

    private let appIconImage = PermissionGuideLayout.makeAppIcon(pointSize: 36)
    private let dashedSlotLayer = CAShapeLayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "DeskSide")
    private let hintBadge = NSTextField(labelWithString: "按住上拖 ↑")
    private let slotPlaceholderLabel = NSTextField(labelWithString: "拖到上方「辅助功能」列表中松开")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    /// Never allow dragging this capsule to move the parent floating window.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Enables dragging on the very first click even when System Settings is the active app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Route clicks anywhere on the capsule (including icon & labels) directly to this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func layout() {
        super.layout()
        dashedSlotLayer.frame = bounds
        let insetRect = bounds.insetBy(dx: 1.0, dy: 1.0)
        if insetRect.width > 0 && insetRect.height > 0 {
            dashedSlotLayer.path = CGPath(
                roundedRect: insetRect,
                cornerWidth: 12,
                cornerHeight: 12,
                transform: nil
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        dashedSlotLayer.fillColor = NSColor.black.withAlphaComponent(0.20).cgColor
        dashedSlotLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        dashedSlotLayer.lineWidth = 1.2
        dashedSlotLayer.lineDashPattern = [6, 4]
        dashedSlotLayer.isHidden = true
        layer?.addSublayer(dashedSlotLayer)

        iconView.image = appIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        hintBadge.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        hintBadge.textColor = NSColor.white.withAlphaComponent(0.62)
        hintBadge.translatesAutoresizingMaskIntoConstraints = false

        slotPlaceholderLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        slotPlaceholderLabel.textColor = NSColor.white.withAlphaComponent(0.38)
        slotPlaceholderLabel.isHidden = true
        slotPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(slotPlaceholderLabel)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(hintBadge)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            hintBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hintBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintBadge.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            slotPlaceholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            slotPlaceholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateLayerAppearance(pressed: false)
    }

    private func updateLayerAppearance(pressed: Bool) {
        if isLiftedForDrag {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0.0
            dashedSlotLayer.isHidden = false
            iconView.isHidden = true
            titleLabel.isHidden = true
            hintBadge.isHidden = true
            slotPlaceholderLabel.isHidden = false
            return
        }

        dashedSlotLayer.isHidden = true
        iconView.isHidden = false
        titleLabel.isHidden = false
        hintBadge.isHidden = false
        slotPlaceholderLabel.isHidden = true

        let bgAlpha: CGFloat = pressed ? 0.22 : (isHovered ? 0.16 : 0.10)
        let borderAlpha: CGFloat = pressed ? 0.42 : (isHovered ? 0.32 : 0.20)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(bgAlpha).cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateLayerAppearance(pressed: false)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateLayerAppearance(pressed: false)
    }

    private func pushClosedHandCursor() {
        guard !didPushClosedHandCursor else { return }
        NSCursor.closedHand.push()
        didPushClosedHandCursor = true
    }

    private func popClosedHandCursorIfNeeded() {
        guard didPushClosedHandCursor else { return }
        NSCursor.pop()
        didPushClosedHandCursor = false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDragInCurrentClick = false
        pushClosedHandCursor()
        updateLayerAppearance(pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        didStartDragInCurrentClick = false
        popClosedHandCursorIfNeeded()
        updateLayerAppearance(pressed: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDragInCurrentClick else { return }
        didStartDragInCurrentClick = true

        let appBundleURL = Bundle.main.bundleURL.standardizedFileURL as NSURL
        let draggingItem = NSDraggingItem(pasteboardWriter: appBundleURL)

        let dragImage = renderDragPreviewImage()
        draggingItem.setDraggingFrame(bounds, contents: dragImage)

        // Keep the floating HUD stationary with an empty dashed slot while only the capsule card moves.
        isLiftedForDrag = true
        updateLayerAppearance(pressed: false)

        let session = beginDraggingSession(with: [draggingItem], event: mouseDownEvent ?? event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func renderDragPreviewImage() -> NSImage {
        let size = bounds.size.width > 0 ? bounds.size : NSSize(width: 316, height: 54)
        let icon = appIconImage
        return NSImage(size: size, flipped: false) { rect in
            let pillRect = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 12, yRadius: 12)

            NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.21, alpha: 0.95).setFill()
            path.fill()

            NSColor.white.withAlphaComponent(0.36).setStroke()
            path.lineWidth = 1.2
            path.stroke()

            let iconRect = NSRect(x: 14, y: (rect.height - 36) / 2.0, width: 36, height: 36)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let titleStr = "DeskSide" as NSString
            let titleSize = titleStr.size(withAttributes: titleAttrs)
            titleStr.draw(
                at: NSPoint(x: 62, y: (rect.height - titleSize.height) / 2.0),
                withAttributes: titleAttrs
            )
            return true
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            onDraggingChanged?(true)
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            isLiftedForDrag = false
            popClosedHandCursorIfNeeded()
            didStartDragInCurrentClick = false
            updateLayerAppearance(pressed: false)
            onDraggingChanged?(false)
        }
    }
}
