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
                setState(busy: false, key: idleStatusKey)
            }
            NotificationCenter.default.post(name: .mikuSpeechMuteChanged, object: self)
        }
    }

    // MARK: - Mute (a quick "be quiet", separate from turning reading aloud off)

    var isMuted: Bool { mute.isMuted() }

    /// Quiet because an automation (a Focus, through Shortcuts) asked, not because you muted.
    var isQuietByAutomation: Bool { mute.isQuietByAutomation && !mute.isMutedByHand() }

    /// From a `miku-desktop://quiet/on|off` link: a Shortcuts automation for a Focus.
    func setQuietByAutomation(_ quiet: Bool) {
        mute.setQuietByAutomation(quiet)
        if quiet {
            cancelCurrentPlayback()
            setState(busy: false, key: "speechMuted")
        } else if !isBusy {
            setState(busy: false, key: idleStatusKey)
        }
        NotificationCenter.default.post(name: .mikuSpeechMuteChanged, object: self)
    }

    /// Carries out a `miku-desktop://` voice link.
    func handle(_ command: SpeechLinkCommand) {
        switch command {
        case let .quiet(quiet):
            setQuietByAutomation(quiet)
        case let .mute(minutes):
            setMuted(true, for: minutes.map { TimeInterval($0) * 60 })
        case .unmute:
            setMuted(false)
        }
    }

    /// When a timed mute ends; nil while not muted or muted until unmuted.
    var mutedUntil: Date? { mute.mutedUntil() }

    /// Mutes for `duration` (nil: until unmuted) and stops what she's saying right now.
    /// Nothing is generated while muted; replays and previews you ask for still play.
    func setMuted(_ muted: Bool, for duration: TimeInterval? = nil) {
        if muted {
            mute.mute(for: duration)
            cancelCurrentPlayback()
            setState(busy: false, key: "speechMuted")
        } else {
            mute.unmute()
            if !isBusy { setState(busy: false, key: idleStatusKey) }
        }
        scheduleMuteExpiry()
        NotificationCenter.default.post(name: .mikuSpeechMuteChanged, object: self)
    }

    private var idleStatusKey: String {
        enabled ? (isMuted ? "speechMuted" : "speechReady") : "speechDisabled"
    }

    /// A timed mute runs out on its own; tell the button and the menu when it does.
    private func scheduleMuteExpiry() {
        muteTimer?.invalidate()
        muteTimer = nil
        guard let until = mute.mutedUntil() else { return }
        muteTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.muteTimer = nil
                if !self.isBusy { self.setState(busy: false, key: self.idleStatusKey) }
                NotificationCenter.default.post(name: .mikuSpeechMuteChanged, object: self)
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

    /// What the audio is doing, so her mouth can move while (and only while) it plays.
    enum PlaybackEvent: Equatable {
        /// The audio for `text` has started and lasts `duration` seconds.
        case started(text: String, duration: TimeInterval)
        /// It played to the end.
        case ended
        /// It was stopped, muted or replaced by a newer line before the end.
        case interrupted
        /// No audio will come for the line that was just sent.
        case failed
    }

    var onPlayback: ((PlaybackEvent) -> Void)?

    /// One line per retry or failure for diagnostics.log: what went wrong, the language, how
    /// long the line was and how long it took. Never the text itself.
    var onDiagnostic: (([String: Any]) -> Void)?

    /// Generating audio waits this long for the service: after a hiccup it restarts its
    /// worker, which takes about half a minute to load.
    static let generationTimeout: TimeInterval = 60
    /// Pause before the single retry, giving a restarting worker a moment.
    static let retryDelay: UInt64 = 1_500_000_000

    /// Whether a reply sent now would be read aloud without you asking (on, a model set, not
    /// muted, not a quiet moment). The reply can still fail later; `.failed` says so.
    var willSpeakAutomatically: Bool {
        enabled && hasConfiguredModel && automaticSpeechBlockStatus(userInitiated: false) == nil
    }

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
    private let generationSession: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var operationTask: Task<Void, Never>?
    private var generation = UUID()
    private var statusKey: String
    private var statusError: Error?
    private let mute: SpeechMute
    private var muteTimer: Timer?

    override convenience init() {
        self.init(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        language = Language(rawValue: defaults.string(forKey: Self.languageKey) ?? "") ?? .automatic
        let mute = SpeechMute(defaults: defaults)
        self.mute = mute
        statusKey = enabled ? (mute.isMuted() ? "speechMuted" : "speechReady") : "speechDisabled"

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
        let generation = configuration.copy() as! URLSessionConfiguration
        generation.timeoutIntervalForRequest = Self.generationTimeout
        generation.timeoutIntervalForResource = Self.generationTimeout * 2 + 10
        generationSession = URLSession(
            configuration: generation,
            delegate: MikuSpeechNoRedirectDelegate(),
            delegateQueue: nil
        )
        super.init()
        scheduleMuteExpiry()
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

    /// `userInitiated`: you asked to hear it (a replay), so it plays even while muted.
    func speak(_ text: String, language override: Language? = nil, userInitiated: Bool = false) {
        guard enabled else {
            setState(busy: false, key: "speechDisabled")
            onPlayback?(.failed)
            return
        }
        if let blockedStatus = automaticSpeechBlockStatus(userInitiated: userInitiated) {
            if !isBusy { setState(busy: false, key: blockedStatus) }
            onPlayback?(.failed)
            return
        }
        cancelCurrentPlayback()

        guard text.count <= Self.maximumTextLength else {
            setState(busy: false, error: SpeechError.textTooLong)
            onPlayback?(.failed)
            return
        }
        let cleaned = Self.sanitized(text)
        guard !cleaned.isEmpty else {
            setState(busy: false, error: SpeechError.emptyText)
            onPlayback?(.failed)
            return
        }
        guard cleaned.count <= Self.maximumTextLength else {
            setState(busy: false, error: SpeechError.textTooLong)
            onPlayback?(.failed)
            return
        }

        // The text decides the voice (Mandarin text is never read in the Cantonese voice, or
        // the other way round); only text that could be either follows the chosen language:
        // Miku's speaking language when one is set, else the voice language setting.
        let preferred = SpeechVoice.voice(forReplyLanguage: defaults.string(forKey: "replyLanguage")) ?? language.rawValue
        let resolved = override ?? Language(rawValue: SpeechVoice.voice(for: cleaned, preferred: preferred)) ?? .mandarin
        start(text: cleaned, language: resolved, userInitiated: userInitiated)
    }

    func stop() {
        cancelCurrentPlayback()
        setState(busy: false, key: idleStatusKey)
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
        start(text: sample, language: resolved, userInitiated: true)
    }

    private func start(text: String, language: Language, userInitiated: Bool) {
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
                let began = Date()
                var attempt = 1
                var audio = Data()
                while true {
                    do {
                        audio = try await generateAudio(
                            text: text,
                            language: language,
                            model: model,
                            endpoint: endpoint
                        )
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // One retry for a service hiccup (500, or the connection dropped while
                        // its worker restarted); anything else fails straight away.
                        guard attempt == 1, Self.isRetryableGeneration(error), generation == currentGeneration else {
                            throw SpeechAttemptError(underlying: error, attempts: attempt, began: began)
                        }
                        diagnose("retry", error: error, attempt: attempt, began: began, language: language, text: text, userInitiated: userInitiated)
                        try await Task.sleep(nanoseconds: Self.retryDelay)
                        try Task.checkCancellation()
                        guard generation == currentGeneration else { return }
                        attempt += 1
                    }
                }
                if attempt > 1 {
                    diagnose("recovered", error: nil, attempt: attempt, began: began, language: language, text: text, userInitiated: userInitiated)
                }
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                if let blockedStatus = automaticSpeechBlockStatus(userInitiated: userInitiated) {
                    operationTask = nil
                    setState(busy: false, key: blockedStatus)
                    onPlayback?(.failed)
                    return
                }
                try play(audio, text: text)
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration else { return }
                let attemptError = error as? SpeechAttemptError
                let underlying = attemptError?.underlying ?? error
                diagnose(
                    "failed",
                    error: underlying,
                    attempt: attemptError?.attempts ?? 1,
                    began: attemptError?.began,
                    language: language,
                    text: text,
                    userInitiated: userInitiated
                )
                let displayedError = Self.isConnectionError(underlying) ? SpeechError.connectionUnavailable : underlying
                setState(busy: false, error: displayedError)
                operationTask = nil
                onPlayback?(.failed)
            }
        }
    }

    /// A failed generation, with how many tries it took.
    private struct SpeechAttemptError: Error {
        let underlying: Error
        let attempts: Int
        let began: Date
    }

    /// Worth one more try: the service answered 5xx, or the local connection broke or timed out.
    nonisolated static func isRetryableGeneration(_ error: Error) -> Bool {
        if case let SpeechError.serverResponse(status) = error { return (500...599).contains(status) }
        if case SpeechError.connectionUnavailable = error { return true }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return false }
        return [
            URLError.timedOut.rawValue,
            URLError.networkConnectionLost.rawValue,
            URLError.cannotConnectToHost.rawValue,
            URLError.notConnectedToInternet.rawValue
        ].contains(value.code)
    }

    /// A short, text-free name for an error in diagnostics.log.
    nonisolated static func diagnosticCode(_ error: Error) -> String {
        if let speech = error as? SpeechError {
            switch speech {
            case let .serverResponse(status): return "http-\(status)"
            case .invalidEndpoint: return "invalid-endpoint"
            case .connectionUnavailable: return "connection-unavailable"
            case .invalidResponse: return "invalid-response"
            case .missingModel: return "missing-model"
            case .unverifiedConnection: return "unverified-connection"
            case .emptyText: return "empty-text"
            case .textTooLong: return "text-too-long"
            case .generationFailed: return "generation-failed"
            case .invalidAudio: return "invalid-audio"
            }
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain { return "url\(value.code)" }
        return "other"
    }

    private func diagnose(
        _ what: String,
        error: Error?,
        attempt: Int,
        began: Date?,
        language: Language,
        text: String,
        userInitiated: Bool
    ) {
        var payload: [String: Any] = [
            "type": "speech",
            "what": what,
            "attempt": attempt,
            "language": language.rawValue,
            "chars": text.count,
            "userInitiated": userInitiated
        ]
        if let error { payload["code"] = Self.diagnosticCode(error) }
        if let began { payload["elapsedMs"] = Int(Date().timeIntervalSince(began) * 1000) }
        onDiagnostic?(payload)
    }

    /// Automatic speech is checked both before generation and immediately before playback.
    private func automaticSpeechBlockStatus(userInitiated: Bool) -> String? {
        guard !userInitiated else { return nil }
        if isMuted { return "speechMuted" }
        if SpeechQuietTimes.isQuietNow() { return "speechQuietNow" }
        return nil
    }

    private func cancelCurrentPlayback() {
        generation = UUID()
        operationTask?.cancel()
        operationTask = nil
        let wasPlaying = audioPlayer != nil
        audioPlayer?.stop()
        audioPlayer?.delegate = nil
        audioPlayer = nil
        if wasPlaying { onPlayback?(.interrupted) }
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
        let (audio, response) = try await self.data(for: request, accept: "audio/wav", using: generationSession)
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

    private func play(_ data: Data, text: String) throws {
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
        onPlayback?(.started(text: text, duration: player.duration))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        onPlayback?(.ended)
        if flag {
            setState(busy: false, key: idleStatusKey)
        } else {
            setState(busy: false, error: SpeechError.invalidAudio)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        onPlayback?(.ended)
        setState(busy: false, error: SpeechError.invalidAudio)
    }

    private func data(
        for request: URLRequest,
        accept: String = "application/json",
        using chosenSession: URLSession? = nil
    ) async throws -> (Data, URLResponse) {
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
                return try await (chosenSession ?? session).data(for: request)
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
}
