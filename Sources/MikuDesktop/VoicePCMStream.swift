import Foundation

enum MikuVoiceStyle: String, CaseIterable, Sendable {
    case neutral, happy, gentle, sleepy

    static func fromEmotion(_ emotion: String) -> Self {
        switch emotion {
        case "happy", "curious": return .happy
        case "sad", "shy": return .gentle
        case "sleepy": return .sleepy
        default: return .neutral
        }
    }
}

struct VoiceAudioCapabilities: Decodable {
    let version: Int
    let model: String
    let languages: [String]
    let formats: [String]
    let styles: [String]
    let streamingLanguages: [String]

    enum CodingKeys: String, CodingKey {
        case version, model, languages, formats, styles
        case streamingLanguages = "streaming_languages"
    }

    static func decode(_ data: Data, model: String) throws -> Self {
        guard data.count <= 32_768 else { throw VoicePCMStreamError.invalidHeader }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let allowedLanguages: Set<String> = ["zh", "yue", "ja", "en", "ko"]
        guard value.version == 1, value.model == model,
              value.languages.count <= 5, Set(value.languages).isSubset(of: allowedLanguages),
              value.formats.count <= 8, value.formats.allSatisfy({ $0.utf8.count <= 64 }),
              value.styles.count <= 16, value.styles.allSatisfy({ $0.utf8.count <= 32 }),
              Set(value.streamingLanguages).isSubset(of: Set(value.languages)), value.streamingLanguages.count <= 5 else {
            throw VoicePCMStreamError.invalidHeader
        }
        return value
    }

    func canStream(language: String) -> Bool {
        formats.contains("pcm_s16le") && streamingLanguages.contains(language)
    }

    func style(_ requested: MikuVoiceStyle) -> String? {
        if styles.contains(requested.rawValue) { return requested.rawValue }
        return styles.contains(MikuVoiceStyle.neutral.rawValue) ? MikuVoiceStyle.neutral.rawValue : nil
    }
}

enum VoicePCMStreamError: Error, Equatable {
    case invalidHeader, invalidSequence, invalidAudio, overflow, truncated, trailingData
    case serverError(String)
}

struct VoicePCMFrame {
    enum Kind { case audio, end }
    let kind: Kind
    let sampleRate: Int
    let payload: Data
}

/// A network read is at most 4 KiB. Only the current header and PCM frame are retained.
struct VoicePCMStreamParser {
    static let maximumHeaderBytes = 65_536
    static let maximumFrameBytes = 65_536
    static let maximumTotalBytes = 32 * 1_024 * 1_024
    private static let maximumBufferedBytes = maximumHeaderBytes + maximumFrameBytes + 4_100

    private struct Header: Decodable {
        let v: Int
        let type: String
        let id: String
        let seq: Int
        let payloadBytes: Int
        let language: String?
        let seed: Int?
        let sampleRate: Int?
        let channels: Int?
        let format: String?
        let totalSamples: Int?
        let code: String?
        enum CodingKeys: String, CodingKey {
            case v, type, id, seq, language, seed, channels, format, code
            case payloadBytes = "payload_bytes", sampleRate = "sample_rate", totalSamples = "total_samples"
        }
    }

    let language: String
    private var buffer = Data()
    private var pendingHeader: Header?
    private var streamID: String?
    private var seed: Int?
    private var sampleRate: Int?
    private var nextSequence = 0
    private var totalBytes = 0
    private var headerBytes = 0
    private(set) var ended = false

    var bytesNeeded: Int {
        if let pendingHeader { return max(1, pendingHeader.payloadBytes - buffer.count) }
        if buffer.count < 4 { return 4 - buffer.count }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return max(1, 4 + length - buffer.count)
    }

    mutating func append(_ bytes: Data) throws -> [VoicePCMFrame] {
        guard !ended || bytes.isEmpty else { throw VoicePCMStreamError.trailingData }
        guard bytes.count <= Self.maximumBufferedBytes - buffer.count else { throw VoicePCMStreamError.overflow }
        buffer.append(bytes)
        var frames: [VoicePCMFrame] = []
        while !buffer.isEmpty {
            if pendingHeader == nil {
                guard buffer.count >= 4 else { break }
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= Self.maximumHeaderBytes else { throw VoicePCMStreamError.invalidHeader }
                guard headerBytes <= 2 * 1_024 * 1_024 - length, nextSequence < 4_096 else { throw VoicePCMStreamError.overflow }
                guard buffer.count >= 4 + length else { break }
                let data = Data(buffer.dropFirst(4).prefix(length))
                let header: Header
                do { header = try JSONDecoder().decode(Header.self, from: data) }
                catch { throw VoicePCMStreamError.invalidHeader }
                try validate(header)
                pendingHeader = header
                headerBytes += length
                buffer.removeFirst(4 + length)
            }
            guard let header = pendingHeader, buffer.count >= header.payloadBytes else { break }
            let payload = Data(buffer.prefix(header.payloadBytes))
            buffer.removeFirst(header.payloadBytes)
            pendingHeader = nil
            nextSequence += 1
            if header.type == "error" {
                let raw = header.code ?? "STREAM_FAILED"
                let code = raw.utf8.count <= 64 && raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? raw : "STREAM_FAILED"
                throw VoicePCMStreamError.serverError(code)
            }
            let rate = header.sampleRate!
            if header.type == "end" {
                guard totalBytes > 0, header.totalSamples == totalBytes / 2 else { throw VoicePCMStreamError.invalidAudio }
                ended = true
                guard buffer.isEmpty else { throw VoicePCMStreamError.trailingData }
                frames.append(VoicePCMFrame(kind: .end, sampleRate: rate, payload: Data()))
            } else {
                guard totalBytes <= Self.maximumTotalBytes - payload.count,
                      totalBytes / 2 + payload.count / 2 <= rate * 120 else { throw VoicePCMStreamError.overflow }
                totalBytes += payload.count
                frames.append(VoicePCMFrame(kind: .audio, sampleRate: rate, payload: payload))
            }
        }
        return frames
    }

    func finish() throws {
        guard ended, buffer.isEmpty, pendingHeader == nil else { throw VoicePCMStreamError.truncated }
    }

    private mutating func validate(_ header: Header) throws {
        guard header.v == 1, (1...128).contains(header.id.utf8.count),
              header.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || ".:_-".unicodeScalars.contains($0) }),
              ["audio", "end", "error"].contains(header.type),
              header.payloadBytes >= 0, header.payloadBytes <= Self.maximumFrameBytes else { throw VoicePCMStreamError.invalidHeader }
        guard header.seq == nextSequence, streamID == nil || streamID == header.id else { throw VoicePCMStreamError.invalidSequence }
        if header.type == "error" {
            guard header.payloadBytes == 0 else { throw VoicePCMStreamError.invalidHeader }
        } else {
            guard header.language == language, let rate = header.sampleRate, (8_000...96_000).contains(rate),
                  header.channels == 1, header.format == "pcm_s16le", let seed = header.seed,
                  (0...2_147_483_647).contains(seed), sampleRate == nil || sampleRate == rate,
                  self.seed == nil || self.seed == seed,
                  header.type == "audio" ? header.payloadBytes > 0 && header.payloadBytes % 2 == 0 : header.payloadBytes == 0 else {
                throw VoicePCMStreamError.invalidAudio
            }
            sampleRate = rate
            self.seed = seed
        }
        streamID = header.id
    }
}
