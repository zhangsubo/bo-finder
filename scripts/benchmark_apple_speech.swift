// Compile with MeetingModels.swift and MeetingAppleSpeech.swift. No microphone,
// system capture, user meeting files, or cloud transcription are accessed.
import Foundation
import AVFoundation

@main
struct AppleSpeechBenchmark {
    @MainActor
    static func main() async throws {
        let args = CommandLine.arguments
        let locale = "zh-CN"
        if args.contains("--check") || args.contains("--install") {
            print(try await MeetingAppleSpeech.check(locale: locale, install: args.contains("--install")) { print($0) })
            return
        }
        guard let index = args.firstIndex(of: "--audio"), args.count > index + 1 else {
            throw MeetingFailure.message("Usage: --check | --install | --audio fixture.wav [--realtime]")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[index + 1]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deskside-apple-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loadStart = ProcessInfo.processInfo.systemUptime
        let session = try await MeetingAppleSpeech.start(locale: locale, sources: ["mic", "system"])
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let began = ProcessInfo.processInfo.systemUptime
        var firstText: Double?
        var emissions = 0
        var segments: [MeetingSegment] = []
        var issues: [String] = []
        var events: [[String: Any]] = []
        var latestSubmission = began
        var emissionLags: [Double] = []
        session.onStatus = { issues.append($0) }
        session.onResult = { source, segment, final in
            events.append(["source": source, "start": segment.start, "end": segment.end,
                           "text": segment.text, "final": final, "wall_seconds": ProcessInfo.processInfo.systemUptime - began])
        }
        session.onUpdate = { value in
            emissions += 1
            segments = value
            if !value.isEmpty, firstText == nil { firstText = ProcessInfo.processInfo.systemUptime - began }
            // A service emission is not a per-chunk acknowledgment. Report separately
            // from the X-ASR worker's request/response latency.
            emissionLags.append(ProcessInfo.processInfo.systemUptime - latestSubmission)
        }
        var offset: AVAudioFramePosition = 0
        while offset < file.length {
            let count = AVAudioFrameCount(min(AVAudioFramePosition(file.processingFormat.sampleRate), file.length - offset))
            let buffer = try MeetingAudioFileReader.read(file, frames: count)
            guard buffer.frameLength == count else { throw MeetingFailure.message("Fixture ended before expected frame count.") }
            let start = Double(offset) / file.processingFormat.sampleRate
            let audioEnd = start + Double(count) / file.processingFormat.sampleRate
            let pauseOffset = args.contains("--pause-test") && start >= 5 ? 2.0 : 0.0
            if args.contains("--realtime") {
                let wait = began + audioEnd + pauseOffset - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            let url = folder.appendingPathComponent("\(offset).wav")
            do {
                let output = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings)
                try output.write(from: buffer)
            }
            latestSubmission = ProcessInfo.processInfo.systemUptime
            for source in ["mic", "system"] {
                session.submit(MeetingAudioChunk(file: url.lastPathComponent, start: start + pauseOffset, duration: Double(count) / file.processingFormat.sampleRate, source: source), file: url)
            }
            offset += AVAudioFramePosition(count)
            await Task.yield()
        }
        await session.finish()
        let sorted = emissionLags.sorted()
        let report: [String: Any] = [
            "engine": "Apple SpeechTranscriber", "audio_seconds": Double(file.length) / file.processingFormat.sampleRate,
            "tracks": 2, "realtime": args.contains("--realtime"), "load_seconds": loadSeconds,
            "pause_test": args.contains("--pause-test"),
            "first_text_wall_seconds": firstText as Any? ?? NSNull(), "emissions": emissions,
            "emission_since_latest_submission_p95_seconds": sorted.isEmpty ? NSNull() : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] as Any,
            "issues": issues,
            "result_events": events,
            "transcript": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] }
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        guard firstText != nil, issues.isEmpty else { throw MeetingFailure.message("Apple benchmark did not complete cleanly; see report.") }
    }
}
