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

        // 1. Configuration defaults & backward compatibility
        let config = MeetingConfiguration()
        check(!config.automatic, "Recording requires initial user opt-in")
        check(config.transcription == "local", "Default does not upload audio")
        check(config.liveEngine == "apple" && config.speechLocale == "zh-CN", "Fresh zero-Python configuration defaults to Apple native speech + zh-CN")
        check(config.enableVoiceprint && config.enableLiveNotes && !config.floatingPanelCapturable, "Voiceprint, live notes, and screen-share invisibility enabled by default")

        let encoded = try JSONEncoder().encode(config)
        let json = String(decoding: encoded, as: UTF8.self)
        check(!json.contains("apiKey") && !json.contains("password"), "Credentials excluded from configuration")
        let roundtrip = try JSONDecoder().decode(MeetingConfiguration.self, from: encoded)
        check(roundtrip.template == config.template, "Template survives configuration roundtrip")

        // Legacy configuration JSON without new optional fields must decode cleanly and preserve X-ASR when python is configured
        let legacyJSON = #"""
        {
          "automatic": false,
          "tencent": true,
          "wechat": true,
          "microphone": "default",
          "systemAudio": true,
          "python": "/usr/local/bin/python3",
          "models": "/tmp/models",
          "transcription": "local",
          "asrBase": "https://api.xiaomimimo.com/v1",
          "asrModel": "mimo-v2-omni",
          "summaryBase": "https://api.openai.com/v1",
          "summaryModel": "gpt-4.1-mini",
          "template": "完整纪要"
        }
        """#.data(using: .utf8)!
        let decodedLegacy = try JSONDecoder().decode(MeetingConfiguration.self, from: legacyJSON)
        check(decodedLegacy.liveEngine == "xasr" && decodedLegacy.speechLocale == "zh-CN", "Legacy configuration with Python runtime keeps X-ASR")

        var appleConfig = config
        appleConfig.liveTranscription = "apple"
        appleConfig.appleSpeechLocale = "en-US"
        let appleRoundtrip = try JSONDecoder().decode(MeetingConfiguration.self, from: JSONEncoder().encode(appleConfig))
        check(appleRoundtrip.liveEngine == "apple" && appleRoundtrip.speechLocale == "en-US", "Apple engine and language persist")
        check(appleRoundtrip.transcription == "local", "Apple preview retains local offline processing")

        // 2. Preview timeline & tail-breath preservation fix
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
        check(timeline.segments.count == 2, "Matching empty final removes withdrawn draft")
        // Regression test: tail-only empty final (breath/noise) must NOT wipe an earlier long volatile draft
        timeline.replace(source: "system", start: 10, end: 18, text: "正在讨论的完整长句", final: false)
        timeline.replace(source: "system", start: 17.5, end: 18.2, text: "", final: true)
        check(timeline.segments.contains { $0.text == "正在讨论的完整长句" }, "Tail-only empty breath final does not erase earlier long volatile sentence")
        timeline.replace(source: "mic", start: 30, end: 31, text: "暂停后", final: true)
        check(timeline.segments.last?.start == 30, "Pause gaps keep the original meeting timeline")
        timeline.replace(source: "mic", start: .nan, end: 32, text: "无效", final: false)
        check(!timeline.segments.contains { $0.text == "无效" }, "Invalid timestamps do not corrupt preview")

        // 3. MeetingHeardText cleaning, continuation joining, and speakerphone echo deduplication
        check(MeetingHeardText.clean("[laughter] 我们今天讨论发版") == "我们今天讨论发版", "Strips bracketed breath/noise markers")
        check(!MeetingHeardText.hasWords("... 、 ，"), "Punctuation-only fragment has no words")
        check(MeetingHeardText.continues("因为接口还没联调完", "所以我们推迟到周四", gap: 0.9, cut: true), "Micro-pause cut sentence continues smoothly")
        check(!MeetingHeardText.continues("第一点已经确认。", "第二点我们看预算", gap: 0.5, cut: false), "Terminal sentence punctuation prevents false join")
        check(MeetingHeardText.join("我们今天讨论", "发版节奏") == "我们今天讨论发版节奏", "Mid-phrase Chinese split joins seamlessly without artificial comma")
        check(MeetingHeardText.join("Let's check metrics.", "before rollout") == "Let's check metrics before rollout", "Latin clauses strip premature period and join with space")
        check(MeetingHeardText.isEcho("我觉得可以推进", of: "这个方案我觉得可以推进"), "Detects speakerphone echo bleed-through")
        check(!MeetingHeardText.isEcho("那下周三正式上线", of: "我同意这个排期"), "Distinct turns are not marked as echo")

        // 4. Kaldi 80-bin Fbank numerical accuracy against torchaudio.compliance.kaldi.fbank
        let signal: [Float] = (0..<16000).map { n in
            let t = Double(n) / 16000
            return Float(
                0.3 * sin(2 * .pi * 220 * t)
                + 0.1 * sin(2 * .pi * 1234 * t)
                + 0.05 * (Double((n * 7919) % 1000) / 1000 - 0.5)
            )
        }
        let fbank = MeetingFbank.compute(signal)
        check(fbank.count == 98 * 80, "1s 16kHz audio produces 98x80 Kaldi Fbank frames")
        let expectedBins: [(frame: Int, bins: [Float])] = [
            (0, [14.668, 16.6069, 12.7853, 20.1031]),
            (97, [13.7549, 16.6393, 14.6429, 20.1246]),
        ]
        var fbankMatches = true
        for exp in expectedBins {
            for (bin, val) in zip([0, 10, 40, 79], exp.bins) {
                if abs(fbank[exp.frame * 80 + bin] - val) >= 0.01 {
                    fbankMatches = false
                }
            }
        }
        let fbankMean = fbank.reduce(0, +) / Float(fbank.count)
        check(fbankMatches && abs(fbankMean - 16.1517) < 0.01, "Accelerate vDSP Fbank matches Kaldi reference (<0.01)")

        // 5. Bundled WeSpeaker ResNet34-LM Core ML embedding & online cosine voice clusterer
        let voiceprints = try MeetingVoiceprints.load()
        let twoSecSignal = signal + signal
        let emb = voiceprints.embed(twoSecSignal)
        let norm = emb.map { v in v.map { $0 * $0 }.reduce(0, +).squareRoot() } ?? 0
        check(emb?.count == 256 && abs(norm - 1.0) < 0.001, "Bundled Core ML SpeakerEmbedding produces unit-norm 256-d vector")
        check(voiceprints.embed(Array(signal.prefix(4000))) == nil, "Clips shorter than 0.5s abstain from voiceprint embedding")

        func unitVec(_ idx: Int, noise: Float = 0) -> [Float] {
            var v = [Float](repeating: noise, count: 256)
            v[idx] = 1
            let len = v.map { $0 * $0 }.reduce(0, +).squareRoot()
            return v.map { $0 / len }
        }
        var clusterer = MeetingVoiceClusterer()
        check(clusterer.label(unitVec(0), seconds: 3.0) == 0, "First >=2s utterance starts voice cluster 0")
        check(clusterer.label(unitVec(0, noise: 0.02), seconds: 1.0) == 0, "Similar short utterance joins cluster 0")
        check(clusterer.label(unitVec(1), seconds: 1.0) == nil, "Unfamiliar <2s utterance abstains instead of creating noise cluster")
        check(clusterer.label(unitVec(1), seconds: 2.5) == 1, "Unfamiliar >=2s utterance starts cluster 1")
        clusterer.merge(1, into: 0)
        check(clusterer.label(unitVec(1, noise: 0.01), seconds: 1.2) == 0, "Merged cluster routes both centroids to target speaker")

        // 6. Structured notes parser (<think> stripping, evidence timestamps, carryTimes, homophone search, fact highlight)
        let rawLLM = """
        <think>先梳理议题与证据行号</think>
        ```json
        {
          "title": "“Q4发版评审”",
          "summary": "明确了灰度放量节奏与网关超时根因。",
          "topics": [
            {
              "start": 12,
              "title": "网关超时排查",
              "summary": "定位连接池耗尽与重试风暴",
              "points": [
                {"text": "高峰期连接池上限过小", "evidence": ["L2"]},
                {"text": "客户端无退避重试放大流量", "evidence": ["L3"]}
              ],
              "evidence": ["L2"],
              "fishbone": {
                "question": "网关 P99 超时飙升",
                "branches": [
                  {"label": "连接池配置", "detail": "默认最大连接仅 32", "evidence": ["L2"]},
                  {"label": "重试策略", "detail": "失败立即重试 3 次", "evidence": ["L3"]}
                ]
              }
            }
          ],
          "conclusions": [{"text": "本周五下午3点前将灰度比例提升至 30%", "evidence": ["L4"]}],
          "todos": [{"text": "11月8日前补齐指数退避压测报告", "owner": "张工", "evidence": ["L5"]}],
          "terms": [{"name": "DeskSide", "note": "桌边工作台", "heard": ["袋鼠赛", "得克赛"]}]
        }
        ```
        """
        let segTimes: [Double] = [5, 18, 42, 95, 130]
        let parsedNotes = MeetingNotesParser.parse(rawLLM, times: segTimes, startedAt: 5)
        check(parsedNotes != nil, "Structured notes parser handles <think> tags and code fences")
        check(parsedNotes?.title == "Q4发版评审", "Strips decorative quotes around auto-generated title")
        check(parsedNotes?.topics.first?.fishbone?.branches.count == 2, "Parses >=2-branch root-cause fishbone diagram")
        check(parsedNotes?.topics.first?.pointTime(0) == 18 && parsedNotes?.conclusions.first?.t == 95, "Maps 1-based evidence line numbers to earliest segment timestamps")
        check(parsedNotes?.todos.first?.owner == "张工", "Extracts todo owner")

        if let firstPass = parsedNotes {
            var secondPass = firstPass
            secondPass.conclusions[0].t = 130
            MeetingNotesParser.carryTimes(from: firstPass, into: &secondPass)
            check(secondPass.conclusions[0].t == 95, "carryTimes preserves earliest evidence timestamp across incremental updates")
        }

        let expandedQueries = MeetingNoteTerm.expandQuery("desk", terms: parsedNotes?.terms ?? [])
        check(expandedQueries.contains("袋鼠赛") && expandedQueries.contains("得克赛"), "Search query expands ASR homophone variants from glossary")

        let facts = MeetingFactHighlight.matchedSubstrings("定于本周五下午将转化率提升 15%，预算控制在 20万元 以内")
        check(facts.contains { $0.contains("本周五下午") } && facts.contains { $0.contains("15%") } && facts.contains { $0.contains("20万元") }, "Fact highlighter captures dates, percentages, and numbers with units")

        // 7. Speaker name inference ±2 line evidence proximity validation
        var voiceRecord = MeetingRecord(title: "架构周会", source: "腾讯会议")
        voiceRecord.segments = [
            MeetingSegment(start: 2, end: 6, speaker: "v0", text: "大家好，我是王磊，今天先同步网关改造。", voiceID: 0),
            MeetingSegment(start: 8, end: 12, speaker: "v0", text: "目前灰度集群稳定。", voiceID: 0),
            MeetingSegment(start: 15, end: 20, speaker: "v1", text: "收到，谢谢王磊。客户端这边昨天刚提测。", voiceID: 1),
            MeetingSegment(start: 22, end: 26, speaker: "v1", text: "预计周四完成回归。", voiceID: 1),
            MeetingSegment(start: 30, end: 35, speaker: "me", text: "好的，那压测环境今天下午保持冻结。"),
            MeetingSegment(start: 38, end: 42, speaker: "me", text: "接口文档我发群里了。"),
            MeetingSegment(start: 45, end: 50, speaker: "me", text: "顺便提一下隔壁组的赵敏下周休假。"),
        ]
        check(voiceRecord.voiceDisplayNumbers == ["v0": 1, "v1": 2], "Assigns 1-based speaker numbers by first appearance")
        let guessReply = #"{"speakers": [{"speaker": 1, "name": "王磊", "evidence": "L1"}, {"speaker": 2, "name": "赵敏", "evidence": "L7"}]}"#
        let (foundGuesses, refutedGuesses) = MeetingSpeakerGuessLogic.read(guessReply, record: voiceRecord)
        check(foundGuesses["v0"]?.name == "王磊", "Accepts speaker guess when speaker spoke within ±2 lines of evidence")
        check(foundGuesses["v1"] == nil && refutedGuesses["v1"] == "赵敏", "Refutes third-party name when speaker did not speak within ±2 lines of evidence")

        // 8. Persistence backward compatibility & Markdown / Word (.docx) export
        var record = MeetingRecord(title: "讨论", source: "线下")
        record.segments = [
            MeetingSegment(start: 1.5, end: 4, speaker: "A", text: "周三前交付"),
            MeetingSegment(start: 5, end: 8, speaker: "A", text: "先测试"),
        ]
        record.speakerNames["A"] = "负责人"
        record.notes = parsedNotes
        record.summaries = [MeetingSummary(transcriptRevision: 0, model: "example", template: "完整纪要", text: "保留旧版")]
        record.revision = 1
        let restored = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record))
        check(restored.segments.map(\.id) == record.segments.map(\.id), "Stable source IDs survive persistence")
        check(restored.transcript.components(separatedBy: "负责人").count == 3, "Speaker rename applies to every turn")
        check(restored.summaries[0].transcriptRevision != restored.revision, "Edited transcript marks prior summary stale")
        check(restored.transcript.contains(record.segments[0].id.uuidString), "Summary input carries verifiable source references")

        let md = MeetingDocumentExport.markdown(for: restored)
        check(md.contains("## 会议纪要") && md.contains("网关超时排查") && md.contains("负责人"), "Markdown export renders structured notes and speaker names")
        let docxData = try MeetingDocumentExport.docx(for: restored)
        check(docxData.count > 1000 && docxData.prefix(2) == Data([0x50, 0x4B]), "Word .docx export produces valid non-empty OOXML ZIP archive")

        // 9. Timestamp & endpoint security checks
        check(MeetingRecord.timestamp(3661) == "01:01:01", "Long meetings retain hours")
        check(MeetingRecord.timestamp(-1) == "00:00:00", "Invalid negative timestamp is clamped")
        let url = try MeetingFiles.endpoint("https://example.com/v1/", path: "chat/completions")
        check(url.absoluteString == "https://example.com/v1/chat/completions", "Custom compatible endpoint path")
        for invalid in ["http://remote.example/v1", "https://key@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/test", ""] {
            do {
                _ = try MeetingFiles.endpoint(invalid, path: "chat/completions")
                fatalError("Accepted invalid endpoint")
            } catch {
                checks += 1
            }
        }
        _ = try MeetingFiles.endpoint("http://127.0.0.1:8000/v1", path: "chat/completions")
        checks += 1

        // 10. AppUpdater version comparison & SHA-256 checksum parsing
        check(AppUpdaterLogic.isNewer("1.2.0.1", than: "1.2.0"), "CI build suffix version is newer than base version")
        check(AppUpdaterLogic.isNewer("1.2.0.2", than: "1.2.0.1"), "Incremented CI run version is newer")
        check(AppUpdaterLogic.isNewer("v1.10.0", than: "1.9.9"), "Multi-digit minor version compares numerically")
        check(!AppUpdaterLogic.isNewer("1.2.0", than: "1.2.0"), "Identical version is not newer")
        let sampleChecksums = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  DeskSide-1.2.0.1-macOS-arm64.zip\n".data(using: .utf8)!
        check(
            AppUpdaterLogic.expectedSHA256(for: "DeskSide-1.2.0.1-macOS-arm64.zip", in: sampleChecksums)
                == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "Parses SHA-256 digest from shasum checksums.txt"
        )

        print("Meeting tests: \(checks) passed")
    }
}
