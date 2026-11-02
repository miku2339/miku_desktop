import AVFoundation
import CoreAudio
import Foundation
import SoundAnalysis

/// Acoustic speech evidence is separate from ASR text. Music and singing do not open an
/// interruption gate merely because a recognizer happened to return words.
struct VoiceCallSpeechActivity {
    private(set) var isActive = false
    private var quietWindows = 0

    mutating func observe(speech: Double, music: Double, singing: Double) -> Bool {
        if speech >= 0.8, music < 0.35, singing < 0.35 {
            quietWindows = 0
            isActive = true
        } else if speech < 0.45 || music >= 0.6 || singing >= 0.6 {
            quietWindows += 1
            if quietWindows >= 2 { isActive = false }
        }
        return isActive
    }
}

private final class VoiceCallSoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private var gate = VoiceCallSpeechActivity()
    private let onActivity: @Sendable (Bool) -> Void
    private let onFailure: @Sendable () -> Void

    init(onActivity: @escaping @Sendable (Bool) -> Void, onFailure: @escaping @Sendable () -> Void) {
        self.onActivity = onActivity
        self.onFailure = onFailure
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let scores = Dictionary(result.classifications.map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        onActivity(gate.observe(speech: scores["speech", default: 0], music: scores["music", default: 0], singing: scores["singing", default: 0]))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { onFailure() }
    func requestDidComplete(_ request: SNRequest) {}
}

/// SoundAnalysis runs on its own bounded queue; neither analyzer work nor borrowed input
/// buffers may accumulate indefinitely behind the audio tap.
private final class VoiceCallInputDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.qimake.MikuDesktop.voice-activity", qos: .userInitiated)
    private var enabled = true
    private var pending = 0
    private var framePosition: AVAudioFramePosition = 0
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private var analyzer: SNAudioStreamAnalyzer?
    private var observer: VoiceCallSoundObserver?

    init(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onActivity: @escaping @Sendable (Bool) -> Void, onAnalysisFailure: @escaping @Sendable () -> Void) {
        self.onBuffer = onBuffer
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            guard request.knownClassifications.contains("speech"), request.knownClassifications.contains("music"),
                  request.knownClassifications.contains("singing") else { return }
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let observer = VoiceCallSoundObserver(onActivity: onActivity, onFailure: onAnalysisFailure)
            try analyzer.add(request, withObserver: observer)
            self.analyzer = analyzer
            self.observer = observer
        } catch {}
    }

    var supportsSpeechActivity: Bool { analyzer != nil }

    func receive(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        onBuffer(buffer)
        let position = framePosition
        framePosition += AVAudioFramePosition(buffer.frameLength)
        guard let analyzer, pending < 4, let owned = Self.copy(buffer) else { lock.unlock(); return }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let shouldAnalyze = enabled
            lock.unlock()
            if shouldAnalyze { analyzer.analyze(owned, atAudioFramePosition: position) }
            lock.lock()
            pending -= 1
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        enabled = false
        lock.unlock()
        queue.async { [self] in analyzer?.removeAllRequests() }
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for index in 0..<from.count {
            guard let a = from[index].mData, let b = to[index].mData,
                  from[index].mDataByteSize <= to[index].mDataByteSize else { return nil }
            memcpy(b, a, Int(from[index].mDataByteSize))
        }
        return copy
    }
}

/// One voice-processing graph supplies both the echo-cancelled input and the TTS output
/// reference. Starting or finishing a sentence only touches the player, never the input.
@MainActor
final class VoiceCallAudio {
    static let shared = VoiceCallAudio()
    enum Failure: Error { case inputUnavailable, voiceProcessingUnavailable, invalidWAV, playbackUnavailable }
    private(set) var automaticInterruptionAvailable = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var delivery: VoiceCallInputDelivery?
    private var inputActive = false
    private var hasTap = false
    private var inputID = 0
    private var playbackID = 0
    private var playbackBuffer: AVAudioPCMBuffer?
    @MainActor private final class PCMPlayback {
        let inputFormat: AVAudioFormat
        let converter: AVAudioConverter?
        let onActivity: (Bool) -> Void
        let completion: (Bool) -> Void
        var buffers: [UUID: AVAudioPCMBuffer] = [:]
        var queuedDuration: TimeInterval = 0
        var waiter: CheckedContinuation<Void, Error>?
        var startTask: Task<Void, Never>?
        var audible = false
        var finished = false

        init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat, onActivity: @escaping (Bool) -> Void,
             completion: @escaping (Bool) -> Void) throws {
            self.inputFormat = inputFormat
            converter = inputFormat == outputFormat ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
            guard inputFormat == outputFormat || converter != nil else { throw Failure.playbackUnavailable }
            self.onActivity = onActivity
            self.completion = completion
        }
    }
    private var pcmPlayback: PCMPlayback?
    private var configurationObserver: NSObjectProtocol?

    func startInput(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
                    onActivity: @escaping @Sendable (Bool) -> Void,
                    onFailure: @escaping @Sendable (String) -> Void = { _ in }) throws {
        stopInput()
        if playbackBuffer == nil, pcmPlayback == nil {
            engine = nil
            player = nil
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, Self.hasInputDevice() else { throw Failure.inputUnavailable }
        if engine == nil { try makeGraph() }
        guard let engine else { throw Failure.inputUnavailable }
        let token = inputID
        let input = engine.inputNode
        input.isVoiceProcessingInputMuted = false
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.inputUnavailable }
        let delivery = VoiceCallInputDelivery(format: format, onBuffer: onBuffer, onActivity: onActivity, onAnalysisFailure: { [weak self] in
            Task { @MainActor in
                guard let self, self.inputID == token, self.inputActive else { return }
                self.automaticInterruptionAvailable = false
                onActivity(false)
            }
        })
        automaticInterruptionAvailable = delivery.supportsSpeechActivity
        self.delivery = delivery
        do {
            try Self.installTap(on: input, format: format) { buffer, _ in delivery.receive(buffer) }
            hasTap = true
            inputActive = true
            if !engine.isRunning { engine.prepare(); try engine.start() }
        } catch {
            stopInput()
            throw Failure.inputUnavailable
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            onFailure("voiceCallInputUnavailable")
        }
    }

    func stopInput() {
        inputID &+= 1
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        delivery?.close()
        delivery = nil
        if let engine {
            engine.inputNode.isVoiceProcessingInputMuted = true
            if hasTap { engine.inputNode.removeTap(onBus: 0) }
            if playbackBuffer == nil, pcmPlayback == nil { engine.stop() }
        }
        hasTap = false
        inputActive = false
        automaticInterruptionAvailable = false
    }

    @discardableResult
    func playWAV(_ data: Data, completion: @escaping (Bool) -> Void) throws -> TimeInterval {
        let decoded = try VoiceCallWAV.decode(data)
        guard let engine, let player else { throw Failure.playbackUnavailable }
        let format = player.outputFormat(forBus: 0)
        let buffer = try VoiceCallWAV.convert(decoded, to: format)
        stopPlayback()
        playbackID &+= 1
        let token = playbackID
        playbackBuffer = buffer
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
        } catch {
            playbackBuffer = nil
            throw Failure.playbackUnavailable
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] type in
            Task { @MainActor in
                guard let self, self.playbackID == token, self.playbackBuffer != nil else { return }
                self.playbackBuffer = nil
                if !self.inputActive { self.engine?.stop() }
                completion(type == .dataPlayedBack)
            }
        }
        do {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { try player.playAudio() }
            else { player.play() }
            #else
            player.play()
            #endif
        } catch {
            stopPlayback()
            throw Failure.playbackUnavailable
        }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }

    func stopPlayback() {
        playbackID &+= 1
        playbackBuffer = nil
        let stream = pcmPlayback
        pcmPlayback = nil
        stream?.startTask?.cancel()
        stream?.waiter?.resume(throwing: CancellationError())
        stream?.waiter = nil
        player?.stop()
        if !inputActive { engine?.stop() }
    }

    func beginPCMStream(sampleRate: Int, onActivity: @escaping (Bool) -> Void, completion: @escaping (Bool) -> Void) throws {
        guard (8_000...96_000).contains(sampleRate), let player,
              let inputFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1) else {
            throw Failure.playbackUnavailable
        }
        stopPlayback()
        pcmPlayback = try PCMPlayback(inputFormat: inputFormat, outputFormat: player.outputFormat(forBus: 0),
                                      onActivity: onActivity, completion: completion)
    }

    /// Awaiting playback capacity also pauses the network reader. Only two seconds of
    /// decoded buffers can be scheduled, independent of the sentence length.
    func appendPCMStream(_ data: Data) async throws {
        guard let stream = pcmPlayback, !stream.finished, !data.isEmpty, data.count <= 65_536, data.count % 2 == 0 else {
            throw Failure.invalidWAV
        }
        let maximumSamples = max(1, Int(stream.inputFormat.sampleRate / 4))
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard pcmPlayback === stream else { throw CancellationError() }
            let count = min(maximumSamples, (data.count - offset) / 2)
            guard let source = AVAudioPCMBuffer(pcmFormat: stream.inputFormat, frameCapacity: AVAudioFrameCount(count)) else {
                throw Failure.invalidWAV
            }
            source.frameLength = AVAudioFrameCount(count)
            let bytes = [UInt8](data[offset..<(offset + count * 2)])
            for index in 0..<count {
                let value = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
                source.floatChannelData![0][index] = Float(value) / 32_768
            }
            offset += count * 2
            let converted = try convertPCM(source, stream: stream)
            if converted.frameLength > 0 { try await schedulePCM(converted, stream: stream) }
        }
    }

    func finishPCMStream() async throws {
        guard let stream = pcmPlayback, !stream.finished else { throw Failure.playbackUnavailable }
        if let converter = stream.converter, let player {
            var flushed = false
            for _ in 0..<8 {
                guard let tail = AVAudioPCMBuffer(pcmFormat: player.outputFormat(forBus: 0), frameCapacity: 256) else {
                    throw Failure.invalidWAV
                }
                var error: NSError?
                let status = converter.convert(to: tail, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                guard status != .error, error == nil else { throw Failure.invalidWAV }
                if tail.frameLength > 0 { try await schedulePCM(tail, stream: stream) }
                if status == .endOfStream || tail.frameLength == 0 { flushed = true; break }
            }
            guard flushed else { throw Failure.invalidWAV }
        }
        guard pcmPlayback === stream else { throw CancellationError() }
        stream.finished = true
        completePCMIfDrained(stream)
    }

    private func convertPCM(_ source: AVAudioPCMBuffer, stream: PCMPlayback) throws -> AVAudioPCMBuffer {
        guard let converter = stream.converter else { return source }
        let size = ceil(Double(source.frameLength) * converter.outputFormat.sampleRate / source.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(size)) else {
            throw Failure.invalidWAV
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return source
        }
        guard status != .error, error == nil else { throw Failure.invalidWAV }
        return output
    }

    private func schedulePCM(_ buffer: AVAudioPCMBuffer, stream: PCMPlayback) async throws {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        while pcmPlayback === stream, stream.queuedDuration + duration > 2.001 {
            try await withCheckedThrowingContinuation { continuation in stream.waiter = continuation }
            try Task.checkCancellation()
        }
        guard pcmPlayback === stream, let player, let engine else { throw CancellationError() }
        if !engine.isRunning { engine.prepare(); try engine.start() }
        let id = UUID()
        stream.buffers[id] = buffer
        stream.queuedDuration += duration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, weak stream] type in
            Task { @MainActor in
                guard let self, let stream, self.pcmPlayback === stream,
                      stream.buffers.removeValue(forKey: id) != nil else { return }
                stream.queuedDuration = max(0, stream.queuedDuration - duration)
                guard type == .dataPlayedBack else { self.stopPlayback(); stream.completion(false); return }
                let waiter = stream.waiter; stream.waiter = nil; waiter?.resume()
                if stream.buffers.isEmpty, stream.audible {
                    stream.audible = false
                    stream.onActivity(false)
                }
                self.completePCMIfDrained(stream)
            }
        }
        if !player.isPlaying {
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { try player.playAudio() }
            else { player.play() }
            #else
            player.play()
            #endif
        }
        if !stream.audible, stream.startTask == nil {
            let initialTime = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
            stream.startTask = Task { @MainActor [weak self, weak stream] in
                defer { stream?.startTask = nil }
                while let self, let stream, self.pcmPlayback === stream, !stream.buffers.isEmpty, !Task.isCancelled {
                    let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }?.sampleTime ?? 0
                    if player.isPlaying, time > initialTime {
                        stream.audible = true
                        stream.onActivity(true)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
    }

    private func completePCMIfDrained(_ stream: PCMPlayback) {
        guard pcmPlayback === stream, stream.finished, stream.buffers.isEmpty else { return }
        pcmPlayback = nil
        stream.startTask?.cancel()
        if !inputActive { engine?.stop() }
        stream.completion(true)
    }

    private func makeGraph() throws {
        let engine = AVAudioEngine()
        // This must precede engine.start(); enabling one IO node also enables its peer.
        do { try engine.inputNode.setVoiceProcessingEnabled(true) }
        catch { throw Failure.voiceProcessingUnavailable }
        guard engine.inputNode.isVoiceProcessingEnabled, engine.outputNode.isVoiceProcessingEnabled else { throw Failure.voiceProcessingUnavailable }
        let outputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0,
              let playerFormat = AVAudioFormat(standardFormatWithSampleRate: outputFormat.sampleRate, channels: 1) else { throw Failure.inputUnavailable }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            try engine.connectNode(player, to: engine.mainMixerNode, format: playerFormat)
            try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        }
        #else
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        #endif
        let reference = engine.outputNode.inputFormat(forBus: 0)
        guard reference.sampleRate == outputFormat.sampleRate, reference.channelCount == outputFormat.channelCount else { throw Failure.voiceProcessingUnavailable }
        self.engine = engine
        self.player = player
    }

    private static func hasInputDevice() -> Bool {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr && device != kAudioObjectUnknown
    }

    private static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            try node.__installTap(onBus: 0, bufferSize: 1_024, format: format, error: (), block: block)
        } else { node.installTap(onBus: 0, bufferSize: 1_024, format: format, block: block) }
        #else
        node.installTap(onBus: 0, bufferSize: 1_024, format: format, block: block)
        #endif
    }
}

/// Bounded PCM WAV decoding and conversion, entirely in memory. Chunk padding and PCM
/// sample width are read from the file instead of assuming a fixed 44-byte header.
enum VoiceCallWAV {
    static let maximumBytes = 64 * 1_024 * 1_024
    static func decode(_ data: Data) throws -> AVAudioPCMBuffer {
        guard data.count >= 44, data.count <= maximumBytes else { throw VoiceCallAudio.Failure.invalidWAV }
        return try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
            func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
            func tag(_ i: Int, _ value: [UInt8]) -> Bool { value.enumerated().allSatisfy { bytes[i + $0.offset] == $0.element } }
            guard tag(0, [82, 73, 70, 70]), tag(8, [87, 65, 86, 69]), u32(4) + 8 <= data.count else { throw VoiceCallAudio.Failure.invalidWAV }
            let end = u32(4) + 8
            var offset = 12
            var fields: (channels: Int, rate: Int, bits: Int, align: Int)?
            var samples: Range<Int>?
            while offset + 8 <= end {
                let size = u32(offset + 4)
                let start = offset + 8
                guard size <= end - start else { throw VoiceCallAudio.Failure.invalidWAV }
                if tag(offset, [102, 109, 116, 32]) {
                    guard size >= 16, u16(start) == 1 else { throw VoiceCallAudio.Failure.invalidWAV }
                    fields = (u16(start + 2), u32(start + 4), u16(start + 14), u16(start + 12))
                } else if tag(offset, [100, 97, 116, 97]) { samples = start..<(start + size) }
                offset = start + size + (size & 1)
            }
            guard let fields, let samples, (1...2).contains(fields.channels), (8_000...192_000).contains(fields.rate),
                  [16, 24, 32].contains(fields.bits), fields.align == fields.channels * fields.bits / 8,
                  !samples.isEmpty, samples.count % fields.align == 0 else { throw VoiceCallAudio.Failure.invalidWAV }
            let frames = samples.count / fields.align
            guard frames * fields.channels <= 12_000_000, Double(frames) / Double(fields.rate) <= 120,
                  let format = AVAudioFormat(standardFormatWithSampleRate: Double(fields.rate), channels: AVAudioChannelCount(fields.channels)),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channels = pcm.floatChannelData else { throw VoiceCallAudio.Failure.invalidWAV }
            pcm.frameLength = AVAudioFrameCount(frames)
            let width = fields.bits / 8
            for frame in 0..<frames {
                for channel in 0..<fields.channels {
                    let index = samples.lowerBound + frame * fields.align + channel * width
                    let value: Float
                    if width == 2 { value = Float(Int16(bitPattern: UInt16(u16(index)))) / 32_768 }
                    else if width == 3 {
                        var bits = UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
                        if bits & 0x800000 != 0 { bits |= 0xFF000000 }
                        value = Float(Int32(bitPattern: bits)) / 8_388_608
                    } else { value = Float(Int32(bitPattern: UInt32(u32(index)))) / 2_147_483_648 }
                    channels[channel][frame] = value
                }
            }
            return pcm
        }
    }

    static func convert(_ source: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        let capacity = ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 64
        guard capacity > 0, capacity <= 12_000_000,
              let converter = AVAudioConverter(from: source.format, to: format),
              let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else { throw VoiceCallAudio.Failure.invalidWAV }
        var provided = false
        var conversionError: NSError?
        let result = converter.convert(to: converted, error: &conversionError) { _, state in
            if provided { state.pointee = .endOfStream; return nil }
            provided = true
            state.pointee = .haveData
            return source
        }
        guard conversionError == nil, result != .error, converted.frameLength > 0 else { throw VoiceCallAudio.Failure.invalidWAV }
        return converted
    }
}
