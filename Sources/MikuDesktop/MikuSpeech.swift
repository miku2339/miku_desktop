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
        case invalidResponse
        case serverResponse(Int)
        case missingModel
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
            case .invalidResponse:
                return L10n.text("speechErrorInvalidResponse")
            case let .serverResponse(status):
                return L10n.format("speechErrorHTTP", String(status))
            case .missingModel:
                return L10n.text("speechErrorMissingModel")
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
            defaults.set(enabled, forKey: Self.enabledKey)
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
            defaults.set(language.rawValue, forKey: Self.languageKey)
            notifyStateChanged()
        }
    }

    var endpoint: String {
        defaults.string(forKey: Self.endpointKey) ?? MikuSpeechAuthorization.defaultEndpoint
    }

    var configuredModelID: String {
        defaults.string(forKey: Self.modelKey) ?? ""
    }

    var hasConfiguredModel: Bool {
        !configuredModelID.isEmpty
    }

    private(set) var isBusy = false
    var status: String {
        statusError?.localizedDescription ?? L10n.text(statusKey)
    }
    var onStateChanged: (() -> Void)?

    // 保留舊有擁有者 Keychain 項目與 CLI，相容既有私人設定。
    var hasAccessToken: Bool {
        guard let token = try? MikuSpeechKeychain.load() else { return false }
        return !token.isEmpty
    }

    static let automaticModelID = "miku-four-language-auto"
    static let ownerModelIDs: Set<String> = [
        "miku-gpt-sovits-yue",
        "miku-gpt-sovits-zh",
        "miku-gpt-sovits-ja",
        "miku-gpt-sovits-en"
    ]

    private static let enabledKey = "speechEnabled"
    private static let languageKey = "speechLanguage"
    private static let endpointKey = "speechLocalEndpoint"
    private static let modelKey = "speechLocalModel"
    private static let maximumTextLength = 2_000
    private static let maximumAudioBytes = 64 * 1_024 * 1_024

    private let defaults: UserDefaults
    private let session: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var statusKey: String
    private var statusError: Error?

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        language = Language(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .automatic
        statusKey = enabled ? "speechReady" : "speechDisabled"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        session = URLSession(
            configuration: configuration,
            delegate: MikuSpeechNoRedirectDelegate(),
            delegateQueue: nil
        )
        super.init()
    }

    func configure(endpoint: String, modelID: String) throws {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEndpoint = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: normalizedEndpoint) else { throw SpeechError.invalidEndpoint }
        do {
            try MikuSpeechAuthorization.validateServiceEndpoint(url)
        } catch {
            throw SpeechError.unverifiedConnection
        }
        guard modelID.isEmpty || modelID == Self.automaticModelID || MikuSpeechWire.validModelID(modelID) else {
            throw SpeechError.missingModel
        }
        defaults.set(normalizedEndpoint, forKey: Self.endpointKey)
        defaults.set(modelID, forKey: Self.modelKey)
        notifyStateChanged()
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
        start(text: cleaned, language: resolved)
    }

    func stop() {
        cancelCurrentPlayback()
        setState(busy: false, key: enabled ? "speechReady" : "speechDisabled")
    }

    func testConnection() async throws -> [String] {
        let endpoint = try serviceEndpoint()
        let statusURL = endpoint.appendingPathComponent("models/status")
        var request = try localRequest(url: statusURL, endpoint: endpoint)
        request.httpMethod = "GET"
        let (data, response) = try await self.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url == statusURL else {
            throw SpeechError.invalidResponse
        }
        if response.statusCode == 200 {
            do {
                return try MikuSpeechWire.audioModelIDs(from: data)
            } catch {
                throw SpeechError.invalidResponse
            }
        }
        guard response.statusCode == 404 else { throw SpeechError.serverResponse(response.statusCode) }

        let modelsURL = endpoint.appendingPathComponent("models")
        var fallback = try localRequest(url: modelsURL, endpoint: endpoint)
        fallback.httpMethod = "GET"
        let (modelsData, modelsResponse) = try await self.data(for: fallback)
        try validate(modelsResponse, expectedURL: modelsURL, statusCode: 200)
        do {
            try MikuSpeechWire.validateModelsResponse(modelsData)
        } catch {
            throw SpeechError.invalidResponse
        }
        return []
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
        start(text: sample, language: resolved)
    }

    private func start(text: String, language: Language) {
        let currentGeneration = generation
        setState(busy: true, key: "speechConnecting")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try serviceEndpoint()
                let model = try modelID(for: language)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                setState(busy: true, key: "speechGenerating")
                let audio = try await generateAudio(
                    text: text,
                    language: language,
                    model: model,
                    endpoint: endpoint
                )
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                try play(audio)
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

    private func generateAudio(
        text: String,
        language: Language,
        model: String,
        endpoint: URL
    ) async throws -> Data {
        let url = endpoint.appendingPathComponent("audio/speech")
        var request = try localRequest(url: url, endpoint: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MikuSpeechWire.speechBody(
            model: model,
            input: text,
            language: language.rawValue
        )
        let (audio, response) = try await self.data(for: request, accept: "audio/wav")
        guard let response = response as? HTTPURLResponse, response.url == url else {
            throw SpeechError.invalidResponse
        }
        guard response.statusCode == 200 else { throw SpeechError.serverResponse(response.statusCode) }
        guard MikuSpeechWire.isAudioContentType(response.value(forHTTPHeaderField: "Content-Type")),
              response.expectedContentLength <= Int64(Self.maximumAudioBytes),
              !audio.isEmpty,
              audio.count <= Self.maximumAudioBytes else {
            throw SpeechError.invalidAudio
        }
        return audio
    }

    private func play(_ data: Data) throws {
        guard MikuSpeechWire.validWAV(data) else { throw SpeechError.invalidAudio }
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
        guard let url = request.url, MikuSpeechAuthorization.isLoopbackServiceURL(url) else {
            throw SpeechError.invalidEndpoint
        }
        var request = request
        request.setValue("MikuDesktop/0.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let mayRetry = request.httpMethod == "GET"
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

    private func localRequest(url: URL, endpoint: URL) throws -> URLRequest {
        do {
            return try MikuSpeechAuthorization.localRequest(url: url, endpoint: endpoint)
        } catch {
            throw SpeechError.unverifiedConnection
        }
    }

    private func validate(_ response: URLResponse, expectedURL: URL, statusCode: Int) throws {
        guard let response = response as? HTTPURLResponse, response.url == expectedURL else {
            throw SpeechError.invalidResponse
        }
        guard response.statusCode == statusCode else { throw SpeechError.serverResponse(response.statusCode) }
    }

    private func serviceEndpoint() throws -> URL {
        guard let url = URL(string: endpoint) else { throw SpeechError.invalidEndpoint }
        do {
            try MikuSpeechAuthorization.validateServiceEndpoint(url)
        } catch {
            throw SpeechError.unverifiedConnection
        }
        return url
    }

    private func modelID(for language: Language) throws -> String {
        let configured = configuredModelID
        guard configured != Self.automaticModelID else {
            switch language {
            case .cantonese: return "miku-gpt-sovits-yue"
            case .mandarin, .automatic: return "miku-gpt-sovits-zh"
            case .japanese: return "miku-gpt-sovits-ja"
            case .english: return "miku-gpt-sovits-en"
            }
        }
        guard MikuSpeechWire.validModelID(configured) else { throw SpeechError.missingModel }
        return configured
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
}
