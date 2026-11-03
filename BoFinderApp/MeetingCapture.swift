import AppKit
@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

// MARK: - Core Audio System Process Tap (No Screen Recording Permission Needed)

/// Captures system playback audio via Core Audio Process Tap (macOS 14.2+ / 26+).
/// Excludes DeskSide's own PID so playing back meeting clips never loops into live transcription.
final class MeetingSystemAudioTap {
    var onAudio: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var audioUnit: AudioUnit?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var clientFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var renderBuffer: AVAudioPCMBuffer?

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &obj
        )
        return (status == noErr && obj != kAudioObjectUnknown) ? obj : nil
    }

    private static func defaultOutputUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? (uid as String) : nil
    }

    private func fail(_ message: String) -> MeetingFailure {
        stop()
        return .message(message)
    }

    func start() throws {
        stop()

        let excluded = Self.ownProcessObject().map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "DeskSide Meeting Tap"
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else {
            throw fail("无法建立系统音频采集（\(status)），请在「系统设置 → 隐私与安全性 → 系统音频录制」中允许 DeskSide。")
        }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else {
            throw fail("找不到默认音频输出设备，请检查扬声器或耳机连接。")
        }

        let aggregateUID = "com.bofinder.app.tap.\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DeskSide Audio Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            throw fail("无法创建系统音频聚合设备（\(status)）。")
        }
        aggregateID = agg

        var component = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let found = AudioComponentFindNext(nil, &component) else {
            throw fail("找不到系统 HAL 音频组件。")
        }
        var unit: AudioUnit?
        status = AudioComponentInstanceNew(found, &unit)
        guard status == noErr, let unit else {
            throw fail("无法初始化系统音频单元（\(status)）。")
        }
        audioUnit = unit

        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))

        var device = aggregateID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioObjectID>.size))
        guard status == noErr else {
            throw fail("无法绑定系统音频设备（\(status)）。")
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let clientFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw fail("无法创建系统音频格式。")
        }
        self.clientFormat = clientFormat
        self.monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        self.renderBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: 4096)

        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else {
            throw fail("无法配置系统音频流格式（\(status)）。")
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, timestamp, bus, frames, _ in
                let tap = Unmanaged<MeetingSystemAudioTap>.fromOpaque(refCon).takeUnretainedValue()
                return tap.render(timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else {
            throw fail("无法注册系统音频采集回调（\(status)）。")
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw fail("系统音频初始化失败（\(status)），请检查系统音频录制权限。")
        }
        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw fail("系统音频启动失败（\(status)），请在系统设置中允许系统音频录制。")
        }
    }

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit = audioUnit, let clientFormat else { return noErr }
        var pcm = renderBuffer
        if pcm == nil || pcm!.frameCapacity < frames {
            pcm = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: frames)
            renderBuffer = pcm
        }
        guard let pcm else { return noErr }
        pcm.frameLength = frames
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, timestamp, bus, frames, pcm.mutableAudioBufferList)
        guard status == noErr else { return status }

        guard let monoFormat,
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let src = pcm.floatChannelData,
              let dst = mono.floatChannelData else {
            return noErr
        }
        mono.frameLength = frames
        let n = Int(frames)
        if pcm.format.channelCount >= 2 {
            for i in 0..<n {
                dst[0][i] = (src[0][i] + src[1][i]) * 0.5
            }
        } else {
            memcpy(dst[0], src[0], n * MemoryLayout<Float>.size)
        }
        onAudio?(mono)
        return noErr
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = kAudioObjectUnknown
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = kAudioObjectUnknown
        clientFormat = nil
        monoFormat = nil
        renderBuffer = nil
    }

    deinit { stop() }
}

// MARK: - Dual-Source Audio Capture (Microphone + System Audio)

/// Both sources are serialized onto one queue; in-memory PCM buffers stream directly to live speech
/// while completed WAV segments are persisted to disk for timestamp playback and recovery.
final class MeetingCapture: NSObject, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "deskside.meeting.audio", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "deskside.meeting.capture-control")
    private var converters: [String: AVAudioConverter] = [:]
    private var systemTap: MeetingSystemAudioTap?
    private var microphone: AVCaptureSession?
    private var directory: URL?
    private var began = ProcessInfo.processInfo.systemUptime
    private var accepting = false
    private var chunkSamples = 16000
    private var buffers: [String: [Int16]] = [:]
    private var offsets: [String: Double] = [:]

    /// Direct zero-disk-latency PCM callback invoked on `queue` for live Apple SpeechAnalyzer.
    var onPCMBuffer: ((String, AVAudioPCMBuffer) -> Void)?
    var onChunk: ((MeetingAudioChunk) -> Void)?
    var onFailure: ((String) -> Void)?

    static var inputDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func start(directory: URL, config: MeetingConfiguration, system: Bool) async throws {
        guard config.microphone != "off" || system else {
            throw MeetingFailure.message("请至少开启一个录音音源。")
        }
        if config.microphone != "off" {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw MeetingFailure.message("麦克风未获授权，请在系统设置中允许 DeskSide 使用麦克风。")
            }
        }
        self.directory = directory
        if config.transcription == "local" && config.liveEngine == "apple" {
            // In-memory PCM feeds Apple Speech directly; 10s disk chunks keep playback smooth with 90% fewer files.
            chunkSamples = 160_000
        } else {
            chunkSamples = config.transcription == "local" ? 16_000 : 48_000
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        began = ProcessInfo.processInfo.systemUptime
        accepting = true

        do {
            if system {
                let tap = MeetingSystemAudioTap()
                tap.onAudio = { [weak self] mono in
                    self?.queue.async {
                        self?.consumePCM(mono, source: "system")
                    }
                }
                try tap.start()
                systemTap = tap
            }
            if config.microphone != "off" {
                let device = config.microphone == "default"
                    ? AVCaptureDevice.default(for: .audio)
                    : Self.inputDevices.first { $0.uniqueID == config.microphone }
                guard let device else {
                    throw MeetingFailure.message("所选麦克风不可用，请重新选择输入设备。")
                }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    throw MeetingFailure.message("无法建立麦克风录音会话。")
                }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                microphone = session
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    controlQueue.async {
                        session.startRunning()
                        continuation.resume()
                    }
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func pause(_ paused: Bool) {
        queue.async {
            self.accepting = !paused
            if paused { self.flushAll() }
        }
    }

    func stop() async {
        systemTap?.stop()
        systemTap = nil
        if let session = microphone {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controlQueue.async {
                    session.stopRunning()
                    continuation.resume()
                }
            }
            microphone = nil
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.accepting = false
                self.flushAll()
                self.converters.removeAll()
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, CMSampleBufferDataIsReady(sampleBuffer),
              let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(count),
            into: input.mutableAudioBufferList
        )
        guard copied == noErr else { return }
        consumePCM(input, source: "mic")
    }

    private func consumePCM(_ input: AVAudioPCMBuffer, source: String) {
        guard accepting, input.frameLength > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            return
        }
        if converters[source]?.inputFormat != input.format {
            converters[source] = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter = converters[source],
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 16_000 / input.format.sampleRate + 64)
              ) else {
            return
        }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard conversionError == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            return
        }

        // Deliver 16 kHz mono float buffer directly to live SpeechAnalyzer without waiting for WAV flush.
        onPCMBuffer?(source, output)

        if buffers[source, default: []].isEmpty {
            offsets[source] = max(0, ProcessInfo.processInfo.systemUptime - began - Double(output.frameLength) / 16_000)
        }
        for i in 0..<Int(output.frameLength) {
            let value = samples[i].isFinite ? samples[i] : 0
            buffers[source, default: []].append(Int16(max(-32767, min(32767, value * 32767))))
        }
        if buffers[source, default: []].count >= chunkSamples {
            flush(source)
        }
    }

    private func flushAll() {
        for key in Array(buffers.keys) {
            flush(key)
        }
    }

    private func flush(_ source: String) {
        guard let samples = buffers[source], !samples.isEmpty, let directory else { return }
        let offset = offsets[source] ?? 0
        let name = "\(source)-\(Int(offset * 1000))-\(UUID().uuidString).wav"
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        word(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16))
        word(UInt16(1))
        word(UInt16(1))
        word(UInt32(16_000))
        word(UInt32(32_000))
        word(UInt16(2))
        word(UInt16(16))
        data.append(contentsOf: "data".utf8)
        word(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            onChunk?(MeetingAudioChunk(
                file: name,
                start: offset,
                duration: Double(samples.count) / 16_000,
                source: source
            ))
        } catch {
            accepting = false
            onFailure?("录音写入失败，录制已中断。请检查磁盘空间和目录权限。")
        }
        buffers[source] = []
    }
}

// MARK: - Meeting Call Auto-Detector (Supports Helper Subprocesses without Screen Recording)

/// Detects active calls across dedicated meeting apps and IM voice calls using Core Audio process objects,
/// walking up helper bundle IDs (e.g., `com.bytedance.lark.helper` -> `com.bytedance.lark`).
final class MeetingDetector {
    private static let dedicatedMeetingApps: Set<String> = [
        "com.tencent.meeting",
        "us.zoom.xos",
        "com.electron.lark",
        "com.bytedance.lark",
        "com.microsoft.teams2",
        "com.microsoft.teams",
    ]

    private var consecutive: [String: Int] = [:]
    private var absent: [String: Int] = [:]
    private var suppressed = Set<String>()
    private(set) var current: String?

    func suppressCurrent() {
        if let current { suppressed.insert(current) }
    }

    static func displayName(for bundleID: String) -> String {
        switch bundleID {
        case "com.tencent.meeting": return "腾讯会议"
        case "com.tencent.xinWeChat": return "微信通话"
        case "com.electron.lark", "com.bytedance.lark": return "飞书会议"
        case "com.alibaba.DingTalkMac": return "钉钉通话"
        case "us.zoom.xos": return "Zoom 会议"
        default: return "线上会议"
        }
    }

    /// Walks up helper bundle IDs (`com.electron.lark.helper.Audio`) to find the parent running app.
    static func ownerBundle(of processBundleID: String, running: Set<String>) -> String? {
        var parts = processBundleID.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            let candidate = parts.joined(separator: ".")
            if running.contains(candidate) { return candidate }
            parts.removeLast()
        }
        return nil
    }

    func poll(config: MeetingConfiguration) -> (started: String?, ended: Bool) {
        var enabled: [String] = []
        if config.tencent { enabled.append("com.tencent.meeting") }
        if config.wechat { enabled.append("com.tencent.xinWeChat") }
        if config.feishu { enabled += ["com.bytedance.lark", "com.electron.lark"] }
        if config.dingtalk { enabled.append("com.alibaba.DingTalkMac") }
        if config.zoom { enabled.append("us.zoom.xos") }

        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ownBundle = Bundle.main.bundleIdentifier ?? "com.bofinder.app"
        let audioStates = activeAudioBundles(running: runningBundles, ownBundle: ownBundle)

        var active = Set<String>()
        for bundle in Set(enabled).union(current.map { [$0] } ?? []) {
            guard runningBundles.contains(bundle), let state = audioStates[bundle] else { continue }
            if Self.dedicatedMeetingApps.contains(bundle) {
                if state.input || (bundle == current && state.output) {
                    active.insert(bundle)
                }
            } else {
                // Chat apps (WeChat, DingTalk) run both input & output during a real voice/video call.
                if (state.input && state.output) || (bundle == current && state.input) {
                    active.insert(bundle)
                }
            }
        }

        for bundle in Set(enabled).union(suppressed).union(current.map { [$0] } ?? []) {
            if active.contains(bundle) {
                consecutive[bundle, default: 0] += 1
                absent[bundle] = 0
            } else {
                consecutive[bundle] = 0
                absent[bundle, default: 0] += 1
            }
            if absent[bundle, default: 0] >= 15 {
                suppressed.remove(bundle)
            }
        }

        if let current, absent[current, default: 0] >= 15 {
            self.current = nil
            return (nil, true)
        }
        if current == nil,
           config.automatic,
           let start = enabled.first(where: { consecutive[$0, default: 0] >= 2 && !suppressed.contains($0) }) {
            current = start
            return (start, false)
        }
        return (nil, false)
    }

    private func activeAudioBundles(running: Set<String>, ownBundle: String) -> [String: (input: Bool, output: Bool)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let systemObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObj, &address, 0, nil, &size) == noErr, size > 0 else {
            return [:]
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObj, &address, 0, nil, &size, &ids) == noErr else {
            return [:]
        }

        var merged: [String: (input: Bool, output: Bool)] = [:]
        for obj in ids {
            var inRun: UInt32 = 0
            var outRun: UInt32 = 0
            var propLen = UInt32(MemoryLayout<UInt32>.size)

            address.mSelector = kAudioProcessPropertyIsRunningInput
            _ = AudioObjectGetPropertyData(obj, &address, 0, nil, &propLen, &inRun)
            address.mSelector = kAudioProcessPropertyIsRunningOutput
            _ = AudioObjectGetPropertyData(obj, &address, 0, nil, &propLen, &outRun)
            guard inRun != 0 || outRun != 0 else { continue }

            var cfBundle: CFString = "" as CFString
            var strLen = UInt32(MemoryLayout<CFString>.size)
            address.mSelector = kAudioProcessPropertyBundleID
            let status = withUnsafeMutablePointer(to: &cfBundle) { ptr in
                AudioObjectGetPropertyData(obj, &address, 0, nil, &strLen, ptr)
            }
            guard status == noErr else { continue }
            let rawBundle = cfBundle as String
            guard !rawBundle.isEmpty,
                  let owner = Self.ownerBundle(of: rawBundle, running: runningBundles(from: running)),
                  owner != ownBundle else {
                continue
            }
            let prev = merged[owner] ?? (false, false)
            merged[owner] = (prev.input || inRun != 0, prev.output || outRun != 0)
        }
        return merged
    }

    private func runningBundles(from set: Set<String>) -> Set<String> { set }
}
