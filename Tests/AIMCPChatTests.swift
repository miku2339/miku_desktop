import Foundation

private final class AIMCPChatModelProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var prompts: [String] = []

    static func reset() { lock.lock(); prompts = []; lock.unlock() }
    static func recordedPrompt() -> String { lock.lock(); defer { lock.unlock() }; return prompts.joined(separator: "\n") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        Self.lock.lock()
        Self.prompts.append(messages.compactMap { $0["content"] as? String }.joined(separator: "\n"))
        Self.lock.unlock()
        let reply = #"{"text":"I checked the available references.","emotion":"happy","action":"nod"}"#
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply]]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor AIMCPChatProbe {
    var status = 200
    var name = "Online Fixture Song"
    private(set) var knowledgeRequests = 0
    private(set) var vocadbRequests = 0

    func prepare(status: Int = 200, name: String = "Online Fixture Song") {
        self.status = status
        self.name = name
    }

    func knowledge(_ request: URLRequest) throws -> (Data, URLResponse) {
        knowledgeRequests += 1
        let item: [String: Any] = [
            "slug": "online-fixture-song", "type": "song", "title": name, "originalTitle": name,
            "summary": "FixtureProducer made this song.", "content": "Only supplied facts.",
            "facts": [["label": "Producer", "value": "FixtureProducer"]],
            "sources": [["label": "VocaDB", "url": "https://vocadb.net/S/45678"]],
            "url": "https://mikuwiki.qimake.com/wiki/online-fixture-song?lang=en",
        ]
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "items": [item]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func vocadb(_ request: URLRequest) -> (Data, URLResponse) {
        vocadbRequests += 1
        return (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@main
private enum AIMCPChatTests {
    private static var checks = 0

    @MainActor
    static func main() async {
        do { try await run() }
        catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-aimcp-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("empty.json")
        let localMention: [String: Any] = [
            "id": "song.mention", "kind": "song", "aliases": ["Offline Mention"], "creators": ["LocalFixtureArtist"],
            "content": ["zh-Hant": "Mentions Online Fixture Song", "en": "Mentions Online Fixture Song", "ja": "Mentions Online Fixture Song"],
            "sourceURL": "https://vocadb.net/S/9876", "featured": false, "sourceStatus": "bundled",
        ]
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "version": "fixture", "entries": [localMention]]).write(to: fixture)
        let defaultsName = "AIMCPChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: VocaDBLookup.enabledKey)
        let configuration = AIConfiguration(defaults: defaults)
        configuration.endpoint = "http://127.0.0.1:9123/v1"
        configuration.model = "fixture"
        configuration.replyLanguage = "en"
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [AIMCPChatModelProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let probe = AIMCPChatProbe()
        let key = "aimcp_" + String(repeating: "f", count: 43)
        let store = SongKnowledgeStore(applicationSupportDirectory: folder, bundledURL: fixture, downloader: { try await probe.knowledge($0) }, apiKeyLoader: { key })
        let vocadb = VocaDBLookup(defaults: defaults, applicationSupportDirectory: folder, fetch: { await probe.vocadb($0) })
        let ai = LocalAI(configuration: configuration, songKnowledge: store, vocaDB: vocadb, session: session)
        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "Do you know Online Fixture Song?", history: [])
        let successfulPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(successfulPrompt.contains("FixtureProducer"), "a real chat request receives online AIMCP factual content")
        try check(successfulPrompt.contains("https://mikuwiki.qimake.com/wiki/online-fixture-song"), "chat receives the Wiki article URL")
        try check(successfulPrompt.contains("https://vocadb.net/S/45678"), "chat receives the original source URL")
        try check(!successfulPrompt.contains(key), "the LLM request never receives the AIMCP key")
        let successRequests = await probe.knowledgeRequests
        let successFallbacks = await probe.vocadbRequests
        try check(successRequests == 1 && successFallbacks == 0, "chat uses AIMCP for a missing offline title before VocaDB")

        configuration.replyLanguage = "auto"
        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "Online Fixture Song 알아?", history: [])
        let koreanPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(koreanPrompt.contains("FixtureProducer"), "Korean song questions receive AIMCP facts")
        try check(koreanPrompt.contains("자연스러운 한국어로"), "Korean song questions keep Korean as the reply language")
        try check(!koreanPrompt.contains(key), "Korean LLM requests never receive the AIMCP key")
        configuration.replyLanguage = "en"

        for status in [401, 403, 429] {
            await probe.prepare(status: status)
            AIMCPChatModelProtocol.reset()
            _ = try await ai.reply(to: "Do you know Online Fixture Song?", history: [])
            let prompt = AIMCPChatModelProtocol.recordedPrompt()
            let fallbacks = await probe.vocadbRequests
            try check(fallbacks == 0, "AIMCP HTTP \(status) cannot silently trigger VocaDB")
            try check(!prompt.contains("FixtureProducer"), "failed authorization does not give the model stale facts")
            try check(status == 429 ? prompt.contains("rate limited") : prompt.contains("key could not be used"), "chat receives the actual AIMCP access failure")
        }

        defaults.set(false, forKey: VocaDBLookup.enabledKey)
        await probe.prepare(name: "A Different Song")
        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "Do you know Online Fixture Song?", history: [])
        let unrelatedPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(!unrelatedPrompt.contains("FixtureProducer"), "an unrelated full-text search hit cannot be mistaken for the asked title")
        try check(unrelatedPrompt.contains("not in the locally verified facts"), "unmatched titles retain the unknown-song boundary")

        var eventMemory = MemoryContext.empty
        eventMemory.events = [
            FetchedEvent(kind: "mikuExpo", year: 2026, city: "London", venue: "Fixture London Hall", start: "2026-11-12", end: "2026-11-12", source: "https://mikuexpo.com/europe2026/"),
            FetchedEvent(kind: "mikuExpo", year: 2027, city: "Paris", venue: "Fixture Paris Hall", start: "2027-11-12", end: "2027-11-12", source: "https://mikuexpo.com/europe2027/"),
            FetchedEvent(kind: "magicalMirai", year: 2026, city: "osaka", venue: "Fixture Mirai Hall", start: "2026-08-14", end: "2026-08-16", source: "https://magicalmirai.com/2026/"),
            FetchedEvent(kind: "mikuWithYou", year: 2026, city: "shanghai", venue: "Fixture Shanghai Hall", start: "2026-10-31", end: "2026-11-01", source: "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/4728/ip/16.html")
        ]
        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "When is MIKU EXPO 2026?", history: [], memory: eventMemory)
        let expoPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(expoPrompt.contains("Fixture London Hall"), "an event chat request receives the requested year's cached venue")
        try check(expoPrompt.contains("https://mikuexpo.com/europe2026/"), "an event chat request retains its official source")
        try check(!expoPrompt.contains("Fixture Paris Hall") && !expoPrompt.contains("europe2027/"), "an explicit event year does not receive another year's schedule")
        try check(!expoPrompt.contains("Fixture Mirai Hall") && !expoPrompt.contains("Fixture Shanghai Hall"), "an event chat request is not mixed with another event series")
        try check(expoPrompt.lowercased().contains("cache"), "the model is told these event facts are cached")
        try check(expoPrompt.contains("not a fresh live lookup") && expoPrompt.contains("Never claim you just browsed"), "cached event results cannot be presented as a live website lookup")

        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "When is MIKU WITH YOU 2027?", history: [], memory: eventMemory)
        let unknownEventPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(!unknownEventPrompt.contains("Fixture Shanghai Hall"), "an unknown event year cannot reuse last year's venue")
        try check(!unknownEventPrompt.contains("Fixture London Hall") && !unknownEventPrompt.contains("Fixture Paris Hall"), "an unknown event does not borrow a different series' schedule")
        try check(unknownEventPrompt.contains("no confirmed matching schedule in the app's cache") && unknownEventPrompt.contains("does not establish that it is unannounced"), "a missing cached schedule is unconfirmed rather than assumed unannounced")

        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(to: "When is MIKU EXPO 2026?", history: [], memory: eventMemory, mode: .voice)
        let voiceEventPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(voiceEventPrompt.contains("Fixture London Hall") && voiceEventPrompt.contains("https://mikuexpo.com/europe2026/"), "voice replies receive the same verified event facts and source")
        try check(!voiceEventPrompt.contains("Fixture Paris Hall"), "voice replies keep the requested event year")

        let lookupCount = await probe.knowledgeRequests
        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(
            to: "What am I listening to?", history: [],
            listening: ListeningContext(song: "Unlisted track — LocalFixtureArtist", video: #"A "quoted" title"#, videoIsRecent: true)
        )
        let mediaPrompt = AIMCPChatModelProtocol.recordedPrompt()
        try check(mediaPrompt.contains(#""recentVideo":"A \"quoted\" title""#), "cached video titles are encoded as recent, escaped data")
        try check(!mediaPrompt.contains("Mentions Online Fixture Song"), "the playing song does not inherit another song's facts based on artist")
        try check(await probe.knowledgeRequests == lookupCount, "observed media does not trigger a Wiki lookup")

        AIMCPChatModelProtocol.reset()
        _ = try await ai.reply(
            to: "What am I listening to?", history: [],
            listening: ListeningContext(song: "Offline Mention — LocalFixtureArtist")
        )
        try check(AIMCPChatModelProtocol.recordedPrompt().contains("Mentions Online Fixture Song"), "a matching playing title can include offline credits")
        print("AIMCP chat: \(checks) checks passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
    }

    private struct Failure: Error { let message: String }
}
