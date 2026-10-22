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
            let fixtureFolder = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: fixtureFolder, withIntermediateDirectories: true)
            let url = fixtureFolder.appendingPathComponent("memory.json")
            let object: [String: Any] = [
                "version": 1, "messages": [], "summarizedCount": 0, "summary": "", "facts": [], "touchDays": [],
                "relationship": ["friendship": friendship, "boundaryStrikes": 0, "dailyGain": [:]]
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            return url
        }
        func preciseFriendship(_ memory: CompanionMemory) throws -> Double {
            guard let value = memory.relationshipPayload()["friendship"] as? Double else {
                throw TestFailure(message: "Relationship payload must contain friendship")
            }
            return value
        }

        for (friendship, level) in [(24.9, 0), (25, 1), (49.9, 1), (50, 2), (74.9, 2), (75, 3)] {
            try check(CompanionMemory.level(for: friendship) == level, "Friendship level boundary at \(friendship)")
        }

        for (index, sample) in [(10.0, 9.7), (25.0, 25.0), (50.0, 50.3), (75.0, 75.4)].enumerated() {
            let memory = CompanionMemory(
                fileURL: try fixture("carry-level-\(index)", friendship: sample.0),
                defaults: defaults
            )
            memory.recordTouch("carry")
            let friendship = try preciseFriendship(memory)
            try check(friendship == sample.1, "Carry score at friendship \(sample.0)")
        }

        let touchCap = CompanionMemory(fileURL: try fixture("touch-cap", friendship: 60), defaults: defaults)
        for _ in 0..<13 { touchCap.recordTouch("headPat") }
        let cappedFriendship = try preciseFriendship(touchCap)
        try check(cappedFriendship == 65, "Positive touches stop at the daily +5 cap")

        let negativeThenPositive = CompanionMemory(
            fileURL: try fixture("negative-then-positive", friendship: 10),
            defaults: defaults
        )
        for _ in 0..<5 { negativeThenPositive.recordTouch("carry") }
        for _ in 0..<13 { negativeThenPositive.recordTouch("headPat") }
        let friendshipAfterLossAndGain = try preciseFriendship(negativeThenPositive)
        try check(
            friendshipAfterLossAndGain == 13.5,
            "Negative carry scores do not consume the positive daily cap"
        )

        let offendedCarry = CompanionMemory(fileURL: try fixture("offended-carry", friendship: 80), defaults: defaults)
        offendedCarry.recordTouch("boundary", part: "chest")
        let offendedScore = try preciseFriendship(offendedCarry)
        offendedCarry.recordTouch("carry")
        let friendshipAfterOffendedCarry = try preciseFriendship(offendedCarry)
        try check(friendshipAfterOffendedCarry == offendedScore, "Being carried cannot add friendship while upset")

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

        let roundTripURL = try fixture("reset-round-trip", friendship: 80)
        let roundTrip = CompanionMemory(fileURL: roundTripURL, defaults: defaults)
        roundTrip.noteUserMessage("我喜歡你，可以做我女朋友嗎？")
        let oldImageName = try require(roundTrip.saveImage(Data([0xFF, 0xD8, 0xFF, 0xD9])), "Test image must be saved")
        let oldImageURL = try require(roundTrip.imageURL(named: oldImageName), "Saved image must have a URL")
        let oldMessages = [
            ChatMessage(role: .user, text: "重設前", imageName: oldImageName),
            ChatMessage(role: .assistant, text: "我會記得")
        ]
        roundTrip.record(oldMessages)
        roundTrip.saveNow()
        defaults.set("keep-this", forKey: "unrelatedSetting")

        var erasedNotifications = 0
        var restoredNotifications = 0
        let erasedObserver = NotificationCenter.default.addObserver(forName: .mikuMemoryErased, object: roundTrip, queue: nil) { _ in
            erasedNotifications += 1
        }
        let restoredObserver = NotificationCenter.default.addObserver(forName: .mikuMemoryRestored, object: roundTrip, queue: nil) { _ in
            restoredNotifications += 1
        }
        defer {
            NotificationCenter.default.removeObserver(erasedObserver)
            NotificationCenter.default.removeObserver(restoredObserver)
        }

        roundTrip.eraseAll()
        try check(erasedNotifications == 1, "Reset posts one erased notification")
        try check(roundTrip.hasResetBackup, "Reset keeps one undo backup")
        try check(roundTrip.storedMessages.isEmpty, "Reset clears the conversation")
        try check(roundTrip.relationshipStatus == .friends, "Reset clears dating before undo")
        try check(FileManager.default.fileExists(atPath: oldImageURL.path), "Reset keeps images referenced by its backup")
        try check(defaults.string(forKey: "unrelatedSetting") == "keep-this", "Reset preserves unrelated settings")

        let newImageName = try require(roundTrip.saveImage(Data([0xFF, 0xD8, 0x00, 0xD9])), "Post-reset image must be saved")
        let newImageURL = try require(roundTrip.imageURL(named: newImageName), "Post-reset image must have a URL")
        roundTrip.record([ChatMessage(role: .user, text: "重設後", imageName: newImageName)])
        try check(roundTrip.restoreResetBackup(), "A valid reset backup can be restored")
        try check(restoredNotifications == 1, "Undo posts one restored notification")
        try check(!roundTrip.hasResetBackup, "Undo consumes the one-time backup")
        try check(roundTrip.storedMessages.map(\.text) == oldMessages.map(\.text), "Undo replaces post-reset chat with the backed-up chat")
        try check(roundTrip.relationshipStatus == .dating, "Undo restores dating status")
        try check(FileManager.default.fileExists(atPath: oldImageURL.path), "Undo keeps restored chat images")
        try check(!FileManager.default.fileExists(atPath: newImageURL.path), "Undo removes images used only by replaced post-reset chat")
        try check(defaults.string(forKey: "unrelatedSetting") == "keep-this", "Undo preserves unrelated settings")
        try check(!roundTrip.restoreResetBackup(), "The same reset backup cannot be restored twice")

        let singleBackupURL = try fixture("single-reset-backup", friendship: 60)
        let singleBackup = CompanionMemory(fileURL: singleBackupURL, defaults: defaults)
        singleBackup.record([ChatMessage(role: .user, text: "first reset")])
        singleBackup.eraseAll()
        singleBackup.record([ChatMessage(role: .user, text: "second reset")])
        singleBackup.eraseAll()
        singleBackup.eraseAll()
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: singleBackupURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == "memory-before-reset.json" }
        try check(backupFiles.count == 1, "Only one reset backup is retained")
        try check(singleBackup.restoreResetBackup(), "The latest non-empty reset has a valid backup")
        try check(singleBackup.storedMessages.map(\.text) == ["second reset"], "A newer reset replaces the older reset backup")

        let deleteBackupURL = try fixture("delete-reset-backup", friendship: 65)
        let deleteBackup = CompanionMemory(fileURL: deleteBackupURL, defaults: defaults)
        let deletedImageName = try require(deleteBackup.saveImage(Data([0xFF, 0xD8, 0x01, 0xD9])), "Backup image must be saved")
        let deletedImageURL = try require(deleteBackup.imageURL(named: deletedImageName), "Backup image must have a URL")
        deleteBackup.record([ChatMessage(role: .user, text: "delete backup", imageName: deletedImageName)])
        deleteBackup.eraseAll()
        try check(FileManager.default.fileExists(atPath: deletedImageURL.path), "Backup image remains until the backup is deleted")
        deleteBackup.deleteResetBackup()
        try check(!deleteBackup.hasResetBackup, "Permanent deletion removes the reset backup")
        try check(!FileManager.default.fileExists(atPath: deletedImageURL.path), "Permanent deletion removes images used only by the backup")

        let legacyURL = try fixture("legacy-reset-backup", friendship: 30)
        let legacy = CompanionMemory(fileURL: legacyURL, defaults: defaults)
        legacy.record([ChatMessage(role: .user, text: "temporary")])
        let legacyDate = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let legacyMessageID = UUID()
        let legacyBackup: [String: Any] = [
            "version": 1,
            "messages": [["id": legacyMessageID.uuidString, "role": "user", "text": "legacy chat", "date": legacyDate]],
            "summarizedCount": 99,
            "summary": "legacy summary",
            "facts": [],
            "touchDays": [],
            "relationship": ["friendship": 72.0, "boundaryStrikes": 0, "dailyGain": [:]]
        ]
        let legacyBackupURL = legacyURL.deletingLastPathComponent().appendingPathComponent("memory-before-reset.json")
        try JSONSerialization.data(withJSONObject: legacyBackup).write(to: legacyBackupURL)
        try check(legacy.restoreResetBackup(), "A legacy version-1 backup can be restored")
        try check(legacy.storedMessages.map(\.text) == ["legacy chat"], "Legacy backup restores its conversation")
        try check(legacy.friendship == 72, "Legacy backup restores friendship")
        try check(legacy.relationshipStatus == .friends, "Legacy backup without relationship status defaults to friends")
        try check(defaults.string(forKey: "unrelatedSetting") == "keep-this", "Legacy restore preserves unrelated settings")

        let corruptURL = try fixture("corrupt-reset-backup", friendship: 40)
        let corrupt = CompanionMemory(fileURL: corruptURL, defaults: defaults)
        corrupt.record([ChatMessage(role: .user, text: "current chat")])
        let corruptBackupURL = corruptURL.deletingLastPathComponent().appendingPathComponent("memory-before-reset.json")
        try Data("not json".utf8).write(to: corruptBackupURL)
        try check(!corrupt.restoreResetBackup(), "A corrupt reset backup is rejected")
        try check(corrupt.storedMessages.map(\.text) == ["current chat"], "A failed restore leaves current memory unchanged")

        let backupFailureURL = try fixture("reset-backup-write-failure", friendship: 55)
        let backupFailure = CompanionMemory(fileURL: backupFailureURL, defaults: defaults)
        backupFailure.record([ChatMessage(role: .user, text: "older backup")])
        backupFailure.eraseAll()
        backupFailure.record([ChatMessage(role: .user, text: "must not be erased without a fresh backup")])
        let backupFailureFolder = backupFailureURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backupFailureFolder.path)
        backupFailure.eraseAll()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupFailureFolder.path)
        try check(
            backupFailure.storedMessages.map(\.text) == ["must not be erased without a fresh backup"],
            "Reset must leave current memory intact when its fresh backup cannot replace the older backup"
        )

        let restoreFailureURL = try fixture("reset-restore-write-failure", friendship: 58)
        let restoreFailure = CompanionMemory(fileURL: restoreFailureURL, defaults: defaults)
        restoreFailure.record([ChatMessage(role: .user, text: "backed up")])
        restoreFailure.eraseAll()
        let restoreFailureFolder = restoreFailureURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restoreFailureFolder.path)
        let restoreSucceeded = restoreFailure.restoreResetBackup()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restoreFailureFolder.path)
        try check(!restoreSucceeded, "Restore must report failure when restored memory cannot be persisted")
        try check(restoreFailure.storedMessages.isEmpty, "A failed restore leaves current memory intact")
        try check(restoreFailure.hasResetBackup, "A failed restore keeps the backup available for retry")

        let clearAfterResetURL = try fixture("clear-after-reset", friendship: 62)
        let clearAfterReset = CompanionMemory(fileURL: clearAfterResetURL, defaults: defaults)
        let backupOnlyImageName = try require(clearAfterReset.saveImage(Data([0xFF, 0xD8, 0x02, 0xD9])), "Backup-only image must be saved")
        let backupOnlyImageURL = try require(clearAfterReset.imageURL(named: backupOnlyImageName), "Backup-only image must have a URL")
        clearAfterReset.record([ChatMessage(role: .user, text: "image in reset backup", imageName: backupOnlyImageName)])
        clearAfterReset.eraseAll()
        clearAfterReset.clearConversation()
        try check(
            FileManager.default.fileExists(atPath: backupOnlyImageURL.path),
            "Clearing post-reset chat must keep images referenced by the reset backup"
        )

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

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(message: message) }
    return value
}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
