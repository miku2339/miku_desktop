import Foundation

@MainActor
protocol VoiceCallInput: AnyObject {
    var automaticInterruptionAvailable: Bool { get }
    func configure(language: VoiceCallLanguage, onPreparation: @escaping (VoiceCallPreparation) -> Void)
    func authorize() async throws
    func listen(onResult: @escaping (String, Bool) -> Void, onActivity: @escaping (Bool) -> Void,
                onError: @escaping (String) -> Void) throws
    /// Replaces only the ASR request. The input engine and buffers keep running.
    func resetRecognition() throws
    func releasePreparation()
    func stop()
}

extension VoiceCallInput {
    func configure(language: VoiceCallLanguage, onPreparation: @escaping (VoiceCallPreparation) -> Void) {}
    func releasePreparation() {}
}

@MainActor
protocol VoiceCallScheduledTask: AnyObject { func cancel() }

@MainActor
protocol VoiceCallScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> VoiceCallScheduledTask
}

@MainActor
private final class VoiceCallTimer: VoiceCallScheduledTask {
    private var task: Task<Void, Never>?
    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                action()
            } catch {}
        }
    }
    func cancel() { task?.cancel(); task = nil }
}

@MainActor
private struct VoiceCallClock: VoiceCallScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> VoiceCallScheduledTask {
        VoiceCallTimer(delay: delay, action: action)
    }
}

/// ASR stays alive while Miku thinks and speaks. Acoustic activity plus recognized speech
/// can interrupt the pending answer without resetting the user's opening audio.
@MainActor
final class VoiceCallController {
    enum Phase: Equatable { case inactive, preparing, listening, thinking, speaking, paused, failed }
    private(set) var phase: Phase = .inactive
    private(set) var isMicrophoneMuted = false
    private(set) var transcript = ""
    private(set) var errorKey: String?
    private(set) var automaticInterruptionAvailable = false
    private(set) var language: VoiceCallLanguage = .mandarin
    private(set) var preparation: VoiceCallPreparation?
    var isActive: Bool { phase != .inactive && phase != .failed }
    var onChange: (() -> Void)?
    var onUtterance: ((String) -> Void)?
    var onInterrupt: (() -> Void)?

    private let input: VoiceCallInput
    private let scheduler: VoiceCallScheduling
    private var authorizationTask: Task<Void, Never>?
    private var silenceTask: VoiceCallScheduledTask?
    private var turnLimitTask: VoiceCallScheduledTask?
    private var generation = 0
    private var inputEpoch = 0
    private var turnEpoch = 0
    private var authorized = false
    private var inputRunning = false
    private var waitingForPlayback = false
    private var speechActive = false
    private var hasSpeechEvidence = false
    private var lastResultFinal = false

    init(input: VoiceCallInput? = nil, scheduler: VoiceCallScheduling? = nil) {
        self.input = input ?? LocalSpeechInput()
        self.scheduler = scheduler ?? VoiceCallClock()
    }

    func start() {
        guard !isActive else { return }
        generation &+= 1
        let token = generation
        stopInput()
        authorizationTask?.cancel()
        authorized = false
        waitingForPlayback = false
        isMicrophoneMuted = false
        transcript = ""
        errorKey = nil
        phase = .preparing
        preparation = .checking
        onChange?()
        input.configure(language: language) { [weak self] state in
            guard let self, generation == token, phase == .preparing else { return }
            preparation = state
            onChange?()
        }
        authorizationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == token, isActive else { return }
            do {
                try await input.authorize()
                guard !Task.isCancelled, generation == token, isActive else { return }
                authorizationTask = nil
                authorized = true
                if isMicrophoneMuted { phase = .paused; onChange?() }
                else { beginInput(preserving: .listening) }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, generation == token, isActive else { return }
                fail((error as? LocalSpeechInput.Failure)?.key ?? "voiceCallRecognitionFailed")
            }
        }
    }

    func selectLanguage(_ language: VoiceCallLanguage) {
        guard language != self.language else { return }
        let restart = isActive
        let muted = isMicrophoneMuted
        if restart {
            onInterrupt?()
            end()
        }
        self.language = language
        onChange?()
        if restart {
            start()
            if muted { toggleMicrophone() }
        }
    }

    func end() {
        generation &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        stopInput()
        input.releasePreparation()
        authorized = false
        waitingForPlayback = false
        isMicrophoneMuted = false
        transcript = ""
        errorKey = nil
        preparation = nil
        phase = .inactive
        onChange?()
    }

    func toggleMicrophone() {
        guard isActive else { return }
        isMicrophoneMuted.toggle()
        if isMicrophoneMuted {
            stopInput()
            transcript = ""
            if phase == .listening { phase = .paused }
        } else if authorized {
            let keep = phase == .thinking || phase == .speaking ? phase : .listening
            beginInput(preserving: keep)
            return
        }
        onChange?()
    }

    func replyReady() {
        guard isActive, phase == .thinking else { return }
        waitingForPlayback = true
        onChange?()
    }

    func playbackStarted() {
        guard isActive, waitingForPlayback, phase == .thinking else { return }
        phase = .speaking
        onChange?()
    }

    func playbackFinished() {
        guard isActive, waitingForPlayback, phase == .thinking || phase == .speaking else { return }
        waitingForPlayback = false
        phase = isMicrophoneMuted ? .paused : .listening
        onChange?()
        if !speechActive, hasSpeechEvidence { scheduleEndpoint() }
    }

    func replyFailed() {
        guard isActive else { return }
        fail("voiceCallReplyFailed")
    }

    /// A manual interruption also preserves already-captured opening words.
    func interruptAndListen() {
        guard isActive, authorized else { return }
        waitingForPlayback = false
        phase = isMicrophoneMuted ? .paused : .listening
        onChange?()
        if !isMicrophoneMuted, !inputRunning { beginInput(preserving: .listening) }
        if !automaticInterruptionAvailable, lastResultFinal, !transcript.isEmpty, phase == .listening { finishUtterance() }
        else if !speechActive { scheduleEndpoint() }
    }

    private func beginInput(preserving phase: Phase) {
        guard isActive, authorized, !isMicrophoneMuted else { return }
        stopInput()
        let token = generation
        let epoch = inputEpoch
        transcript = ""
        self.phase = phase
        onChange?()
        do {
            try input.listen(onResult: { [weak self] text, final in
                guard let self, generation == token, inputEpoch == epoch, isActive, !isMicrophoneMuted else { return }
                receive(text, final: final)
            }, onActivity: { [weak self] active in
                guard let self, generation == token, inputEpoch == epoch, isActive, !isMicrophoneMuted else { return }
                receiveActivity(active)
            }, onError: { [weak self] key in
                guard let self, generation == token, inputEpoch == epoch, isActive else { return }
                fail(key)
            })
            inputRunning = true
            automaticInterruptionAvailable = input.automaticInterruptionAvailable
            onChange?()
        } catch { fail((error as? LocalSpeechInput.Failure)?.key ?? "voiceCallInputUnavailable") }
    }

    private func receiveActivity(_ active: Bool) {
        automaticInterruptionAvailable = input.automaticInterruptionAvailable
        guard automaticInterruptionAvailable else {
            speechActive = false
            hasSpeechEvidence = false
            silenceTask?.cancel(); silenceTask = nil
            turnLimitTask?.cancel(); turnLimitTask = nil
            onChange?()
            return
        }
        speechActive = active
        if active {
            hasSpeechEvidence = true
            silenceTask?.cancel()
            silenceTask = nil
            ensureTurnLimit()
            maybeInterrupt()
        } else if phase == .listening, hasSpeechEvidence, !transcript.isEmpty {
            scheduleEndpoint()
        }
        onChange?()
    }

    private func receive(_ raw: String, final: Bool) {
        let text = String(raw.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return }
        transcript = text
        lastResultFinal = final
        onChange?()
        maybeInterrupt()
        guard phase == .listening else { return }
        if !automaticInterruptionAvailable {
            // Without a classifier, only Apple's explicit end-of-utterance result hands
            // off a turn; automatic interruption stays unavailable in the UI.
            if final { finishUtterance() }
        } else if hasSpeechEvidence, !speechActive { scheduleEndpoint() }
    }

    private func maybeInterrupt() {
        guard automaticInterruptionAvailable, hasSpeechEvidence, !transcript.isEmpty,
              phase == .thinking || phase == .speaking else { return }
        waitingForPlayback = false
        phase = .listening
        // Root cancels the old AI/TTS synchronously. Do not rotate ASR here: it already
        // contains the first words that caused the interruption.
        onInterrupt?()
        onChange?()
        if !speechActive { scheduleEndpoint() }
    }

    private func scheduleEndpoint() {
        guard automaticInterruptionAvailable, hasSpeechEvidence, silenceTask == nil,
              phase == .listening, !transcript.isEmpty else { return }
        let token = generation
        let epoch = turnEpoch
        silenceTask = scheduler.schedule(after: 0.75) { [weak self] in
            guard let self, generation == token, turnEpoch == epoch, isActive,
                  !isMicrophoneMuted, !speechActive, phase == .listening else { return }
            silenceTask = nil
            finishUtterance()
        }
    }

    private func ensureTurnLimit() {
        guard turnLimitTask == nil else { return }
        let token = generation
        let epoch = turnEpoch
        turnLimitTask = scheduler.schedule(after: 25) { [weak self] in
            guard let self, generation == token, turnEpoch == epoch else { return }
            turnLimitTask = nil
            guard phase == .listening else { return }
            if !transcript.isEmpty { finishUtterance() }
        }
    }

    private func finishUtterance() {
        guard phase == .listening, !transcript.isEmpty else { return }
        let text = transcript
        clearTurn()
        transcript = ""
        phase = .thinking
        waitingForPlayback = false
        do { try input.resetRecognition() }
        catch { fail("voiceCallRecognitionFailed"); return }
        let token = generation
        onChange?()
        guard generation == token, phase == .thinking else { return }
        onUtterance?(text)
    }

    private func clearTurn() {
        turnEpoch &+= 1
        silenceTask?.cancel(); silenceTask = nil
        turnLimitTask?.cancel(); turnLimitTask = nil
        speechActive = false
        hasSpeechEvidence = false
        lastResultFinal = false
    }

    private func stopInput() {
        inputEpoch &+= 1
        clearTurn()
        input.stop()
        inputRunning = false
        automaticInterruptionAvailable = false
    }

    private func fail(_ key: String) {
        generation &+= 1
        authorizationTask?.cancel(); authorizationTask = nil
        stopInput()
        input.releasePreparation()
        authorized = false
        waitingForPlayback = false
        transcript = ""
        errorKey = key
        preparation = nil
        phase = .failed
        onChange?()
    }
}
