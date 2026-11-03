import Foundation

struct MeetingSegment: Codable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

struct MeetingAudioChunk: Codable {
    var file: String
    var start: Double
    var duration: Double
    var source: String
}

struct MeetingSummary: Codable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var transcriptRevision: Int
    var model: String
    var template: String
    var text: String
}

struct MeetingRecord: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var date: Date = Date()
    var source: String
    var duration: Double = 0
    var phase: String = "recording"
    var transcriptState: String = "waiting"
    var summaryState: String = "waiting"
    var issue: String = ""
    var chunks: [MeetingAudioChunk] = []
    var segments: [MeetingSegment] = []
    var preview: [MeetingSegment] = []
    var speakerNames: [String: String] = [:]
    var revision: Int = 0
    var summaries: [MeetingSummary] = []

    func speakerName(_ key: String) -> String { speakerNames[key] ?? (key == "?" ? "说话人待识别" : "说话人 \(key)") }
    var transcript: String {
        segments.map { "[\($0.id.uuidString)] [\(Self.timestamp($0.start))–\(Self.timestamp($0.end))] \(speakerName($0.speaker))：\($0.text)" }.joined(separator: "\n")
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}

struct MeetingConfiguration: Codable {
    var automatic = false
    var tencent = true
    var wechat = true
    var microphone = "default"
    var systemAudio = true
    var python = ""
    var models = ""
    var transcription = "local"
    // Optional fields keep pre-Apple configurations decodable without resetting preferences.
    var liveTranscription: String? = nil
    var appleSpeechLocale: String? = nil
    var liveEngine: String { liveTranscription ?? "xasr" }
    var speechLocale: String { appleSpeechLocale ?? "zh-CN" }
    var speakerCount: Int? = nil
    var asrBase = "https://api.xiaomimimo.com/v1"
    var asrModel = "mimo-v2.5-asr"
    var summaryBase = ""
    var summaryModel = ""
    var template = "基于完整转录，生成会议概览、分议题讨论、明确决策、行动项和待确认问题。行动项列出事项、负责人、截止时间；未明确的信息填写未明确。保留依据片段 ID 和时间，不补写事实。"
}

/// Apple may revise or split a volatile range. Keep each source independent and
/// replace overlapping drafts, rather than appending every hypothesis as a sentence.
struct MeetingPreviewTimeline {
    private struct Entry {
        var source: String
        var segment: MeetingSegment
        var final: Bool
    }
    private var entries: [Entry] = []
    var segments: [MeetingSegment] { entries.map(\.segment).sorted { $0.start < $1.start } }

    mutating func replace(source: String, start: Double, end: Double, text: String, final: Bool) {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return }
        let replaced = entries.filter {
            $0.source == source && !$0.final &&
            (abs($0.segment.start - start) < 0.001 || ($0.segment.start < end && $0.segment.end > start))
        }
        let ids = Set(replaced.map { $0.segment.id })
        entries.removeAll { ids.contains($0.segment.id) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.append(Entry(source: source, segment: MeetingSegment(id: replaced.first?.segment.id ?? UUID(), start: start, end: end, speaker: "?", text: text), final: final))
    }
}

enum MeetingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum MeetingFiles {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeskSide/Meetings", isDirectory: true)
    static func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func save(_ record: MeetingRecord) throws {
        let directory = directory(record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(record)
        let file = directory.appendingPathComponent("meeting.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func load() throws -> [MeetingRecord] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let file = directory.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(MeetingRecord.self, from: Data(contentsOf: file))
        }.sorted { $0.date > $1.date }
    }
    static func endpoint(_ base: String, path: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw MeetingFailure.message("请输入有效的 HTTPS 服务地址（本机服务可使用 HTTP），不要在地址中包含密钥。")
        }
        return url.appendingPathComponent(path)
    }
}
