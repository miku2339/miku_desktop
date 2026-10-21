import Foundation

@main
struct CompanionMemoryTests {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-memory-tests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.qimake.MikuDesktop.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw TestFailure(message: message) }
            checks += 1
        }
        func fixture(_ name: String, friendship: Double) throws -> URL {
            let url = folder.appendingPathComponent(name + ".json")
            let object: [String: Any] = [
                "version": 1, "messages": [], "summarizedCount": 0, "summary": "", "facts": [], "touchDays": [],
                "relationship": ["friendship": friendship, "boundaryStrikes": 0, "dailyGain": [:]]
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url
        }

        let highURL = try fixture("high", friendship: 80)
        let high = CompanionMemory(fileURL: highURL, defaults: defaults)
        try check(high.friendship == 80, "Legacy memory must retain affection")
        try check(high.relationshipStatus == .friends, "Legacy memory starts as friends")
        high.noteUserMessage("我喜歡你，可以做我女朋友嗎？")
        try check(high.context().confessionDecision == .accepted, "Close friends can accept a confession")
        try check(high.relationshipStatus == .dating, "Acceptance establishes a relationship")
        high.saveNow()
        let restored = CompanionMemory(fileURL: highURL, defaults: defaults)
        try check(restored.relationshipStatus == .dating, "Dating must survive a restart")
        try check(restored.friendship == 80, "Accepting does not manufacture affection")
        restored.noteUserMessage("I love you")
        try check(restored.context().confessionDecision == .alreadyDating, "Repeated confessions retain the relationship")
        restored.noteUserMessage("你喜歡哪首歌？")
        try check(restored.context().confessionDecision == nil, "A normal message clears the previous decision")
        restored.recordTouch("boundary", part: "skirt")
        restored.noteUserMessage("I love you")
        try check(restored.context().confessionDecision == .upset, "Dating cannot override a boundary")
        try check(restored.relationshipStatus == .dating, "An argument does not silently erase dating")

        let ordinary = CompanionMemory(fileURL: try fixture("ordinary", friendship: 95), defaults: defaults)
        for text in ["我喜歡你的歌", "我鍾意你嘅歌聲", "我喜歡你的人設", "佢鍾意你", "我冇話過我鍾意你", "'I love you' 是甚麼意思？", "好きですか？", "ミクが好きですか？"] {
            ordinary.noteUserMessage(text)
            try check(ordinary.context().confessionDecision == nil, "Not a direct confession: \(text)")
            try check(ordinary.relationshipStatus == .friends, "An ordinary message must not start dating")
        }

        let low = CompanionMemory(fileURL: try fixture("low", friendship: 74.9), defaults: defaults)
        low.noteUserMessage("好きです。付き合ってください。")
        try check(low.context().confessionDecision == .notReady, "Fractional affection cannot round up into acceptance")
        try check(low.relationshipStatus == .friends, "A refusal does not change relationship status")

        let upset = CompanionMemory(fileURL: try fixture("upset", friendship: 95), defaults: defaults)
        upset.recordTouch("boundary", part: "chest")
        upset.noteUserMessage("我喜歡你，跟我交往吧")
        try check(upset.context().confessionDecision == .upset, "High affection cannot override an unresolved boundary")
        try check(upset.relationshipStatus == .friends, "An upset refusal stays friends")
        upset.noteUserMessage("對唔住，我喜歡你，跟我交往吧")
        try check(upset.context().confessionDecision == .recovering, "An apology cannot immediately buy acceptance")
        try check(upset.relationshipStatus == .friends, "Forgiveness does not establish dating")

        defaults.set("gentle", forKey: "personalityPreset")
        defaults.set("zh-Hant", forKey: "interfaceLanguage")
        restored.eraseAll()
        try check(restored.relationshipStatus == .friends, "Reset also clears dating")
        try check(restored.friendship == 30, "Reset restores initial affection")
        try check(restored.context().confessionDecision == nil, "Reset discards the prior confession decision")
        try check(restored.relationshipPayload()["reset"] as? Bool == true, "Reset remains distinct from forgiveness")
        try check(defaults.string(forKey: "personalityPreset") == "gentle", "Reset preserves personality")
        try check(defaults.string(forKey: "interfaceLanguage") == "zh-Hant", "Reset preserves language")
        let afterReset = CompanionMemory(fileURL: highURL, defaults: defaults)
        try check(afterReset.relationshipStatus == .friends, "Reset relationship is persisted")

        defaults.set(false, forKey: CompanionMemory.enabledKey)
        let disabled = CompanionMemory(fileURL: try fixture("disabled", friendship: 80), defaults: defaults)
        try check(!disabled.isEnabled, "Tests use isolated preferences")
        disabled.noteUserMessage("我只是作為朋友喜歡你")
        try check(disabled.relationshipStatus == .friends, "A friendly compliment must not start dating")

        let configuration = AIConfiguration(defaults: defaults)
        configuration.endpoint = "invalid-endpoint"
        let ai = LocalAI(configuration: configuration)
        for language in ["zh-Hant", "en", "ja"] {
            configuration.replyLanguage = language
            for decision in [ConfessionDecision.accepted, .notReady, .upset, .recovering, .alreadyDating] {
                var context = MemoryContext.empty
                context.confessionDecision = decision
                context.relationshipStatus = decision == .accepted || decision == .alreadyDating ? .dating : .friends
                let reply = try await ai.reply(to: "我喜歡你", history: [], memory: context)
                try check(!reply.text.isEmpty, "Every confession result has a local response")
                let positive = decision == .accepted || decision == .alreadyDating
                try check(reply.emotion == (positive ? "happy" : "calm"), "Expression agrees with the decision")
                try check(reply.action == (positive ? "nod" : "idle"), "Action agrees with the decision")
            }
        }
        print("PASS: \(checks) memory and dialogue checks")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
