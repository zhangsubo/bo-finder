import AppKit
import CryptoKit
import Foundation

// MARK: - Pure Testable Version & Checksum Helpers

enum AppUpdaterLogic {
    /// Compares dotted numeric version strings (e.g. "1.2.0.1" > "1.2.0" > "1.1.0", "1.10.0" > "1.9.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let cleanA = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))
        let cleanB = current.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n"))
        let partsA = cleanA.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let partsB = cleanB.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let count = max(partsA.count, partsB.count)
        guard count > 0 else { return false }
        for idx in 0..<count {
            let a = idx < partsA.count ? partsA[idx] : 0
            let b = idx < partsB.count ? partsB[idx] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Parses the SHA-256 hex digest for `fileName` from `shasum -a 256` output (`checksums.txt`).
    static func expectedSHA256(for fileName: String, in checksumsData: Data) -> String? {
        let content = String(decoding: checksumsData, as: UTF8.self)
        for line in content.split(whereSeparator: \.isNewline) {
            let cols = line.split(whereSeparator: \.isWhitespace)
            guard cols.count >= 2 else { continue }
            let hash = String(cols[0]).lowercased()
            let target = cols[1].trimmingCharacters(in: CharacterSet(charactersIn: "*./"))
            if (target == fileName || URL(fileURLWithPath: target).lastPathComponent == fileName),
               hash.count == 64,
               hash.allSatisfy(\.isHexDigit) {
                return hash
            }
        }
        return nil
    }
}

#if !MEETING_UNIT_TESTS
// MARK: - In-App GitHub Release Auto-Updater

@MainActor
final class AppUpdater: ObservableObject {
    struct ReleaseUpdate: Equatable {
        let version: String
        let releaseURL: URL
        let zipURL: URL?
        let checksumsURL: URL?
        let sizeBytes: Int
    }

    struct UpdateFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let shared = AppUpdater()
    static let repositoryURL = URL(string: "https://github.com/zhangsubo/bo-finder")!
    private static let autoInstallDefaultsKey = "deskside.autoInstallUpdates"
    private static let checkInterval: TimeInterval = 15 * 60

    @Published private(set) var availableUpdate: ReleaseUpdate? = nil
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var errorMessage: String = ""
    @Published private(set) var lastCheckedAt: Date? = nil

    var autoInstallEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.autoInstallDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.autoInstallDefaultsKey)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.autoInstallDefaultsKey)
            if newValue, let update = availableUpdate, canAutoInstallInPlace {
                Task { await maybeAutoInstall(update) }
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0"
    }

    /// True when running from `/Applications/DeskSide.app` or `~/Applications/DeskSide.app` (writable, non-translocated, not a workspace `build/` bundle).
    var canInstallInPlace: Bool {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let folder = appURL.deletingLastPathComponent()
        guard !appURL.path.contains("/AppTranslocation/"),
              !appURL.path.hasPrefix("/Volumes/"),
              FileManager.default.isWritableFile(atPath: folder.path) else {
            return false
        }
        return true
    }

    var canAutoInstallInPlace: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return canInstallInPlace && !path.contains("/build/")
    }

    private var pollTimer: Timer? = nil
    private var deferredUntilMeetingEnds: Bool = false

    private var feedURL: URL {
        if let custom = ProcessInfo.processInfo.environment["DESKSIDE_UPDATE_FEED"],
           let url = URL(string: custom) {
            return url
        }
        return URL(string: "https://api.github.com/repos/zhangsubo/bo-finder/releases/latest")!
    }

    private init() {}

    func start() {
        guard pollTimer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            Task { @MainActor in
                await self?.checkForUpdates(manual: false)
            }
        }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(manual: false)
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func notifyMeetingRecordingEnded() {
        guard deferredUntilMeetingEnds, let update = availableUpdate else { return }
        deferredUntilMeetingEnds = false
        if autoInstallEnabled && canAutoInstallInPlace {
            Task { await install(update, silentRelaunch: true) }
        }
    }

    func checkForUpdates(manual: Bool = true) async {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        if manual {
            errorMessage = ""
            statusMessage = "正在检查 GitHub Release 最新版本…"
        }
        defer { isChecking = false }

        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DeskSide/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard code == 200 else {
                if manual {
                    if code == 404 {
                        statusMessage = "当前仓库暂无已发布的 GitHub Release（当前版本 v\(currentVersion)）"
                    } else {
                        errorMessage = "检查更新失败（HTTP \(code)）"
                    }
                }
                return
            }

            let release = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
            guard let htmlURL = URL(string: release.html_url) else { return }
            lastCheckedAt = Date()

            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let zipAsset = release.assets.first {
                $0.name.hasPrefix("DeskSide-") && $0.name.hasSuffix(".zip")
            } ?? release.assets.first {
                $0.name == "DeskSide.zip"
            }
            let checksumAsset = release.assets.first { $0.name == "checksums.txt" }

            if AppUpdaterLogic.isNewer(latest, than: currentVersion) {
                let update = ReleaseUpdate(
                    version: latest,
                    releaseURL: htmlURL,
                    zipURL: zipAsset.flatMap { URL(string: $0.browser_download_url) },
                    checksumsURL: checksumAsset.flatMap { URL(string: $0.browser_download_url) },
                    sizeBytes: zipAsset?.size ?? 0
                )
                availableUpdate = update
                statusMessage = "发现新版本 v\(latest)"
                if !manual && autoInstallEnabled && canAutoInstallInPlace {
                    await maybeAutoInstall(update)
                }
            } else {
                availableUpdate = nil
                deferredUntilMeetingEnds = false
                if manual {
                    statusMessage = "已是最新版本（v\(currentVersion)）"
                }
            }
        } catch {
            if manual {
                errorMessage = "检查更新失败：\(error.localizedDescription)"
            }
        }
    }

    private func maybeAutoInstall(_ update: ReleaseUpdate) async {
        let manager = MeetingManager.shared
        guard manager.active == nil, !manager.starting, !manager.stopping else {
            deferredUntilMeetingEnds = true
            statusMessage = "已发现新版本 v\(update.version)，将在当前会议录音结束后自动安装"
            return
        }
        await install(update, silentRelaunch: true)
    }

    func install(_ update: ReleaseUpdate, silentRelaunch: Bool = false) async {
        guard !isInstalling else { return }
        guard canInstallInPlace else {
            NSWorkspace.shared.open(update.releaseURL)
            errorMessage = "当前应用目录不可写，已打开 Release 页面供手动下载。"
            return
        }
        guard let zipURL = update.zipURL, let checksumsURL = update.checksumsURL else {
            NSWorkspace.shared.open(update.releaseURL)
            errorMessage = "该版本缺少自动安装包或校验文件，已打开发布页。"
            return
        }

        let manager = MeetingManager.shared
        if manager.active != nil || manager.starting || manager.stopping {
            deferredUntilMeetingEnds = true
            statusMessage = "正在录音中，已排入队列，散会后自动完成更新"
            return
        }

        isInstalling = true
        downloadProgress = 0
        errorMessage = ""
        statusMessage = "正在下载 v\(update.version) 更新包…"

        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("DeskSideUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipFile = workDir.appendingPathComponent(zipURL.lastPathComponent)
            try await downloadFile(from: zipURL, to: zipFile) { [weak self] fraction in
                self?.downloadProgress = fraction
            }

            statusMessage = "正在校验 SHA-256 与代码签名…"
            var checksumReq = URLRequest(url: checksumsURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            checksumReq.setValue("DeskSide/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (checksumsData, _) = try await URLSession.shared.data(for: checksumReq)
            guard let expectedHash = AppUpdaterLogic.expectedSHA256(for: zipFile.lastPathComponent, in: checksumsData) else {
                throw UpdateFailure(message: "checksums.txt 中未找到 \(zipFile.lastPathComponent) 的校验值")
            }
            let actualHash = try await computeSHA256(of: zipFile)
            guard actualHash == expectedHash else {
                throw UpdateFailure(message: "更新包 SHA-256 校验不一致，已中止安装")
            }

            let unpackedDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
            try await runTool("/usr/bin/ditto", arguments: ["-x", "-k", zipFile.path, unpackedDir.path])

            let newAppURL = unpackedDir.appendingPathComponent("DeskSide.app")
            let newInfo = Bundle(url: newAppURL)?.infoDictionary
            guard newInfo?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
                throw UpdateFailure(message: "更新包 Bundle ID 不匹配")
            }
            try await runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", newAppURL.path])

            let swapURL = workDir.appendingPathComponent("swap.sh")
            try Self.swapScript.write(to: swapURL, atomically: true, encoding: .utf8)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [
                swapURL.path,
                String(getpid()),
                appURL.path,
                newAppURL.path,
                workDir.path,
                silentRelaunch ? "--updated-silently" : ""
            ]
            try proc.run()

            statusMessage = "正在重启以完成 v\(update.version) 更新…"
            NSApp.terminate(nil)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            isInstalling = false
            downloadProgress = 0
            errorMessage = "自动更新失败：\(error.localizedDescription)"
            statusMessage = ""
        }
    }

    private static let swapScript = """
    PID="$1"
    TARGET_APP="$2"
    NEW_APP="$3"
    WORK_DIR="$4"
    RELAUNCH_ARG="$5"
    for _ in $(seq 1 60); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.2
    done
    if mv "$TARGET_APP" "$WORK_DIR/old.app"; then
      if mv "$NEW_APP" "$TARGET_APP"; then
        xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
        rm -rf "$WORK_DIR/old.app"
      else
        mv "$WORK_DIR/old.app" "$TARGET_APP"
      fi
    fi
    if [ -n "$RELAUNCH_ARG" ]; then
      open "$TARGET_APP" --args "$RELAUNCH_ARG"
    else
      open "$TARGET_APP"
    fi
    rm -rf "$WORK_DIR"
    """

    private func downloadFile(from url: URL, to destination: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 180)
            req.setValue("DeskSide/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let task = URLSession.shared.downloadTask(with: req) { tempURL, response, error in
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    continuation.resume(throwing: UpdateFailure(message: "下载失败（HTTP \(status)）"))
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: error ?? UpdateFailure(message: "下载失败"))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in onProgress(fraction) }
            }
            task.resume()
        }
    }

    private func computeSHA256(of fileURL: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    private func runTool(_ path: String, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateFailure(message: "\(URL(fileURLWithPath: path).lastPathComponent) 校验未通过"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private struct GitHubReleasePayload: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int?
        }
    }
}
#endif
