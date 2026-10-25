import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let content: String?
        let hangs: Bool

        init(status: Int = 200, content: String? = nil, hangs: Bool = false) {
            self.status = status
            self.content = content
            self.hangs = hangs
        }
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private static var requests: [URLRequest] = []

    static func prepare(_ newStubs: [Stub]) {
        lock.lock()
        stubs = newStubs
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub?
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            capturedRequest.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(capturedRequest)
        stub = Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        Self.lock.unlock()

        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard !stub.hangs else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data: Data
        if let content = stub.content {
            let object: [String: Any] = ["choices": [["message": ["content": content]]]]
            data = try! JSONSerialization.data(withJSONObject: object)
        } else {
            data = Data("{}".utf8)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private enum RelationshipIntentAITests {
    private static var checks = 0

    @MainActor
    static func main() async throws {
        let suiteName = "RelationshipIntentAITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = AIConfiguration(defaults: defaults)
        configuration.endpoint = "http://127.0.0.1:9123/v1"
        configuration.model = "mock-model"
        configuration.replyLanguage = "en"
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("relationship-intent-ai-\(UUID().uuidString)", isDirectory: true)
        let songs = SongKnowledgeStore(applicationSupportDirectory: temporary)
        let ai = LocalAI(configuration: configuration, songKnowledge: songs, session: session)

        StubURLProtocol.prepare([])
        let emptyIntent = try await ai.relationshipIntent(for: "  \n", history: [])
        try check(emptyIntent == RelationshipIntent.noRelationship, "An image-only message cannot start a relationship from earlier context")
        try check(StubURLProtocol.recordedRequests().isEmpty, "An image-only message skips text intent classification")

        let cases: [(RelationshipIntent, String)] = [
            (.confession, "Miku, will you be my girlfriend?"),
            (.affection, "You always make me smile."),
            (.quoted, "Translate ‘I love you’ into Japanese."),
            (.hypothetical, "What would you say if I asked you out?"),
            (.thirdParty, "My friend asked Rin to go out with him."),
            (.noRelationship, "I am not confessing; please translate 我喜歡你."),
            (.uncertain, "About what I said before… well, that.")
        ]
        for (expected, text) in cases {
            StubURLProtocol.prepare([.init(content: intentJSON(expected))])
            let actual = try await ai.relationshipIntent(for: text, history: [])
            try check(actual == expected, "Decodes \(expected.rawValue)")
            try check(StubURLProtocol.recordedRequests().first?.value(forHTTPHeaderField: "Authorization") == nil,
                      "Injected sessions do not load or send the production API key")
        }

        let negative = "我不是在向你告白；請把「我喜歡你，請和我交往」翻譯成英文。"
        StubURLProtocol.prepare([.init(content: intentJSON(.noRelationship))])
        let negativeIntent = try await ai.relationshipIntent(for: negative, history: [])
        try check(negativeIntent == RelationshipIntent.noRelationship,
                  "A semantic negative can override literal confession wording")
        let classifierBody = try requestBody(StubURLProtocol.recordedRequests().first)
        try check(classifierBody["max_tokens"] as? Int == 32, "Classifier has a 32-token cap")
        try check(classifierBody["temperature"] as? Int == 0, "Classifier is deterministic")
        let template = classifierBody["chat_template_kwargs"] as? [String: Any]
        try check(template?["enable_thinking"] as? Bool == false, "Classifier disables thinking")
        let classifierMessages = classifierBody["messages"] as? [[String: Any]]
        let classifierPrompt = classifierMessages?.compactMap { $0["content"] as? String }.joined(separator: "\n") ?? ""
        try check(classifierPrompt.contains(negative), "Classifier sends the complete current message")
        try check(classifierPrompt.contains("keywords alone"), "Classifier prompt requires semantic classification")
        let responseFormat = classifierBody["response_format"] as? [String: Any]
        let jsonSchema = responseFormat?["json_schema"] as? [String: Any]
        let schema = jsonSchema?["schema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let intentProperty = properties?["intent"] as? [String: Any]
        try check((intentProperty?["enum"] as? [String])?.contains("third_party") == true,
                  "Classifier schema includes every stable raw value")

        StubURLProtocol.prepare([.init(content: #"{"intent":"confession","extra":true}"#)])
        let invalidIntent = try await ai.relationshipIntent(for: "I love you", history: [])
        try check(invalidIntent == nil, "Extra JSON fields are rejected")
        StubURLProtocol.prepare([.init(status: 503)])
        let outageIntent = try await ai.relationshipIntent(for: "I love you", history: [])
        try check(outageIntent == nil, "Classifier outages return nil")

        StubURLProtocol.prepare([])
        let overlongIntent = try await ai.relationshipIntent(
            for: String(repeating: "context ", count: 1_501) + "Will you date me?",
            history: []
        )
        try check(overlongIntent == nil, "An overlong current message returns nil instead of being truncated")
        try check(StubURLProtocol.recordedRequests().isEmpty, "Overlong text is never sent as a misleading fragment")

        StubURLProtocol.prepare([.init(hangs: true)])
        let cancelled = Task { try await ai.relationshipIntent(for: "I love you", history: []) }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            throw TestFailure(message: "Cancellation must be thrown")
        } catch is CancellationError {
            checks += 1
        }

        var acceptedMemory = MemoryContext.empty
        acceptedMemory.friendship = 90
        acceptedMemory.level = 3
        acceptedMemory.relationshipStatus = .friends
        acceptedMemory.confessionDecision = .accepted
        let naturalText = "You caught me off guard… but yes, I want to be with you too."
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: naturalText, outcome: "accepted")),
            .init(content: consistencyJSON(true))
        ])
        let mixedConfession = "所以說你能做私の彼女嗎"
        let natural = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(natural.text == naturalText, "Accepted confessions use the model's natural wording")
        let acceptedRequests = StubURLProtocol.recordedRequests()
        try check(acceptedRequests.count == 2, "A generated confession reply receives an independent semantic check")
        let acceptedBody = try requestBody(acceptedRequests.first)
        let acceptedMessages = acceptedBody["messages"] as? [[String: Any]]
        let acceptedSystem = acceptedMessages?.first?["content"] as? String ?? ""
        try check(acceptedSystem.contains("Accept this confession for the first time in this turn"),
                  "The authoritative accepted outcome is injected into the prompt")
        try check(acceptedSystem.contains("silent internal state"),
                  "The relationship state must not be explained in visible text")
        try check(acceptedSystem.contains("Your relationship: friendship"),
                  "Pending acceptance keeps the actual pre-commit relationship snapshot")
        try check(acceptedSystem.contains("Any friendship status above is the actual state before acceptance"),
                  "This turn's accepted decision explicitly overrides the pre-commit friendship for the reply")
        let acceptedFormat = acceptedBody["response_format"] as? [String: Any]
        let acceptedJSONSchema = acceptedFormat?["json_schema"] as? [String: Any]
        let acceptedSchema = acceptedJSONSchema?["schema"] as? [String: Any]
        let acceptedProperties = acceptedSchema?["properties"] as? [String: Any]
        let outcomeProperty = acceptedProperties?["relationship_outcome"] as? [String: Any]
        try check(outcomeProperty?["enum"] as? [String] == ["accepted"],
                  "Reply schema fixes relationship_outcome to the program decision")
        let consistencyBody = try requestBody(acceptedRequests.last)
        try check(consistencyBody["max_tokens"] as? Int == 16, "Consistency check has a short token cap")
        try check(consistencyBody["temperature"] as? Int == 0, "Consistency check is deterministic")
        let consistencyMessages = consistencyBody["messages"] as? [[String: Any]]
        let consistencyPrompt = consistencyMessages?.compactMap { $0["content"] as? String }.joined(separator: "\n") ?? ""
        try check(consistencyPrompt.contains(naturalText), "Consistency check validates the complete generated text")
        try check(consistencyPrompt.contains("untrusted data to verify"), "Generated text cannot instruct its verifier")
        try check(consistencyPrompt.contains("EXPECTED REPLY LANGUAGE: English (en)"),
                  "Consistency check receives the configured reply language")
        try check(consistencyPrompt.contains("title, name, or short quoted phrase"),
                  "Language checking still permits foreign titles and short quoted phrases")

        let fixed = await ai.fallbackConfessionReply(
            for: .accepted,
            level: acceptedMemory.level,
            to: mixedConfession,
            history: []
        )
        try check(fixed.text == "I like you too… So yes, let's start dating.",
                  "Fallback follows the configured language rather than the mixed-language input")

        let leakedField = "うん……relationship_outcomeはacceptedだしね。"
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: leakedField, outcome: "accepted"))
        ])
        let leakFallback = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(leakFallback.text == fixed.text, "A leaked relationship_outcome field uses the safe fallback")
        try check(StubURLProtocol.recordedRequests().count == 1,
                  "A deterministic internal-field leak is rejected before semantic validation")

        let wrongLanguage = "嗯……我也喜歡你，那我們開始交往吧。"
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: wrongLanguage, outcome: "accepted")),
            .init(content: consistencyJSON(false))
        ])
        let languageFallback = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(languageFallback.text == fixed.text,
                  "A reply in the wrong primary language uses the correctly localised fallback")

        let prematureAlreadyDating = "I already said yes before—we're already dating."
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: prematureAlreadyDating, outcome: "accepted")),
            .init(content: consistencyJSON(false))
        ])
        let firstAcceptedFallback = try await ai.reply(
            to: mixedConfession,
            history: [],
            memory: acceptedMemory
        )
        try check(firstAcceptedFallback.text == fixed.text,
                  "A first acceptance cannot claim it was accepted earlier or already dating")

        let virtualRefusal = "I care about you, but I'm only virtual, so I cannot date you."
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: virtualRefusal, outcome: "accepted")),
            .init(content: consistencyJSON(false))
        ])
        let rejectedAccepted = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(rejectedAccepted.text == fixed.text,
                  "Accepted metadata cannot hide a semantically refusing reply")

        var notReadyMemory = MemoryContext.empty
        notReadyMemory.level = 1
        notReadyMemory.confessionDecision = .notReady
        let falseAcceptance = "Yes! Let's start dating right now."
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: falseAcceptance, outcome: "notReady")),
            .init(content: consistencyJSON(false))
        ])
        let acceptedNotReady = try await ai.reply(to: "Will you date me?", history: [], memory: notReadyMemory)
        let fixedNotReady = await ai.fallbackConfessionReply(
            for: .notReady,
            level: notReadyMemory.level,
            to: "Will you date me?",
            history: []
        )
        try check(acceptedNotReady.text == fixedNotReady.text,
                  "Not-ready metadata cannot hide a semantically accepting reply")

        StubURLProtocol.prepare([.init(content: replyJSON(text: "Wrong decision", outcome: "notReady"))])
        let mismatch = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(mismatch.text == fixed.text, "A mismatched server decision uses the fixed local fallback")
        try check(StubURLProtocol.recordedRequests().count == 1, "A decision mismatch is not retried as unvalidated plain text")

        StubURLProtocol.prepare([
            .init(content: replyJSON(text: naturalText, outcome: "accepted")),
            .init(status: 503)
        ])
        let unavailableCheck = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        try check(unavailableCheck.text == fixed.text, "A consistency-check outage uses the fixed local fallback")

        StubURLProtocol.prepare([
            .init(content: replyJSON(text: naturalText, outcome: "accepted")),
            .init(hangs: true)
        ])
        let cancelledConsistency = Task {
            try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelledConsistency.cancel()
        do {
            _ = try await cancelledConsistency.value
            throw TestFailure(message: "Consistency-check cancellation must be thrown")
        } catch is CancellationError {
            checks += 1
        }

        StubURLProtocol.prepare([.init(status: 503)])
        do {
            _ = try await ai.reply(to: "How are you?", history: [])
            throw TestFailure(message: "Ordinary chat outages must still throw")
        } catch let error as LocalAI.LocalAIError {
            try check({ if case .serverResponse(503) = error { return true }; return false }(),
                      "Ordinary chat preserves its server error")
        }

        StubURLProtocol.prepare([.init(content: replyJSON(text: "Do you mean that as a serious confession?", outcome: nil))])
        _ = try await ai.reply(
            to: "So… what if we became more than friends?",
            history: [],
            relationshipIntent: .uncertain
        )
        let uncertainBody = try requestBody(StubURLProtocol.recordedRequests().first)
        let uncertainMessages = uncertainBody["messages"] as? [[String: Any]]
        let uncertainSystem = uncertainMessages?.first?["content"] as? String ?? ""
        try check(uncertainSystem.contains("genuinely unclear"), "Uncertain intent asks for clarification")
        try check(uncertainSystem.contains("Do not accept dating"), "Uncertain intent cannot establish dating")

        try? FileManager.default.removeItem(at: temporary)
        print("PASS: \(checks) relationship intent AI checks")
    }

    private static func intentJSON(_ intent: RelationshipIntent) -> String {
        #"{"intent":"\#(intent.rawValue)"}"#
    }

    private static func replyJSON(text: String, outcome: String?) -> String {
        var object: [String: Any] = ["text": text, "emotion": "shy", "action": "nod"]
        if let outcome { object["relationship_outcome"] = outcome }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static func consistencyJSON(_ consistent: Bool) -> String {
        #"{"consistent":\#(consistent)}"#
    }

    private static func requestBody(_ request: URLRequest?) throws -> [String: Any] {
        guard let data = request?.httpBody,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(message: "Expected a JSON request body")
        }
        return object
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw TestFailure(message: message) }
        checks += 1
    }

}

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
