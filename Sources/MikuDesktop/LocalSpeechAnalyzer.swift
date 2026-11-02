import AVFoundation
import CoreMedia
import Foundation
import Speech

@MainActor
protocol LocalSpeechAnalyzing: AnyObject {
    func start(feed: VoiceCallPCMFeed, onResult: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void)
    func reset()
    func stop()
}

@available(macOS 26.0, *)
@MainActor
enum LocalSpeechResources {
    static func canUse(status: AssetInventory.Status, locale: Locale, installedLocales: [Locale]) -> Bool {
        guard status != .unsupported else { return false }
        if status == .installed { return true }
        guard status == .supported else { return false }
        func identifier(_ locale: Locale) -> String {
            locale.identifier(.bcp47).lowercased()
        }
        return installedLocales.contains { identifier($0) == identifier(locale) }
    }

    static func prepare(language: VoiceCallLanguage, onState: @escaping (VoiceCallPreparation) -> Void) async throws {
        onState(.checking)
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language.localeIdentifier)) else {
            throw LocalSpeechInput.Failure.languageUnsupported
        }
        try Task.checkCancellation()
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [module])
        guard status != .unsupported else { throw LocalSpeechInput.Failure.languageUnsupported }
        let installed = await SpeechTranscriber.installedLocales
        if !canUse(status: status, locale: locale, installedLocales: installed) {
            let reserved = await AssetInventory.reservedLocales
            let alreadyReserved = reserved.contains { $0.identifier == locale.identifier }
            if !alreadyReserved {
                guard try await AssetInventory.reserve(locale: locale) else {
                    throw LocalSpeechInput.Failure.resourceDownloadFailed
                }
            }
            do {
                try Task.checkCancellation()
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                    throw LocalSpeechInput.Failure.resourceDownloadFailed
                }
                onState(.downloading)
                try await withTaskCancellationHandler {
                    try await request.downloadAndInstall()
                    try Task.checkCancellation()
                } onCancel: {
                    request.progress.cancel()
                }
            } catch {
                if !alreadyReserved { await AssetInventory.release(reservedLocale: locale) }
                try Task.checkCancellation()
                throw LocalSpeechInput.Failure.resourceDownloadFailed
            }
            let finalStatus = await AssetInventory.status(forModules: [module])
            let finalInstalled = await SpeechTranscriber.installedLocales
            guard canUse(status: finalStatus, locale: locale, installedLocales: finalInstalled) else {
                if !alreadyReserved { await AssetInventory.release(reservedLocale: locale) }
                throw LocalSpeechInput.Failure.resourceDownloadFailed
            }
        }
        try Task.checkCancellation()
        onState(.ready)
    }
}

/// The tap owns its buffers only until the next render callback. Copy before handing
/// them to the serialized converter, and fail rather than silently dropping audio.
@available(macOS 26.0, *)
private final class SpeechAnalyzerPCMFeed: @unchecked Sendable {
    let stream: AsyncThrowingStream<AnalyzerInput, Error>
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let queue = DispatchQueue(label: "com.qimake.MikuDesktop.speech-converter")
    private let lock = NSLock()
    private let format: AVAudioFormat
    private let onFailure: @Sendable () -> Void
    private var converter: AVAudioConverter?
    private var enabled = true
    private var pending = 0
    private var receivedTime: TimeInterval = 0

    init(format: AVAudioFormat, onFailure: @escaping @Sendable () -> Void) {
        self.format = format
        self.onFailure = onFailure
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        stream = pair.stream
        continuation = pair.continuation
    }

    var endTime: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return receivedTime
    }

    func append(_ source: AVAudioPCMBuffer) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        guard pending < 16, source.format.sampleRate > 0, let copy = VoiceCallPCMFeed.copy(source) else {
            lock.unlock(); fail(); return
        }
        let start = receivedTime
        receivedTime += Double(source.frameLength) / source.format.sampleRate
        pending += 1
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            lock.lock(); let active = enabled; lock.unlock()
            guard active else { return }
            do {
                let converted = try convert(copy)
                guard converted.frameLength > 0 else { return }
                let input = AnalyzerInput(buffer: converted, bufferStartTime: CMTime(seconds: start, preferredTimescale: 48_000))
                if case .dropped = continuation.yield(input) { fail() }
            } catch { fail() }
        }
    }

    func finish() {
        lock.lock(); enabled = false; lock.unlock()
        continuation.finish()
    }

    private func fail() {
        lock.lock()
        let report = enabled
        enabled = false
        lock.unlock()
        guard report else { return }
        continuation.finish(throwing: LocalSpeechInput.Failure.inputUnavailable)
        onFailure()
    }

    private func convert(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        if converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: format)
        }
        let size = ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 64
        guard let converter, size <= Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(size)) else {
            throw LocalSpeechInput.Failure.inputUnavailable
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return source
        }
        guard status != .error, error == nil else { throw LocalSpeechInput.Failure.inputUnavailable }
        return output
    }
}

@available(macOS 26.0, *)
@MainActor
final class LocalSpeechAnalyzerSession: LocalSpeechAnalyzing {
    let format: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var pcmFeed: SpeechAnalyzerPCMFeed?
    private var resultsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var transcript: VoiceCallTranscript
    private var active = false

    init(language: VoiceCallLanguage, format: AVAudioFormat) {
        self.format = format
        transcript = VoiceCallTranscript(separatesWords: language.separatesWords)
        transcriber = SpeechTranscriber(locale: Locale(identifier: language.localeIdentifier), transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
    }

    static func prepare(language: VoiceCallLanguage, onState: @escaping (VoiceCallPreparation) -> Void) async throws -> LocalSpeechAnalyzerSession {
        try await LocalSpeechResources.prepare(language: language, onState: onState)
        let module = SpeechTranscriber(locale: Locale(identifier: language.localeIdentifier), preset: .progressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw LocalSpeechInput.Failure.inputUnavailable
        }
        let session = LocalSpeechAnalyzerSession(language: language, format: format)
        try await session.analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        return session
    }

    func start(feed: VoiceCallPCMFeed, onResult: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void) {
        active = true
        let sink = SpeechAnalyzerPCMFeed(format: format) { [weak self] in
            Task { @MainActor in
                guard let self, self.active else { return }
                onError(LocalSpeechInput.Failure.inputUnavailable.key)
            }
        }
        pcmFeed = sink
        feed.replace(append: { sink.append($0) }, end: { sink.finish() })
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, active, !Task.isCancelled else { return }
                    let start = CMTimeGetSeconds(result.range.start)
                    let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    var text = String(result.text.characters)
                    var acceptedStart = start
                    if start < transcript.boundary {
                        // Only timed words wholly after the turn boundary can be retained
                        // when a late result contains both old and new audio.
                        let fresh = result.text.runs.filter {
                            guard let time = $0.audioTimeRange else { return false }
                            return CMTimeGetSeconds(time.start) >= self.transcript.boundary
                        }
                        guard let first = fresh.first, let time = first.audioTimeRange else { continue }
                        text = fresh.map { String(result.text[$0.range].characters) }.joined()
                        acceptedStart = CMTimeGetSeconds(time.start)
                    }
                    if let full = transcript.receive(text, start: acceptedStart, end: end) {
                        onResult(full, result.isFinal)
                    }
                }
            } catch {
                guard let self, active, !Task.isCancelled else { return }
                onError(LocalSpeechInput.Failure.recognitionFailed.key)
            }
        }
        analysisTask = Task { [weak self, analyzer] in
            do { try await analyzer.start(inputSequence: sink.stream) }
            catch {
                guard let self, active, !Task.isCancelled else { return }
                onError(LocalSpeechInput.Failure.recognitionFailed.key)
            }
        }
    }

    func reset() {
        transcript.reset(after: pcmFeed?.endTime ?? 0)
    }

    func stop() {
        active = false
        pcmFeed?.finish(); pcmFeed = nil
        resultsTask?.cancel(); resultsTask = nil
        analysisTask?.cancel(); analysisTask = nil
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
