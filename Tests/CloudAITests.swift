import Foundation
import Security

/// Records every chat request and answers with the next queued status (200 = a good reply).
private final class CloudAIProtocol: URLProtocol, @unchecked Sendable {
    struct Seen {
        let url: URL
        let authorization: String?
        let body: [String: Any]
    }

    private static let lock = NSLock()
    private static var seen: [Seen] = []
    private static var statuses: [Int] = []

    static func reset(statuses: [Int] = []) {
        lock.lock(); seen = []; self.statuses = statuses; lock.unlock()
    }
    static func requests() -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

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
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        Self.lock.lock()
        Self.seen.append(Seen(url: request.url!, authorization: request.value(forHTTPHeaderField: "Authorization"), body: body))
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        Self.lock.unlock()

        let isList = request.url!.path.hasSuffix("/models")
        let reply: Data
        if isList {
            reply = try! JSONSerialization.data(withJSONObject: ["data": [["id": "cloud-fixture"]]])
        } else if body["response_format"] == nil {
            reply = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "Plain hello from the cloud."]]]])
        } else {
            let content = #"{"text":"Hello from the cloud.","emotion":"happy","action":"wave"}"#
            reply = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? reply : Data(#"{"error":"nope"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An in-memory Keychain for CloudAIKey.
private final class MemoryKeychain: @unchecked Sendable {
    var items: [String: Data] = [:]

    var store: AIMCPKeychainStore {
        AIMCPKeychainStore(
            copyMatching: { query in
                let key = "\(query[kSecAttrService as String]!)/\(query[kSecAttrAccount as String]!)"
                guard let data = self.items[key] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            },
            update: { query, attributes in
                let key = "\(query[kSecAttrService as String]!)/\(query[kSecAttrAccount as String]!)"
                guard self.items[key] != nil else { return errSecItemNotFound }
                self.items[key] = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { item in
                let key = "\(item[kSecAttrService as String]!)/\(item[kSecAttrAccount as String]!)"
                self.items[key] = item[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { query in
                let key = "\(query[kSecAttrService as String]!)/\(query[kSecAttrAccount as String]!)"
                return self.items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
            }
        )
    }
}

private final class KeyBox: @unchecked Sendable {
    var value: String?
    init(_ value: String?) { self.value = value }
}

@main
private enum CloudAITests {
    private static var checks = 0

    @MainActor
    static func main() async {
        do {
            try await run()
            print("Cloud AI: \(checks) checks passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    private static func run() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-cloud-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = folder.appendingPathComponent("songs.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "version": "fixture", "entries": []]).write(to: fixture)

        let suite = "CloudAITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Settings: local by default, cloud values kept apart, sharing off until turned on.
        let fresh = AIConfiguration(defaults: defaults)
        try check(!fresh.usesCloud && fresh.sharesAwarenessWithAI, "a new install uses the local AI")
        fresh.provider = "cloud"
        fresh.cloudEndpoint = "https://api.example.com/v1"
        fresh.cloudModel = "cloud-fixture"
        fresh.save()
        let reloaded = AIConfiguration(defaults: defaults)
        try check(reloaded.usesCloud && reloaded.activeEndpoint == "https://api.example.com/v1"
                  && reloaded.activeModel == "cloud-fixture", "the cloud choice and its endpoint and model are remembered")
        try check(reloaded.endpoint == "http://127.0.0.1:8000/v1", "the local endpoint is kept for switching back")
        try check(!reloaded.sharesAwarenessWithAI, "the screen, apps and media stay on this Mac by default")
        try check(defaults.dictionaryRepresentation().values.allSatisfy { "\($0)".contains("sk-") == false },
                  "no key ends up in the settings")

        // The key lives in the Keychain only.
        let keychain = MemoryKeychain()
        try check(CloudAIKey.load(keychain: keychain.store) == nil, "no key at first")
        try CloudAIKey.save("  sk-fixture-123  ", keychain: keychain.store)
        try check(CloudAIKey.load(keychain: keychain.store) == "sk-fixture-123", "a pasted key is trimmed and stored")
        try CloudAIKey.save("", keychain: keychain.store)
        try check(CloudAIKey.hasKey(keychain: keychain.store), "an empty field never wipes the saved key")
        var rejected = false
        do { try CloudAIKey.save("two words", keychain: keychain.store) } catch { rejected = true }
        try check(rejected, "a key with spaces inside is refused")
        try CloudAIKey.clear(keychain: keychain.store)
        try check(!CloudAIKey.hasKey(keychain: keychain.store), "the key can be removed")

        let configuration = AIConfiguration(defaults: defaults)
        configuration.replyLanguage = "en"
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CloudAIProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let store = SongKnowledgeStore(applicationSupportDirectory: folder, bundledURL: fixture, downloader: { _ in throw URLError(.notConnectedToInternet) }, apiKeyLoader: { nil })
        let vocadb = VocaDBLookup(defaults: defaults, applicationSupportDirectory: folder, fetch: { request in
            (Data(#"{"items":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let key = KeyBox("sk-fixture-123")
        let ai = LocalAI(configuration: configuration, songKnowledge: store, vocaDB: vocadb, session: session, cloudAPIKey: { key.value })

        // Cloud: HTTPS, the user's key, the cloud model, no local-only options.
        CloudAIProtocol.reset()
        let reply = try await ai.reply(to: "Hi!", history: [])
        let first = CloudAIProtocol.requests()
        try check(reply.text == "Hello from the cloud.", "a cloud reply comes back")
        try check(first.count == 1 && first[0].url.absoluteString == "https://api.example.com/v1/chat/completions",
                  "the request goes to the cloud endpoint")
        try check(first[0].authorization == "Bearer sk-fixture-123", "the user's key is sent to that endpoint")
        try check(first[0].body["model"] as? String == "cloud-fixture", "the cloud model is asked")
        try check(first[0].body["chat_template_kwargs"] == nil, "local-only options are left out for the cloud")
        try check(!"\(first[0].body)".contains("sk-fixture-123"), "the key is never in the prompt")

        // A service that refuses the JSON schema gets one plain retry.
        CloudAIProtocol.reset(statuses: [400])
        let plain = try await ai.reply(to: "Hi again!", history: [])
        let retried = CloudAIProtocol.requests()
        try check(retried.count == 2 && retried[1].body["response_format"] == nil, "a refused schema is retried without it")
        try check(plain.text == "Plain hello from the cloud.", "the plain reply is used")

        for status in [400, 422] {
            CloudAIProtocol.reset(statuses: [status])
            let voice = try await ai.reply(to: "Voice fixture", history: [], mode: .voice, onVoiceText: { _ in })
            let requests = CloudAIProtocol.requests()
            try check(requests.count == 2 && requests[0].body["stream"] as? Bool == true
                      && requests[1].body["response_format"] == nil,
                      "voice retries a refused schema without it (HTTP \(status))")
            try check(voice.text == "Plain hello from the cloud.", "voice uses the plain retry (HTTP \(status))")
        }

        // An observation queued under local settings must not follow a switch to the cloud.
        configuration.provider = "local"
        let queuedObservation = "Fixture app observed before changing providers"
        let queuedScreen = Data("fixture-screen".utf8)
        configuration.provider = "cloud"
        CloudAIProtocol.reset()
        var cancelledObservation = false
        do {
            _ = try await ai.reply(to: queuedObservation, image: queuedScreen, history: [], requiresAwarenessSharing: true)
        } catch is CancellationError {
            cancelledObservation = true
        }
        try check(cancelledObservation && CloudAIProtocol.requests().isEmpty,
                  "an old app or screen observation cannot go to the cloud after switching providers")
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: "Welcome back fixture", history: [])
        try check(CloudAIProtocol.requests().count == 1, "a generic greeting still works with awareness sharing off")
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: "Please look at this attached fixture", image: queuedScreen, history: [])
        let attachmentMessages = CloudAIProtocol.requests().first?.body["messages"] as? [[String: Any]]
        try check(attachmentMessages?.last?["content"] is [[String: Any]],
                  "a picture explicitly sent by the user still goes to their cloud AI")
        configuration.cloudSharesAwareness = true
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: queuedObservation, image: queuedScreen, history: [], requiresAwarenessSharing: true)
        try check(CloudAIProtocol.requests().count == 1, "sharing allows an app or screen observation")
        configuration.cloudSharesAwareness = false
        CloudAIProtocol.reset()
        cancelledObservation = false
        do {
            _ = try await ai.reply(to: queuedObservation, image: queuedScreen, history: [], requiresAwarenessSharing: true)
        } catch is CancellationError {
            cancelledObservation = true
        }
        try check(cancelledObservation && CloudAIProtocol.requests().isEmpty,
                  "turning cloud sharing off also blocks an already collected screen observation")

        // What's playing stays out of cloud prompts unless the user shares it.
        let listening = ListeningContext(song: "CloudFixtureTitle — Somebody")
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: "What am I listening to?", history: [], listening: listening)
        try check(!"\(CloudAIProtocol.requests().first?.body ?? [:])".contains("CloudFixtureTitle"), "media titles are not sent to the cloud by default")
        configuration.cloudSharesAwareness = true
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: "What am I listening to?", history: [], listening: listening)
        try check("\(CloudAIProtocol.requests().first?.body ?? [:])".contains("CloudFixtureTitle"), "media titles are sent once the user shares them")
        configuration.cloudSharesAwareness = false

        // Connection check uses the key too.
        CloudAIProtocol.reset()
        let connection = await ai.checkConnection()
        try check(connection.reachable && connection.modelAvailable == true, "the connection check finds the cloud model")
        try check(CloudAIProtocol.requests().first?.authorization == "Bearer sk-fixture-123", "the connection check sends the key")

        // Without a key nothing is sent.
        key.value = nil
        CloudAIProtocol.reset()
        var missingKey = false
        do { _ = try await ai.reply(to: "Hi!", history: []) } catch let error as LocalAI.LocalAIError {
            if case .missingAPIKey = error { missingKey = true }
        }
        try check(missingKey && CloudAIProtocol.requests().isEmpty, "without a key no request leaves this Mac")
        key.value = "sk-fixture-123"

        // Keys only travel encrypted.
        configuration.cloudEndpoint = "http://api.example.com/v1"
        CloudAIProtocol.reset()
        var refused = false
        do { _ = try await ai.reply(to: "Hi!", history: []) } catch let error as LocalAI.LocalAIError {
            if case .invalidEndpoint = error { refused = true }
        }
        try check(refused && CloudAIProtocol.requests().isEmpty, "a plain-http cloud endpoint is refused")
        configuration.cloudEndpoint = "https://api.example.com/v1"

        // Local: as before. The cloud key never goes to the local server.
        configuration.provider = "local"
        configuration.endpoint = "http://127.0.0.1:9123/v1"
        configuration.model = "local-fixture"
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: "Hi!", history: [], listening: listening)
        let local = CloudAIProtocol.requests()
        try check(local.first?.url.host == "127.0.0.1" && local.first?.authorization == nil, "the local AI never receives the cloud key")
        try check(local.first?.body["chat_template_kwargs"] != nil, "local requests keep their options")
        try check("\(local.first?.body ?? [:])".contains("CloudFixtureTitle"), "the local AI still hears what's playing")
        CloudAIProtocol.reset()
        _ = try await ai.reply(to: queuedObservation, image: queuedScreen, history: [], requiresAwarenessSharing: true)
        try check(CloudAIProtocol.requests().count == 1, "local observations still work without cloud sharing")
        configuration.endpoint = "https://api.example.com/v1"
        var localRefused = false
        do { _ = try await ai.reply(to: "Hi!", history: []) } catch let error as LocalAI.LocalAIError {
            if case .invalidEndpoint = error { localRefused = true }
        }
        try check(localRefused, "the local choice still only talks to this Mac")

        // Messages say what's wrong with the cloud, not with oMLX.
        let auth = LocalAI.message(for: LocalAI.LocalAIError.serverResponse(401), endpoint: "", model: "m", cloud: true)
        try check(auth == L10n.text("errorAuthCloud"), "a refused key is explained as a cloud key problem")
        let missing = LocalAI.message(for: LocalAI.LocalAIError.missingAPIKey, endpoint: "", model: "m", cloud: true)
        try check(missing == L10n.text("errorCloudKeyMissing"), "a missing key says where to add it")
        let busy = LocalAI.message(for: LocalAI.LocalAIError.serverResponse(429), endpoint: "", model: "m", cloud: true)
        try check(busy == L10n.text("errorRateLimited"), "a used-up quota is explained")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
    }

    private struct Failure: Error { let message: String }
}
