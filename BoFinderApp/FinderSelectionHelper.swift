import Cocoa
import ApplicationServices

enum FinderSelectionHelper {
    /// Use system-wide hit testing so overlays such as Dock are not mistaken for Finder behind them.
    /// Also ignores clicks on Finder's window toolbar or menu bar so customizing the toolbar does not pop up quick bars.
    static func isFinderElement(at cgPoint: CGPoint, finderPID: pid_t) -> Bool {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            AXUIElementCreateSystemWide(), Float(cgPoint.x), Float(cgPoint.y), &hitElement
        ) == .success, var current = hitElement else {
            return false
        }
        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(current, &ownerPID) == .success, ownerPID == finderPID else {
            return false
        }

        for _ in 0..<10 {
            if let role = axRole(of: current) {
                if role == "AXToolbar" || role == (kAXMenuBarRole as String) || role == (kAXMenuRole as String) {
                    return false
                }
                if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) {
                    break
                }
            }
            guard let parent = axParent(of: current) else { break }
            current = parent
        }
        return true
    }

    /// Checks whether a given URL is inside iCloud Drive (including iCloud-synced Desktop & Documents)
    /// or CloudStorage where macOS 14+ disables third-party FinderSync extensions.
    static func isCloudFolder(_ url: URL) -> Bool {
        return PathFormatter.isCloudBackedURL(url)
    }

    /// Reads currently selected file URLs in Finder via Accessibility (and optionally hit-tests the mouse CGPoint).
    static func currentSelectionOrFolderURLs(mouseCGPoint: CGPoint? = nil) -> (selected: [URL], currentFolder: URL?) {
        guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return ([], nil)
        }
        let appElem = AXUIElementCreateApplication(finderApp.processIdentifier)

        var selectedURLs: [URL] = []

        // 1. Check focused UI element in Finder (Icon view, List view outline, Column view browser, Desktop)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focusedObj = focusedRef {
            let focusedElem = focusedObj as! AXUIElement
            selectedURLs.append(contentsOf: extractSelectedURLs(from: focusedElem))
        }

        // 1b. If Finder was unfocused when right-clicked, inspect the view container under the cursor for prior multi-selection
        if selectedURLs.isEmpty, let pt = mouseCGPoint, let container = selectionContainerAtScreenPoint(pt, appElem: appElem) {
            selectedURLs.append(contentsOf: extractSelectedURLs(from: container))
        }

        // 2. If a mouse click point (CGEvent location, top-left screen origin) was provided, also hit-test the item under cursor
        if let pt = mouseCGPoint, let hitURL = urlAtScreenPoint(pt, appElem: appElem) {
            let hitStd = hitURL.standardizedFileURL.path
            if !selectedURLs.contains(where: { $0.standardizedFileURL.path == hitStd }) {
                // When user right-clicks a specific item that wasn't part of the prior selection, Finder targets the clicked item
                selectedURLs = [hitURL]
            }
        }

        // 3. Read current folder URL: prefer the specific Finder window (or Desktop) under the cursor first
        var currentFolderURL: URL?
        if let pt = mouseCGPoint {
            currentFolderURL = folderURLAtScreenPoint(pt, appElem: appElem)
        }

        if currentFolderURL == nil {
            for winAttr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
                var winRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(appElem, winAttr, &winRef) == .success,
                   let winObj = winRef {
                    let winElem = winObj as! AXUIElement
                    if let resolved = folderURL(fromWindow: winElem) {
                        currentFolderURL = resolved
                        break
                    }
                }
            }
        }

        // 4. If currentFolderURL is still nil, infer from selected item's parent directory
        if currentFolderURL == nil, let firstSel = selectedURLs.first {
            currentFolderURL = firstSel.deletingLastPathComponent()
        }

        // Deduplicate while preserving order
        var seen = Set<String>()
        let uniqueSelected = selectedURLs.filter { seen.insert($0.standardizedFileURL.path).inserted }

        return (uniqueSelected, currentFolderURL)
    }

    /// Hit-tests the Finder UI element at `cgPoint` (top-left origin screen coordinates) to find the file/folder URL under the cursor.
    static func urlAtScreenPoint(_ cgPoint: CGPoint, appElem: AXUIElement? = nil) -> URL? {
        guard var currentElem = hitFinderElement(at: cgPoint, appElem: appElem) else {
            return nil
        }

        let containerStopRoles: Set<String> = [
            kAXWindowRole as String,
            kAXScrollAreaRole as String,
            kAXApplicationRole as String,
            kAXOutlineRole as String,
            kAXListRole as String,
            kAXBrowserRole as String,
            "AXSplitGroup",
            "AXToolbar"
        ]

        // Walk up parent levels (e.g. AXStaticText/AXImage -> AXGroup -> AXCell -> AXRow/AXIcon) looking for AXURL
        for _ in 0..<6 {
            let role = axRole(of: currentElem)
            if let role = role {
                // Stop if we hit a multi-item view or window container so empty-space clicks never grab the first file in the folder
                if containerStopRoles.contains(role) {
                    break
                }
                if role == (kAXGroupRole as String),
                   let parent = axParent(of: currentElem),
                   axRole(of: parent) == (kAXScrollAreaRole as String) {
                    break
                }
            }

            if let directURL = extractDirectURL(from: currentElem) {
                return directURL
            }

            if role == (kAXRowRole as String) || role == (kAXCellRole as String) {
                if let rowURL = extractURL(from: currentElem, maxDepth: 4) {
                    return rowURL
                }
            }

            if let parent = axParent(of: currentElem) {
                currentElem = parent
            } else {
                break
            }
        }
        return nil
    }

    private static func hitFinderElement(at cgPoint: CGPoint, appElem: AXUIElement? = nil) -> AXUIElement? {
        let targetAppElem: AXUIElement
        if let provided = appElem {
            targetAppElem = provided
        } else {
            guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
                return nil
            }
            targetAppElem = AXUIElementCreateApplication(finderApp.processIdentifier)
        }

        var hitElemRef: AXUIElement?
        if AXUIElementCopyElementAtPosition(targetAppElem, Float(cgPoint.x), Float(cgPoint.y), &hitElemRef) == .success,
           let hit = hitElemRef {
            return hit
        }

        // Fallback to system-wide hit-testing when Finder is currently unfocused in the background
        var sysHitRef: AXUIElement?
        var targetPID: pid_t = 0
        guard AXUIElementGetPid(targetAppElem, &targetPID) == .success,
              AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(cgPoint.x), Float(cgPoint.y), &sysHitRef) == .success,
              let sysHit = sysHitRef else {
            return nil
        }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(sysHit, &hitPID) == .success, hitPID == targetPID else {
            return nil
        }
        return sysHit
    }

    private static func selectionContainerAtScreenPoint(_ cgPoint: CGPoint, appElem: AXUIElement) -> AXUIElement? {
        guard var current = hitFinderElement(at: cgPoint, appElem: appElem) else { return nil }
        let selectionContainerRoles: Set<String> = [
            kAXOutlineRole as String,
            kAXListRole as String,
            kAXBrowserRole as String,
            kAXGroupRole as String
        ]
        for _ in 0..<10 {
            if let role = axRole(of: current) {
                if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) {
                    break
                }
                if selectionContainerRoles.contains(role) {
                    var selChildren: CFTypeRef?
                    var selRows: CFTypeRef?
                    if AXUIElementCopyAttributeValue(current, kAXSelectedChildrenAttribute as CFString, &selChildren) == .success
                        || AXUIElementCopyAttributeValue(current, kAXSelectedRowsAttribute as CFString, &selRows) == .success {
                        return current
                    }
                }
            }
            guard let parent = axParent(of: current) else { break }
            current = parent
        }
        return nil
    }

    private static func folderURLAtScreenPoint(_ cgPoint: CGPoint, appElem: AXUIElement) -> URL? {
        guard var current = hitFinderElement(at: cgPoint, appElem: appElem) else { return nil }
        var sawScrollArea = false
        for _ in 0..<15 {
            if let role = axRole(of: current) {
                if role == (kAXScrollAreaRole as String) {
                    sawScrollArea = true
                }
                if role == (kAXWindowRole as String) {
                    return folderURL(fromWindow: current)
                }
                if role == (kAXApplicationRole as String) {
                    // Finder's Desktop icons/surface live under AXApplication -> AXScrollArea -> AXGroup without an AXWindow
                    if sawScrollArea {
                        let desktopPath = "\(PathFormatter.realHomeDirectory())/Desktop"
                        if FileManager.default.fileExists(atPath: desktopPath) {
                            return URL(fileURLWithPath: desktopPath)
                        }
                    }
                    break
                }
            }
            guard let parent = axParent(of: current) else { break }
            current = parent
        }
        return nil
    }

    private static func folderURL(fromWindow winElem: AXUIElement) -> URL? {
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(winElem, kAXDocumentAttribute as CFString, &docRef) == .success,
           let docStr = docRef as? String,
           let url = URL(string: docStr),
           url.isFileURL {
            return url
        }

        // Window proxy icon often holds AXURL even when AXDocument is unavailable
        var proxyRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(winElem, kAXProxyAttribute as CFString, &proxyRef) == .success,
           let proxyObj = proxyRef,
           let proxyURL = extractDirectURL(from: proxyObj as! AXUIElement) {
            return proxyURL
        }

        // Special cases: top-level "iCloud云盘" / "iCloud Drive" or standard user folders where AXDocument is nil
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(winElem, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            let home = PathFormatter.realHomeDirectory()
            if title.localizedCaseInsensitiveContains("iCloud") || title == "云盘" {
                let iCloudRoot = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
                if FileManager.default.fileExists(atPath: iCloudRoot) {
                    return URL(fileURLWithPath: iCloudRoot)
                }
            } else if title == "桌面" || title == "Desktop" {
                let desktopPath = "\(home)/Desktop"
                if FileManager.default.fileExists(atPath: desktopPath) {
                    return URL(fileURLWithPath: desktopPath)
                }
            } else if title == "文稿" || title == "Documents" {
                let docsPath = "\(home)/Documents"
                if FileManager.default.fileExists(atPath: docsPath) {
                    return URL(fileURLWithPath: docsPath)
                }
            }
        }
        return nil
    }

    private static func axRole(of element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
            return roleRef as? String
        }
        return nil
    }

    private static func axParent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
           let parentObj = parentRef {
            return (parentObj as! AXUIElement)
        }
        return nil
    }

    private static func extractDirectURL(from element: AXUIElement) -> URL? {
        var urlRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
           let val = urlRef {
            if CFGetTypeID(val) == CFURLGetTypeID() {
                return (val as! URL)
            }
            if let str = val as? String, let url = URL(string: str), url.isFileURL {
                return url
            }
        }
        return nil
    }

    private static func extractSelectedURLs(from element: AXUIElement) -> [URL] {
        var urls: [URL] = []

        // Try kAXSelectedChildrenAttribute
        var selectedChildrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedChildrenAttribute as CFString, &selectedChildrenRef) == .success,
           let children = selectedChildrenRef as? [AXUIElement] {
            for child in children {
                if let url = extractURL(from: child) {
                    urls.append(url)
                }
            }
        }

        // Try kAXSelectedRowsAttribute (used in Finder List View / AXOutline)
        if urls.isEmpty {
            var selectedRowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedRowsAttribute as CFString, &selectedRowsRef) == .success,
               let rows = selectedRowsRef as? [AXUIElement] {
                for row in rows {
                    if let url = extractURL(from: row) {
                        urls.append(url)
                    }
                }
            }
        }

        return urls
    }

    private static func extractURL(from element: AXUIElement, maxDepth: Int = 3) -> URL? {
        var urlRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
           let val = urlRef {
            if CFGetTypeID(val) == CFURLGetTypeID() {
                return (val as! URL)
            }
            if let str = val as? String, let url = URL(string: str), url.isFileURL {
                return url
            }
        }

        guard maxDepth > 0 else { return nil }

        // Recursively check children (e.g., AXOutlineRow -> AXCell -> AXStaticText/AXTextField/AXImage with AXURL)
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = extractURL(from: child, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }
        return nil
    }
}
