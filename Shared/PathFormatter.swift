import Foundation
import Darwin

public enum PathFormatter {
    /// Returns the real user home directory (e.g., `/Users/username`), bypassing App Sandbox container redirection.
    public static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dirPtr = pw.pointee.pw_dir {
            return String(cString: dirPtr)
        }
        let home = NSHomeDirectory()
        if let range = home.range(of: "/Library/Containers/") {
            return String(home[..<range.lowerBound])
        }
        return home
    }

    public static func format(
        urls: [URL],
        as format: PathFormat,
        windowsStyle: WindowsPathStyle = .backslash
    ) -> String {
        let formattedItems = urls.map { formatSingle(url: $0, as: format, windowsStyle: windowsStyle) }
        switch format {
        case .terminal:
            // Join multiple terminal-escaped paths with a space so they can be pasted directly as command arguments
            return formattedItems.joined(separator: " ")
        default:
            return formattedItems.joined(separator: "\n")
        }
    }

    public static func formatSingle(
        url: URL,
        as format: PathFormat,
        windowsStyle: WindowsPathStyle = .backslash
    ) -> String {
        let posixPath = url.path

        switch format {
        case .posix:
            return posixPath

        case .url:
            return url.absoluteString

        case .windows:
            let backslashed = posixPath.replacingOccurrences(of: "/", with: "\\")
            switch windowsStyle {
            case .backslash:
                return backslashed
            case .driveC:
                if backslashed.hasPrefix("\\") {
                    return "C:" + backslashed
                } else {
                    return "C:\\" + backslashed
                }
            case .unc:
                if backslashed.hasPrefix("\\") {
                    return "\\\\mac" + backslashed
                } else {
                    return "\\\\mac\\" + backslashed
                }
            }

        case .terminal:
            return escapeForTerminal(posixPath)

        case .tilde:
            let home = realHomeDirectory()
            if posixPath == home {
                return "~"
            } else if posixPath.hasPrefix(home + "/") {
                return "~" + String(posixPath.dropFirst(home.count))
            }
            return posixPath

        case .filename:
            return url.lastPathComponent

        case .markdown:
            let name = url.lastPathComponent
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            return "[\(name)](\(url.absoluteString))"
        }
    }

    public static func escapeForTerminal(_ path: String) -> String {
        let specialCharacters = Set<Character>([
            " ", "\\", "\"", "'", "(", ")", "[", "]", "{", "}",
            "&", ";", "|", "*", "?", "$", "`", "!", "#", "~", "<", ">"
        ])
        var result = String()
        result.reserveCapacity(path.count + 8)
        for ch in path {
            if specialCharacters.contains(ch) {
                result.append("\\")
            }
            result.append(ch)
        }
        return result
    }
}
