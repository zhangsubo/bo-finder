import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreAudio

/// Both sources are serialized onto one queue; each completed WAV is recoverable on its own.
final class MeetingCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "deskside.meeting.audio", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "deskside.meeting.capture-control")
    private var converters: [String: AVAudioConverter] = [:]
    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    private var directory: URL?
    private var began = ProcessInfo.processInfo.systemUptime
    private var accepting = false
    private var chunkSamples = 16000
    private var buffers: [String: [Int16]] = [:]
    private var offsets: [String: Double] = [:]
    var onChunk: ((MeetingAudioChunk) -> Void)?
    var onFailure: ((String) -> Void)?

    static var inputDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInMicrophone, .externalUnknown], mediaType: .audio, position: .unspecified).devices
    }

    func start(directory: URL, config: MeetingConfiguration, system: Bool) async throws {
        guard config.microphone != "off" || system else { throw MeetingFailure.message("请至少开启一个录音音源。") }
        if config.microphone != "off" {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw MeetingFailure.message("麦克风未获授权，请在系统设置中允许 DeskSide 使用麦克风。") }
        }
        self.directory = directory
        chunkSamples = config.transcription == "local" ? 16000 : 48000
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        began = ProcessInfo.processInfo.systemUptime
        accepting = true
        do {
            if system {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw MeetingFailure.message("没有可捕获的显示器，请检查系统音频录制权限。") }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 16000
                configuration.channelCount = 1
                let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                stream = capture
                try await capture.startCapture()
            }
            if config.microphone != "off" {
                let device = config.microphone == "default" ? AVCaptureDevice.default(for: .audio) : Self.inputDevices.first { $0.uniqueID == config.microphone }
                guard let device else { throw MeetingFailure.message("所选麦克风不可用，请重新选择输入设备。") }
                let session = AVCaptureSession()
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                guard session.canAddInput(input), session.canAddOutput(output) else { throw MeetingFailure.message("无法建立麦克风录音会话。") }
                session.addInput(input)
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                microphone = session
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    controlQueue.async { session.startRunning(); continuation.resume() }
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    func pause(_ paused: Bool) {
        queue.async { self.accepting = !paused; if paused { self.flushAll() } }
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if let session = microphone {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controlQueue.async { session.stopRunning(); continuation.resume() }
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

    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?("系统音频录制中断，已保存的片段仍保留。请检查权限和音频设备。") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { consume(sampleBuffer, source: "system") }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { consume(sampleBuffer, source: "mic") }

    private func consume(_ sample: CMSampleBuffer, source: String) {
        guard accepting, CMSampleBufferDataIsReady(sample),
              let description = sample.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        let copied = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList)
        guard copied == noErr,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        if converters[source]?.inputFormat != format { converters[source] = AVAudioConverter(from: format, to: target) }
        guard let converter = converters[source],
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16000 / format.sampleRate + 64)) else { return }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard conversionError == nil, let samples = output.floatChannelData?[0] else { return }
        if buffers[source, default: []].isEmpty {
            offsets[source] = max(0, ProcessInfo.processInfo.systemUptime - began - Double(output.frameLength) / 16000)
        }
        for i in 0..<Int(output.frameLength) {
            let value = samples[i].isFinite ? samples[i] : 0
            buffers[source, default: []].append(Int16(max(-32767, min(32767, value * 32767))))
        }
        if buffers[source, default: []].count >= chunkSamples { flush(source) }
    }

    private func flushAll() { for key in Array(buffers.keys) { flush(key) } }
    private func flush(_ source: String) {
        guard let samples = buffers[source], !samples.isEmpty, let directory else { return }
        let offset = offsets[source] ?? 0
        let name = "\(source)-\(Int(offset * 1000))-\(UUID().uuidString).wav"
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples.count * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(16000)); word(UInt32(32000)); word(UInt16(2)); word(UInt16(16))
        data.append(contentsOf: "data".utf8); word(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        do {
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            onChunk?(MeetingAudioChunk(file: name, start: offset, duration: Double(samples.count) / 16000, source: source))
        } catch {
            accepting = false
            onFailure?("录音写入失败，录制已中断。请检查磁盘空间和目录权限。")
        }
        buffers[source] = []
    }
}

/// Process input activity + a call window is evidence, not mere application launch.
final class MeetingDetector {
    private var consecutive: [String: Int] = [:]
    private var absent: [String: Int] = [:]
    private var suppressed = Set<String>()
    private(set) var current: String?

    func suppressCurrent() { if let current { suppressed.insert(current) } }

    func poll(config: MeetingConfiguration) -> (started: String?, ended: Bool) {
        guard #available(macOS 14.2, *) else { return (nil, false) }
        let enabled = [config.tencent ? "com.tencent.meeting" : "", config.wechat ? "com.tencent.xinWeChat" : ""].filter { !$0.isEmpty }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let processes = audioProcesses()
        var active = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, enabled.contains(bundle) || bundle == current else { continue }
            let input = processes.contains { $0.0 == app.processIdentifier && ($0.1 || (bundle == current && $0.2)) }
            let callWindow = windows.contains { window in
                guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                      let name = window[kCGWindowName as String] as? String else { return false }
                let lowered = name.lowercased()
                return ["正在通话", "语音通话", "视频通话", "会议中", "meeting", "腾讯会议"].contains { lowered.contains($0) }
            }
            if input && callWindow { active.insert(bundle) }
        }
        for bundle in Set(enabled).union(suppressed).union(current.map { [$0] } ?? []) {
            if active.contains(bundle) { consecutive[bundle, default: 0] += 1; absent[bundle] = 0 }
            else { consecutive[bundle] = 0; absent[bundle, default: 0] += 1 }
            if absent[bundle, default: 0] >= 15 { suppressed.remove(bundle) }
        }
        if let current, absent[current, default: 0] >= 15 {
            self.current = nil
            return (nil, true)
        }
        if current == nil, config.automatic, let start = enabled.first(where: { consecutive[$0, default: 0] >= 2 && !suppressed.contains($0) }) {
            current = start
            return (start, false)
        }
        return (nil, false)
    }

    @available(macOS 14.2, *)
    private func audioProcesses() -> [(Int32, Bool, Bool)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var pid: Int32 = 0; var running: UInt32 = 0; var length: UInt32 = 4
            address.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &length, &pid) == noErr else { return nil }
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &length, &running) == noErr else { return nil }
            var output: UInt32 = 0
            address.mSelector = kAudioProcessPropertyIsRunningOutput
            _ = AudioObjectGetPropertyData(id, &address, 0, nil, &length, &output)
            return (pid, running != 0, output != 0)
        }
    }
}
