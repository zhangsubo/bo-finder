import Foundation

struct MeetingSegment: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var speaker: String
    var text: String
    var voiceID: Int? = nil
}

struct MeetingAudioChunk: Codable, Equatable {
    var file: String
    var start: Double
    var duration: Double
    var source: String
}

struct MeetingSummary: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var transcriptRevision: Int
    var model: String
    var template: String
    var text: String
}

struct MeetingSpeakerGuess: Codable, Equatable {
    var name: String
    var evidence: String
}

struct MeetingStructuredNotes: Codable, Equatable {
    var title: String? = nil
    var summary: String = ""
    var topics: [MeetingNoteTopic] = []
    var conclusions: [MeetingNoteItem] = []
    var todos: [MeetingNoteItem] = []
    var terms: [MeetingNoteTerm] = []
    var coveredCount: Int = 0
    var updatedAt: Date? = nil
    var isFinal: Bool = false
    var transcriptRevision: Int = 0

    var isEmpty: Bool {
        summary.isEmpty && topics.isEmpty && conclusions.isEmpty && todos.isEmpty
    }
}

struct MeetingNoteTopic: Codable, Equatable, Identifiable {
    var start: Double
    var title: String
    var summary: String
    var points: [String]
    var fishbone: MeetingFishbone? = nil
    var pointTimes: [Double?]? = nil

    var id: String { "\(Int(start))-\(title)" }

    func pointTime(_ index: Int) -> Double? {
        pointTimes.flatMap { index >= 0 && index < $0.count ? $0[index] : nil }
    }
}

struct MeetingFishbone: Codable, Equatable {
    var question: String
    var branches: [MeetingFishboneBranch]
}

struct MeetingFishboneBranch: Codable, Equatable, Identifiable {
    var label: String
    var detail: String
    var t: Double? = nil
    var support: Int
    var id: String { label + detail }
}

struct MeetingNoteItem: Codable, Equatable, Identifiable {
    var text: String
    var owner: String? = nil
    var support: Int
    var t: Double? = nil
    var id: String { text + (owner ?? "") }
}

struct MeetingNoteTerm: Codable, Equatable, Identifiable {
    var name: String
    var note: String
    var heard: [String]
    var id: String { name }

    static func ordered(_ terms: [MeetingNoteTerm]) -> [MeetingNoteTerm] {
        terms.filter { !$0.heard.isEmpty } + terms.filter { $0.heard.isEmpty }
    }

    /// Expands a user search query with matching glossary canonical names and misheard variants.
    static func expandQuery(_ rawQuery: String, terms: [MeetingNoteTerm]) -> [String] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out = [q]
        for term in terms {
            let forms = [term.name] + term.heard
            if forms.contains(where: { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }) {
                for form in forms where !form.isEmpty && !out.contains(form) {
                    out.append(form)
                }
            }
        }
        return out
    }
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
    // Optional fields keep older meeting.json files decodable without migration errors.
    var notes: MeetingStructuredNotes? = nil
    var speakerGuesses: [String: MeetingSpeakerGuess]? = nil
    var userRenamedTitle: Bool? = nil

    /// Stable 1-based display numbers for voiceprint speaker keys ("v0", "v1", ...) in appearance order.
    var voiceDisplayNumbers: [String: Int] {
        var seen: [String: Int] = [:]
        var next = 1
        for seg in segments {
            let key = seg.voiceID.map { "v\($0)" } ?? seg.speaker
            guard key.hasPrefix("v"), Int(key.dropFirst()) != nil else { continue }
            if seen[key] == nil {
                seen[key] = next
                next += 1
            }
        }
        return seen
    }

    func speakerName(_ key: String) -> String {
        if let explicit = speakerNames[key], !explicit.isEmpty {
            return explicit
        }
        if key == "me" { return "我" }
        if key == "them" { return "对方" }
        if key == "?" { return "说话人待识别" }
        // Empty string in speakerNames means user explicitly dismissed AI's guess ("不是 TA").
        if speakerNames[key] == nil, let guess = speakerGuesses?[key], !guess.name.isEmpty {
            return guess.name
        }
        if key.hasPrefix("v"), let raw = Int(key.dropFirst()) {
            let number = voiceDisplayNumbers[key] ?? (raw + 1)
            return "说话人 \(number)"
        }
        return "说话人 \(key)"
    }

    var transcript: String {
        segments.map {
            "[\($0.id.uuidString)] [\(Self.timestamp($0.start))–\(Self.timestamp($0.end))] \(speakerName($0.speaker))：\($0.text)"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }

    static func shortClock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
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
    // Optional fields keep pre-Apple / older configurations decodable without resetting preferences.
    var liveTranscription: String? = nil
    var appleSpeechLocale: String? = nil
    var voiceprintEnabled: Bool? = nil
    var liveNotesEnabled: Bool? = nil
    var floatingPanelAutoShow: Bool? = nil
    var floatingPanelShareable: Bool? = nil
    var feishuEnabled: Bool? = nil
    var dingtalkEnabled: Bool? = nil
    var zoomEnabled: Bool? = nil

    /// Defaults to zero-Python Apple native recognition unless user explicitly selected X-ASR
    /// or migrated from a legacy configuration that already had a Python runtime configured.
    var liveEngine: String { liveTranscription ?? (python.isEmpty ? "apple" : "xasr") }
    var speechLocale: String { appleSpeechLocale ?? "zh-CN" }
    var enableVoiceprint: Bool {
        get { voiceprintEnabled ?? true }
        set { voiceprintEnabled = newValue }
    }
    var enableLiveNotes: Bool {
        get { liveNotesEnabled ?? true }
        set { liveNotesEnabled = newValue }
    }
    var autoShowFloatingPanel: Bool {
        get { floatingPanelAutoShow ?? true }
        set { floatingPanelAutoShow = newValue }
    }
    var floatingPanelCapturable: Bool {
        get { floatingPanelShareable ?? false }
        set { floatingPanelShareable = newValue }
    }
    var feishu: Bool {
        get { feishuEnabled ?? true }
        set { feishuEnabled = newValue }
    }
    var dingtalk: Bool {
        get { dingtalkEnabled ?? true }
        set { dingtalkEnabled = newValue }
    }
    var zoom: Bool {
        get { zoomEnabled ?? true }
        set { zoomEnabled = newValue }
    }

    var speakerCount: Int? = nil
    var asrBase = "https://api.xiaomimimo.com/v1"
    var asrModel = "mimo-v2.5-asr"
    var summaryBase = ""
    var summaryModel = ""
    var template = "基于完整转录，生成会议概览、分议题讨论、明确决策、行动项和待确认问题。行动项列出事项、负责人、截止时间；未明确的信息填写未明确。保留依据片段 ID 和时间，不补写事实。"
}

/// Cleans speech recognizer breath/hesitation artifacts and rejoins sentences split across short pauses.
enum MeetingHeardText {
    static let joinGap = 1.5
    static let joinWords = 40

    static func clean(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(
            of: #"\[(?:music|laughter|applause|noise|silence|blank_audio|音乐|笑声|掌声|噪音)\]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasWords(_ text: String) -> Bool {
        text.contains(where: \.isLetter)
    }

    static func continues(_ previous: String, _ next: String, gap: Double, cut: Bool) -> Bool {
        guard gap >= -0.5, gap <= joinGap, let last = previous.last, let first = next.first else { return false }
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        let size = cjk ? previous.count / 2 : previous.split(separator: " ").count
        guard size < joinWords else { return false }
        switch last {
        case "?", "!", "？", "！":
            return false
        case ".", "。":
            return cut && (cjk || first.isLowercase)
        default:
            return true
        }
    }

    static func join(_ previous: String, _ next: String) -> String {
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        var head = previous
        if head.hasSuffix(".") && !head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("。") { head.removeLast() }
        return cjk ? head + next : head + " " + next
    }

    /// Detects whether a microphone utterance is speakerphone acoustic echo of concurrent system audio.
    static func isEcho(_ micText: String, of systemText: String) -> Bool {
        let a = normalizedLetters(micText)
        let b = normalizedLetters(systemText)
        guard a.count >= 2, b.count >= 2 else { return false }
        if b.contains(a) { return true }
        if a.contains(b), Double(b.count) / Double(a.count) >= 0.65 { return true }
        let setA = bigrams(a)
        let setB = bigrams(b)
        guard !setA.isEmpty, !setB.isEmpty else { return a == b }
        let overlap = setA.intersection(setB).count
        let dice = Double(2 * overlap) / Double(setA.count + setB.count)
        return dice >= 0.65
    }

    private static func normalizedLetters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return s.isEmpty ? [] : [s] }
        var out: Set<String> = []
        for i in 0..<(chars.count - 1) {
            out.insert(String([chars[i], chars[i + 1]]))
        }
        return out
    }
}

/// Apple may revise or split a volatile range. Keep each source independent and
/// replace overlapping drafts, rather than appending every hypothesis as a sentence.
/// Finalized entries are immutable, and tail breath/empty finals never erase earlier long drafts.
struct MeetingPreviewTimeline {
    private struct Entry {
        var source: String
        var segment: MeetingSegment
        var final: Bool
    }
    private var entries: [Entry] = []
    var segments: [MeetingSegment] { entries.map(\.segment).sorted { $0.start < $1.start } }

    /// Current unfinalized volatile text across active tracks, suitable for live captioning.
    var activeVolatileText: String {
        entries.filter { !$0.final }
            .sorted { $0.segment.start < $1.segment.start }
            .map(\.segment.text)
            .joined(separator: " ")
    }

    mutating func replace(source: String, start: Double, end: Double, text: String, final: Bool, speaker: String = "?") {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return }
        let trimmed = final ? MeetingHeardText.clean(text) : text.trimmingCharacters(in: .whitespacesAndNewlines)
        let validText = final ? (MeetingHeardText.hasWords(trimmed) ? trimmed : "") : trimmed
        if validText.isEmpty {
            // Only withdraw a draft whose start aligns with this empty final; never wipe an earlier long draft on tail noise.
            if final {
                entries.removeAll {
                    $0.source == source && !$0.final && abs($0.segment.start - start) < 0.5
                }
            }
            return
        }
        let replaced = entries.filter {
            $0.source == source && !$0.final &&
            (abs($0.segment.start - start) < 0.001 || ($0.segment.start < end && $0.segment.end > start))
        }
        let ids = Set(replaced.map { $0.segment.id })
        entries.removeAll { ids.contains($0.segment.id) }
        entries.append(Entry(
            source: source,
            segment: MeetingSegment(
                id: replaced.first?.segment.id ?? UUID(),
                start: start,
                end: end,
                speaker: speaker,
                text: validText
            ),
            final: final
        ))
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

enum MeetingKeyMask {
    /// Formats a saved API key showing the first 8 characters, `***`, and the last 4 characters.
    /// Shorter keys fall back to narrower prefixes/suffixes so middle characters are never exposed.
    static func format(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let chars = Array(trimmed)
        if chars.count > 12 {
            return String(chars.prefix(8)) + "***" + String(chars.suffix(4))
        } else if chars.count >= 9 {
            return String(chars.prefix(4)) + "***" + String(chars.suffix(2))
        } else if chars.count >= 5 {
            return String(chars.prefix(2)) + "***" + String(chars.suffix(2))
        } else {
            return "***"
        }
    }
}

enum MeetingModelListParser {
    /// Extracts unique model IDs from OpenAI-compatible `/v1/models` responses.
    static func parse(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rawItems: [Any] = []
        if let dict = root as? [String: Any] {
            if let dataArr = dict["data"] as? [Any] {
                rawItems = dataArr
            } else if let modelsArr = dict["models"] as? [Any] {
                rawItems = modelsArr
            }
        } else if let arr = root as? [Any] {
            rawItems = arr
        }

        var seen = Set<String>()
        var result: [String] = []
        for item in rawItems {
            let candidate: String?
            if let str = item as? String {
                candidate = str
            } else if let obj = item as? [String: Any] {
                if let id = obj["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidate = id
                } else if let name = obj["name"] as? String {
                    candidate = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                } else {
                    candidate = nil
                }
            } else {
                candidate = nil
            }
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty,
               seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}
