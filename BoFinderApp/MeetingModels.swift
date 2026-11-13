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

/// Unrecorded interval between two merged meeting recordings on the shared timeline.
struct MeetingGap: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var startDate: Date
    var endDate: Date

    var missingSeconds: Double {
        max(0, end - start)
    }

    var formattedMissingDuration: String {
        let total = max(1, Int(missingSeconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            if minutes == 0 && seconds == 0 { return "\(hours)小时" }
            if seconds == 0 { return "\(hours)小时\(minutes)分钟" }
            return "\(hours)小时\(minutes)分\(seconds)秒"
        }
        if minutes > 0 {
            if seconds == 0 { return "\(minutes)分钟" }
            return "\(minutes)分\(seconds)秒"
        }
        return "\(seconds)秒"
    }

    func formattedWallClockRange(timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameDay = calendar.isDate(startDate, inSameDayAs: endDate)
        let startHM = calendar.dateComponents([.hour, .minute], from: startDate)
        let endHM = calendar.dateComponents([.hour, .minute], from: endDate)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone

        if sameDay {
            let needsSeconds = (startHM.hour == endHM.hour && startHM.minute == endHM.minute)
                || Int(missingSeconds.rounded()) < 60
            formatter.dateFormat = needsSeconds ? "HH:mm:ss" : "HH:mm"
            return "\(formatter.string(from: startDate))–\(formatter.string(from: endDate))"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
            return "\(formatter.string(from: startDate))–\(formatter.string(from: endDate))"
        }
    }

    func markerText(timeZone: TimeZone = .current) -> String {
        "(\(formattedWallClockRange(timeZone: timeZone)) 会议中断未录制，缺失 \(formattedMissingDuration))"
    }
}

enum MeetingTimelineEntry: Identifiable, Equatable {
    case segment(MeetingSegment)
    case gap(MeetingGap)

    var id: String {
        switch self {
        case .segment(let seg): return "seg-\(seg.id.uuidString)"
        case .gap(let gap): return "gap-\(gap.id.uuidString)"
        }
    }

    var startTime: Double {
        switch self {
        case .segment(let seg): return seg.start
        case .gap(let gap): return gap.start
        }
    }

    fileprivate var sortOrder: Int {
        switch self {
        case .gap: return 0
        case .segment: return 1
        }
    }
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
    var gaps: [MeetingGap]? = nil
    var mergedSourceCount: Int? = nil

    /// Marks final summary generation as failed while keeping any mid-meeting live notes intact.
    mutating func applyFinalSummaryFailure(_ message: String) {
        summaryState = "failed"
        if notes?.isEmpty == false, !message.contains("已保留会中速记") {
            issue = "完整版纪要未完成（已保留会中速记）：\(message)"
        } else {
            issue = message
        }
    }

    /// Recovers records left in `"working"` state across an app restart or interrupted final pass.
    mutating func recoverInterruptedSummaryOnLaunch() {
        guard summaryState == "working" else { return }
        summaryState = "failed"
        if issue.isEmpty {
            issue = (notes?.isEmpty == false)
                ? "上次完整版纪要未完成（已保留会中速记），可点击下方「生成 / 更新纪要」重试。"
                : "上次纪要整理中断，可点击下方「生成 / 更新纪要」重试。"
        }
    }

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

    func timelineEntries(usingPreviewFallback: Bool = false) -> [MeetingTimelineEntry] {
        let effectiveSegments = (!segments.isEmpty || !usingPreviewFallback) ? segments : preview
        var items: [MeetingTimelineEntry] = effectiveSegments.map { .segment($0) }
        if let gaps, !gaps.isEmpty {
            items += gaps.map { .gap($0) }
        }
        return items.sorted { lhs, rhs in
            if abs(lhs.startTime - rhs.startTime) > 0.0001 {
                return lhs.startTime < rhs.startTime
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }

    func formattedTranscript(timeZone: TimeZone = .current) -> String {
        timelineEntries().map { entry in
            switch entry {
            case .segment(let seg):
                return "[\(seg.id.uuidString)] [\(Self.timestamp(seg.start))–\(Self.timestamp(seg.end))] \(speakerName(seg.speaker))：\(seg.text)"
            case .gap(let gap):
                return "[\(Self.timestamp(gap.start))–\(Self.timestamp(gap.end))] \(gap.markerText(timeZone: timeZone))"
            }
        }.joined(separator: "\n")
    }

    var transcript: String {
        formattedTranscript()
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

/// Chronological multi-record splicer that aligns segments, audio chunks, speaker clusters,
/// and notes on wall-clock timestamps while marking unrecorded interruption gaps.
enum MeetingMerger {
    static let minimumGapSeconds: Double = 1.0
    static let longGapWarningSeconds: Double = 4 * 3600

    struct ChunkCopyInstruction: Equatable {
        var sourceRecordID: UUID
        var sourceFile: String
        var destinationFile: String
        var shiftedChunk: MeetingAudioChunk
    }

    struct PlanPart: Identifiable, Equatable {
        var id: UUID
        var title: String
        var source: String
        var startDate: Date
        var endDate: Date
        var offset: Double
        var localSpan: Double
        var segmentCount: Int
    }

    struct MergePlan: Equatable {
        var parts: [PlanPart]
        var boundaryGapsByPartIndex: [Int: MeetingGap]
        var gaps: [MeetingGap]
        var suggestedTitle: String
        var suggestedTitleIsUserRenamed: Bool
        var totalDuration: Double
        var totalSegments: Int

        var hasLongGapWarning: Bool {
            gaps.contains { $0.missingSeconds > MeetingMerger.longGapWarningSeconds }
        }
    }

    static func sortedRecords(_ records: [MeetingRecord]) -> [MeetingRecord] {
        records.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    static func localSpan(of record: MeetingRecord) -> Double {
        let effectiveSegs = record.segments.isEmpty ? record.preview : record.segments
        let maxChunkEnd = record.chunks.map { $0.start + $0.duration }.max() ?? 0
        let maxSegEnd = effectiveSegs.map(\.end).max() ?? 0
        let maxGapEnd = (record.gaps ?? []).map(\.end).max() ?? 0
        let raw = max(record.duration, maxChunkEnd, maxSegEnd, maxGapEnd)
        return raw.isFinite && raw > 0 ? raw : 0
    }

    static func plan(records: [MeetingRecord]) -> MergePlan {
        let sorted = sortedRecords(records)
        guard let first = sorted.first else {
            return MergePlan(
                parts: [],
                boundaryGapsByPartIndex: [:],
                gaps: [],
                suggestedTitle: "",
                suggestedTitleIsUserRenamed: false,
                totalDuration: 0,
                totalSegments: 0
            )
        }

        let baseDate = first.date
        var cursorEnd: Double = 0
        var parts: [PlanPart] = []
        var boundaryGaps: [Int: MeetingGap] = [:]
        var allGaps: [MeetingGap] = []
        var totalSegs = 0

        for (idx, rec) in sorted.enumerated() {
            let span = localSpan(of: rec)
            let rawOffset = idx == 0 ? 0 : rec.date.timeIntervalSince(baseDate)
            let offset = idx == 0 ? 0 : max(cursorEnd, rawOffset)

            if idx > 0 {
                let missing = rawOffset - cursorEnd
                if missing >= minimumGapSeconds {
                    let gap = MeetingGap(
                        start: cursorEnd,
                        end: offset,
                        startDate: baseDate.addingTimeInterval(cursorEnd),
                        endDate: rec.date
                    )
                    boundaryGaps[idx] = gap
                    allGaps.append(gap)
                }
            }

            if let existingGaps = rec.gaps {
                for g in existingGaps {
                    allGaps.append(MeetingGap(
                        id: g.id,
                        start: g.start + offset,
                        end: g.end + offset,
                        startDate: g.startDate,
                        endDate: g.endDate
                    ))
                }
            }

            let segCount = (rec.segments.isEmpty ? rec.preview : rec.segments).count
            totalSegs += segCount
            parts.append(PlanPart(
                id: rec.id,
                title: rec.title,
                source: rec.source,
                startDate: rec.date,
                endDate: rec.date.addingTimeInterval(span),
                offset: offset,
                localSpan: span,
                segmentCount: segCount
            ))
            cursorEnd = max(cursorEnd, offset + span)
        }

        allGaps.sort { $0.start < $1.start }

        let suggestedTitle: String
        let suggestedUserRenamed: Bool
        if let renamed = sorted.first(where: { $0.userRenamedTitle == true }) {
            suggestedTitle = renamed.title
            suggestedUserRenamed = true
        } else if let autoTitled = sorted.first(where: { !($0.notes?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            suggestedTitle = autoTitled.title
            suggestedUserRenamed = false
        } else {
            suggestedTitle = first.title
            suggestedUserRenamed = false
        }

        return MergePlan(
            parts: parts,
            boundaryGapsByPartIndex: boundaryGaps,
            gaps: allGaps,
            suggestedTitle: suggestedTitle,
            suggestedTitleIsUserRenamed: suggestedUserRenamed,
            totalDuration: cursorEnd,
            totalSegments: totalSegs
        )
    }

    static func merge(
        records: [MeetingRecord],
        customTitle: String? = nil,
        mergedID: UUID = UUID(),
        timeZone: TimeZone = .current
    ) throws -> (record: MeetingRecord, chunkCopies: [ChunkCopyInstruction]) {
        guard records.count >= 2 else {
            throw MeetingFailure.message("请至少选择两条会议记录进行合并。")
        }

        let sorted = sortedRecords(records)
        let mergePlan = plan(records: sorted)

        // Combine unique sources in chronological order
        var seenSources = Set<String>()
        var orderedSources: [String] = []
        for rec in sorted {
            let s = rec.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, seenSources.insert(s).inserted {
                orderedSources.append(s)
            }
        }
        let combinedSource = orderedSources.isEmpty ? "合并会议" : orderedSources.joined(separator: " + ")

        let trimmedCustom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = trimmedCustom.isEmpty ? mergePlan.suggestedTitle : trimmedCustom
        let resolvedUserRenamed: Bool? = (!trimmedCustom.isEmpty && trimmedCustom != mergePlan.suggestedTitle)
            ? true
            : (mergePlan.suggestedTitleIsUserRenamed ? true : nil)

        var chunkCopies: [ChunkCopyInstruction] = []
        var mergedChunks: [MeetingAudioChunk] = []
        var mergedSegments: [MeetingSegment] = []
        var usedSegmentIDs = Set<UUID>()

        var mergedSpeakerNames: [String: String] = [:]
        var mergedSpeakerGuesses: [String: MeetingSpeakerGuess] = [:]
        // Maps explicit non-empty human name -> (mergedSpeakerKey, mergedVoiceID) so identical named speakers unify across parts
        var explicitKeyByName: [String: (key: String, voiceID: Int?)] = [:]
        var nextVoiceID = 0
        var usedCustomKeys = Set<String>()

        for (partIdx, rec) in sorted.enumerated() {
            let offset = mergePlan.parts[partIdx].offset

            // 1. Shift audio chunks onto the unified meeting timeline
            for chunk in rec.chunks {
                let shiftedStart = chunk.start + offset
                let destName = "\(chunk.source)-\(Int((shiftedStart * 1000).rounded()))-\(UUID().uuidString).wav"
                let shifted = MeetingAudioChunk(
                    file: destName,
                    start: shiftedStart,
                    duration: chunk.duration,
                    source: chunk.source
                )
                chunkCopies.append(ChunkCopyInstruction(
                    sourceRecordID: rec.id,
                    sourceFile: chunk.file,
                    destinationFile: destName,
                    shiftedChunk: shifted
                ))
                mergedChunks.append(shifted)
            }

            // 2. Remap session-local speaker clusters to avoid conflating independent v0/v1 voice IDs across sessions
            var localSpeakerMap: [String: (key: String, voiceID: Int?)] = [:]
            func mapSpeaker(rawSpeaker: String, rawVoiceID: Int?) -> (key: String, voiceID: Int?) {
                let parsedVoice = rawVoiceID ?? (rawSpeaker.hasPrefix("v") ? Int(rawSpeaker.dropFirst()) : nil)
                let origKey = parsedVoice.map { "v\($0)" } ?? rawSpeaker

                if origKey == "me" || origKey == "them" || origKey == "?" {
                    if let explicit = rec.speakerNames[origKey], !explicit.isEmpty, mergedSpeakerNames[origKey] == nil {
                        mergedSpeakerNames[origKey] = explicit
                    }
                    return (origKey, nil)
                }

                if let cached = localSpeakerMap[origKey] {
                    return cached
                }

                let explicitName = rec.speakerNames[origKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let explicitName, !explicitName.isEmpty, let existing = explicitKeyByName[explicitName] {
                    localSpeakerMap[origKey] = existing
                    return existing
                }

                let mapped: (key: String, voiceID: Int?)
                if parsedVoice != nil {
                    let v = nextVoiceID
                    nextVoiceID += 1
                    mapped = ("v\(v)", v)
                } else {
                    var candidate = origKey
                    if usedCustomKeys.contains(candidate) {
                        var suffix = 2
                        while usedCustomKeys.contains("\(origKey)_\(suffix)") { suffix += 1 }
                        candidate = "\(origKey)_\(suffix)"
                    }
                    usedCustomKeys.insert(candidate)
                    mapped = (candidate, nil)
                }

                localSpeakerMap[origKey] = mapped
                if let explicitRaw = rec.speakerNames[origKey] {
                    mergedSpeakerNames[mapped.key] = explicitRaw
                    let trimmed = explicitRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        explicitKeyByName[trimmed] = mapped
                    }
                }
                if var guess = rec.speakerGuesses?[origKey] {
                    guess.evidence = shiftGuessEvidence(guess.evidence, by: offset)
                    mergedSpeakerGuesses[mapped.key] = guess
                }
                return mapped
            }

            let sourceSegments = rec.segments.isEmpty ? rec.preview : rec.segments
            for seg in sourceSegments {
                let mapped = mapSpeaker(rawSpeaker: seg.speaker, rawVoiceID: seg.voiceID)
                let segID = usedSegmentIDs.insert(seg.id).inserted ? seg.id : UUID()
                mergedSegments.append(MeetingSegment(
                    id: segID,
                    start: seg.start + offset,
                    end: seg.end + offset,
                    speaker: mapped.key,
                    text: seg.text,
                    voiceID: mapped.voiceID
                ))
            }
        }

        mergedChunks.sort { $0.start < $1.start }
        mergedSegments.sort { $0.start < $1.start }

        // 3. Immediately stitch existing structured notes & plain summaries with gap markers
        let stitchedNotes = stitchStructuredNotes(sorted: sorted, plan: mergePlan, timeZone: timeZone)
        let stitchedSummaries = stitchPlainSummaries(
            sorted: sorted,
            plan: mergePlan,
            hasStructuredNotes: stitchedNotes != nil,
            timeZone: timeZone
        )

        let totalMergedSources = sorted.reduce(0) { $0 + max(1, $1.mergedSourceCount ?? 1) }

        var merged = MeetingRecord(
            id: mergedID,
            title: resolvedTitle,
            date: sorted[0].date,
            source: combinedSource,
            duration: mergePlan.totalDuration,
            phase: "ended",
            transcriptState: mergedSegments.isEmpty ? "waiting" : "ready",
            summaryState: (stitchedNotes != nil || !stitchedSummaries.isEmpty) ? "ready" : "waiting",
            issue: (mergedSegments.isEmpty && !mergedChunks.isEmpty) ? "合并记录包含未转写音频，可点击下方按钮进行转录。" : "",
            chunks: mergedChunks,
            segments: mergedSegments,
            preview: [],
            speakerNames: mergedSpeakerNames,
            revision: 1,
            summaries: stitchedSummaries,
            notes: stitchedNotes,
            speakerGuesses: mergedSpeakerGuesses.isEmpty ? nil : mergedSpeakerGuesses,
            userRenamedTitle: resolvedUserRenamed,
            gaps: mergePlan.gaps.isEmpty ? nil : mergePlan.gaps,
            mergedSourceCount: totalMergedSources
        )
        if merged.duration < (mergedSegments.last?.end ?? 0) {
            merged.duration = mergedSegments.last?.end ?? merged.duration
        }
        return (merged, chunkCopies)
    }

    private static func shiftGuessEvidence(_ evidence: String, by offset: Double) -> String {
        guard offset > 0, let open = evidence.firstIndex(of: "“") else { return evidence }
        let clock = evidence[..<open].trimmingCharacters(in: .whitespaces)
        let tokens = clock.split(separator: ":").compactMap { Int($0) }
        let baseSeconds: Double?
        if tokens.count == 2 {
            baseSeconds = Double(tokens[0] * 60 + tokens[1])
        } else if tokens.count == 3 {
            baseSeconds = Double(tokens[0] * 3600 + tokens[1] * 60 + tokens[2])
        } else {
            baseSeconds = nil
        }
        guard let baseSeconds else { return evidence }
        return "\(MeetingRecord.shortClock(baseSeconds + offset)) \(evidence[open...])"
    }

    private static func stitchStructuredNotes(
        sorted: [MeetingRecord],
        plan: MergePlan,
        timeZone: TimeZone
    ) -> MeetingStructuredNotes? {
        guard sorted.contains(where: { $0.notes?.isEmpty == false }) else {
            return nil
        }

        var out = MeetingStructuredNotes()
        out.title = sorted.compactMap { $0.notes?.title?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        var summaryPieces: [String] = []
        var coveredTotal = 0

        for (idx, rec) in sorted.enumerated() {
            if let gap = plan.boundaryGapsByPartIndex[idx] {
                summaryPieces.append(gap.markerText(timeZone: timeZone))
            }
            guard let notes = rec.notes, !notes.isEmpty else { continue }
            let offset = plan.parts[idx].offset
            let partSegCount = plan.parts[idx].segmentCount
            coveredTotal += min(max(0, notes.coveredCount), partSegCount)

            let trimmedSummary = notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                summaryPieces.append(trimmedSummary)
            }

            for topic in notes.topics {
                var shiftedTopic = topic
                shiftedTopic.start += offset
                shiftedTopic.pointTimes = topic.pointTimes?.map { $0.map { $0 + offset } }
                if var fb = topic.fishbone {
                    fb.branches = fb.branches.map { branch in
                        var b = branch
                        b.t = b.t.map { $0 + offset }
                        return b
                    }
                    shiftedTopic.fishbone = fb
                }
                out.topics.append(shiftedTopic)
            }

            for item in notes.conclusions {
                var shifted = item
                shifted.t = item.t.map { $0 + offset }
                if let existingIdx = out.conclusions.firstIndex(where: { $0.text == shifted.text }) {
                    out.conclusions[existingIdx].support = max(out.conclusions[existingIdx].support, shifted.support)
                    out.conclusions[existingIdx].t = [out.conclusions[existingIdx].t, shifted.t].compactMap { $0 }.min()
                } else {
                    out.conclusions.append(shifted)
                }
            }

            for item in notes.todos {
                var shifted = item
                shifted.t = item.t.map { $0 + offset }
                if let existingIdx = out.todos.firstIndex(where: { $0.text == shifted.text }) {
                    out.todos[existingIdx].support = max(out.todos[existingIdx].support, shifted.support)
                    out.todos[existingIdx].t = [out.todos[existingIdx].t, shifted.t].compactMap { $0 }.min()
                    if out.todos[existingIdx].owner == nil {
                        out.todos[existingIdx].owner = shifted.owner
                    }
                } else {
                    out.todos.append(shifted)
                }
            }

            for term in notes.terms {
                if let existingIdx = out.terms.firstIndex(where: { $0.name.caseInsensitiveCompare(term.name) == .orderedSame }) {
                    if out.terms[existingIdx].note.isEmpty && !term.note.isEmpty {
                        out.terms[existingIdx].note = term.note
                    }
                    for h in term.heard where !out.terms[existingIdx].heard.contains(h) {
                        out.terms[existingIdx].heard.append(h)
                    }
                } else {
                    out.terms.append(term)
                }
            }
        }

        out.summary = summaryPieces.joined(separator: " ")
        for gap in plan.gaps {
            let rangeText = gap.formattedWallClockRange(timeZone: timeZone)
            if !out.summary.contains(rangeText) {
                let marker = gap.markerText(timeZone: timeZone)
                out.summary = out.summary.isEmpty ? marker : "\(out.summary) \(marker)"
            }
        }
        out.topics.sort { $0.start < $1.start }
        if out.terms.count > 20 {
            out.terms = Array(MeetingNoteTerm.ordered(out.terms).prefix(20))
        }
        out.coveredCount = coveredTotal
        out.updatedAt = Date()
        out.isFinal = false
        out.transcriptRevision = 0
        return out.isEmpty ? nil : out
    }

    private static func stitchPlainSummaries(
        sorted: [MeetingRecord],
        plan: MergePlan,
        hasStructuredNotes: Bool,
        timeZone: TimeZone
    ) -> [MeetingSummary] {
        guard !hasStructuredNotes, sorted.contains(where: { !$0.summaries.isEmpty }) else {
            return []
        }
        var blocks: [String] = []
        var latestModel = "合并纪要"
        var latestTemplate = ""
        for (idx, rec) in sorted.enumerated() {
            if let gap = plan.boundaryGapsByPartIndex[idx] {
                blocks.append(gap.markerText(timeZone: timeZone))
            }
            if let last = rec.summaries.last {
                let trimmed = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(trimmed)
                }
                if !last.model.isEmpty { latestModel = last.model }
                if !last.template.isEmpty { latestTemplate = last.template }
            }
        }
        var combined = blocks.joined(separator: "\n\n")
        for gap in plan.gaps {
            let rangeText = gap.formattedWallClockRange(timeZone: timeZone)
            if !combined.contains(rangeText) {
                let marker = gap.markerText(timeZone: timeZone)
                combined = combined.isEmpty ? marker : "\(combined)\n\n\(marker)"
            }
        }
        guard !combined.isEmpty else { return [] }
        return [MeetingSummary(
            transcriptRevision: 0,
            model: latestModel,
            template: latestTemplate,
            text: combined
        )]
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

enum MeetingCloudPayload {
    /// Xiaomi MiMo-v2 models enable Deep Thinking CoT by default on `*.xiaomimimo.com`, which consumes
    /// thousands of reasoning tokens and 100s+ latency on structured extraction unless explicitly disabled.
    static func shouldDisableMiMoThinking(url: URL, model: String, disableThinking: Bool) -> Bool {
        guard disableThinking,
              let host = url.host?.lowercased(),
              host == "xiaomimimo.com" || host.hasSuffix(".xiaomimimo.com") else {
            return false
        }
        let lowerModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowerModel.hasPrefix("mimo-v2") && !lowerModel.contains("asr")
    }

    static func extractCompletionContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw MeetingFailure.message("模型未返回可用文本，请检查接口是否兼容 Chat Completions。")
        }
        if choice["finish_reason"] as? String == "length" {
            throw MeetingFailure.message("模型输出被长度限制截断，本次未保存为完整纪要；请更换模型或调整模板后重试。")
        }
        guard let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingFailure.message("模型未返回可用文本，请检查接口是否兼容 Chat Completions。")
        }
        return content
    }
}
