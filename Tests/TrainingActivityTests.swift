import Foundation

@main
struct TrainingActivityTests {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appendingPathComponent("runtime/voice-call-state.json")
        let activity = MikuTrainingActivity(location: location)
        var checks = 0
        func check(_ condition: Bool) {
            precondition(condition)
            checks += 1
        }
        func snapshot() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: location)) as! [String: Any]
        }
        activity.publish()
        let idle = try snapshot()
        check(Set(idle.keys) == ["version", "active", "updated_at", "pid"])
        check(idle["active"] as? Bool == false)
        check(idle["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier)
        check(abs((idle["updated_at"] as? Double ?? 0) - Date().timeIntervalSince1970) < 2)
        activity.setVoiceCallActive(true)
        check(try snapshot()["active"] as? Bool == true)
        activity.setVoiceCallActive(false)
        check(try snapshot()["active"] as? Bool == false)
        let permissions = try FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? Int
        check(permissions == 0o600)
        print("\(checks) training activity checks passed")
    }
}
