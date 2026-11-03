import Foundation
@preconcurrency import AVFoundation
import Speech

enum MeetingAudioFileReader {
    /// AVAudioFile can return fewer frames than requested before EOF. Never skip
    /// the remainder of a WAV just because the first read succeeded.
    static func read(_ file: AVAudioFile, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw MeetingFailure.message("无法分配音频读取缓冲区。")
        }
        var total: AVAudioFrameCount = 0
        let bytesPerFrame = Int(file.processingFormat.streamDescription.pointee.mBytesPerFrame)
        while total < frames {
            if file.framePosition >= file.length { break }
            guard let part = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames - total) else {
                throw MeetingFailure.message("无法分配音频读取缓冲区。")
            }
            try file.read(into: part, frameCount: frames - total)
            guard part.frameLength > 0 else { break }
            let source = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
            for index in source.indices {
                guard let src = source[index].mData, let dst = destination[index].mData else {
                    throw MeetingFailure.message("音频缓冲区为空。")
                }
                memcpy(dst.advanced(by: Int(total) * bytesPerFrame), src, Int(part.frameLength) * bytesPerFrame)
            }
            total += part.frameLength
        }
        output.frameLength = total
        return output
    }
}

@MainActor
protocol MeetingAppleLiveSession: AnyObject {
    var onUpdate: (([MeetingSegment]) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onResult: ((String, MeetingSegment, Bool) -> Void)? { get set }
    func submit(_ chunk: MeetingAudioChunk, file: URL)
    func finish() async
}

@MainActor
enum MeetingAppleSpeech {
    static var supportedOS: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func check(locale: String, install: Bool = false, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        guard #available(macOS 26, *) else { throw MeetingFailure.message("Apple 原生转录需要 macOS 26 或更新版本。") }
        let transcriber = try await module(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        if !install {
            switch status {
            case .installed: return "Apple 语音模型已就绪（\(locale)），可用于本地实时转录。"
            case .downloading: return "系统正在下载该语言的语音模型，请稍后检查。"
            case .supported: return "此语言受支持，需先下载 Apple 语音模型。"
            case .unsupported: throw MeetingFailure.message("这台 Mac 暂不支持所选 Apple 语音模型。")
            @unknown default: throw MeetingFailure.message("无法确认 Apple 语音模型状态。")
            }
        }
        // Reserve only our selected language; never evict another app's assets.
        guard try await AssetInventory.reserve(locale: transcriber.selectedLocales[0]) else {
            throw MeetingFailure.message("无法为此语言保留语音模型，请检查系统语言资源限制。")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let monitor = Task {
                while !Task.isCancelled {
                    progress("正在准备 Apple 语音模型：\(Int(request.progress.fractionCompleted * 100))%")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            defer { monitor.cancel() }
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw MeetingFailure.message("Apple 语音模型尚未就绪，请稍后重试。")
        }
        return "Apple 语音模型已就绪（\(locale)），音频识别在本机进行。"
    }

    static func start(locale: String, sources: [String]) async throws -> any MeetingAppleLiveSession {
        guard #available(macOS 26, *) else { throw MeetingFailure.message("Apple 原生转录需要 macOS 26 或更新版本；可改选 X-ASR。") }
        let session = AppleSpeechSession()
        do { try await session.start(locale: locale, sources: sources); return session }
        catch { await session.finish(); throw error }
    }

    @available(macOS 26, *)
    fileprivate static func module(locale: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw MeetingFailure.message("当前设备的 Apple 原生转录不可用，可改选 X-ASR。") }
        guard let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw MeetingFailure.message("Apple 原生转录不支持所选语言（\(locale)）。")
        }
        return SpeechTranscriber(locale: equivalent, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }
}

@available(macOS 26, *)
@MainActor
private final class AppleSpeechSession: MeetingAppleLiveSession {
    private final class Track {
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        var results: Task<Void, Never>?
        var converter: AVAudioConverter?
        var lastEnd: Double = 0
        var inputEnd: Double?
        var failed = false
        init(analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
            self.analyzer = analyzer; self.continuation = continuation; self.format = format
        }
    }
    private var tracks: [String: Track] = [:]
    private var timeline = MeetingPreviewTimeline()
    private var stopped = false
    var onUpdate: (([MeetingSegment]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onResult: ((String, MeetingSegment, Bool) -> Void)?

    func start(locale: String, sources: [String]) async throws {
        for source in Set(sources).sorted() {
            let module = try await MeetingAppleSpeech.module(locale: locale)
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw MeetingFailure.message("Apple 语音模型未就绪。请在会议设置中下载模型；录音仍可保存。")
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw MeetingFailure.message("Apple 语音模型没有兼容的音频格式。")
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(4))
            let analyzer = SpeechAnalyzer(modules: [module])
            let track = Track(analyzer: analyzer, continuation: continuation, format: format)
            tracks[source] = track
            track.results = Task { [weak self, weak track] in
                do {
                    for try await result in module.results {
                        guard !Task.isCancelled, let self else { return }
                        self.onResult?(source, MeetingSegment(start: result.range.start.seconds, end: result.range.end.seconds, speaker: "?", text: String(result.text.characters)), result.isFinal)
                        self.timeline.replace(source: source, start: result.range.start.seconds, end: result.range.end.seconds,
                                              text: String(result.text.characters), final: result.isFinal)
                        self.onUpdate?(self.timeline.segments)
                    }
                } catch {
                    track?.failed = true
                    if let self, !self.stopped { self.onStatus?("Apple 实时识别中断：\(error.localizedDescription)。录音保留，会后可重新转录。") }
                }
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        }
    }

    func submit(_ chunk: MeetingAudioChunk, file: URL) {
        guard !stopped, let track = tracks[chunk.source], !track.failed else { return }
        do {
            let audio = try AVAudioFile(forReading: file)
            // Only bounded capture chunks are accepted here, never whole meetings.
            guard audio.length > 0, Double(audio.length) / audio.processingFormat.sampleRate <= 5,
                  chunk.start.isFinite, chunk.start >= 0 else {
                throw MeetingFailure.message("实时音频片段无效。")
            }
            let input = try MeetingAudioFileReader.read(audio, frames: AVAudioFrameCount(audio.length))
            guard input.frameLength == audio.length else { throw MeetingFailure.message("实时音频片段不完整。") }
            let continuous = track.inputEnd.map { abs(chunk.start - $0) < 0.05 } ?? false
            let buffer: AVAudioPCMBuffer
            if input.format == track.format { buffer = input }
            else {
                if track.converter?.inputFormat != input.format { track.converter = AVAudioConverter(from: input.format, to: track.format) }
                guard let converter = track.converter,
                      let output = AVAudioPCMBuffer(pcmFormat: track.format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * track.format.sampleRate / input.format.sampleRate) + 128)) else {
                    throw MeetingFailure.message("无法转换 Apple 识别所需的音频格式。")
                }
                // Preserve resampler context across WAV boundaries. Resetting for every
                // second loses priming samples and makes Speech treat each chunk as a gap.
                if !continuous { converter.reset() }
                var supplied = false
                var conversionError: NSError?
                converter.convert(to: output, error: &conversionError) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return input
                }
                if let conversionError { throw conversionError }
                buffer = output
            }
            guard buffer.frameLength > 0 else { return }
            // Capture timestamps preserve pauses and source offsets. Clamp tiny callback
            // overlaps so the analyzer always receives monotonically ordered buffers.
            let start = continuous ? track.lastEnd : max(chunk.start, track.lastEnd)
            let value = AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(seconds: start, preferredTimescale: 48000))
            switch track.continuation.yield(value) {
            case .enqueued:
                track.lastEnd = start + Double(buffer.frameLength) / buffer.format.sampleRate
                track.inputEnd = chunk.start + Double(input.frameLength) / input.format.sampleRate
            case .dropped:
                onStatus?("Apple 实时识别暂时落后，跳过预览片段；原始录音保留供会后处理。")
            case .terminated:
                track.failed = true
                onStatus?("Apple 实时识别已停止，录音仍保留。")
            @unknown default: break
            }
        } catch {
            track.failed = true
            track.continuation.finish()
            onStatus?("Apple 实时识别失败：\(error.localizedDescription)。录音仍保留。")
        }
    }

    func finish() async {
        guard !stopped else { return }
        stopped = true
        let pending = Array(tracks.values)
        for track in pending { track.continuation.finish() }
        // A speech service stall must not prevent saving/ending a recording.
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            for track in pending { track.results?.cancel(); await track.analyzer.cancelAndFinishNow() }
        }
        defer { timeout.cancel(); tracks.removeAll() }
        for track in pending {
            do { try await track.analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await track.analyzer.cancelAndFinishNow() }
            await track.results?.value
        }
    }
}
