import Foundation

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let status: Int
        let content: String?
        let hangs: Bool
        let chunks: [Data]?
        let failsAfterChunks: Bool
        let hangsAfterChunks: Bool

        init(status: Int = 200, content: String? = nil, hangs: Bool = false,
             chunks: [Data]? = nil, failsAfterChunks: Bool = false, hangsAfterChunks: Bool = false) {
            self.status = status
            self.content = content
            self.hangs = hangs
            self.chunks = chunks
            self.failsAfterChunks = failsAfterChunks
            self.hangsAfterChunks = hangsAfterChunks
        }
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []
    private static var requests: [URLRequest] = []
    private static var finished = false
    private static var deliveredChunks = 0
    private var stopped = false
    private let loadingLock = NSLock()

    static func prepare(_ newStubs: [Stub]) {
        lock.lock()
        stubs = newStubs
        requests = []
        finished = false
        deliveredChunks = 0
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func hasFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    static func chunkCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deliveredChunks
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
        if let path = ProcessInfo.processInfo.environment["MIKU_SYNTHETIC_PROMPT_AUDIT"],
           let data = capturedRequest.httpBody,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = body["messages"] as? [[String: Any]],
           let line = try? JSONSerialization.data(withJSONObject: ["messages": messages]) {
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let file = try? FileHandle(forWritingTo: url) {
                defer { try? file.close() }
                _ = try? file.seekToEnd()
                try? file.write(contentsOf: line + Data([10]))
            }
        }
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
            headerFields: ["Content-Type": stub.chunks == nil ? "application/json" : "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunks = stub.chunks {
            deliver(chunks, index: 0, fails: stub.failsAfterChunks, hangs: stub.hangsAfterChunks)
            return
        }
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

    private func deliver(_ chunks: [Data], index: Int, fails: Bool, hangs: Bool) {
        loadingLock.lock()
        let cancelled = stopped
        loadingLock.unlock()
        guard !cancelled else { return }
        if index < chunks.count {
            Self.lock.lock()
            Self.deliveredChunks += 1
            Self.lock.unlock()
            client?.urlProtocol(self, didLoad: chunks[index])
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { [self] in
                deliver(chunks, index: index + 1, fails: fails, hangs: hangs)
            }
        } else if !hangs {
            Self.lock.lock()
            Self.finished = true
            Self.lock.unlock()
            if fails {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        loadingLock.lock()
        stopped = true
        loadingLock.unlock()
    }
}

private actor VoicePrefixes {
    private(set) var values: [String] = []
    private(set) var receivedBeforeEnd = false
    private(set) var firstChunkCount: Int?

    func append(_ value: String) {
        values.append(value)
        if firstChunkCount == nil { firstChunkCount = StubURLProtocol.chunkCount() }
        if !StubURLProtocol.hasFinished() { receivedBeforeEnd = true }
    }
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
        let knowledgeURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Knowledge/miku-knowledge.json")
        let songs = SongKnowledgeStore(applicationSupportDirectory: temporary, bundledURL: knowledgeURL)
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

        configuration.interfaceLanguage = "zh-Hant"
        let languageCases: [(setting: String, text: String, history: [ChatMessage], expectedPrompt: String)] = [
            ("auto", "오늘도 같이 있어 줘", [], "자연스러운 한국어로"),
            ("auto", "「メルト」 정말 좋지?", [], "자연스러운 한국어로"),
            ("auto", "你聽過《한국 노래》嗎？", [], "使用台灣國語口吻"),
            ("auto", "《한국 노래》", [ChatMessage(role: .user, text: "今天過得怎樣？")], "使用台灣國語口吻"),
            ("auto", "ok", [ChatMessage(role: .user, text: "오늘 어땠어?")], "使用台灣國語口吻"),
            ("ko", "How are you?", [], "자연스러운 한국어로"),
            ("en", "오늘 어땠어?", [], "Reply in natural English"),
            ("auto", "你好", [ChatMessage(role: .user, text: "今日真係好攰，想瞓覺")], "使用台灣國語口吻"),
            ("auto", "你今天過得好嗎？", [ChatMessage(role: .assistant, text: "我今日好開心呀")], "使用台灣國語口吻"),
            ("auto", "今日真係好攰", [], "使用香港粵語口語"),
            ("auto", "メルト", [ChatMessage(role: .user, text: "日本語で話して")], "使用台灣國語口吻"),
            ("auto", "Tell Your World", [], "使用台灣國語口吻"),
            ("auto", "Have you heard メルト?", [], "Reply in natural English"),
            ("auto", "我真的大好き", [], "使用台灣國語口吻"),
            ("auto", "「你聽過」ってどういう意味？", [], "ミク自身として自然な日本語"),
            ("auto", "用日文回答，今天過得怎麼樣？", [], "ミク自身として自然な日本語"),
            ("auto", "請用韓語回答", [], "자연스러운 한국어로"),
            ("auto", "Please reply in English", [], "Reply in natural English"),
            ("auto", "日本語で話して", [], "ミク自身として自然な日本語"),
            ("auto", "한국어로 말해 줘", [], "자연스러운 한국어로"),
            ("auto", "用粵語回答", [], "使用香港粵語口語"),
            ("yue", "請用國語回答", [], "使用台灣國語口吻"),
            ("zh-Hant", "請用日文回答", [], "ミク自身として自然な日本語"),
            ("zh-Hant", "한국어로 말해 줘", [], "자연스러운 한국어로"),
            ("zh-Hant", "광둥어로 대답해 줘", [], "使用香港粵語口語"),
            ("zh-Hant", "Please reply in English", [], "Reply in natural English")
        ]
        for test in languageCases {
            configuration.replyLanguage = test.setting
            StubURLProtocol.prepare([.init(content: replyJSON(text: "응, 곁에 있을게!", outcome: nil))])
            _ = try await ai.reply(to: test.text, history: test.history)
            let body = try requestBody(StubURLProtocol.recordedRequests().first)
            let messages = body["messages"] as? [[String: Any]]
            let prompt = messages?.first?["content"] as? String ?? ""
            try check(prompt.contains(test.expectedPrompt), "Korean routing respects prose, quoted titles and explicit language: \(test.text)")
        }
        configuration.replyLanguage = "auto"
        StubURLProtocol.prepare([.init(content: replyJSON(text: "你好呀！", outcome: nil))])
        _ = try await ai.reply(to: "你好", history: [ChatMessage(role: .user, text: "今日啲嘢好難搞")])
        let mandarinBody = try requestBody(StubURLProtocol.recordedRequests().first)
        let mandarinSystem = (mandarinBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        try check(!mandarinSystem.contains("一律用香港粵語"), "Old Cantonese cannot inject a Cantonese-only instruction into current Mandarin")
        let mandarinFallback = await ai.fallbackConfessionReply(
            for: .notReady, level: 1, to: "你好", history: [ChatMessage(role: .user, text: "我鍾意你")]
        )
        try check(mandarinFallback.text.contains("我們"), "Local relationship fallback also avoids the old Cantonese dialect")

        for setting in ["zh-Hant", "yue", "en", "ja", "ko"] {
            configuration.replyLanguage = setting
            StubURLProtocol.prepare([.init(content: replyJSON(text: "好的。", outcome: nil))])
            let textReply = try await ai.reply(to: "你好", history: [], mode: .text)
            let textBody = try requestBody(StubURLProtocol.recordedRequests().first)
            let textSystem = (textBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            StubURLProtocol.prepare([.init(content: replyJSON(text: "好的。", outcome: nil))])
            let voiceReply = try await ai.reply(to: "你好", history: [], mode: .voice)
            let voiceBody = try requestBody(StubURLProtocol.recordedRequests().first)
            let voiceSystem = (voiceBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            try check(textSystem.contains("text") && voiceSystem.contains("voice"), "Both interaction modes reach the local model: \(setting)")
            try check(textReply.text == voiceReply.text && textReply.action == voiceReply.action && textReply.emotion == voiceReply.emotion,
                      "Reply modes preserve the existing decoded reply schema: \(setting)")
            let format = voiceBody["response_format"] as? [String: Any]
            let json = format?["json_schema"] as? [String: Any]
            let schema = json?["schema"] as? [String: Any]
            try check(Set(schema?["required"] as? [String] ?? []) == Set(["text", "emotion", "action"]),
                      "Voice mode adds no public reply fields: \(setting)")
        }
        configuration.replyLanguage = "zh-Hant"
        StubURLProtocol.prepare([.init(content: replyJSON(text: "今天發生什麼事了？", outcome: nil))])
        _ = try await ai.reply(to: "我今天有點累", history: [])
        let warmBody = try requestBody(StubURLProtocol.recordedRequests().first)
        let warmSystem = (warmBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        try check(warmSystem.contains("可以自然接續一個相關問題") && !warmSystem.contains("不要主動追問"),
                  "The persona can follow up once without an unconditional follow-up prohibition")
        try check(warmSystem.contains("需要解釋時可以說得更完整"), "Ordinary short replies are a default rather than a hard explanation limit")
        var forgivenMemory = MemoryContext.empty
        forgivenMemory.justForgiven = true
        forgivenMemory.forgaveAccident = true
        forgivenMemory.boundaryPart = "skirt"
        StubURLProtocol.prepare([.init(content: replyJSON(text: "沒關係啦～", outcome: nil))])
        _ = try await ai.reply(to: "剛剛是點錯了", history: [], memory: forgivenMemory)
        let forgivenBody = try requestBody(StubURLProtocol.recordedRequests().first)
        let forgivenSystem = (forgivenBody["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        try check(forgivenSystem.contains("已確認是誤觸，不算冒犯"), "Confirmed accidental touches no longer instruct the persona to stay offended")
        try check(!forgivenSystem.contains("下次小心啲"), "Taiwan Mandarin apology guidance contains no old Cantonese example")

        configuration.replyLanguage = "ko"
        let koreanFallback = await ai.fallbackConfessionReply(
            for: .accepted, level: 3, to: "나랑 사귀자", history: []
        )
        try check(koreanFallback.text.contains("사귀자"), "Korean relationship fallback is localised")
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: "응, 나도 좋아해. 오늘부터 사귀자!", outcome: "accepted")),
            .init(content: consistencyJSON(true))
        ])
        _ = try await ai.reply(to: "나랑 사귀자", history: [], memory: acceptedMemory)
        let koreanConsistency = try requestBody(StubURLProtocol.recordedRequests().last)
        let koreanMessages = koreanConsistency["messages"] as? [[String: Any]]
        let koreanPrompt = koreanMessages?.compactMap { $0["content"] as? String }.joined(separator: "\n") ?? ""
        try check(koreanPrompt.contains("EXPECTED REPLY LANGUAGE: Korean (ko)"), "Korean consistency checker receives its selected language")

        try testVoiceStreamParser()
        configuration.replyLanguage = "en"
        let voice = VoicePrefixes()
        let firstPart = #"{"emotion":"happy","text":"  Hello! Next"#
        let lastPart = #" sentence.  ","action":"wave"}"#
        StubURLProtocol.prepare([.init(chunks: [
            streamEvent(firstPart),
            streamEvent(lastPart) + streamEnd()
        ])])
        let streamed = try await ai.reply(to: "Hi", history: [], mode: .voice, onVoiceText: { await voice.append($0) })
        let prefixes = await voice.values
        try check(streamed.text == "Hello! Next sentence.", "Streaming retains the existing full structured decode and trim")
        try check(prefixes == ["Hello!"], "Callbacks expose cumulative stable text without JSON or metadata")
        let receivedEarly = await voice.receivedBeforeEnd
        try check(receivedEarly, "Voice text arrives before the HTTP response finishes")
        let chunksAtFirstCallback = await voice.firstChunkCount
        try check(chunksAtFirstCallback == 1, "The first voice callback precedes the fragment completing reply JSON")
        let streamedBody = try requestBody(StubURLProtocol.recordedRequests().first)
        try check(streamedBody["stream"] as? Bool == true, "Voice requests opt into SSE")
        try check(streamedBody["temperature"] as? Double == 0.2, "Voice streaming preserves generation policy")
        try check(streamedBody["response_format"] != nil, "Voice streaming preserves the structured schema")

        configuration.replyLanguage = "zh-Hant"
        let chineseVoice = VoicePrefixes()
        StubURLProtocol.prepare([.init(chunks: [
            streamEvent(#"{"text":"这是一个测试。现在"#),
            streamEvent(#"继续。","emotion":"calm","action":"nod"}"#) + streamEnd()
        ])])
        let chineseReply = try await ai.reply(to: "你好", history: [], mode: .voice, onVoiceText: { await chineseVoice.append($0) })
        let chinesePrefixes = await chineseVoice.values
        try check(chinesePrefixes == ["這是一個測試。"], "Streaming applies the existing Traditional Chinese conversion first")
        try check(chineseReply.text.hasPrefix(chinesePrefixes.first ?? "missing"), "Converted prefixes remain prefixes of the final reply")
        configuration.replyLanguage = "en"

        let blockedVoice = VoicePrefixes()
        StubURLProtocol.prepare([
            .init(content: replyJSON(text: naturalText, outcome: "accepted")),
            .init(content: consistencyJSON(true))
        ])
        _ = try await ai.reply(to: mixedConfession, history: [], memory: acceptedMemory,
                               onVoiceText: { await blockedVoice.append($0) })
        let bufferedConfessionBody = try requestBody(StubURLProtocol.recordedRequests().first)
        try check(bufferedConfessionBody["stream"] as? Bool == false,
                  "Confessions stay buffered until the independent policy check")
        StubURLProtocol.prepare([.init(content: replyJSON(text: "Can you clarify?", outcome: nil))])
        _ = try await ai.reply(to: "Maybe more?", history: [], relationshipIntent: .uncertain,
                               onVoiceText: { await blockedVoice.append($0) })
        let bufferedUncertainBody = try requestBody(StubURLProtocol.recordedRequests().first)
        try check(bufferedUncertainBody["stream"] as? Bool == false,
                  "Uncertain relationship intent cannot stream unchecked speech")
        let blockedPrefixes = await blockedVoice.values
        try check(blockedPrefixes.isEmpty, "Policy-gated replies never invoke the voice callback")

        StubURLProtocol.prepare([
            .init(chunks: [streamEvent("not JSON")]),
            .init(content: "A buffered fallback.")
        ])
        let fallbackVoice = VoicePrefixes()
        let plainFallback = try await ai.reply(to: "Hello", history: [], onVoiceText: { await fallbackVoice.append($0) })
        try check(plainFallback.text == "A buffered fallback.", "Invalid streams with no emitted voice retain the plain fallback")
        let plainFallbackBody = try requestBody(StubURLProtocol.recordedRequests().last)
        try check(plainFallbackBody["stream"] as? Bool == false,
                  "The fallback uses the existing nonstream request")

        for failure in ["network", "missing-done", "invalid-action", "length"] {
            let failedVoice = VoicePrefixes()
            var chunks = [streamEvent(#"{"text":"Hello! More"#)]
            if failure == "invalid-action" {
                chunks.append(streamEvent(#" text.","emotion":"calm","action":"invalid"}"#) + streamEnd())
            } else if failure == "length" {
                chunks.append(streamEvent("", finishReason: "length"))
            }
            StubURLProtocol.prepare([.init(chunks: chunks, failsAfterChunks: failure == "network")])
            do {
                _ = try await ai.reply(to: "Hi", history: [], onVoiceText: { await failedVoice.append($0) })
                throw TestFailure(message: "A failed stream after speech must throw: \(failure)")
            } catch is TestFailure { throw TestFailure(message: "Failed stream unexpectedly returned: \(failure)") }
            catch {
                let emitted = await failedVoice.values
                try check(emitted == ["Hello!"], "Failure is exercised after audible text: \(failure)")
                try check(StubURLProtocol.recordedRequests().count == 1, "Spoken text is never retried: \(failure)")
            }
        }

        let cancelledVoice = VoicePrefixes()
        StubURLProtocol.prepare([.init(chunks: [streamEvent(#"{"text":"Hello! More"#)], hangsAfterChunks: true)])
        let cancelledStream = Task {
            try await ai.reply(to: "Hi", history: [], onVoiceText: { await cancelledVoice.append($0) })
        }
        for _ in 0..<100 {
            if !(await cancelledVoice.values).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        cancelledStream.cancel()
        let prefixesBeforeCancellation = await cancelledVoice.values
        try check(prefixesBeforeCancellation == ["Hello!"], "Cancellation is exercised after streamed text reaches the caller")
        do {
            _ = try await cancelledStream.value
            throw TestFailure(message: "Voice stream cancellation must throw")
        } catch is CancellationError {
            checks += 1
        }
        try check(StubURLProtocol.recordedRequests().count == 1, "Cancelled speech is never retried")

        StubURLProtocol.prepare([.init(status: 503, chunks: [])])
        do {
            _ = try await ai.reply(to: "Hi", history: [], onVoiceText: { _ in })
            throw TestFailure(message: "Voice HTTP errors must throw")
        } catch LocalAI.LocalAIError.serverResponse(503) { checks += 1 }

        try? FileManager.default.removeItem(at: temporary)
        print("PASS: \(checks) relationship intent AI checks")
    }

    private static func streamEvent(_ fragment: String, finishReason: String? = nil) -> Data {
        let choice: [String: Any] = ["index": 0, "delta": ["content": fragment],
                                     "finish_reason": finishReason as Any? ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return Data("data: \(String(decoding: data, as: UTF8.self))\r\n\r\n".utf8)
    }

    private static func streamEnd() -> Data {
        streamEvent("", finishReason: "stop") + Data("data: [DONE]\n\n".utf8)
    }

    private static func testVoiceStreamParser() throws {
        var stream = LocalAIVoiceStream()
        var prefixes: [String] = []
        let fragments = [
            #"{"other":{"text":"wrong"},"emotion":"happy","te"#,
            #"xt":"Hi \"Miku\"\n\uD8"#,
            #"3D\uDE"#,
            #"00 你好 "#,
            #"\\ \/ \t!","action":"wave"}"#
        ]
        for fragment in fragments {
            for byte in streamEvent(fragment) {
                if let prefix = try stream.consume(byte) { prefixes.append(prefix) }
            }
        }
        for byte in streamEnd() { _ = try stream.consume(byte) }
        try stream.finish()
        try check(prefixes.first == "Hi \"Miku\"\n", "Partial Unicode escapes are withheld without losing decoded text")
        try check(prefixes.contains("Hi \"Miku\"\n😀 你好 "), "SSE decodes fragmented surrogate pairs and UTF-8 bytes")
        try check(prefixes.last == "Hi \"Miku\"\n😀 你好 \\ / \t!", "Escapes become text and nested keys never become voice")

        var multi = LocalAIVoiceStream()
        let envelope = #"{"choices":[{"index":1,"delta":{"content":"{\"text\":\"wrong\"}"}},{"index":0,"delta":{"reasoning_content":"secret","content":"{\"text\":\"Right! Next\",\"emotion\":\"calm\",\"action\":\"idle\"}"}}]}"#
        var selected: String?
        for byte in Data("event: message\n: heartbeat\ndata: \(envelope)\n\n".utf8) {
            if let prefix = try multi.consume(byte) { selected = prefix }
        }
        for byte in streamEnd() { _ = try multi.consume(byte) }
        try multi.finish()
        try check(selected == "Right! Next", "Choice zero is selected by index and reasoning metadata is ignored")

        var multiline = LocalAIVoiceStream()
        let first = #"{"choices":[{"index":0,"delta":{"content":"{\"text\":\"Hello\"}"},"#
        let second = #""finish_reason":null}]}"#
        for byte in Data("data: \(first)\ndata: \(second)\n\n".utf8) { _ = try multiline.consume(byte) }
        for byte in streamEnd() { _ = try multiline.consume(byte) }
        try multiline.finish()
        try check(multiline.content == #"{"text":"Hello"}"#, "Multiple data fields form one SSE event")

        var carriageReturns = LocalAIVoiceStream()
        let carriageData = String(decoding: streamEvent(#"{"te\u0078t":"Hi"}"#) + streamEnd(), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r")
        for byte in carriageData.utf8 { _ = try carriageReturns.consume(byte) }
        try carriageReturns.finish()
        try check(carriageReturns.content.contains("Hi"), "SSE accepts carriage-return framing and escaped root keys")

        for invalid in [#"{"text":"\uDE00"}"#, #"{"text":"\uD800x"}"#,
                        #"{"text":"\q"}"#, #"<think>secret</think>{"text":"Hi"}"#,
                        #"{"text":"First","text":"Second"}"#] {
            do {
                var parser = LocalAIVoiceStream()
                for byte in streamEvent(invalid) { _ = try parser.consume(byte) }
                throw TestFailure(message: "Invalid JSON must fail before it can be spoken")
            } catch is TestFailure { throw TestFailure(message: "Accepted invalid JSON prefix") }
            catch { checks += 1 }
        }
        for ending in [Data(), Data("data: [DONE]\n\n".utf8), streamEvent("", finishReason: "length")] {
            do {
                var parser = LocalAIVoiceStream()
                for byte in streamEvent(#"{"text":"Hello"}"#) + ending { _ = try parser.consume(byte) }
                try parser.finish()
                throw TestFailure(message: "Incomplete or truncated streams must fail")
            } catch is TestFailure { throw TestFailure(message: "Accepted incomplete stream") }
            catch { checks += 1 }
        }
        do {
            var parser = LocalAIVoiceStream()
            for byte in Data("data: ".utf8) + Data([0xFF, 10]) { _ = try parser.consume(byte) }
            throw TestFailure(message: "Invalid UTF-8 must fail")
        } catch is TestFailure { throw TestFailure(message: "Accepted malformed UTF-8") }
        catch { checks += 1 }
        do {
            var parser = LocalAIVoiceStream()
            for byte in streamEvent(#"{"text":""# + String(repeating: "a", count: 66_000)) {
                _ = try parser.consume(byte)
            }
            throw TestFailure(message: "Overlong streams must fail")
        } catch is TestFailure { throw TestFailure(message: "Accepted overlong stream") }
        catch { checks += 1 }
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
