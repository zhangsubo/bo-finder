import Foundation
import AVFoundation

@main
struct MeetingAppleSpeechTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("deskside-audio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var checks = 0
        // PCM16 matches MeetingCapture. Float32 also exercises benchmark fixtures.
        for float in [false, true] {
            let count = 32017
            let url = folder.appendingPathComponent(float ? "float.wav" : "pcm.wav")
            var data = Data()
            func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
            let bytes = float ? 4 : 2
            data.append(contentsOf: "RIFF".utf8); word(UInt32(36 + count * bytes)); data.append(contentsOf: "WAVEfmt ".utf8)
            word(UInt32(16)); word(UInt16(float ? 3 : 1)); word(UInt16(1)); word(UInt32(16000)); word(UInt32(16000 * bytes)); word(UInt16(bytes)); word(UInt16(bytes * 8))
            data.append(contentsOf: "data".utf8); word(UInt32(count * bytes))
            for index in 0..<count {
                let value = Int16(index % 30000 - 15000)
                if float { word((Float(value) / 32768).bitPattern) }
                else { word(value) }
            }
            try data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            var offset = 0
            while offset < count {
                let frames = min(16000, count - offset)
                let buffer = try MeetingAudioFileReader.read(file, frames: AVAudioFrameCount(frames))
                precondition(buffer.frameLength == frames, "Short reads must not drop WAV tail samples")
                let samples = buffer.floatChannelData![0]
                for index in 0..<frames {
                    let expected = Float(Int16((offset + index) % 30000 - 15000)) / 32768
                    precondition(abs(samples[index] - expected) < 0.00001, "Samples must remain ordered and intact across read boundaries")
                }
                offset += frames; checks += 1
            }
            let eof = try MeetingAudioFileReader.read(file, frames: 10)
            precondition(eof.frameLength == 0, "EOF must terminate without spinning")
            checks += 1
        }
        print("Apple audio input tests: \(checks) passed (PCM16/Float32, every sample checked)")
    }
}
