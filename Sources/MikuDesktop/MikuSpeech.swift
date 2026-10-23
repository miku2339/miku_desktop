import AVFoundation
import Foundation
import Security

private final class MikuSpeechNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private enum MikuSpeechKeychain {
    static let service = "com.qimake.MikuDesktop.tts"
    static let account = "miku-four-language-gpt-sovits-v2"

    enum KeychainError: LocalizedError {
        case invalidToken
        case unexpectedData
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return L10n.text("speechErrorInvalidToken")
            case .unexpectedData:
                return L10n.text("speechErrorKeychainRead")
            case let .osStatus(status):
                return L10n.format("speechErrorKeychainStatus", String(status))
            }
        }
    }

    static func store(_ token: String) throws {
        guard isValid(token) else {
            throw KeychainError.invalidToken
        }
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.osStatus(updated) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.osStatus(added) }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        guard isValid(token) else { throw KeychainError.invalidToken }
        return token
    }

    private static func isValid(_ token: String) -> Bool {
        (43...16_384).contains(token.utf8.count)
            && token.unicodeScalars.allSatisfy { scalar in
                (0x30...0x39).contains(scalar.value)
                    || (0x41...0x5A).contains(scalar.value)
                    || (0x61...0x7A).contains(scalar.value)
                    || scalar == "_"
                    || scalar == "-"
            }
    }
}

@MainActor
final class MikuSpeech: NSObject, AVAudioPlayerDelegate {
    static let shared = MikuSpeech()

    enum Language: String, CaseIterable {
        case automatic = "auto"
        case cantonese = "yue"
        case mandarin = "zh"
        case japanese = "ja"
        case english = "en"
    }

    enum SpeechError: LocalizedError {
        case invalidEndpoint
        case connectionUnavailable
        case launcherUnavailable
        case launcherFailed
        case invalidResponse
        case wrongProfile
        case serverResponse(Int)
        case missingAccessToken
        case unverifiedConnection
        case emptyText
        case textTooLong
        case generationFailed
        case invalidAudio

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return L10n.text("speechErrorInvalidEndpoint")
            case .connectionUnavailable:
                return L10n.text("speechErrorConnectionUnavailable")
            case .launcherUnavailable:
                return L10n.text("speechErrorLauncherUnavailable")
            case .launcherFailed:
                return L10n.text("speechErrorLauncherFailed")
            case .invalidResponse:
                return L10n.text("speechErrorInvalidResponse")
            case .wrongProfile:
                return L10n.text("speechErrorWrongProfile")
            case let .serverResponse(status):
                return L10n.format("speechErrorHTTP", String(status))
            case .missingAccessToken:
                return L10n.text("speechErrorMissingToken")
            case .unverifiedConnection:
                return L10n.text("speechErrorUnverifiedConnection")
            case .emptyText:
                return L10n.text("speechErrorEmptyText")
            case .textTooLong:
                return L10n.text("speechErrorTextTooLong")
            case .generationFailed:
                return L10n.text("speechErrorGenerationFailed")
            case .invalidAudio:
                return L10n.text("speechErrorInvalidAudio")
            }
        }
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "speechEnabled")
            if !enabled {
                stop()
            } else {
                setState(busy: false, key: "speechReady")
            }
        }
    }

    var language: Language {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: "speechLanguage")
            notifyStateChanged()
        }
    }

    private(set) var isBusy = false
    var status: String {
        statusError?.localizedDescription ?? L10n.text(statusKey)
    }
    var onStateChanged: (() -> Void)?

    var hasAccessToken: Bool {
        guard let token = try? MikuSpeechKeychain.load() else { return false }
        return !token.isEmpty
    }

    private struct ConnectionConfiguration: Decodable {
        let endpoint: String?
        let launcherPath: String?
        let launcherConfig: String?

        enum CodingKeys: String, CodingKey {
            case endpoint
            case launcherPath = "launcher_path"
            case launcherConfig = "launcher_config"
        }
    }

    private struct HealthResponse: Decodable {
        let status: String
        let engineReady: Bool
        let profileID: String
        let profileSHA256: String
        let authRequired: Bool

        enum CodingKeys: String, CodingKey {
            case status
            case engineReady = "engine_ready"
            case profileID = "profile_id"
            case profileSHA256 = "profile_sha256"
            case authRequired = "auth_required"
        }
    }

    private struct CreateJobRequest: Encodable {
        let language: String
        let text: String
        let seed: Int?
    }

    private struct JobResponse: Decodable {
        let id: String
        let status: String
        let audioURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case status
            case audioURL = "audio_url"
        }
    }

    private static let profileID = "miku-four-language-gpt-sovits-v2"
    private static let profileSHA256 = "85a367fe5d21da466e2cb03182561ab11b012a24b2eb342e2bc6e2b64edad145"
    private static let defaultEndpoint = MikuSpeechAuthorization.officialEndpoint
    private static let maximumTextLength = 2_000
    private static let maximumAudioBytes = 64 * 1_024 * 1_024
    private static let jobIDPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{32}$")

    private let defaults: UserDefaults
    private let loopbackSession: URLSession
    private let httpsSession: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var bootstrapTask: Task<Void, Error>?
    private var statusKey: String
    private var statusError: Error?

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "speechEnabled") as? Bool ?? false
        language = Language(rawValue: defaults.string(forKey: "speechLanguage") ?? "") ?? .automatic
        statusKey = enabled ? "speechReady" : "speechDisabled"

        func configuration(useSystemProxy: Bool) -> URLSessionConfiguration {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = useSystemProxy ? nil : [:]
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 120
            return configuration
        }
        loopbackSession = URLSession(
            configuration: configuration(useSystemProxy: false),
            delegate: MikuSpeechNoRedirectDelegate(),
            delegateQueue: nil
        )
        httpsSession = URLSession(
            configuration: configuration(useSystemProxy: true),
            delegate: MikuSpeechNoRedirectDelegate(),
            delegateQueue: nil
        )
        super.init()
    }

    func speak(_ text: String, language override: Language? = nil) {
        cancelCurrentPlayback()
        guard enabled else {
            setState(busy: false, key: "speechDisabled")
            return
        }

        guard text.count <= Self.maximumTextLength else {
            setState(busy: false, error: SpeechError.textTooLong)
            return
        }
        let cleaned = Self.sanitized(text)
        guard !cleaned.isEmpty else {
            setState(busy: false, error: SpeechError.emptyText)
            return
        }
        guard cleaned.count <= Self.maximumTextLength else {
            setState(busy: false, error: SpeechError.textTooLong)
            return
        }

        let selected = override ?? language
        let resolved = selected == .automatic ? Self.detectLanguage(in: cleaned) : selected
        start(text: cleaned, language: resolved, seed: nil)
    }

    func stop() {
        cancelCurrentPlayback()
        setState(busy: false, key: enabled ? "speechReady" : "speechDisabled")
    }

    func testConnection() async throws {
        let token = try accessToken()
        let endpoint = try serviceEndpoint()
        try await ensureHealthy(endpoint: endpoint)
        try await authenticate(endpoint: endpoint, token: token)
    }

    func storeAccessToken(_ token: String) throws {
        try MikuSpeechKeychain.store(token)
        notifyStateChanged()
    }

    nonisolated static func storeAccessTokenFromInput() throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard var token = String(data: data, encoding: .utf8) else {
            throw MikuSpeechKeychain.KeychainError.invalidToken
        }
        while token.last == "\n" || token.last == "\r" {
            token.removeLast()
        }
        try MikuSpeechKeychain.store(token)
    }

    func playSample(language: Language) {
        let resolved = language == .automatic ? Language.mandarin : language
        let sample: String
        switch resolved {
        case .cantonese:
            sample = "你今日辛苦喇。唔使急，我會陪住你，慢慢嚟就得喇。"
        case .mandarin, .automatic:
            sample = "没关系，你已经做得很好了。放松一点，慢慢说就好。"
        case .japanese:
            sample = "こんばんは。今日はもう休んでいいよ。ここでゆっくり話そうね。"
        case .english:
            sample = "It is okay to rest. We do not have to hurry."
        }
        cancelCurrentPlayback()
        guard enabled else {
            setState(busy: false, key: "speechDisabled")
            return
        }
        start(text: sample, language: resolved, seed: nil)
    }

    private func start(text: String, language: Language, seed: Int?) {
        let currentGeneration = generation
        setState(busy: true, key: "speechConnecting")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try accessToken()
                let endpoint = try serviceEndpoint()
                try await ensureHealthy(endpoint: endpoint)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                setState(busy: true, key: "speechGenerating")
                let audio = try await generateAudio(
                    text: text,
                    language: language,
                    seed: seed,
                    endpoint: endpoint,
                    token: token
                )
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                try play(audio, language: language)
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                let displayedError = Self.isConnectionError(error) ? SpeechError.connectionUnavailable : error
                setState(busy: false, error: displayedError)
                operationTask = nil
            }
        }
    }

    private func cancelCurrentPlayback() {
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
    }

    private func ensureHealthy(endpoint: URL) async throws {
        do {
            try await checkHealth(endpoint: endpoint)
            return
        } catch {
            guard Self.isLoopbackHTTP(endpoint), Self.shouldBootstrap(after: error) else { throw error }
        }

        try await bootstrapConnection()
        do {
            try await checkHealth(endpoint: endpoint)
        } catch let error as SpeechError {
            throw error
        } catch {
            throw SpeechError.connectionUnavailable
        }
    }

    private func bootstrapConnection() async throws {
        if let bootstrapTask {
            try await bootstrapTask.value
            return
        }
        let task = Task { try await runLauncher() }
        bootstrapTask = task
        do {
            try await task.value
            bootstrapTask = nil
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    private func checkHealth(endpoint: URL) async throws {
        let url = endpoint.appendingPathComponent("api/health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await self.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpeechError.invalidResponse }
        guard response.statusCode == 200 else { throw SpeechError.serverResponse(response.statusCode) }
        let health: HealthResponse
        do {
            health = try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw SpeechError.invalidResponse
        }
        guard health.profileID == Self.profileID,
              health.profileSHA256.lowercased() == Self.profileSHA256,
              health.authRequired else {
            throw SpeechError.wrongProfile
        }
        guard health.status == "ok", health.engineReady else { throw SpeechError.connectionUnavailable }
    }

    private func authenticate(endpoint: URL, token: String) async throws {
        let url = endpoint.appendingPathComponent("api/session")
        var request = try protectedRequest(url: url, token: token)
        request.httpMethod = "GET"
        let (_, response) = try await self.data(for: request)
        try validate(response, expectedURL: url, statusCode: 200)
    }

    private func generateAudio(
        text: String,
        language: Language,
        seed: Int?,
        endpoint: URL,
        token: String
    ) async throws -> Data {
        let createURL = endpoint.appendingPathComponent("api/jobs")
        var createRequest = try protectedRequest(url: createURL, token: token)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONEncoder().encode(CreateJobRequest(
            language: language.rawValue,
            text: text,
            seed: seed
        ))
        let (createData, createResponse) = try await self.data(for: createRequest)
        try validate(createResponse, expectedURL: createURL, statusCode: 202)
        let created = try decodeJob(createData)
        guard Self.validJobID(created.id), created.status == "queued" || created.status == "running" else {
            throw SpeechError.invalidResponse
        }

        let jobURL = endpoint.appendingPathComponent("api/jobs/\(created.id)")
        let deadline = Date().addingTimeInterval(360)
        while Date() < deadline {
            try Task.checkCancellation()
            var request = try protectedRequest(url: jobURL, token: token)
            request.httpMethod = "GET"
            let (data, response) = try await self.data(for: request)
            try validate(response, expectedURL: jobURL, statusCode: 200)
            let job = try decodeJob(data)
            guard job.id == created.id else { throw SpeechError.invalidResponse }
            switch job.status {
            case "queued", "running":
                try await Task.sleep(nanoseconds: 600_000_000)
            case "failed":
                throw SpeechError.generationFailed
            case "succeeded":
                guard let value = job.audioURL,
                      let audioURL = URL(string: value, relativeTo: endpoint)?.absoluteURL,
                      validAudioURL(audioURL, endpoint: endpoint, jobID: created.id) else {
                    throw SpeechError.invalidResponse
                }
                var audioRequest = try protectedRequest(url: audioURL, token: token)
                audioRequest.httpMethod = "GET"
                let (audio, audioResponse) = try await self.data(for: audioRequest, accept: "audio/wav")
                try validate(audioResponse, expectedURL: audioURL, statusCode: 200)
                guard !audio.isEmpty, audio.count <= Self.maximumAudioBytes else {
                    throw SpeechError.invalidAudio
                }
                return audio
            default:
                throw SpeechError.invalidResponse
            }
        }
        throw SpeechError.generationFailed
    }

    private func play(_ data: Data, language: Language) throws {
        let expectedSampleRate = language == .cantonese ? 48_000 : 32_000
        guard Self.validWAV(data, sampleRate: expectedSampleRate) else { throw SpeechError.invalidAudio }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            throw SpeechError.invalidAudio
        }
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw SpeechError.invalidAudio }
        audioPlayer = player
        operationTask = nil
        setState(busy: true, key: "speechSpeaking")
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        if flag {
            setState(busy: false, key: "speechReady")
        } else {
            setState(busy: false, error: SpeechError.invalidAudio)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        setState(busy: false, error: SpeechError.invalidAudio)
    }

    private func data(for request: URLRequest, accept: String = "application/json") async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw SpeechError.invalidEndpoint }
        var request = request
        request.setValue("MikuDesktop/0.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let session: URLSession
        switch url.scheme?.lowercased() {
        case "http":
            session = loopbackSession
        case "https":
            session = httpsSession
        default:
            throw SpeechError.invalidEndpoint
        }

        let mayRetry = request.httpMethod == "GET" && url.path != "/api/session"
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard mayRetry, attempt < 2, Self.isRetryableNetworkError(error) else { throw error }
                let delay: UInt64 = attempt == 0 ? 500_000_000 : 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw SpeechError.connectionUnavailable
    }

    private func protectedRequest(url: URL, token: String) throws -> URLRequest {
        do {
            return try MikuSpeechAuthorization.protectedRequest(url: url, token: token)
        } catch {
            throw SpeechError.unverifiedConnection
        }
    }

    private func validate(_ response: URLResponse, expectedURL: URL, statusCode: Int) throws {
        guard let response = response as? HTTPURLResponse,
              response.url == expectedURL else {
            throw SpeechError.invalidResponse
        }
        guard response.statusCode == statusCode else { throw SpeechError.serverResponse(response.statusCode) }
    }

    private func decodeJob(_ data: Data) throws -> JobResponse {
        do {
            return try JSONDecoder().decode(JobResponse.self, from: data)
        } catch {
            throw SpeechError.invalidResponse
        }
    }

    private func accessToken() throws -> String {
        guard let token = try MikuSpeechKeychain.load(), !token.isEmpty else {
            throw SpeechError.missingAccessToken
        }
        return token
    }

    private func validAudioURL(_ url: URL, endpoint: URL, jobID: String) -> Bool {
        guard Self.isAllowedServiceOrigin(url),
              Self.sameOrigin(url, endpoint),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/api/jobs/\(jobID)/audio" else {
            return false
        }
        return true
    }

    private func serviceEndpoint() throws -> URL {
        let value = connectionConfiguration()?.endpoint ?? Self.defaultEndpoint
        guard let url = URL(string: value) else {
            throw SpeechError.invalidEndpoint
        }
        do {
            try MikuSpeechAuthorization.validateServiceEndpoint(url)
        } catch {
            throw SpeechError.unverifiedConnection
        }
        return url
    }

    private func connectionConfiguration() -> ConnectionConfiguration? {
        guard let data = try? Data(contentsOf: Self.connectionConfigurationURL) else { return nil }
        return try? JSONDecoder().decode(ConnectionConfiguration.self, from: data)
    }

    private func runLauncher() async throws {
        _ = try serviceEndpoint()
        guard let connection = connectionConfiguration(), let launcher = connection.launcherPath else {
            throw SpeechError.launcherUnavailable
        }
        let launcherURL = try readableFileURL(path: launcher)
        var arguments = [launcherURL.path, "--no-open"]
        if let config = connection.launcherConfig {
            arguments += ["--config", try readableFileURL(path: config).path]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SpeechError.launcherFailed
        }

        let deadline = Date().addingTimeInterval(35)
        while process.isRunning, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                process.terminate()
                throw error
            }
        }
        if process.isRunning {
            process.terminate()
            throw SpeechError.launcherFailed
        }
        guard process.terminationStatus == 0 else { throw SpeechError.launcherFailed }
    }

    private func readableFileURL(path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw SpeechError.launcherUnavailable }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw SpeechError.launcherUnavailable
        }
        return url
    }

    private func setState(busy: Bool, key: String) {
        isBusy = busy
        statusKey = key
        statusError = nil
        notifyStateChanged()
    }

    private func setState(busy: Bool, error: Error) {
        isBusy = busy
        statusError = error
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    private static var connectionConfigurationURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appendingPathComponent("com.qimake.MikuDesktop", isDirectory: true)
            .appendingPathComponent("tts-connection.json")
    }

    private static func isAllowedServiceOrigin(_ url: URL) -> Bool {
        MikuSpeechAuthorization.isOfficialServiceURL(url)
    }

    private static func isLoopbackHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            if let port = url.port { return port }
            switch url.scheme?.lowercased() {
            case "http": return 80
            case "https": return 443
            default: return nil
            }
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
    }

    private static func validJobID(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return jobIDPattern.firstMatch(in: value, range: range) != nil
    }

    private static func isConnectionError(_ error: Error) -> Bool {
        if error is URLError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        let retryable: Set<Int> = [
            URLError.networkConnectionLost.rawValue,
            URLError.timedOut.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.dnsLookupFailed.rawValue,
            URLError.cannotFindHost.rawValue,
            URLError.notConnectedToInternet.rawValue
        ]
        return retryable.contains(value.code)
    }

    private static func shouldBootstrap(after error: Error) -> Bool {
        if isConnectionError(error) { return true }
        guard let error = error as? SpeechError else { return false }
        if case .connectionUnavailable = error { return true }
        return false
    }

    private static func sanitized(_ text: String) -> String {
        var value = text
        value = replace(#"(?s)```.*?(?:```|$)"#, in: value, with: " ")
        value = replace(#"!\[[^\]]*\]\([^)]*\)"#, in: value, with: " ")
        value = replace(#"\[([^\]]+)\]\([^)]*\)"#, in: value, with: "$1")
        value = replace(#"(?i)(?:https?://|www\.)[^\s<>()\[\]，。！？；：、]+"#, in: value, with: " ")
        value = replace(#"(?i)<[^>]+>"#, in: value, with: " ")
        value = replace(
            #"(?i)(?:\(|\[|（|【)\s*(?:laughs?|sighs?|smiles?|waves?|nods?|pauses?|giggles?|whispers?|softly|笑|苦笑|微笑|嘆氣|叹气|揮手|挥手|點頭|点头|抱抱|沉默|輕聲|轻声)\s*(?:\)|\]|）|】)"#,
            in: value,
            with: " "
        )
        value = replace(
            #"(?im)^\s*[*_]{1,3}\s*(?:laughs?|sighs?|smiles?|waves?|nods?|pauses?|giggles?|whispers?|softly|笑|苦笑|微笑|嘆氣|叹气|揮手|挥手|點頭|点头|抱抱|沉默|輕聲|轻声)\s*[*_]{1,3}\s*$"#,
            in: value,
            with: " "
        )
        value = replace(#"(?m)^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)"#, in: value, with: "")
        value = replace(#"[`*_~]+"#, in: value, with: "")
        value = replace(#"[\t ]+"#, in: value, with: " ")
        value = replace(#"\s*\n\s*"#, in: value, with: "。")
        value = replace(#"。{2,}"#, in: value, with: "。")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningful = replace(#"[0-9#*]\uFE0F?\u20E3"#, in: value, with: "")
        guard meaningful.unicodeScalars.contains(where: {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }) else {
            return ""
        }
        return value
    }

    private static func replace(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }

    private static func detectLanguage(in text: String) -> Language {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains(Int($0.value)) }) {
            return .japanese
        }
        let cantonese = #"唔|冇|喺|嘅|咁|嚟|啦|喇|啲|佢|哋|俾|畀|攞|睇|諗|瞓|而家|點解|乜|噉|嘢|㗎|㖭|吖|啱|傾|(?:你|我|佢|呢|就|都|唔)係"#
        if text.range(of: cantonese, options: .regularExpression) != nil {
            return .cantonese
        }
        if scalars.contains(where: { (0x3400...0x9FFF).contains(Int($0.value)) }) {
            return .mandarin
        }
        if scalars.contains(where: { (0x0041...0x005A).contains(Int($0.value)) || (0x0061...0x007A).contains(Int($0.value)) }) {
            return .english
        }
        return .mandarin
    }

    private static func validWAV(_ data: Data, sampleRate expectedSampleRate: Int) -> Bool {
        guard data.count >= 44,
              ascii(data, offset: 0, count: 4) == "RIFF",
              ascii(data, offset: 8, count: 4) == "WAVE" else {
            return false
        }
        var offset = 12
        var validFormat = false
        var hasAudio = false
        while offset + 8 <= data.count {
            let name = ascii(data, offset: offset, count: 4)
            guard let sizeValue = uint32(data, offset: offset + 4) else { return false }
            let size = Int(sizeValue)
            let content = offset + 8
            guard size >= 0, content <= data.count, size <= data.count - content else { return false }
            if name == "fmt " {
                guard size >= 16,
                      uint16(data, offset: content) == 1,
                      uint16(data, offset: content + 2) == 1,
                      uint32(data, offset: content + 4) == UInt32(expectedSampleRate),
                      uint16(data, offset: content + 14) == 16 else {
                    return false
                }
                validFormat = true
            } else if name == "data" {
                hasAudio = size > 0
            }
            let paddedSize = size + (size % 2)
            guard paddedSize <= data.count - content else { return false }
            offset = content + paddedSize
        }
        return validFormat && hasAudio
    }

    private static func ascii(_ data: Data, offset: Int, count: Int) -> String? {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else { return nil }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii)
    }

    private static func uint16(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
