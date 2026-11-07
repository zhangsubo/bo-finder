import Foundation

@main
struct MeetingCloudTests {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let text = try await MeetingCloud.completion(base: base + "/ok", key: "test-only", model: "test-model", messages: [["role": "user", "content": "测试转录"]])
        precondition(text == "测试纪要")
        for path in ["unauthorized", "empty", "truncated", "reasoning-truncated", "redirect"] {
            do {
                _ = try await MeetingCloud.completion(base: base + "/" + path, key: "test-only", model: "test-model", messages: [["role": "user", "content": "测试转录"]], disableThinking: true)
                fatalError("Accepted invalid response: \(path)")
            } catch {
                if path == "reasoning-truncated" {
                    precondition(error.localizedDescription.contains("长度限制截断"))
                }
                print("✅ Rejected \(path)")
            }
        }
        let models = try await MeetingCloud.fetchModels(base: base + "/ok", key: "test-only")
        precondition(models == ["mimo-v2.6-flash", "mimo-v2-omni"])
        for path in ["unauthorized", "redirect"] {
            do {
                _ = try await MeetingCloud.fetchModels(base: base + "/" + path, key: "test-only")
                fatalError("Accepted invalid /models response: \(path)")
            } catch { print("✅ Rejected /models \(path)") }
        }
        print("Cloud contract: 8 cases passed")
    }
}
