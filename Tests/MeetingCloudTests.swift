import Foundation

@main
struct MeetingCloudTests {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let text = try await MeetingCloud.completion(base: base + "/ok", key: "test-only", model: "test-model", messages: [["role": "user", "content": "测试转录"]])
        precondition(text == "测试纪要")
        for path in ["unauthorized", "empty", "truncated", "redirect"] {
            do {
                _ = try await MeetingCloud.completion(base: base + "/" + path, key: "test-only", model: "test-model", messages: [["role": "user", "content": "测试转录"]])
                fatalError("Accepted invalid response: \(path)")
            } catch { print("✅ Rejected \(path)") }
        }
        print("Cloud contract: 5 cases passed")
    }
}
