import AVFoundation
import Foundation
import Speech

private final class LocalSpeechRequestTarget: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func end() { request.endAudio() }
}

/// Request replacement and append/endAudio share one lock. Buffers arriving in a request
/// gap wait in a bounded memory pre-roll, instead of dropping the first syllable.
final class VoiceCallPCMFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var appendToRequest: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var endRequest: (@Sendable () -> Void)?
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if let appendToRequest { appendToRequest(buffer); return }
        let maximum = max(1, Int(buffer.format.sampleRate * 0.5))
        guard Int(buffer.frameLength) <= maximum, let copy = Self.copy(buffer) else { return }
        pending.append(copy)
        pendingFrames += Int(copy.frameLength)
        while pendingFrames > maximum, !pending.isEmpty { pendingFrames -= Int(pending.removeFirst().frameLength) }
    }

    func replace(append: @escaping @Sendable (AVAudioPCMBuffer) -> Void, end: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        endRequest?()
        appendToRequest = append
        endRequest = end
        for buffer in pending { append(buffer) }
        pending.removeAll(keepingCapacity: false)
        pendingFrames = 0
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        endRequest?()
        appendToRequest = nil
        endRequest = nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        enabled = false
        endRequest?()
        appendToRequest = nil
        endRequest = nil
        pending.removeAll(keepingCapacity: false)
        pendingFrames = 0
    }

    var queuedFrameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingFrames
    }

    static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in 0..<from.count {
            guard let a = from[index].mData, let b = to[index].mData, from[index].mDataByteSize <= to[index].mDataByteSize else { return nil }
            memcpy(b, a, Int(from[index].mDataByteSize))
        }
        return copy
    }
}

/// Continuous, on-device ASR on the shared echo-cancelled call graph.
@MainActor
final class LocalSpeechInput: VoiceCallInput {
    enum Failure: Error {
        case microphoneDenied, speechDenied, onDeviceUnavailable, inputUnavailable, recognitionFailed, voiceProcessingUnavailable
        case languageUnsupported, resourceDownloadFailed
        var key: String {
            switch self {
            case .microphoneDenied: return "voiceCallMicrophoneDenied"
            case .speechDenied: return "voiceCallSpeechDenied"
            case .onDeviceUnavailable: return "voiceCallOnDeviceUnavailable"
            case .inputUnavailable: return "voiceCallInputUnavailable"
            case .recognitionFailed: return "voiceCallRecognitionFailed"
            case .voiceProcessingUnavailable: return "voiceCallEchoCancellationUnavailable"
            case .languageUnsupported: return "voiceCallLanguageUnsupported"
            case .resourceDownloadFailed: return "voiceCallResourceDownloadFailed"
            }
        }
    }

    var automaticInterruptionAvailable: Bool { audio.automaticInterruptionAvailable }
    private let audio: VoiceCallAudio
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var feed: VoiceCallPCMFeed?
    private var generation = 0
    private var requestEpoch = 0
    private var prefix = ""
    private var onResult: ((String, Bool) -> Void)?
    private var onError: ((String) -> Void)?
    private var language: VoiceCallLanguage = .mandarin
    private var onPreparation: ((VoiceCallPreparation) -> Void)?
    private var preparedAnalyzer: LocalSpeechAnalyzing?
    private var runningAnalyzer: LocalSpeechAnalyzing?
    private var makeAnalyzer: (() -> LocalSpeechAnalyzing)?

    init(audio: VoiceCallAudio? = nil) { self.audio = audio ?? .shared }

    func configure(language: VoiceCallLanguage, onPreparation: @escaping (VoiceCallPreparation) -> Void) {
        self.language = language
        self.onPreparation = onPreparation
    }

    static func prepareResources(for language: VoiceCallLanguage, onState: @escaping (VoiceCallPreparation) -> Void = { _ in }) async throws {
        if #available(macOS 26.0, *) {
            try await LocalSpeechResources.prepare(language: language, onState: onState)
        } else {
            onState(.checking)
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier)),
                  recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw Failure.onDeviceUnavailable }
            onState(.ready)
        }
    }

    func authorize() async throws {
        preparedAnalyzer?.stop(); preparedAnalyzer = nil
        makeAnalyzer = nil
        recognizer = nil
        let microphoneAllowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneAllowed = true
        case .notDetermined:
            microphoneAllowed = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
        default: microphoneAllowed = false
        }
        try Task.checkCancellation()
        guard microphoneAllowed else { throw Failure.microphoneDenied }
        let speechAllowed: Bool
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechAllowed = true
        case .notDetermined:
            speechAllowed = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: speechAllowed = false
        }
        try Task.checkCancellation()
        guard speechAllowed else { throw Failure.speechDenied }
        if #available(macOS 26.0, *) {
            let selected = language
            let onState = onPreparation ?? { _ in }
            let session = try await LocalSpeechAnalyzerSession.prepare(language: selected, onState: onState)
            try Task.checkCancellation()
            let format = session.format
            preparedAnalyzer = session
            makeAnalyzer = { LocalSpeechAnalyzerSession(language: selected, format: format) }
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw Failure.onDeviceUnavailable }
        self.recognizer = recognizer
        onPreparation?(.ready)
    }

    func listen(onResult: @escaping (String, Bool) -> Void, onActivity: @escaping (Bool) -> Void,
                onError: @escaping (String) -> Void) throws {
        stop()
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw Failure.microphoneDenied }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw Failure.speechDenied }
        self.onResult = onResult
        self.onError = onError
        let feed = VoiceCallPCMFeed()
        self.feed = feed
        prefix = ""
        try replaceRequest()
        let token = generation
        do {
            try audio.startInput(onBuffer: { buffer in feed.append(buffer) }, onActivity: { [weak self] active in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    onActivity(active)
                }
            }, onFailure: { [weak self] key in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    onError(key)
                }
            })
        } catch VoiceCallAudio.Failure.voiceProcessingUnavailable {
            stop()
            throw Failure.voiceProcessingUnavailable
        } catch {
            stop()
            throw Failure.inputUnavailable
        }
    }

    func resetRecognition() throws {
        prefix = ""
        try replaceRequest()
    }

    private func replaceRequest() throws {
        guard let feed else { throw Failure.inputUnavailable }
        if let makeAnalyzer {
            if let runningAnalyzer { runningAnalyzer.reset(); return }
            let session = preparedAnalyzer ?? makeAnalyzer()
            preparedAnalyzer = nil
            runningAnalyzer = session
            let token = generation
            session.start(feed: feed, onResult: { [weak self] text, final in
                guard let self, generation == token else { return }
                onResult?(text, final)
            }, onError: { [weak self] key in
                guard let self, generation == token else { return }
                onError?(key)
            })
            return
        }
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw Failure.onDeviceUnavailable }
        requestEpoch &+= 1
        let epoch = requestEpoch
        let token = generation
        feed.detach()
        recognitionTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let target = LocalSpeechRequestTarget(request)
        feed.replace(append: { target.append($0) }, end: { target.end() })
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let noSpeech = (error as NSError?)?.code == 1110
            let failed = error != nil
            Task { @MainActor in
                guard let self, self.generation == token, self.requestEpoch == epoch else { return }
                if let text {
                    let separator = self.language.separatesWords ? " " : ""
                    let full = String((self.prefix.isEmpty ? text : self.prefix + separator + text).prefix(1_000))
                    self.onResult?(full, final)
                    guard self.generation == token, self.requestEpoch == epoch else { return }
                    if final {
                        self.prefix = full
                        do { try self.replaceRequest() }
                        catch { self.onError?(Failure.recognitionFailed.key) }
                        return
                    }
                }
                guard failed else { return }
                if noSpeech {
                    do { try self.replaceRequest() }
                    catch { self.onError?(Failure.recognitionFailed.key) }
                } else { self.onError?(Failure.recognitionFailed.key) }
            }
        }
    }

    func stop() {
        generation &+= 1
        requestEpoch &+= 1
        feed?.close(); feed = nil
        recognitionTask?.cancel(); recognitionTask = nil
        runningAnalyzer?.stop(); runningAnalyzer = nil
        onResult = nil; onError = nil
        prefix = ""
        audio.stopInput()
    }

    func releasePreparation() {
        preparedAnalyzer?.stop(); preparedAnalyzer = nil
        makeAnalyzer = nil
        recognizer = nil
        onPreparation = nil
    }
}
