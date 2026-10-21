import Cocoa
import ApplicationServices

enum FinderSelectionHelper {
    /// Checks whether a given URL is inside iCloud Drive or CloudStorage where macOS 14+ disables third-party FinderSync extensions.
    static func isCloudFolder(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/Library/Mobile Documents") || path.contains("/Library/CloudStorage")
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

        // 2. If a mouse click point (CGEvent location, top-left screen origin) was provided, also hit-test the item under cursor
        if let pt = mouseCGPoint, let hitURL = urlAtScreenPoint(pt, appElem: appElem) {
            if !selectedURLs.contains(where: { $0.path == hitURL.path }) {
                // When user right-clicks a specific item that wasn't part of the prior selection, Finder targets the clicked item
                selectedURLs = [hitURL]
            }
        }

        // 3. Read current folder URL from the focused/main Finder window
        var currentFolderURL: URL?
        for winAttr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, winAttr, &winRef) == .success,
               let winObj = winRef {
                let winElem = winObj as! AXUIElement
                var docRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(winElem, kAXDocumentAttribute as CFString, &docRef) == .success,
                   let docStr = docRef as? String,
                   let url = URL(string: docStr),
                   url.isFileURL {
                    currentFolderURL = url
                    break
                }

                // Special case: top-level "iCloud云盘" / "iCloud Drive" window where AXDocument is nil
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(winElem, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String,
                   (title.localizedCaseInsensitiveContains("iCloud") || title == "云盘") {
                    let iCloudRoot = "\(PathFormatter.realHomeDirectory())/Library/Mobile Documents/com~apple~CloudDocs"
                    if FileManager.default.fileExists(atPath: iCloudRoot) {
                        currentFolderURL = URL(fileURLWithPath: iCloudRoot)
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
        let uniqueSelected = selectedURLs.filter { seen.insert($0.path).inserted }

        return (uniqueSelected, currentFolderURL)
    }

    /// Hit-tests the Finder UI element at `cgPoint` (top-left origin screen coordinates) to find the file/folder URL under the cursor.
    static func urlAtScreenPoint(_ cgPoint: CGPoint, appElem: AXUIElement? = nil) -> URL? {
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
        let err = AXUIElementCopyElementAtPosition(targetAppElem, Float(cgPoint.x), Float(cgPoint.y), &hitElemRef)
        guard err == .success, var currentElem = hitElemRef else {
            return nil
        }

        // Walk up to 5 parent levels (e.g. AXStaticText/AXImage -> AXCell -> AXRow/AXIcon) looking for AXURL
        for _ in 0..<5 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElem, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                // Stop if we hit the window or scroll area container so we don't accidentally treat the window document as a clicked item
                if role == (kAXWindowRole as String) || role == (kAXScrollAreaRole as String) || role == (kAXApplicationRole as String) {
                    break
                }
            }

            if let url = extractURL(from: currentElem) {
                return url
            }

            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElem, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentObj = parentRef {
                currentElem = (parentObj as! AXUIElement)
            } else {
                break
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
