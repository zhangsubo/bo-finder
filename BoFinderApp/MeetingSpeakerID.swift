import Accelerate
import AVFoundation
import CoreML
import Foundation
import SwiftUI

// MARK: - Kaldi Log-Mel Filterbank (Pure Swift + Accelerate/vDSP)

/// Computes 80-dim Kaldi log-mel filterbank features matching WeSpeaker ResNet34-LM training:
/// 16 kHz mono float samples (-1...1), 25 ms Povey window (400), 10 ms frame shift (160),
/// DC offset removal, 0.97 pre-emphasis, 512-point power spectrum, 20 Hz–8 kHz Mel banks.
enum MeetingFbank {
    static let bins = 80
    static let frameLength = 400
    static let shift = 160
    private static let fftSize = 512

    private static let window: [Float] = (0..<frameLength).map {
        pow(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frameLength - 1)), 0.85)
    }

    private static let melBanks: [Float] = {
        func mel(_ freq: Double) -> Double { 1127 * log(1 + freq / 700) }
        let cols = fftSize / 2 + 1
        let lo = mel(20), hi = mel(8000), delta = (hi - lo) / Double(bins + 1)
        var weights = [Float](repeating: 0, count: bins * cols)
        for m in 0..<bins {
            let left = lo + Double(m) * delta
            let center = left + delta
            let right = center + delta
            for k in 0..<(fftSize / 2) {
                let x = mel(Double(k) * 16000 / Double(fftSize))
                let v = min((x - left) / (center - left), (right - x) / (right - center))
                if v > 0 { weights[m * cols + k] = Float(v) }
            }
        }
        return weights
    }()

    private static let fftSetup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

    static func compute(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        let frames = 1 + (samples.count - frameLength) / shift
        let cols = fftSize / 2 + 1
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: fftSize / 2)
        var im = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: cols)
        var mels = [Float](repeating: 0, count: bins)

        for f in 0..<frames {
            let start = f * shift
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768 }
            for i in frameLength..<fftSize { frame[i] = 0 }

            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            for i in 0..<frameLength { frame[i] -= mean }

            for i in stride(from: frameLength - 1, to: 0, by: -1) {
                frame[i] -= 0.97 * frame[i - 1]
            }
            frame[0] -= 0.97 * frame[0]

            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            power[0] = re[0] * re[0] / 4
            power[cols - 1] = im[0] * im[0] / 4
            for k in 1..<(fftSize / 2) {
                power[k] = (re[k] * re[k] + im[k] * im[k]) / 4
            }
            vDSP_mmul(melBanks, 1, power, 1, &mels, 1, vDSP_Length(bins), 1, vDSP_Length(cols))
            for b in 0..<bins {
                out[f * bins + b] = log(max(mels[b], .ulpOfOne))
            }
        }
        return out
    }
}

// MARK: - Bundled Core ML Voiceprint Extractor

/// WeSpeaker ResNet34-LM (VoxCeleb, CC BY 4.0) bundled as `.mlpackage`.
/// Compiled on first use via `MLModel.compileModel(at:)` and cached under Application Support.
final class MeetingVoiceprints: @unchecked Sendable {
    static let minSeconds = 0.5
    static let maxSeconds = 20.0

    private let model: MLModel

    private init(model: MLModel) {
        self.model = model
    }

    static func locatePackage() -> URL? {
        if let bundled = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlpackage") {
            return bundled
        }
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("BoFinderApp/Resources/SpeakerEmbedding.mlpackage"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("DeskSide.app/Contents/Resources/SpeakerEmbedding.mlpackage"),
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("BoFinderApp/Resources/SpeakerEmbedding.mlpackage"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func load(packageURL: URL? = nil) throws -> MeetingVoiceprints {
        guard let pkg = packageURL ?? locatePackage() else {
            throw MeetingFailure.message("未找到内置声纹模型 SpeakerEmbedding.mlpackage。")
        }
        let weightPath = pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin").path
        let size = (try? FileManager.default.attributesOfItem(atPath: weightPath)[.size] as? Int) ?? 0
        let cacheDir = MeetingFiles.root.appendingPathComponent("ModelsCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheURL = cacheDir.appendingPathComponent("SpeakerEmbedding-\(size).mlmodelc")
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            let compiled = try MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: cacheURL)
            try FileManager.default.moveItem(at: compiled, to: cacheURL)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        if let preferred = try? MLModel(contentsOf: cacheURL, configuration: configuration) {
            return MeetingVoiceprints(model: preferred)
        }
        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly
        return MeetingVoiceprints(model: try MLModel(contentsOf: cacheURL, configuration: cpuConfig))
    }

    /// Produces a unit-length 256-d speaker embedding for 16 kHz mono float samples.
    func embed(_ samples: [Float]) -> [Float]? {
        guard Double(samples.count) >= Self.minSeconds * 16000 else { return nil }
        let maxSamples = Int(Self.maxSeconds * 16000)
        let clip = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples
        var feats = MeetingFbank.compute(clip)
        let frames = feats.count / MeetingFbank.bins
        guard frames >= 50 else { return nil }

        // Per-bin mean normalization across the utterance, matching training.
        for b in 0..<MeetingFbank.bins {
            var sum: Float = 0
            for f in 0..<frames { sum += feats[f * MeetingFbank.bins + b] }
            let mean = sum / Float(frames)
            for f in 0..<frames { feats[f * MeetingFbank.bins + b] -= mean }
        }

        guard let input = try? MLMultiArray(
            shape: [1, NSNumber(value: frames), NSNumber(value: MeetingFbank.bins)],
            dataType: .float32
        ) else {
            return nil
        }
        feats.withUnsafeBufferPointer { src in
            input.withUnsafeMutableBytes { dst, _ in
                dst.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }

        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": input])),
              let embs = out.featureValue(for: "embs")?.multiArrayValue else {
            return nil
        }
        var vector = (0..<embs.count).map { Float(truncating: embs[$0]) }
        var normSq: Float = 0
        vDSP_svesq(vector, 1, &normSq, vDSP_Length(vector.count))
        guard normSq > 0 else { return nil }
        vDSP_vsdiv(vector, 1, [normSq.squareRoot()], &vector, 1, vDSP_Length(vector.count))
        return vector
    }
}

// MARK: - Online Cosine Voice Clusterer

struct MeetingVoiceClusterer {
    static let newSeconds = 2.0
    static let joinThreshold: Float = 0.5
    static let startNewThreshold: Float = 0.5

    private(set) var sums: [[Float]] = []
    private var redirects: [Int: Int] = [:]

    private func canonical(_ index: Int) -> Int {
        var current = index
        var guardSteps = 0
        while let target = redirects[current], target != current, guardSteps < 64 {
            current = target
            guardSteps += 1
        }
        return current
    }

    mutating func merge(_ from: Int, into: Int) {
        guard sums.indices.contains(from), sums.indices.contains(into) else { return }
        let src = canonical(from)
        let dst = canonical(into)
        guard src != dst else { return }
        redirects[src] = dst
    }

    mutating func label(_ vector: [Float], seconds: Double) -> Int? {
        var best = -1
        var bestSim: Float = -1
        for (i, sum) in sums.enumerated() {
            var dot: Float = 0
            var sq: Float = 0
            vDSP_dotpr(vector, 1, sum, 1, &dot, vDSP_Length(vector.count))
            vDSP_svesq(sum, 1, &sq, vDSP_Length(sum.count))
            guard sq > .ulpOfOne else { continue }
            let sim = dot / sq.squareRoot()
            if sim > bestSim {
                bestSim = sim
                best = i
            }
        }
        if best >= 0, bestSim >= Self.joinThreshold {
            vDSP_vadd(sums[best], 1, vector, 1, &sums[best], 1, vDSP_Length(sums[best].count))
            return canonical(best)
        }
        if seconds >= Self.newSeconds, sums.isEmpty || bestSim < Self.startNewThreshold {
            sums.append(vector)
            return sums.count - 1
        }
        return nil
    }
}

// MARK: - Async Background Speaker Tagger

@MainActor
final class MeetingSpeakerTagger {
    private let queue = DispatchQueue(label: "deskside.meeting.voiceprint", qos: .utility)
    private nonisolated(unsafe) var model: MeetingVoiceprints? = nil
    private nonisolated(unsafe) var loadFailed = false
    private nonisolated(unsafe) var clusterer = MeetingVoiceClusterer()

    func reset() {
        queue.async { [self] in
            clusterer = MeetingVoiceClusterer()
        }
    }

    func merge(_ from: Int, into: Int) {
        queue.async { [self] in
            clusterer.merge(from, into: into)
        }
    }

    func identify(samples: [Float], completion: @escaping @MainActor (Int?) -> Void) {
        let seconds = Double(samples.count) / 16000
        queue.async { [self] in
            if model == nil, !loadFailed {
                do {
                    model = try MeetingVoiceprints.load()
                } catch {
                    loadFailed = true
                }
            }
            let voice = model
                .flatMap { $0.embed(samples) }
                .flatMap { clusterer.label($0, seconds: seconds) }
            DispatchQueue.main.async {
                completion(voice)
            }
        }
    }
}

// MARK: - Conversational Speaker Name Inference (±2 Line Evidence Check)

enum MeetingSpeakerGuessLogic {
    static let evidenceReach = 2

    /// Builds transcript prompt for naming `v0`, `v1`, ... speakers; returns nil if no voice clusters exist.
    static func buildPrompt(_ record: MeetingRecord) -> String? {
        let numbers = record.voiceDisplayNumbers
        guard !numbers.isEmpty else { return nil }
        let recent = Array(record.segments.suffix(400))
        var out = "以下是会议转录片段。标签说明：我 = 本人；说话人N = 通过声纹区分出的不同参会人；对方/待识别 = 尚未归入声纹的短句。\n"
        for (i, seg) in recent.enumerated() {
            let key = seg.voiceID.map { "v\($0)" } ?? seg.speaker
            let who: String
            if key == "me" {
                who = "我"
            } else if let n = numbers[key] {
                who = "说话人\(n)"
            } else {
                who = "对方"
            }
            out += "[L\(i + 1) \(MeetingRecord.shortClock(seg.start)) \(who)] \(seg.text)\n"
        }
        return out
    }

    static let instruction = """
    请根据对话内容判断「说话人1」「说话人2」等标签对应的真实姓名或称呼（如“王总”“李明”“George”）。
    严格规则：
    1. 只有当某人自我介绍（发生在其本人的说话人N行上），或紧邻其发言前后被他人直接点名称呼（例如“谢谢张工”紧跟在说话人1发言之后，说明说话人1是张工）时才认定。
    2. 严禁把与说话人N相隔较远、或仅仅在讨论中提及的第三方人名赋给说话人N。
    3. 语音识别可能写错人名同音字，若是常见称呼或知名人物请按上下文修正写法。不确定的人一律省略。
    4. 仅返回合法 JSON：{"speakers": [{"speaker": 1, "name": "张工", "evidence": "L12"}]}，其中 speaker 为数字编号，evidence 为出现该称呼的行号；若均无法确认则返回 {"speakers": []}。
    """

    static func read(
        _ reply: String,
        record: MeetingRecord
    ) -> (found: [String: MeetingSpeakerGuess], refuted: [String: String]) {
        guard let jsonText = MeetingNotesParser.extractJSONObject(reply),
              let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["speakers"] as? [[String: Any]] else {
            return ([:], [:])
        }

        let numbers = record.voiceDisplayNumbers
        // Map 1-based display number -> "vX" speaker key
        let keyByNumber = Dictionary(uniqueKeysWithValues: numbers.map { ($0.value, $0.key) })
        let lines = Array(record.segments.suffix(400))
        func countForKey(_ key: String) -> Int {
            record.segments.filter { ($0.voiceID.map { "v\($0)" } ?? $0.speaker) == key }.count
        }

        var found: [String: MeetingSpeakerGuess] = [:]
        var refuted: [String: String] = [:]

        for item in list {
            let speakerNum: Int?
            if let n = item["speaker"] as? Int {
                speakerNum = n
            } else if let s = item["speaker"] as? String {
                let digits = s.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
                speakerNum = Int(digits)
            } else {
                speakerNum = nil
            }
            guard let num = speakerNum,
                  let key = keyByNumber[num],
                  let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 40 else {
                continue
            }

            let rawEvidence = (item["evidence"] as? String) ?? "\(item["evidence"] ?? "")"
            let evDigits = rawEvidence.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
            guard let lineIdx = Int(evDigits).map({ $0 - 1 }),
                  lines.indices.contains(lineIdx) else {
                refuted[key] = name
                continue
            }

            let lo = max(0, lineIdx - evidenceReach)
            let hi = min(lines.count - 1, lineIdx + evidenceReach)
            let spokeNearby = lines[lo...hi].contains { seg in
                let segKey = seg.voiceID.map { "v\($0)" } ?? seg.speaker
                return segKey == key
            }
            guard spokeNearby else {
                refuted[key] = name
                continue
            }

            if let existingKey = found.first(where: { $0.value.name == name })?.key {
                if countForKey(existingKey) >= countForKey(key) { continue }
                found[existingKey] = nil
            }

            let evSeg = lines[lineIdx]
            let snippet = evSeg.text.count > 48 ? String(evSeg.text.prefix(48)) + "…" : evSeg.text
            let evidence = "\(MeetingRecord.shortClock(evSeg.start)) “\(snippet)”"
            found[key] = MeetingSpeakerGuess(name: name, evidence: evidence)
        }
        return (found, refuted)
    }

    static func holds(_ guess: MeetingSpeakerGuess, speakerKey: String, in record: MeetingRecord) -> Bool {
        guard let open = guess.evidence.firstIndex(of: "“") else { return true }
        let clock = guess.evidence[..<open].trimmingCharacters(in: .whitespaces)
        let quote = String(guess.evidence[guess.evidence.index(after: open)...].dropLast().prefix(while: { $0 != "…" }))
        guard let idx = record.segments.firstIndex(where: {
            MeetingRecord.shortClock($0.start) == clock && $0.text.hasPrefix(quote)
        }) else {
            return true
        }
        let lo = max(0, idx - evidenceReach)
        let hi = min(record.segments.count - 1, idx + evidenceReach)
        return record.segments[lo...hi].contains { seg in
            (seg.voiceID.map { "v\($0)" } ?? seg.speaker) == speakerKey
        }
    }
}

#if !MEETING_UNIT_TESTS
@MainActor
final class MeetingSpeakerNamer: ObservableObject {
    static let shared = MeetingSpeakerNamer()

    @Published private(set) var busy: Set<UUID> = []
    private var lastAskedCount: [UUID: Int] = [:]

    func maybeGuess(for meetingID: UUID, force: Bool = false) {
        let manager = MeetingManager.shared
        let config = manager.config
        guard config.enableVoiceprint,
              !config.summaryBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !busy.contains(meetingID),
              let record = manager.records.first(where: { $0.id == meetingID }) else {
            return
        }

        let numbers = record.voiceDisplayNumbers
        guard !numbers.isEmpty else { return }
        // Skip if user already manually named or dismissed every voice speaker.
        if numbers.keys.allSatisfy({ record.speakerNames[$0] != nil }) { return }
        let previous = lastAskedCount[meetingID] ?? -1000
        guard force || record.segments.count >= previous + 20,
              let content = MeetingSpeakerGuessLogic.buildPrompt(record) else {
            return
        }

        busy.insert(meetingID)
        lastAskedCount[meetingID] = record.segments.count
        let key = MeetingSecrets.read("summary")
        let base = config.summaryBase
        let model = config.summaryModel

        Task {
            defer { busy.remove(meetingID) }
            do {
                let reply = try await MeetingCloud.completion(
                    base: base,
                    key: key,
                    model: model,
                    messages: [
                        ["role": "system", "content": MeetingSpeakerGuessLogic.instruction],
                        ["role": "user", "content": content]
                    ],
                    temperature: 0.1,
                    maxTokens: 512,
                    timeout: 45
                )
                guard let latest = manager.records.first(where: { $0.id == meetingID }) else { return }
                var (found, refuted) = MeetingSpeakerGuessLogic.read(reply, record: latest)
                for (k, oldGuess) in latest.speakerGuesses ?? [:] {
                    if found[k] == nil, !MeetingSpeakerGuessLogic.holds(oldGuess, speakerKey: k, in: latest) {
                        refuted[k] = oldGuess.name
                    }
                }
                manager.applySpeakerGuesses(meetingID, found: found, refuted: refuted)
            } catch {
                // Silent retry on later lines; speaker naming is best-effort enrichment.
            }
        }
    }
}
#endif

// MARK: - Speaker Palette Helper

enum MeetingSpeakerPalette {
    private static let remoteColors: [Color] = [
        Color(red: 0.059, green: 0.482, blue: 0.424),
        Color(red: 0.478, green: 0.298, blue: 0.761),
        Color(red: 0.690, green: 0.227, blue: 0.478),
        Color(red: 0.541, green: 0.353, blue: 0.000),
        Color(red: 0.165, green: 0.435, blue: 0.690),
    ]

    static func color(for speakerKey: String, in record: MeetingRecord) -> Color {
        if speakerKey == "me" {
            return Color.accentColor
        }
        if let number = record.voiceDisplayNumbers[speakerKey], number >= 1 {
            return remoteColors[(number - 1) % remoteColors.count]
        }
        if speakerKey == "them" || speakerKey == "?" {
            return Color.secondary
        }
        let hash = abs(speakerKey.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return remoteColors[hash % remoteColors.count]
    }
}
