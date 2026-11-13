import AppKit
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

        // 11. API Key masking (first 8 + *** + last 4) & remote /models list parsing
        check(MeetingKeyMask.format("sk-1234567890abcdef") == "sk-12345***cdef", "Saved API key displays first 8 + *** + last 4 mask")
        check(MeetingKeyMask.format("  mimo_key_abcdefgh9876  ") == "mimo_key***9876", "Trims whitespace before applying 8+***+4 mask")
        check(MeetingKeyMask.format("shortkey") == "sh***ey", "Short keys never expose full string")
        check(MeetingKeyMask.format("") == "", "Empty key formats as empty string")

        let openAIModelsJSON = #"{"object":"list","data":[{"id":"mimo-v2.6-flash","object":"model"},{"id":"mimo-v2-omni","object":"model"},{"id":"mimo-v2.6-flash","object":"model"}]}"#.data(using: .utf8)!
        check(MeetingModelListParser.parse(openAIModelsJSON) == ["mimo-v2.6-flash", "mimo-v2-omni"], "Parses and deduplicates OpenAI /v1/models response")
        let altModelsJSON = #"{"models":[{"name":"models/gemini-2.5-flash"},{"id":"deepseek-chat"}]}"#.data(using: .utf8)!
        check(MeetingModelListParser.parse(altModelsJSON) == ["gemini-2.5-flash", "deepseek-chat"], "Parses compatible gateway models response")

        // 12. Regression tests: Tencent Meeting / helper process auto-start & auto-end lifecycle
        let realRunningWithHelpers: Set<String> = [
            "com.bofinder.app",
            "com.tencent.meeting",
            "com.tencent.meeting.services.wmexternal",
            "com.electron.lark",
            "com.electron.lark.helper",
            "com.tencent.xinWeChat",
            "com.tencent.flue.helper.plugin",
        ]
        check(
            MeetingDetector.ownerBundle(of: "com.tencent.meeting.services.wmexternal", running: realRunningWithHelpers) == "com.tencent.meeting",
            "Helper bundle wmexternal resolves to parent com.tencent.meeting even when helper is in runningApplications"
        )
        check(
            MeetingDetector.ownerBundle(of: "com.electron.lark.helper", running: realRunningWithHelpers) == "com.electron.lark",
            "Feishu helper resolves to parent com.electron.lark even when helper is in runningApplications"
        )
        check(
            MeetingDetector.ownerBundle(
                of: "com.tencent.flue.helper.plugin",
                executablePath: "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/WeChatAppEx Framework.framework/Helpers/WeChatAppEx Helper (Plugin).app/Contents/MacOS/WeChatAppEx Helper (Plugin)",
                running: realRunningWithHelpers,
                appBundleIDResolver: { $0 == "/Applications/WeChat.app" ? "com.tencent.xinWeChat" : nil }
            ) == "com.tencent.xinWeChat",
            "Non-prefixed helper bundle resolves to WeChat via outermost .app executable path"
        )
        check(
            MeetingDetector.ownerBundle(
                of: "",
                executablePath: "/Applications/TencentMeeting.app/Contents/Frameworks/WeMeetFramework.framework/Versions/3.47.2.407/Frameworks/wmexternal.app/Contents/MacOS/wmexternal",
                running: realRunningWithHelpers,
                appBundleIDResolver: { $0 == "/Applications/TencentMeeting.app" ? "com.tencent.meeting" : nil }
            ) == "com.tencent.meeting",
            "Empty CoreAudio bundle ID resolves to Tencent Meeting via outermost .app executable path"
        )

        // Mic permission gate: .notDetermined must proceed and prompt (not silently suppress auto-start)
        check(
            MeetingAutoRecordingPolicy.micPermissionGate(status: .notDetermined, microphone: "default") == .proceed
                && MeetingAutoRecordingPolicy.micPermissionGate(status: .authorized, microphone: "default") == .proceed
                && MeetingAutoRecordingPolicy.micPermissionGate(status: .denied, microphone: "default") == .denied
                && MeetingAutoRecordingPolicy.micPermissionGate(status: .denied, microphone: "off") == .proceed,
            "Auto-start mic permission gate prompts on .notDetermined and only blocks when explicitly denied"
        )

        // Scenario A: Tencent Meeting unmuted start -> brief AirPods switch -> hang-up auto-end
        var autoConfig = MeetingConfiguration()
        autoConfig.automatic = true
        var snapRunning = realRunningWithHelpers
        var snapProcesses: [MeetingAudioProcessSample] = []
        let detector = MeetingDetector {
            MeetingDetector.Snapshot(
                runningBundles: snapRunning,
                ownBundle: "com.bofinder.app",
                processes: snapProcesses
            )
        }
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: true, output: true)]
        check(detector.poll(config: autoConfig, now: 10.0) == (nil, false), "Initial call sample begins timing window")
        check(detector.poll(config: autoConfig, now: 12.1) == ("com.tencent.meeting", false), "Sustained >=2s Tencent Meeting audio auto-starts recording")
        // Simulate 1.2s device switch dropout (<2.0s grace)
        snapProcesses = []
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 30.0) == (nil, false), "Brief device switch dropout starts grace timer without ending")
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 31.2) == (nil, false), "1.2s Bluetooth/AirPods switch stays within grace window")
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: false, output: true)]
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 31.5) == (nil, false), "Resumed speaker output cancels hang-up grace timer")
        // Simulate real meeting hang-up: must auto-end promptly within ~2.1s (before user thinks it got stuck!)
        snapProcesses = []
        _ = detector.poll(config: autoConfig, isRecordingOnline: true, now: 50.0)
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 52.1) == (nil, true), "Leaving Tencent Meeting auto-ends promptly after >=2.0s")

        // Scenario A2: Quitting Tencent Meeting app completely (⌘Q) must auto-end immediately (0s wait)
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: true, output: true)]
        _ = detector.poll(config: autoConfig, now: 60.0)
        check(detector.poll(config: autoConfig, now: 62.1) == ("com.tencent.meeting", false), "Second Tencent Meeting starts")
        snapProcesses = []
        snapRunning.remove("com.tencent.meeting")
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 70.0) == (nil, true), "Quitting Tencent Meeting app auto-ends immediately without grace delay")
        snapRunning.insert("com.tencent.meeting")

        // Scenario B: Joining Tencent Meeting with mic muted ("入会静音": input=false, output=true)
        // Brief 1.5s notification chime must NOT start recording
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: false, output: true)]
        check(detector.poll(config: autoConfig, now: 100.0) == (nil, false), "Short notification chime tick 1 does not start")
        check(detector.poll(config: autoConfig, now: 101.5) == (nil, false), "Short notification chime <4.5s does not start")
        snapProcesses = []
        check(detector.poll(config: autoConfig, now: 102.5) == (nil, false), "Ended notification chime resets timer")
        // Entering muted Tencent Meeting room keeps output open >=4.5s -> MUST auto-start and later auto-end
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: false, output: true)]
        _ = detector.poll(config: autoConfig, now: 110.0)
        check(detector.poll(config: autoConfig, now: 114.6) == ("com.tencent.meeting", false), "Muted-mic Tencent Meeting auto-starts after >=4.5s sustained output")
        snapProcesses = []
        _ = detector.poll(config: autoConfig, isRecordingOnline: true, now: 200.0)
        check(detector.poll(config: autoConfig, isRecordingOnline: true, now: 208.1) == (nil, true), "Muted-mic Tencent Meeting auto-ends after hang-up")

        // Scenario C: WeChat playing a 10s voice message (output-only) must NOT start; real voice call (input+output) MUST start
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.xinWeChat", input: false, output: true)]
        _ = detector.poll(config: autoConfig, now: 300.0)
        check(detector.poll(config: autoConfig, now: 310.0) == (nil, false), "WeChat voice note playback (output-only) does not false-start")
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.xinWeChat", input: true, output: true)]
        _ = detector.poll(config: autoConfig, now: 312.0)
        check(detector.poll(config: autoConfig, now: 314.1) == ("com.tencent.xinWeChat", false), "WeChat real voice call (input+output) auto-starts")
        // Manual stop mid-call suppresses re-trigger during same call, then clears after hang-up
        detector.suppressCurrent()
        check(detector.current == nil, "suppressCurrent clears current call pointer immediately")
        check(detector.poll(config: autoConfig, now: 318.0) == (nil, false), "Manually stopped call does not re-auto-start while same call continues")
        snapProcesses = []
        _ = detector.poll(config: autoConfig, now: 320.0)
        _ = detector.poll(config: autoConfig, now: 328.5) // Clears suppression after hang-up

        // Scenario D: User manually started online recording while automatic=true -> still auto-ends when Tencent Meeting hangs up
        snapProcesses = [MeetingAudioProcessSample(bundleID: "com.tencent.meeting", input: true, output: true)]
        _ = detector.poll(config: autoConfig, isRecordingOnline: true, now: 400.0)
        check(detector.current == "com.tencent.meeting", "Detector latches onto active Tencent Meeting during manual online session")
        snapProcesses = []
        _ = detector.poll(config: autoConfig, isRecordingOnline: true, now: 450.0)
        let manualEndEvent = detector.poll(config: autoConfig, isRecordingOnline: true, now: 458.2)
        check(
            manualEndEvent.ended && MeetingAutoRecordingPolicy.shouldAutoEnd(
                eventEnded: manualEndEvent.ended,
                hasActiveRecording: true,
                autoSession: false,
                onlineSession: true,
                automaticEnabled: true
            ),
            "Manual online recording with automatic=true auto-ends when linked Tencent Meeting hangs up"
        )
        check(
            !MeetingAutoRecordingPolicy.shouldAutoEnd(
                eventEnded: true,
                hasActiveRecording: true,
                autoSession: false,
                onlineSession: false,
                automaticEnabled: true
            ),
            "In-person offline recording never auto-ends due to background app audio"
        )

        // 13. Regression tests: final summary failure with existing live notes must never stick in "working",
        // and Xiaomi MiMo reasoning configuration + length-truncation diagnostics
        var stuckWithLiveNotes = MeetingRecord(title: "11月6日 报告引用溯源讨论", source: "腾讯会议")
        stuckWithLiveNotes.summaryState = "working"
        stuckWithLiveNotes.notes = parsedNotes
        stuckWithLiveNotes.applyFinalSummaryFailure("请求超时。")
        check(
            stuckWithLiveNotes.summaryState == "failed"
                && stuckWithLiveNotes.notes?.title == "Q4发版评审"
                && stuckWithLiveNotes.issue.contains("已保留会中速记")
                && stuckWithLiveNotes.issue.contains("请求超时。"),
            "Final summary failure with non-empty live notes marks failed, preserves live notes, and surfaces issue"
        )

        var relaunchedStuck = MeetingRecord(title: "11月6日 技术经验与团队介绍", source: "腾讯会议")
        relaunchedStuck.summaryState = "working"
        relaunchedStuck.notes = parsedNotes
        relaunchedStuck.recoverInterruptedSummaryOnLaunch()
        check(
            relaunchedStuck.summaryState == "failed" && relaunchedStuck.issue.contains("已保留会中速记"),
            "Launch recovery resets stranded working summaryState and explains preserved live notes"
        )

        let mimoPlanURL = URL(string: "https://token-plan-cn.xiaomimimo.com/v1/chat/completions")!
        let openAIURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        check(
            MeetingCloudPayload.shouldDisableMiMoThinking(url: mimoPlanURL, model: "mimo-v2.6-flash", disableThinking: true)
                && !MeetingCloudPayload.shouldDisableMiMoThinking(url: mimoPlanURL, model: "mimo-v2.5-asr", disableThinking: true)
                && !MeetingCloudPayload.shouldDisableMiMoThinking(url: mimoPlanURL, model: "mimo-v2.6-flash", disableThinking: false)
                && !MeetingCloudPayload.shouldDisableMiMoThinking(url: openAIURL, model: "gpt-4.1-mini", disableThinking: true),
            "Disables default Deep Thinking CoT only on Xiaomi MiMo-v2 non-ASR chat completions when requested"
        )

        let reasoningTruncatedJSON = #"{"choices":[{"message":{"content":"","reasoning_content":"长篇思考耗尽配额"},"finish_reason":"length"}]}"#.data(using: .utf8)!
        do {
            _ = try MeetingCloudPayload.extractCompletionContent(from: reasoningTruncatedJSON)
            fatalError("Expected length truncation error when reasoning exhausts token budget")
        } catch {
            check(
                error.localizedDescription.contains("长度限制截断"),
                "Empty content with finish_reason=length reports length truncation instead of incompatible endpoint"
            )
        }

        // 14. Malformed LLM JSON recovery: unescaped inner quotes, regex backslashes, literal newlines, trailing commas, and outer-prose braces
        let malformedLLMJSON = """
        说明：以下按 {title, summary} 结构输出：
        ```JSON
        {
          "title": "技术经验与团队介绍",
          "summary": "重点构建"主流价值语料", "特色语料"两类资产，并在光大银行"政策助手": 召回率达95%
        支持直接供大模型训练。",
          "topics": [
            {
              "start": 10,
              "title": "RAG与正则切片",
              "summary": "使用正则 \\d+ 与 \\s+ 配合 [a"b] 规则切分 1700 份制度文档",
              "points": [
                {"text": "提出"词表约束"方案", "evidence": ["L2", "L5",],},
              ],
              "evidence": ["L2"],
              "fishbone": null,
            },
          ],
          "conclusions": [],
          "todos": [],
          "terms": [{"name": "主流价值语料", "note": "核心语料资产", "heard": ["主流价值饮料"],}],
        }
        ```
        """
        let repairedParsed = MeetingNotesParser.parse(malformedLLMJSON, times: segTimes, startedAt: 5)
        check(
            repairedParsed?.title == "技术经验与团队介绍"
                && repairedParsed?.summary.contains("主流价值语料") == true
                && repairedParsed?.topics.first?.summary.contains(#"\d+"#) == true
                && repairedParsed?.topics.first?.points.first == #"提出"词表约束"方案"#
                && repairedParsed?.terms.first?.heard == ["主流价值饮料"],
            "Parser repairs unescaped inner quotes, regex backslashes, literal newlines, trailing commas, and outer braces"
        )

        // Floating live-notes panel complete hide & mini-card reopen behavior
        let screenRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let miniRect = NSRect(x: 1100, y: 650, width: 320, height: 238)
        let restoredFromMini = MeetingFloatingPanelBehavior.reopenedFrame(current: miniRect, visibleScreen: screenRect)
        check(
            restoredFromMini?.width == 440 && restoredFromMini?.height == 720 && restoredFromMini?.maxX == 1420,
            "Reopening hidden floating panel from <360pt mini card restores 440x720 sidebar anchored to top-right"
        )
        let normalSidebarRect = NSRect(x: 980, y: 160, width: 440, height: 720)
        check(
            MeetingFloatingPanelBehavior.reopenedFrame(current: normalSidebarRect, visibleScreen: screenRect) == nil,
            "Reopening hidden floating panel preserves >=360pt sidebar/wide frame"
        )

        var hideCount = 0
        let testPanel = MeetingFloatingNSPanel(
            contentRect: normalSidebarRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        testPanel.onHideRequested = { hideCount += 1 }
        check(
            testPanel.standardWindowButton(.miniaturizeButton)?.isEnabled == true
                && testPanel.standardWindowButton(.closeButton)?.isEnabled == true,
            "Floating panel enables native close and yellow minimize traffic-light buttons"
        )
        testPanel.miniaturize(nil)
        testPanel.performMiniaturize(nil)
        check(
            hideCount == 2 && !testPanel.isMiniaturized,
            "Yellow minimize action routes to complete hide instead of leaving a minimized/small window"
        )

        // Local self-signed identity parsing for AppUpdater auto-resigning
        check(
            AppUpdaterLogic.parseLocalSigningIdentity(from: "     0 valid identities found\n") == nil,
            "Returns nil when no local code-signing identity exists on external user Mac"
        )
        let untrustedOut = """
          1) 87E2CA34BC9AB5543F97BDA3EEF26C838B129700 "DeskSide Local Signer" (CSSMERR_TP_NOT_TRUSTED)
             1 identities found
        """
        check(
            AppUpdaterLogic.parseLocalSigningIdentity(from: untrustedOut) == nil,
            "Ignores untrusted self-signed certificate lines with CSSMERR_* errors"
        )
        let validOut = """
          1) 1111111111111111111111111111111111111111 "Apple Development: Other"
          2) 87E2CA34BC9AB5543F97BDA3EEF26C838B129700 "DeskSide Local Signer"
             2 valid identities found
        """
        check(
            AppUpdaterLogic.parseLocalSigningIdentity(from: validOut) == "87E2CA34BC9AB5543F97BDA3EEF26C838B129700",
            "Extracts exact 40-char SHA-1 hash for trusted DeskSide Local Signer identity"
        )

        // 15. Multi-record chronological merging, wall-clock gap markers, speaker cluster safety, & exports
        let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai")!
        var shanghaiCal = Calendar(identifier: .gregorian)
        shanghaiCal.timeZone = shanghaiTZ
        let t1000 = shanghaiCal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 0, second: 0))!
        let t101510 = shanghaiCal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 15, second: 10))!
        let t103245 = shanghaiCal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 10, minute: 32, second: 45))!

        // Part 1: 10:00:00 – 10:12:00 (720s)
        var part1 = MeetingRecord(title: "腾讯会议 · 10:00", date: t1000, source: "腾讯会议", duration: 720)
        part1.phase = "interrupted"
        part1.chunks = [MeetingAudioChunk(file: "mic-0-a.wav", start: 0, duration: 720, source: "mic")]
        part1.segments = [
            MeetingSegment(start: 10, end: 20, speaker: "me", text: "我们先对齐双十一大促网关方案"),
            MeetingSegment(start: 690, end: 715, speaker: "v0", text: "好的，目前限流阈值设在五千", voiceID: 0),
        ]
        part1.speakerNames["v0"] = "张工"
        var notes1 = MeetingStructuredNotes()
        notes1.title = "大促网关评审"
        notes1.summary = "前半段对齐了网关限流阈值。"
        notes1.topics = [
            MeetingNoteTopic(start: 10, title: "限流阈值对齐", summary: "确认五千 QPS 上限", points: ["当前阈值 5000"], pointTimes: [690]),
        ]
        notes1.conclusions = [MeetingNoteItem(text: "限流阈值保持 5000", support: 1, t: 690)]
        notes1.terms = [MeetingNoteTerm(name: "DeskSide", note: "会议助手", heard: ["袋鼠赛"])]
        notes1.coveredCount = 2
        part1.notes = notes1

        // Part 2 (passed out of order to verify chronological sorting): 10:15:10 – 10:30:10 (900s, offset = 910s, gap = 720..910 = 3m10s)
        var part2 = MeetingRecord(title: "11月13日 网关压测排期", date: t101510, source: "腾讯会议", duration: 900)
        part2.userRenamedTitle = true
        part2.chunks = [MeetingAudioChunk(file: "system-5000-b.wav", start: 5, duration: 895, source: "system")]
        part2.segments = [
            // Unnamed v0 in part2 is a new session cluster and MUST NOT falsely inherit "张工" from part1's v0
            MeetingSegment(start: 6, end: 18, speaker: "v0", text: "刚才网络断了一下，我是李总，接着说压测", voiceID: 0),
            // Explicitly named "张工" in part2's v1 MUST unify with part1's "张工"
            MeetingSegment(start: 40, end: 55, speaker: "v1", text: "明白，压测脚本周四提交", voiceID: 1),
        ]
        part2.speakerNames["v1"] = "张工"
        part2.speakerGuesses = ["v0": MeetingSpeakerGuess(name: "李总", evidence: "00:06 “刚才网络断了一下，我是李总”")]
        var notes2 = MeetingStructuredNotes()
        notes2.summary = "后半段明确了周四提交压测脚本。"
        notes2.topics = [
            MeetingNoteTopic(start: 6, title: "压测脚本排期", summary: "周四前完成脚本", points: ["周四提交压测脚本"], pointTimes: [40]),
        ]
        notes2.todos = [MeetingNoteItem(text: "周四提交压测脚本", owner: "张工", support: 1, t: 40)]
        notes2.terms = [MeetingNoteTerm(name: "DeskSide", note: "会议助手", heard: ["得克赛"])]
        notes2.coveredCount = 2
        part2.notes = notes2

        // Pass [part2, part1] in reverse order to test chronological sorting by date
        let (merged12, copies12) = try MeetingMerger.merge(records: [part2, part1], timeZone: shanghaiTZ)
        check(merged12.date == t1000 && merged12.mergedSourceCount == 2, "Merged record anchors to earliest start date and tracks source count")
        check(merged12.title == "11月13日 网关压测排期" && merged12.userRenamedTitle == true, "Preserves user-renamed title across merged fragments")
        check(abs(merged12.duration - 1810) < 0.001, "Total merged duration spans wall-clock timeline (910s offset + 900s part2 = 1810s)")
        check(merged12.gaps?.count == 1, "Detects exact 1 unrecorded interruption gap between 10:12:00 and 10:15:10")

        let gap12 = merged12.gaps![0]
        check(abs(gap12.start - 720) < 0.001 && abs(gap12.end - 910) < 0.001, "Gap aligns to 720s..910s on unified timeline")
        check(
            gap12.markerText(timeZone: shanghaiTZ) == "(10:12–10:15 会议中断未录制，缺失 3分10秒)",
            "Formats exact interruption wall-clock range and missing duration marker"
        )

        // Verify audio chunk shifting & filename prefix
        check(copies12.count == 2 && merged12.chunks.count == 2, "Generates copy instructions for all audio chunks")
        check(abs(merged12.chunks[1].start - 915) < 0.001 && merged12.chunks[1].file.hasPrefix("system-915000-"), "Shifts second part chunk timestamp by +910s wall-clock offset")

        // Verify speaker cluster isolation vs explicit name unification + AI evidence timestamp shift
        check(merged12.segments.count == 4, "Preserves all 4 utterances in chronological order")
        check(merged12.speakerName(merged12.segments[1].speaker) == "张工" && merged12.speakerName(merged12.segments[3].speaker) == "张工", "Unifies speakers explicitly named 张工 across parts")
        check(merged12.segments[1].speaker == merged12.segments[3].speaker, "Unified named speaker shares canonical speaker key")
        check(merged12.segments[2].speaker != merged12.segments[1].speaker && merged12.speakerName(merged12.segments[2].speaker) == "李总", "Unnamed v0 in part2 stays isolated from part1 v0 and keeps shifted AI guess")
        check(merged12.speakerGuesses?[merged12.segments[2].speaker]?.evidence.hasPrefix("15:16 ") == true, "Shifts AI speaker guess evidence clock from 00:06 to 15:16")
        check(MeetingSpeakerGuessLogic.holds(merged12.speakerGuesses![merged12.segments[2].speaker]!, speakerKey: merged12.segments[2].speaker, in: merged12), "Shifted speaker guess evidence still passes ±2 line proximity check")

        // Verify transcript & timelineEntries include gap marker at exact chronological position
        let timeline12 = merged12.timelineEntries()
        check(timeline12.count == 5, "Timeline has 4 segments + 1 interleaved gap entry")
        if case .gap(let midGap) = timeline12[2] {
            check(midGap.id == gap12.id, "Gap entry sits strictly between part1 last segment (690s) and part2 first segment (916s)")
        } else {
            fatalError("Expected .gap at index 2 of timelineEntries")
        }
        let formattedTx = merged12.formattedTranscript(timeZone: shanghaiTZ)
        check(formattedTx.contains("[00:12:00–00:15:10] (10:12–10:15 会议中断未录制，缺失 3分10秒)"), "Plain transcript interleaves timestamped interruption marker")

        // Verify stitched structured notes shift timestamps, deduplicate glossary, and include gap marker
        check(merged12.notes?.summary.contains("(10:12–10:15 会议中断未录制，缺失 3分10秒)") == true, "Stitched summary embeds interruption marker between part summaries")
        check(merged12.notes?.topics.count == 2 && abs((merged12.notes?.topics[1].start ?? 0) - 916) < 0.001, "Shifts part2 topic start time by +910s")
        check(merged12.notes?.topics[1].pointTime(0) == 950 && merged12.notes?.todos.first?.t == 950, "Shifts topic pointTimes and todo timestamps by +910s")
        check(merged12.notes?.terms.count == 1 && Set(merged12.notes?.terms.first?.heard ?? []) == ["袋鼠赛", "得克赛"], "Deduplicates glossary terms and merges homophone variants")

        // Verify LLM prompt & ensureGapMarkers post-processing + Markdown / Word .docx export
        let mergePrompt = MeetingNotesParser.prompt(
            notes: MeetingStructuredNotes(),
            segments: merged12.segments,
            speakerResolver: { merged12.speakerName($0) },
            from: 0,
            final: true,
            gaps: merged12.gaps ?? [],
            timeZone: shanghaiTZ
        )
        check(
            mergePrompt.contains("[中断未录制 12:00–15:10] (10:12–10:15 会议中断未录制，缺失 3分10秒)"),
            "LLM summary prompt injects interruption marker at exact break between L2 and L3"
        )
        var llmOmittedGapNotes = MeetingStructuredNotes(summary: "模型生成的总结但漏写了括号标记。")
        MeetingNotesParser.ensureGapMarkers(in: &llmOmittedGapNotes, gaps: merged12.gaps ?? [], timeZone: shanghaiTZ)
        check(
            llmOmittedGapNotes.summary.contains("(10:12–10:15 会议中断未录制，缺失 3分10秒)"),
            "ensureGapMarkers deterministically preserves missing-segment marker when omitted by LLM"
        )

        let mergedMD = MeetingDocumentExport.markdown(for: merged12, includeTranscript: true, timeZone: shanghaiTZ)
        let mdOccurrences = mergedMD.components(separatedBy: "(10:12–10:15 会议中断未录制，缺失 3分10秒)").count - 1
        check(mdOccurrences >= 3, "Exported Markdown marks interruption in summary, topic timeline, and full transcript")
        let mergedDocx = try MeetingDocumentExport.docx(for: merged12, timeZone: shanghaiTZ)
        check(mergedDocx.count > 1000 && mergedDocx.prefix(2) == Data([0x50, 0x4B]), "Exported .docx with interruption markers is a valid OOXML archive")

        // Verify iterative 3-part merge ((part1 + part2) + part3) & sub-minute second-level gap formatting (10:30:10 -> 10:32:45 = 2m35s; plus sub-minute check)
        var part3 = MeetingRecord(title: "尾声补充", date: t103245, source: "手动线上会议", duration: 120)
        part3.preview = [MeetingSegment(start: 3, end: 12, speaker: "me", text: "补充确认一下回滚预案")]
        let (merged123, _) = try MeetingMerger.merge(records: [merged12, part3], timeZone: shanghaiTZ)
        check(merged123.mergedSourceCount == 3 && merged123.gaps?.count == 2, "Iterative merge preserves prior gap and adds second interruption gap")
        check(merged123.source == "腾讯会议 + 手动线上会议", "Combines distinct sources in chronological order")
        check(merged123.segments.count == 5 && merged123.segments.last?.text == "补充确认一下回滚预案", "Promotes preview draft when interrupted fragment had empty finalized segments")
        check(
            merged123.gaps?[1].markerText(timeZone: shanghaiTZ) == "(10:30–10:32 会议中断未录制，缺失 2分35秒)",
            "Second gap computes exact wall-clock range and 2m35s missing duration"
        )

        // Sub-minute same-minute gap uses HH:mm:ss so start and end never look identical ("10:12:05–10:12:40")
        let shortGap = MeetingGap(
            start: 100,
            end: 135,
            startDate: t1000.addingTimeInterval(725),
            endDate: t1000.addingTimeInterval(760)
        )
        check(
            shortGap.markerText(timeZone: shanghaiTZ) == "(10:12:05–10:12:40 会议中断未录制，缺失 35秒)",
            "Sub-minute interruption formats HH:mm:ss wall-clock range and seconds"
        )

        // Overlapping wall-clock timestamps clamp cleanly without emitting bogus negative/zero gaps
        var overlapB = MeetingRecord(title: "重叠片段", date: t1000.addingTimeInterval(718), source: "腾讯会议", duration: 60)
        overlapB.segments = [MeetingSegment(start: 2, end: 8, speaker: "me", text: "紧接上一句")]
        let (mergedOverlap, _) = try MeetingMerger.merge(records: [part1, overlapB], timeZone: shanghaiTZ)
        check(mergedOverlap.gaps == nil && abs(mergedOverlap.segments.last!.start - 722) < 0.001, "Slightly overlapping recordings clamp monotonically without false gap markers")

        // Verify JSON persistence roundtrip of merged record + SF Symbols availability
        let mergedReloaded = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(merged123))
        check(mergedReloaded.gaps == merged123.gaps && mergedReloaded.mergedSourceCount == 3, "Merged gaps and source count survive JSON persistence roundtrip")
        for sym in ["arrow.triangle.merge", "waveform.slash", "clock.arrow.circlepath"] {
            check(NSImage(systemSymbolName: sym, accessibilityDescription: nil) != nil, "SF Symbol '\(sym)' exists on macOS")
        }

        print("Meeting tests: \(checks) passed")
    }
}
