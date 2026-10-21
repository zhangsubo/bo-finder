import Foundation

@main
struct PathFormatterTests {
    static func main() {
        print("Running BoFinder Unit Tests...")
        var passed = 0
        var failed = 0

        func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
            if actual == expected {
                passed += 1
                print("  ✅ \(message)")
            } else {
                failed += 1
                print("  ❌ \(message)\n     Expected: \(expected)\n     Actual:   \(actual)")
            }
        }

        let testURL = URL(fileURLWithPath: "/Users/demo/My Folder/测试 文件 (1).txt")

        // 1. POSIX path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .posix),
            "/Users/demo/My Folder/测试 文件 (1).txt",
            "POSIX path formatting"
        )

        // 2. URL path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .url),
            "file:///Users/demo/My%20Folder/%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6%20(1).txt",
            "URL path formatting with percent encoding"
        )

        // 3. Windows paths
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .backslash),
            "\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows backslash path formatting"
        )
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .driveC),
            "C:\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows C: drive path formatting"
        )
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .windows, windowsStyle: .unc),
            "\\\\mac\\Users\\demo\\My Folder\\测试 文件 (1).txt",
            "Windows UNC path formatting"
        )

        // 4. Terminal escaped path
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .terminal),
            "/Users/demo/My\\ Folder/测试\\ 文件\\ \\(1\\).txt",
            "Terminal escaped path formatting"
        )

        // 5. Tilde path
        let home = PathFormatter.realHomeDirectory()
        let homeFileURL = URL(fileURLWithPath: "\(home)/Documents/report.pdf")
        assertEqual(
            PathFormatter.formatSingle(url: homeFileURL, as: .tilde),
            "~/Documents/report.pdf",
            "Home directory tilde (~) path formatting"
        )

        // 6. Filename only
        assertEqual(
            PathFormatter.formatSingle(url: testURL, as: .filename),
            "测试 文件 (1).txt",
            "Filename only formatting"
        )

        // 7. Multi-file formatting (newline for POSIX, space for Terminal)
        let urlA = URL(fileURLWithPath: "/tmp/a b.txt")
        let urlB = URL(fileURLWithPath: "/tmp/c.txt")
        assertEqual(
            PathFormatter.format(urls: [urlA, urlB], as: .posix),
            "/tmp/a b.txt\n/tmp/c.txt",
            "Multi-file POSIX joined by newline"
        )
        assertEqual(
            PathFormatter.format(urls: [urlA, urlB], as: .terminal),
            "/tmp/a\\ b.txt /tmp/c.txt",
            "Multi-file Terminal escaped joined by space"
        )

        print("\nResults: \(passed) passed, \(failed) failed.")
        if failed > 0 {
            exit(1)
        }
    }
}
