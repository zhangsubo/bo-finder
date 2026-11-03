import Foundation
@preconcurrency import AVFoundation
import CoreMedia
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

struct MeetingAppleFinalizedSegment {
    var source: String
    var segment: MeetingSegment
    var wasCut: Bool
    var voiceSamples: [Float]?
}

@MainActor
protocol MeetingAppleLiveSession: AnyObject {
    var onUpdate: (([MeetingSegment]) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    var onResult: ((String, MeetingSegment, Bool) -> Void)? { get set }
    var onVolatile: ((String, String) -> Void)? { get set }
    var onFinalSegment: ((MeetingAppleFinalizedSegment) -> Void)? { get set }
    func push(source: String, buffer: AVAudioPCMBuffer, startTime: Double?)
    func submit(_ chunk: MeetingAudioChunk, file: URL)
    func finish() async
}

@MainActor
enum MeetingAppleSpeech {
    static var supportedOS: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func resolvedInitialLocale(_ locale: String) async -> String {
        if locale != "auto" { return locale }
        guard #available(macOS 26, *) else { return "zh-CN" }
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        if installed.contains(where: { $0.hasPrefix("zh") }) { return "zh-CN" }
        if installed.contains(where: { $0.hasPrefix("en") }) { return "en-US" }
        return "zh-CN"
    }

    static func check(locale: String, install: Bool = false, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        guard #available(macOS 26, *) else { throw MeetingFailure.message("Apple 原生转录需要 macOS 26 或更新版本。") }
        let localesToCheck = locale == "auto" ? ["zh-CN", "en-US"] : [locale]
        var statuses: [String] = []

        for target in localesToCheck {
            let transcriber: SpeechTranscriber
            do {
                transcriber = try await module(locale: target)
            } catch {
                if locale == "auto" { continue }
                throw error
            }
            let status = await AssetInventory.status(forModules: [transcriber])
            if !install {
                switch status {
                case .installed:
                    statuses.append("\(target) 已就绪")
                case .downloading:
                    statuses.append("\(target) 下载中")
                case .supported:
                    statuses.append("\(target) 可下载")
                case .unsupported:
                    if locale != "auto" {
                        throw MeetingFailure.message("这台 Mac 暂不支持所选 Apple 语音模型（\(target)）。")
                    }
                @unknown default:
                    break
                }
                continue
            }

            if status != .installed {
                _ = try? await AssetInventory.reserve(locale: transcriber.selectedLocales[0])
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let monitor = Task {
                        while !Task.isCancelled {
                            progress("正在准备 Apple 语音模型（\(target)）：\(Int(request.progress.fractionCompleted * 100))%")
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }
                    defer { monitor.cancel() }
                    try await request.downloadAndInstall()
                }
            }
            if await AssetInventory.status(forModules: [transcriber]) == .installed {
                statuses.append("\(target) 已就绪")
            } else if locale != "auto" {
                throw MeetingFailure.message("Apple 语音模型（\(target)）尚未就绪，请稍后重试。")
            }
        }

        if statuses.isEmpty {
            throw MeetingFailure.message("无法确认 Apple 语音模型状态。")
        }
        return "Apple 语音模型状态：" + statuses.joined(separator: "，") + "（音频识别全程在本机进行）。"
    }

    static func start(locale: String, sources: [String], captureVoice: Bool = true) async throws -> any MeetingAppleLiveSession {
        guard #available(macOS 26, *) else {
            throw MeetingFailure.message("Apple 原生转录需要 macOS 26 或更新版本；可改选 X-ASR。")
        }
        let session = AppleSpeechSession(captureVoice: captureVoice)
        do {
            try await session.start(locale: locale, sources: sources)
            return session
        } catch {
            await session.finish()
            throw error
        }
    }

    @available(macOS 26, *)
    fileprivate static func module(locale: String) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else {
            throw MeetingFailure.message("当前设备的 Apple 原生转录不可用，可改选 X-ASR。")
        }
        guard let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw MeetingFailure.message("Apple 原生转录不支持所选语言（\(locale)）。")
        }
        return SpeechTranscriber(
            locale: equivalent,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }
}

// MARK: - Per-Track Unbounded Streaming Router & Voice Ring Buffer

@available(macOS 26, *)
private final class ApplePCMConverter {
    private var converter: AVAudioConverter?

    func reset() { converter?.reset() }

    func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input.format == format {
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: input.frameLength) else { return input }
            copy.frameLength = input.frameLength
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            let srcList = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let dstList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for idx in srcList.indices {
                if let s = srcList[idx].mData, let d = dstList[idx].mData {
                    memcpy(d, s, Int(input.frameLength) * bytesPerFrame)
                }
            }
            return copy
        }
        if converter == nil || converter!.inputFormat != input.format || converter!.outputFormat != format {
            converter = AVAudioConverter(from: input.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 128)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData; return input
        }
        if status == .error || error != nil || out.frameLength == 0 { return nil }
        return out
    }
}

@available(macOS 26, *)
private final class AppleTrackRouter: @unchecked Sendable {
    private static let maxVoiceSliceSeconds = 20.0
    private static let voiceRingLimitSeconds = 90.0
    private static let replayLimitSeconds = 10.0
    private static let voiceThreshold: Float = 0.008

    let queue: DispatchQueue
    private let analyzerConverter = ApplePCMConverter()
    private let voiceConverter = ApplePCMConverter()
    private let voiceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var format: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let captureVoice: Bool

    private var fed: Double = 0
    private var silenceRun: Double = 0
    private var voicedTotal: Double = 0
    private var pause: (end: Double, length: Double) = (0, 0)
    private var lastEnd: Double = 0
    private var inputEnd: Double?

    private var voiceSamplesRing: [Float] = []
    private var voiceStartClock: Double = 0

    private var replayRing: [(buffer: AVAudioPCMBuffer, start: Double, duration: Double, voiced: Bool)] = []
    private var replaySecondsTotal: Double = 0

    init(source: String, captureVoice: Bool) {
        self.queue = DispatchQueue(label: "deskside.meeting.apple.\(source)", qos: .userInitiated)
        self.captureVoice = captureVoice
    }

    func attach(
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        replaySeconds: Double = 0
    ) {
        queue.sync {
            self.continuation?.finish()
            self.format = format
            self.continuation = continuation
            self.pause = (0, 0)
            if replaySeconds > 0, !replayRing.isEmpty {
                var acc = 0.0
                var toReplay: [(buffer: AVAudioPCMBuffer, start: Double, duration: Double, voiced: Bool)] = []
                for item in replayRing.reversed() {
                    if acc >= replaySeconds { break }
                    acc += item.duration
                    toReplay.append(item)
                }
                for item in toReplay.reversed() {
                    let t = CMTime(seconds: item.start, preferredTimescale: 48_000)
                    continuation.yield(AnalyzerInput(buffer: item.buffer, bufferStartTime: t))
                    lastEnd = max(lastEnd, item.start + item.duration)
                    fed = lastEnd
                }
            }
        }
    }

    func detach() {
        queue.sync {
            continuation?.finish()
            continuation = nil
        }
    }

    func push(buffer: AVAudioPCMBuffer, explicitStartTime: Double?) {
        queue.async { [self] in
            process(buffer: buffer, explicitStartTime: explicitStartTime)
        }
    }

    private func process(buffer: AVAudioPCMBuffer, explicitStartTime: Double?) {
        guard buffer.frameLength > 0, let format, let continuation else { return }
        let inputDuration = Double(buffer.frameLength) / buffer.format.sampleRate

        // Compute RMS on float channel 0 when available (or converted 16kHz float) to track micro-pauses.
        let voiceMono = voiceConverter.convert(buffer, to: voiceFormat)
        var rms: Float = 0
        if let vData = voiceMono?.floatChannelData?[0], let vLen = voiceMono?.frameLength, vLen > 0 {
            let n = Int(vLen)
            var sum: Float = 0
            for i in 0..<n { sum += vData[i] * vData[i] }
            rms = (sum / Float(n)).squareRoot()
        }

        let continuous: Bool
        if let explicitStartTime {
            continuous = inputEnd.map { abs(explicitStartTime - $0) < 0.08 } ?? true
        } else {
            continuous = true
        }
        if !continuous {
            analyzerConverter.reset()
        }

        guard let converted = analyzerConverter.convert(buffer, to: format) else { return }
        let outDuration = Double(converted.frameLength) / converted.format.sampleRate
        let start: Double
        if let explicitStartTime {
            start = continuous ? lastEnd : max(explicitStartTime, lastEnd)
        } else {
            start = lastEnd
        }

        let voiced = rms >= Self.voiceThreshold
        if voiced {
            if silenceRun >= 0.12 {
                pause = (start, silenceRun)
            }
            voicedTotal += outDuration
            silenceRun = 0
        } else {
            silenceRun += outDuration
        }

        let input = AnalyzerInput(buffer: converted, bufferStartTime: CMTime(seconds: start, preferredTimescale: 48_000))
        _ = continuation.yield(input)

        let end = start + outDuration
        lastEnd = end
        fed = end
        if let explicitStartTime {
            inputEnd = explicitStartTime + inputDuration
        }

        if captureVoice, let vBuf = voiceMono, let vPtr = vBuf.floatChannelData?[0] {
            let count = Int(vBuf.frameLength)
            if voiceSamplesRing.isEmpty {
                voiceStartClock = start
            } else {
                // Pad silent gap if explicitStartTime jumped across a pause so sample indices match analyzer clock.
                let expectedEnd = voiceStartClock + Double(voiceSamplesRing.count) / 16_000
                let gap = start - expectedEnd
                if gap > 0.05 && gap < 30 {
                    voiceSamplesRing.append(contentsOf: repeatElement(0, count: Int(gap * 16_000)))
                }
            }
            voiceSamplesRing.append(contentsOf: UnsafeBufferPointer(start: vPtr, count: count))
            let limitSamples = Int(Self.voiceRingLimitSeconds * 16_000)
            let over = voiceSamplesRing.count - limitSamples
            if over > 16_000 {
                voiceSamplesRing.removeFirst(over)
                voiceStartClock += Double(over) / 16_000
            }
        }

        replayRing.append((converted, start, outDuration, voiced))
        replaySecondsTotal += outDuration
        while replaySecondsTotal > Self.replayLimitSeconds, !replayRing.isEmpty {
            replaySecondsTotal -= replayRing.removeFirst().duration
        }
    }

    func clock() -> (fed: Double, silence: Double, voicedTotal: Double, pause: (end: Double, length: Double)) {
        queue.sync {
            (fed: fed, silence: silenceRun, voicedTotal: voicedTotal, pause: pause)
        }
    }

    func snapshotVoicedClip(seconds: Double) -> (buffers: [AVAudioPCMBuffer], voicedSeconds: Double) {
        queue.sync {
            var acc = 0.0
            var voiced = 0.0
            var out: [AVAudioPCMBuffer] = []
            for item in replayRing.reversed() {
                if acc >= seconds { break }
                acc += item.duration
                if item.voiced { voiced += item.duration }
                out.append(item.buffer)
            }
            return (buffers: Array(out.reversed()), voicedSeconds: voiced)
        }
    }

    func voiceSamples(from start: Double, to end: Double) -> [Float]? {
        queue.sync {
            guard captureVoice, !voiceSamplesRing.isEmpty else { return nil }
            let lo = Int(((start - voiceStartClock) * 16_000).rounded())
            let hi = Int(((end - voiceStartClock) * 16_000).rounded())
            let clampedLo = max(0, lo)
            let maxCount = Int(Self.maxVoiceSliceSeconds * 16_000)
            let clampedHi = min(voiceSamplesRing.count, hi, clampedLo + maxCount)
            guard clampedHi > clampedLo + 8_000 else { return nil } // >= 0.5s
            return Array(voiceSamplesRing[clampedLo..<clampedHi])
        }
    }
}

// MARK: - Live Apple Speech Session (Micro-Pause Cut + Auto Reconnect + Optional Auto-Language)

@available(macOS 26, *)
@MainActor
private final class AppleSpeechSession: MeetingAppleLiveSession {
    private final class TrackState {
        let source: String
        let router: AppleTrackRouter
        var locale: String
        var analyzer: SpeechAnalyzer?
        var resultsTask: Task<Void, Never>?
        var generation: Int = 0
        var failureStreak: Int = 0

        var volatileText: String = ""
        var volatileStartedAt: Date = Date()
        var volatileStartClock: Double = 0
        var volatileChangedAt: Date = Date()
        var cutting: Bool = false
        var cutAsked: Bool = false
        var lastCutText: String = ""
        var lastCutThrough: Double = 0

        var autoMode: Bool = false
        var languageConfirmed: Bool = false
        var detectingLanguage: Bool = false
        var lastDetectionAt: Date = .distantPast

        init(source: String, locale: String, autoMode: Bool, captureVoice: Bool) {
            self.source = source
            self.locale = locale
            self.autoMode = autoMode
            self.router = AppleTrackRouter(source: source, captureVoice: captureVoice)
        }
    }

    private let captureVoice: Bool
    private var tracks: [String: TrackState] = [:]
    private var timeline = MeetingPreviewTimeline()
    private var tickTimer: Timer?
    private var ticks: Int = 0
    private var finishing = false
    private var stopped = false

    var onUpdate: (([MeetingSegment]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onResult: ((String, MeetingSegment, Bool) -> Void)?
    var onVolatile: ((String, String) -> Void)?
    var onFinalSegment: ((MeetingAppleFinalizedSegment) -> Void)?

    init(captureVoice: Bool) {
        self.captureVoice = captureVoice
    }

    func start(locale: String, sources: [String]) async throws {
        let autoMode = (locale == "auto")
        let initialLocale = await MeetingAppleSpeech.resolvedInitialLocale(locale)

        for source in Set(sources).sorted() {
            let track = TrackState(source: source, locale: initialLocale, autoMode: autoMode, captureVoice: captureVoice)
            tracks[source] = track
            try await connectTrack(track, replaySeconds: 0, failHard: true)
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finishing, !self.stopped else { return }
                self.maybeCutSentences()
                self.ticks += 1
                if self.ticks % 8 == 0 {
                    self.maybeDetectLanguages()
                }
            }
        }
        tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func connectTrack(_ track: TrackState, replaySeconds: Double, failHard: Bool) async throws {
        track.generation += 1
        let gen = track.generation
        track.router.detach()
        track.resultsTask?.cancel()
        track.resultsTask = nil
        if let old = track.analyzer {
            track.analyzer = nil
            await old.cancelAndFinishNow()
        }
        guard !finishing, !stopped else { return }

        let module = try await MeetingAppleSpeech.module(locale: track.locale)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            let err = MeetingFailure.message("Apple 语音模型（\(track.locale)）未就绪。请在会议设置中下载模型；录音仍可保存。")
            if failHard { throw err }
            onStatus?(err.localizedDescription)
            return
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            let err = MeetingFailure.message("Apple 语音模型没有兼容的音频格式。")
            if failHard { throw err }
            onStatus?(err.localizedDescription)
            return
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        guard !finishing, !stopped, gen == track.generation else {
            await analyzer.cancelAndFinishNow()
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        track.router.attach(format: format, continuation: continuation, replaySeconds: replaySeconds)
        track.analyzer = analyzer
        track.volatileText = ""
        track.cutAsked = false

        track.resultsTask = Task { [weak self, weak track] in
            do {
                for try await result in module.results {
                    guard !Task.isCancelled, let self, let track, !self.stopped, track.generation == gen else { return }
                    self.handleResult(result, track: track)
                }
            } catch {
                guard let self, let track, !self.finishing, !self.stopped, track.generation == gen else { return }
                self.handleTrackFailure(track, error: error)
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    private func handleResult(_ result: SpeechTranscriber.Result, track: TrackState) {
        track.failureStreak = 0
        let start = result.range.start.seconds
        let end = result.range.end.seconds
        let rawText = String(result.text.characters)
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return }

        if result.isFinal {
            let cleaned = MeetingHeardText.clean(rawText)
            let wasCut = track.cutAsked
            track.cutAsked = false
            track.volatileText = ""
            onVolatile?(track.source, "")

            timeline.replace(
                source: track.source,
                start: start,
                end: end,
                text: cleaned,
                final: true,
                speaker: track.source == "mic" ? "me" : "?"
            )

            guard MeetingHeardText.hasWords(cleaned) else {
                onUpdate?(timeline.segments)
                return
            }

            let seg = MeetingSegment(
                start: start,
                end: end,
                speaker: track.source == "mic" ? "me" : "?",
                text: cleaned
            )
            let samples = track.router.voiceSamples(from: start, to: end)
            onResult?(track.source, seg, true)
            onFinalSegment?(MeetingAppleFinalizedSegment(
                source: track.source,
                segment: seg,
                wasCut: wasCut,
                voiceSamples: samples
            ))
            onUpdate?(timeline.segments)
        } else {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if track.volatileText.isEmpty && !trimmed.isEmpty {
                track.volatileStartedAt = Date()
                track.volatileStartClock = track.router.clock().fed
            }
            if trimmed != track.volatileText {
                track.volatileChangedAt = Date()
            }
            track.volatileText = trimmed
            onVolatile?(track.source, trimmed)

            let seg = MeetingSegment(
                start: start,
                end: end,
                speaker: track.source == "mic" ? "me" : "?",
                text: trimmed
            )
            onResult?(track.source, seg, false)
            timeline.replace(
                source: track.source,
                start: start,
                end: end,
                text: trimmed,
                final: false,
                speaker: track.source == "mic" ? "me" : "?"
            )
            onUpdate?(timeline.segments)
        }
    }

    private func handleTrackFailure(_ track: TrackState, error: Error) {
        guard !finishing, !stopped else { return }
        track.failureStreak += 1
        let delay = min(20.0, 2.0 * pow(2.0, Double(track.failureStreak - 1)))
        onStatus?("Apple 实时识别短暂中断，\(Int(delay)) 秒后自动重连（录音持续保存）。")
        let expectedGen = track.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak track] in
            guard let self, let track, !self.finishing, !self.stopped, track.generation == expectedGen else { return }
            Task { @MainActor in
                try? await self.connectTrack(track, replaySeconds: 4, failHard: false)
            }
        }
    }

    /// Proactively finalizes long volatile utterances at micro-pauses so SpeechTranscriber's
    /// fast window never stalls for 15–25s or silently drops early clauses.
    private func maybeCutSentences() {
        for track in tracks.values {
            guard !track.cutting,
                  let analyzer = track.analyzer,
                  !track.volatileText.isEmpty,
                  track.volatileText != track.lastCutText else {
                continue
            }
            let isCJK = track.locale.hasPrefix("zh") || track.volatileText.unicodeScalars.contains { $0.properties.isIdeographic }
            let isLong = isCJK
                ? track.volatileText.count >= 24
                : track.volatileText.split(separator: " ").count >= 10
            guard isLong else { continue }

            let held = Date().timeIntervalSince(track.volatileStartedAt)
            let neededPause = held >= 8 ? 0.15 : 0.30
            let c = track.router.clock()
            let midPause = c.pause.end - c.pause.length / 2
            let through: Double

            if c.silence >= neededPause {
                through = c.fed
            } else if c.pause.length >= neededPause,
                      midPause > track.volatileStartClock + 1.5,
                      midPause > track.lastCutThrough,
                      c.pause.end <= c.fed {
                through = midPause
            } else if Date().timeIntervalSince(track.volatileChangedAt) >= (held >= 8 ? 0.6 : 1.2) {
                through = c.fed
            } else {
                continue
            }

            track.cutting = true
            track.cutAsked = true
            track.lastCutText = track.volatileText
            track.lastCutThrough = through
            Task { @MainActor [weak track] in
                do {
                    try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 1000))
                } catch {
                    track?.cutAsked = false
                }
                track?.cutting = false
            }
        }
    }

    /// Optional auto-language switch between zh-CN and en-US when `locale == "auto"`.
    private func maybeDetectLanguages() {
        for track in tracks.values where track.autoMode && !track.languageConfirmed && !track.detectingLanguage {
            guard Date().timeIntervalSince(track.lastDetectionAt) >= 4 else { continue }
            let clip = track.router.snapshotVoicedClip(seconds: 6)
            guard clip.voicedSeconds >= 2.5, !clip.buffers.isEmpty else { continue }

            track.detectingLanguage = true
            track.lastDetectionAt = Date()
            let currentLocale = track.locale
            let buffers = clip.buffers

            Task { @MainActor [weak self, weak track] in
                let scores = await Self.scoreLocales(buffers: buffers, locales: ["zh-CN", "en-US"])
                guard let self, let track, !self.stopped else { return }
                track.detectingLanguage = false
                guard let best = scores.first else { return }
                let runnerUp = scores.dropFirst().first?.score ?? 0
                if best.confidence >= 0.6 && (best.score - runnerUp >= 0.10) {
                    track.languageConfirmed = true
                    if best.locale != currentLocale {
                        track.locale = best.locale
                        try? await self.connectTrack(track, replaySeconds: 8, failHard: false)
                    }
                }
            }
        }
    }

    private nonisolated static func scoreLocales(
        buffers: [AVAudioPCMBuffer],
        locales: [String]
    ) async -> [(locale: String, confidence: Double, score: Double)] {
        await withTaskGroup(of: (String, Double, Double)?.self) { group in
            for locale in locales {
                group.addTask {
                    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
                        return nil
                    }
                    let transcriber = SpeechTranscriber(
                        locale: supported,
                        transcriptionOptions: [],
                        reportingOptions: [],
                        attributeOptions: [.transcriptionConfidence]
                    )
                    guard await AssetInventory.status(forModules: [transcriber]) == .installed,
                          let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        return nil
                    }
                    let converter = ApplePCMConverter()
                    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
                    for b in buffers {
                        if let converted = converter.convert(b, to: format) {
                            continuation.yield(AnalyzerInput(buffer: converted))
                        }
                    }
                    continuation.finish()

                    let collector = Task { () -> (String, Double, Int) in
                        var text = ""
                        var weighted = 0.0
                        var chars = 0
                        for try await res in transcriber.results {
                            text += String(res.text.characters)
                            for run in res.text.runs {
                                guard let conf = run.transcriptionConfidence else { continue }
                                let len = res.text[run.range].characters.filter { !$0.isWhitespace && !$0.isPunctuation }.count
                                weighted += conf * Double(len)
                                chars += len
                            }
                        }
                        return (text, chars > 0 ? weighted / Double(chars) : 0, chars)
                    }

                    do {
                        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
                        try await analyzer.finalizeAndFinishThroughEndOfInput()
                        let (text, conf, chars) = try await collector.value
                        guard chars > 0 else { return (locale, 0, 0) }
                        let lengthFactor = min(1.0, Double(chars) / 6.0)
                        var scriptFactor = 1.0
                        if locale.hasPrefix("zh") {
                            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
                            let latin = letters.filter(\.isASCII).count
                            if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 {
                                scriptFactor = 0.72
                            }
                        }
                        return (locale, conf, conf * lengthFactor * scriptFactor)
                    } catch {
                        collector.cancel()
                        return nil
                    }
                }
            }
            var results: [(locale: String, confidence: Double, score: Double)] = []
            for await item in group {
                if let item { results.append((item.0, item.1, item.2)) }
            }
            return results.sorted { $0.score > $1.score }
        }
    }

    func push(source: String, buffer: AVAudioPCMBuffer, startTime: Double? = nil) {
        guard !finishing, !stopped, let track = tracks[source] else { return }
        track.router.push(buffer: buffer, explicitStartTime: startTime)
    }

    func submit(_ chunk: MeetingAudioChunk, file: URL) {
        guard !finishing, !stopped, let track = tracks[chunk.source] else { return }
        do {
            let audio = try AVAudioFile(forReading: file)
            guard audio.length > 0,
                  Double(audio.length) / audio.processingFormat.sampleRate <= 15,
                  chunk.start.isFinite, chunk.start >= 0 else {
                throw MeetingFailure.message("实时音频片段无效。")
            }
            let input = try MeetingAudioFileReader.read(audio, frames: AVAudioFrameCount(audio.length))
            guard input.frameLength == audio.length else {
                throw MeetingFailure.message("实时音频片段不完整。")
            }
            track.router.push(buffer: input, explicitStartTime: chunk.start)
        } catch {
            onStatus?("Apple 实时音频读取失败：\(error.localizedDescription)。录音仍保留。")
        }
    }

    func finish() async {
        guard !finishing, !stopped else { return }
        finishing = true
        tickTimer?.invalidate()
        tickTimer = nil
        let activeTracks = Array(tracks.values)
        for track in activeTracks {
            track.router.detach()
        }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            for track in activeTracks {
                track.resultsTask?.cancel()
                if let analyzer = track.analyzer {
                    await analyzer.cancelAndFinishNow()
                }
            }
        }
        defer {
            timeout.cancel()
            stopped = true
            tracks.removeAll()
        }
        for track in activeTracks {
            if let analyzer = track.analyzer {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    await analyzer.cancelAndFinishNow()
                }
            }
            await track.resultsTask?.value
            // Rescue any residual volatile hypothesis if analyzer terminated without promoting to isFinal.
            let residual = MeetingHeardText.clean(track.volatileText)
            if MeetingHeardText.hasWords(residual) {
                let start = track.volatileStartClock
                let end = max(start + 0.2, track.router.clock().fed)
                track.volatileText = ""
                onVolatile?(track.source, "")
                timeline.replace(
                    source: track.source,
                    start: start,
                    end: end,
                    text: residual,
                    final: true,
                    speaker: track.source == "mic" ? "me" : "?"
                )
                let seg = MeetingSegment(
                    start: start,
                    end: end,
                    speaker: track.source == "mic" ? "me" : "?",
                    text: residual
                )
                let samples = track.router.voiceSamples(from: start, to: end)
                onResult?(track.source, seg, true)
                onFinalSegment?(MeetingAppleFinalizedSegment(
                    source: track.source,
                    segment: seg,
                    wasCut: false,
                    voiceSamples: samples
                ))
                onUpdate?(timeline.segments)
            }
        }
    }
}
