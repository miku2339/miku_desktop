import Foundation

extension Notification.Name {
    /// Posted on the main actor whenever remembered facts, the summary or the relationship change.
    static let mikuMemoryChanged = Notification.Name("com.qimake.MikuDesktop.memoryChanged")
    /// Posted after every memory has been erased (the chat window clears itself).
    static let mikuMemoryErased = Notification.Name("com.qimake.MikuDesktop.memoryErased")
    /// Posted after a reset was undone (the chat window reloads the conversation).
    static let mikuMemoryRestored = Notification.Name("com.qimake.MikuDesktop.memoryRestored")
}

/// One thing Miku remembers about the user ("Your name is Ka Hei", "You're studying in Chiba").
struct MemoryFact: Codable, Identifiable, Equatable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case name, preference, life, plan, other
    }

    let id: UUID
    var category: Category
    var text: String
    let created: Date
    var updated: Date
}

/// Everything the model is given about the past: kept small so it fits a small local model.
struct MemoryContext: Sendable {
    var summary: String
    var facts: [MemoryFact]
    var friendship: Int
    var level: Int
    var offended: Bool
    var justForgiven: Bool
    var boundaryStrikesToday: Int
    /// Where she was touched last time ("chest" or "skirt").
    var boundaryPart: String?
    var touchesToday: [String: Int]
    var daysKnown: Int
    var hoursSinceLastChat: Double?
    var relationshipStatus: RelationshipStatus = .friends
    var confessionDecision: ConfessionDecision? = nil

    static let empty = MemoryContext(
        summary: "", facts: [], friendship: 30, level: 1, offended: false, justForgiven: false,
        boundaryStrikesToday: 0, boundaryPart: nil, touchesToday: [:], daysKnown: 0, hoursSinceLastChat: nil
    )
}

/// Long-term memory: the visible chat, a rolling summary of older turns, durable facts about
/// the user, and how Miku feels about them (friendship, whether she's upset).
///
/// Everything stays on this Mac, in Application Support/MikuDesktop/memory.json.
@MainActor
final class CompanionMemory {
    static let shared = CompanionMemory()

    static let enabledKey = "memoryEnabled"
    static let maxFacts = 60
    static let maxStoredMessages = 240
    /// Unsummarised turns kept verbatim; older ones are folded into the summary.
    static let recentTurns = 12
    static let summarizeThreshold = 24

    /// Touches that count, and how much each moves friendship.
    static let touchFriendship: [String: Double] = [
        "headPat": 0.4, "headStroke": 0.4, "handHold": 0.5, "wave": 0.2, "hello": 0.2, "poke": 0.1,
        "carry": 0, "dizzy": -1.5, "sulk": -3, "ouch": -0.5
    ]

    private struct TouchDay: Codable {
        var day: String
        var counts: [String: Int]
    }

    private struct Relationship: Codable {
        var friendship: Double = 30
        var status: RelationshipStatus?
        var offendedSince: Date?
        var boundaryStrikes: Int = 0
        var lastBoundary: Date?
        var lastBoundaryPart: String?
        var dailyGain: [String: Double] = [:]
    }

    private struct Store: Codable {
        var version = 1
        var firstMet: Date?
        var lastChat: Date?
        var messages: [ChatMessage] = []
        var summarizedCount = 0
        var summary = ""
        var facts: [MemoryFact] = []
        var touchDays: [TouchDay] = []
        var relationship = Relationship()
    }

    private var store = Store()
    private var saveWork: DispatchWorkItem?
    private var maintenance: Task<Void, Never>?
    private var justForgiven = false
    private var confessionDecision: ConfessionDecision?
    /// The next relationship update is a reset, not her forgiving you.
    private var resetPending = false
    private let fileURL: URL
    private let defaults: UserDefaults

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            notify()
        }
    }

    private convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("MikuDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.init(fileURL: folder.appendingPathComponent("memory.json"), defaults: .standard)
    }

    init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
        load()
    }

    // MARK: - Reading

    var facts: [MemoryFact] { store.facts.sorted { $0.updated > $1.updated } }
    var summary: String { store.summary }
    var friendship: Int { Int(store.relationship.friendship.rounded()) }
    var relationshipStatus: RelationshipStatus { store.relationship.status ?? .friends }
    var isOffended: Bool { store.relationship.offendedSince != nil }

    /// The remembered conversation, restored into the chat window (empty when memory is off).
    var storedMessages: [ChatMessage] { isEnabled ? store.messages : [] }

    static func level(for friendship: Double) -> Int {
        friendship >= 75 ? 3 : friendship >= 50 ? 2 : friendship >= 25 ? 1 : 0
    }

    /// Turns sent to the model verbatim: everything not yet folded into the summary.
    func recentHistory(from messages: [ChatMessage]) -> [ChatMessage] {
        guard isEnabled else { return Array(messages.suffix(10)) }
        let folded = Set(store.messages.prefix(store.summarizedCount).map(\.id))
        let unsummarised = messages.filter { !folded.contains($0.id) }
        return Array(unsummarised.suffix(Self.recentTurns))
    }

    func context() -> MemoryContext {
        let relationship = store.relationship
        let today = touchCounts(for: Self.dayKey(Date()))
        let strikesToday = today["boundary"] ?? 0
        let days = store.firstMet.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
        let hours = store.lastChat.map { Date().timeIntervalSince($0) / 3600 }
        return MemoryContext(
            summary: isEnabled ? store.summary : "",
            facts: isEnabled ? Array(facts.prefix(24)) : [],
            friendship: Int(relationship.friendship.rounded()),
            level: Self.level(for: relationship.friendship),
            offended: relationship.offendedSince != nil,
            justForgiven: justForgiven,
            boundaryStrikesToday: strikesToday,
            boundaryPart: relationship.lastBoundaryPart,
            touchesToday: today.filter { $0.key != "boundary" },
            daysKnown: max(0, days),
            hoursSinceLastChat: hours,
            relationshipStatus: relationshipStatus,
            confessionDecision: confessionDecision
        )
    }

    /// What the character page needs to react the way she feels.
    func relationshipPayload() -> [String: Any] {
        let relationship = store.relationship
        let today = touchCounts(for: Self.dayKey(Date()))
        let reset = resetPending
        resetPending = false
        return [
            "reset": reset,
            "friendship": (relationship.friendship * 10).rounded() / 10,
            "level": Self.level(for: relationship.friendship),
            "status": relationshipStatus.rawValue,
            "offended": relationship.offendedSince != nil,
            "strikesToday": today["boundary"] ?? 0,
            "today": today
        ]
    }

    // MARK: - Chat

    /// Called before a message is sent. Returns true if it was an apology that she accepts.
    @discardableResult
    func noteUserMessage(_ text: String) -> Bool {
        justForgiven = false
        confessionDecision = nil
        if store.firstMet == nil { store.firstMet = Date() }
        if isOffended, Self.isApology(text) {
            store.relationship.offendedSince = nil
            store.relationship.friendship = min(100, store.relationship.friendship + 2)
            justForgiven = true
        }
        confessionDecision = ConfessionPolicy.evaluate(
            text,
            friendship: store.relationship.friendship,
            status: relationshipStatus,
            offended: isOffended,
            justForgiven: justForgiven
        )
        if confessionDecision == .accepted {
            store.relationship.status = .dating
        }
        if justForgiven || confessionDecision == .accepted {
            scheduleSave()
            notify()
        }
        return justForgiven
    }

    func record(_ messages: [ChatMessage]) {
        store.lastChat = Date()
        guard isEnabled else {
            scheduleSave()
            return
        }
        store.messages = messages
        if store.messages.count > Self.maxStoredMessages {
            let drop = store.messages.count - Self.maxStoredMessages
            store.messages.removeFirst(drop)
            store.summarizedCount = max(0, store.summarizedCount - drop)
        }
        store.summarizedCount = min(store.summarizedCount, store.messages.count)
        scheduleSave()
    }

    /// Something she said on her own while the chat window wasn't open yet.
    func appendAssistantMessage(_ text: String) {
        guard isEnabled else { return }
        record(store.messages + [ChatMessage(role: .assistant, text: text)])
    }

    /// A completed exchange: warm up a little, then (in the background) fold old turns into
    /// the summary and pick out anything worth remembering.
    func didExchange(user: ChatMessage, reply: ChatMessage, ai: LocalAI) {
        if !isOffended { gainFriendship(0.6, kind: "chat", dailyCap: 6) }
        justForgiven = false
        confessionDecision = nil
        scheduleSave()
        notify()
        guard isEnabled else { return }
        let previous = maintenance
        maintenance = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.extractFacts(user: user, reply: reply, ai: ai)
            await self.summarizeIfNeeded(ai: ai)
        }
    }

    /// The chat window was cleared: forget the conversation itself, keep the facts.
    func clearConversation() {
        store.messages.removeAll()
        store.summarizedCount = 0
        store.summary = ""
        removeUnusedImages()
        scheduleSave()
        notify()
    }

    // MARK: - Pictures

    /// Pictures sent in the chat live in images/ next to memory.json, never inside it.
    private var imagesFolder: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
    }

    /// Stores a picture (already downscaled JPEG data) and returns its file name.
    func saveImage(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).jpg"
        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            try data.write(to: imagesFolder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func imageURL(named name: String) -> URL? {
        // Only plain file names we created ourselves.
        guard name.range(of: #"^[0-9A-F-]{36}\.jpg$"#, options: .regularExpression) != nil else { return nil }
        return imagesFolder.appendingPathComponent(name)
    }

    func imageData(named name: String) -> Data? {
        imageURL(named: name).flatMap { try? Data(contentsOf: $0) }
    }

    /// Deletes pictures no remembered message refers to any more.
    func removeUnusedImages(keeping extra: Set<String> = []) {
        let backupImages = Set(backupStore()?.messages.compactMap(\.imageName) ?? [])
        let used = Set(store.messages.compactMap(\.imageName)).union(backupImages).union(extra)
        guard let files = try? FileManager.default.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" && !used.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Touch

    func recordTouch(_ kind: String, part: String? = nil) {
        guard Self.touchFriendship[kind] != nil || kind == "boundary" else { return }
        let day = Self.dayKey(Date())
        if let index = store.touchDays.firstIndex(where: { $0.day == day }) {
            store.touchDays[index].counts[kind, default: 0] += 1
        } else {
            store.touchDays.append(TouchDay(day: day, counts: [kind: 1]))
            store.touchDays = Array(store.touchDays.suffix(14))
        }
        if store.firstMet == nil { store.firstMet = Date() }

        if kind == "boundary" {
            let again = store.relationship.offendedSince != nil
            store.relationship.friendship = max(0, store.relationship.friendship - (again ? 12 : 8))
            store.relationship.offendedSince = store.relationship.offendedSince ?? Date()
            store.relationship.boundaryStrikes += 1
            store.relationship.lastBoundary = Date()
            store.relationship.lastBoundaryPart = part ?? "chest"
            justForgiven = false
        } else if let change = Self.touchFriendship[kind] {
            if change < 0 {
                store.relationship.friendship = max(0, store.relationship.friendship + change)
            } else if !isOffended {
                gainFriendship(change, kind: "touch", dailyCap: 5)
            }
        }
        scheduleSave()
        notify()
    }

    // MARK: - Settings

    func deleteFact(id: UUID) {
        store.facts.removeAll { $0.id == id }
        scheduleSave()
        notify()
    }

    /// Forget everything about the two of you: chat, summary, facts, touches, friendship.
    /// Her personality and the app settings are not part of memory and stay as they are.
    @discardableResult
    func eraseAll() -> Bool {
        let empty = Store()
        // Keep what she remembered until now as a backup, so the reset can be undone.
        if !store.messages.isEmpty || !store.facts.isEmpty || store.firstMet != nil {
            do {
                try write(store, to: backupURL)
            } catch {
                return false
            }
        }
        do {
            try write(empty, to: fileURL)
        } catch {
            return false
        }
        saveWork?.cancel()
        saveWork = nil
        maintenance?.cancel()
        maintenance = nil
        store = empty
        justForgiven = false
        confessionDecision = nil
        resetPending = true
        removeUnusedImages()
        NotificationCenter.default.post(name: .mikuMemoryErased, object: self)
        notify()
        return true
    }

    // MARK: - Reset backup

    private var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("memory-before-reset.json")
    }

    /// What a reset would make her forget, for the confirmation.
    var resetSummary: (messages: Int, facts: Int, friendship: Int, daysKnown: Int) {
        let days = store.firstMet.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
        return (store.messages.count, store.facts.count, friendship, max(0, days))
    }

    var hasResetBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    private func backupStore() -> Store? {
        guard let data = try? Data(contentsOf: backupURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Store.self, from: data)
    }

    /// Undoes the last reset. Anything new since then is replaced by the backup.
    @discardableResult
    func restoreResetBackup() -> Bool {
        guard var restored = backupStore() else { return false }
        restored.summarizedCount = min(max(0, restored.summarizedCount), restored.messages.count)
        do {
            try write(restored, to: fileURL)
        } catch {
            return false
        }
        saveWork?.cancel()
        saveWork = nil
        maintenance?.cancel()
        maintenance = nil
        store = restored
        justForgiven = false
        confessionDecision = nil
        resetPending = true
        try? FileManager.default.removeItem(at: backupURL)
        removeUnusedImages()
        NotificationCenter.default.post(name: .mikuMemoryRestored, object: self)
        notify()
        return true
    }

    /// Deletes the backup for good (the reset can no longer be undone).
    @discardableResult
    func deleteResetBackup() -> Bool {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                return false
            }
        }
        removeUnusedImages()
        notify()
        return true
    }

    // MARK: - Background work

    private func extractFacts(user: ChatMessage, reply: ChatMessage, ai: LocalAI) async {
        let text = user.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Greetings and one-word answers never hold anything worth keeping.
        guard text.count >= 6 else { return }
        let existing = facts
        guard let result = try? await ai.extractMemories(existing: existing, user: user.text, reply: reply.text) else { return }
        guard isEnabled, !Task.isCancelled else { return }
        apply(result, existing: existing)
    }

    private func summarizeIfNeeded(ai: LocalAI) async {
        let pending = store.messages.count - store.summarizedCount
        guard pending > Self.summarizeThreshold else { return }
        let foldCount = pending - Self.recentTurns
        let start = store.summarizedCount
        let slice = Array(store.messages[start..<(start + foldCount)])
        let ids = Set(slice.map(\.id))
        guard let summary = try? await ai.summarize(previous: store.summary, messages: slice) else { return }
        guard isEnabled, !Task.isCancelled else { return }
        // The chat may have been cleared meanwhile: only advance if those turns are still there.
        let stillThere = store.messages.dropFirst(store.summarizedCount).prefix(foldCount).map(\.id)
        guard Set(stillThere) == ids else { return }
        store.summary = summary
        store.summarizedCount += foldCount
        scheduleSave()
        notify()
    }

    private func apply(_ result: LocalAI.MemoryUpdate, existing: [MemoryFact]) {
        var changed = false
        // "outdated" refers to the numbered list the model was shown.
        let outdated = Set(result.outdated.prefix(3).compactMap { index in
            existing.indices.contains(index - 1) ? existing[index - 1].id : nil
        })
        if !outdated.isEmpty {
            store.facts.removeAll { outdated.contains($0.id) }
            changed = true
        }
        let now = Date()
        for candidate in result.facts.prefix(4) {
            guard let text = Self.cleanFact(candidate.text) else { continue }
            let category = MemoryFact.Category(rawValue: candidate.category) ?? .other
            let key = Self.normalized(text)
            if category == .name, let index = store.facts.firstIndex(where: { $0.category == .name }) {
                store.facts[index].text = text
                store.facts[index].updated = now
            } else if let index = store.facts.firstIndex(where: {
                let other = Self.normalized($0.text)
                return other == key || (key.count >= 6 && other.contains(key)) || (other.count >= 6 && key.contains(other))
            }) {
                // Same thing again: keep the more complete wording.
                if text.count > store.facts[index].text.count { store.facts[index].text = text }
                store.facts[index].updated = now
            } else {
                store.facts.append(MemoryFact(id: UUID(), category: category, text: text, created: now, updated: now))
            }
            changed = true
        }
        if store.facts.count > Self.maxFacts {
            let keep = store.facts.sorted { lhs, rhs in
                if (lhs.category == .name) != (rhs.category == .name) { return lhs.category == .name }
                return lhs.updated > rhs.updated
            }
            store.facts = Array(keep.prefix(Self.maxFacts))
        }
        if changed {
            scheduleSave()
            notify()
        }
    }

    private func gainFriendship(_ amount: Double, kind: String, dailyCap: Double) {
        let key = "\(Self.dayKey(Date()))-\(kind)"
        let gained = store.relationship.dailyGain[key] ?? 0
        let allowed = max(0, min(amount, dailyCap - gained))
        guard allowed > 0 else { return }
        store.relationship.dailyGain[key] = gained + allowed
        // Only the last few days matter for the cap.
        if store.relationship.dailyGain.count > 12 {
            let recent = Set((0..<4).map { Self.dayKey(Date().addingTimeInterval(Double(-$0) * 86_400)) })
            store.relationship.dailyGain = store.relationship.dailyGain.filter { entry in
                recent.contains { entry.key.hasPrefix($0) }
            }
        }
        store.relationship.friendship = min(100, store.relationship.friendship + allowed)
    }

    private func touchCounts(for day: String) -> [String: Int] {
        store.touchDays.first { $0.day == day }?.counts ?? [:]
    }

    // MARK: - Helpers

    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func isApology(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let words = [
            "對不起", "对不起", "對唔住", "对唔住", "唔好意思", "不好意思", "抱歉", "道歉", "我錯", "我错",
            "sorry", "apologi", "my bad", "forgive me",
            "ごめん", "すみません", "すいません", "申し訳", "許して"
        ]
        return words.contains { lowered.contains($0) }
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Keeps only short, plain statements; drops anything that looks like a secret.
    static func cleanFact(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-•*·\"“”「」"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...120).contains(text.count) else { return nil }
        let lowered = text.lowercased()
        let secrets = ["password", "passcode", "密碼", "密码", "パスワード", "credit card", "信用卡", "api key", "token"]
        if secrets.contains(where: { lowered.contains($0) }) { return nil }
        // Long digit runs: card, phone, ID or account numbers.
        if text.range(of: "[0-9][0-9 -]{7,}[0-9]", options: .regularExpression) != nil { return nil }
        return text
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(Store.self, from: data) {
            store = decoded
            store.summarizedCount = min(max(0, store.summarizedCount), store.messages.count)
        } else {
            // Keep the unreadable file for inspection rather than overwriting it.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            _ = MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    @discardableResult
    func saveNow() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        do {
            try write(store, to: fileURL)
            return true
        } catch {
            return false
        }
    }

    private func write(_ value: Store, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func notify() {
        NotificationCenter.default.post(name: .mikuMemoryChanged, object: self)
    }

    // MARK: - Diagnostics

    /// Appends a line from the character page to diagnostics.log next to the memory file.
    func logDiagnostic(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(json)\n"
        NSLog("Miku diagnostic: %@", json)
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += line
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: true).suffix(200)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
