import Foundation

@main
struct MeetingTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("Failed: \(label)") }
            checks += 1
            print("  ✅ \(label)")
        }
        let config = MeetingConfiguration()
        check(!config.automatic, "Recording requires initial user opt-in")
        check(config.transcription == "local", "Default does not upload audio")
        let encoded = try JSONEncoder().encode(config)
        let json = String(decoding: encoded, as: UTF8.self)
        check(!json.contains("apiKey") && !json.contains("password"), "Credentials excluded from configuration")
        let roundtrip = try JSONDecoder().decode(MeetingConfiguration.self, from: encoded)
        check(roundtrip.template == config.template, "Template survives configuration roundtrip")
        check(roundtrip.liveEngine == "xasr" && roundtrip.speechLocale == "zh-CN", "Legacy configuration without Apple fields keeps X-ASR")
        var appleConfig = config
        appleConfig.liveTranscription = "apple"
        appleConfig.appleSpeechLocale = "en-US"
        let appleRoundtrip = try JSONDecoder().decode(MeetingConfiguration.self, from: JSONEncoder().encode(appleConfig))
        check(appleRoundtrip.liveEngine == "apple" && appleRoundtrip.speechLocale == "en-US", "Apple engine and language persist")
        check(appleRoundtrip.transcription == "local", "Apple preview retains local offline processing")
        var timeline = MeetingPreviewTimeline()
        timeline.replace(source: "mic", start: 1, end: 3, text: "初稿", final: false)
        let draftID = timeline.segments[0].id
        timeline.replace(source: "system", start: 1, end: 3, text: "另一音源", final: false)
        timeline.replace(source: "mic", start: 1, end: 4, text: "修订稿", final: false)
        check(timeline.segments.count == 2, "Revised draft replaces itself without removing the other source")
        check(timeline.segments.first { $0.text == "修订稿" }?.id == draftID, "Volatile revisions preserve UI identity")
        timeline.replace(source: "mic", start: 1, end: 2, text: "前半句", final: true)
        timeline.replace(source: "mic", start: 2, end: 4, text: "后半句", final: true)
        check(timeline.segments.count == 3 && !timeline.segments.contains { $0.text == "修订稿" }, "Final split replaces a longer volatile hypothesis")
        timeline.replace(source: "system", start: 1, end: 3, text: "", final: true)
        check(timeline.segments.count == 2, "Empty final removes withdrawn draft")
        timeline.replace(source: "mic", start: 30, end: 31, text: "暂停后", final: true)
        check(timeline.segments.last?.start == 30, "Pause gaps keep the original meeting timeline")
        timeline.replace(source: "mic", start: .nan, end: 32, text: "无效", final: false)
        check(timeline.segments.count == 3, "Invalid timestamps do not corrupt preview")
        var record = MeetingRecord(title: "讨论", source: "线下")
        record.segments = [MeetingSegment(start: 1.5, end: 4, speaker: "A", text: "周三前交付"), MeetingSegment(start: 5, end: 8, speaker: "A", text: "先测试")]
        record.speakerNames["A"] = "负责人"
        record.summaries = [MeetingSummary(transcriptRevision: 0, model: "example", template: "完整纪要", text: "保留旧版")]
        record.revision = 1
        let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
        check(restored.segments.map(\.id) == record.segments.map(\.id), "Stable source IDs survive persistence")
        check(restored.transcript.components(separatedBy: "负责人").count == 3, "Speaker rename applies to every turn")
        check(restored.summaries[0].transcriptRevision != restored.revision, "Edited transcript marks prior summary stale")
        check(restored.transcript.contains(record.segments[0].id.uuidString), "Summary input carries verifiable source references")
        check(MeetingRecord.timestamp(3661) == "01:01:01", "Long meetings retain hours")
        check(MeetingRecord.timestamp(-1) == "00:00:00", "Invalid negative timestamp is clamped")
        let url = try MeetingFiles.endpoint("https://example.com/v1/", path: "chat/completions")
        check(url.absoluteString == "https://example.com/v1/chat/completions", "Custom compatible endpoint path")
        for invalid in ["http://remote.example/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/test", ""] {
            do { _ = try MeetingFiles.endpoint(invalid, path: "chat/completions"); fatalError("Accepted invalid endpoint") }
            catch { checks += 1 }
        }
        _ = try MeetingFiles.endpoint("http://127.0.0.1:8000/v1", path: "chat/completions")
        checks += 1
        print("Meeting tests: \(checks) passed")
    }
}
