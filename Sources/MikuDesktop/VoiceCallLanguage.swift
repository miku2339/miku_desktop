import Foundation

enum VoiceCallLanguage: String, CaseIterable, Sendable {
    case mandarin = "zh"
    case cantonese = "yue"
    case japanese = "ja"
    case english = "en"
    case korean = "ko"

    var localeIdentifier: String {
        switch self {
        case .mandarin: return "zh-TW"
        case .cantonese: return "zh-HK"
        case .japanese: return "ja-JP"
        case .english: return "en-US"
        case .korean: return "ko-KR"
        }
    }

    var localizationKey: String {
        switch self {
        case .mandarin: return "voiceCallLanguageMandarin"
        case .cantonese: return "voiceCallLanguageCantonese"
        case .japanese: return "voiceCallLanguageJapanese"
        case .english: return "voiceCallLanguageEnglish"
        case .korean: return "voiceCallLanguageKorean"
        }
    }

    var separatesWords: Bool { self == .english || self == .korean }
}

enum VoiceCallPreparation: Equatable, Sendable {
    case checking, downloading, ready
}

/// SpeechAnalyzer reports segments, including revisions of a volatile segment.
/// An audio-time boundary keeps late results from a completed turn out of the next one.
struct VoiceCallTranscript {
    private struct Segment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }
    private var segments: [Segment] = []
    private(set) var boundary: TimeInterval = 0
    let separatesWords: Bool

    mutating func reset(after time: TimeInterval) {
        boundary = max(boundary, time)
        segments.removeAll(keepingCapacity: false)
    }

    mutating func receive(_ text: String, start: TimeInterval, end: TimeInterval) -> String? {
        guard start.isFinite, end.isFinite, end > start, start >= boundary else { return nil }
        let clean = String(text.prefix(1_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        segments.removeAll { $0.start < end && $0.end > start }
        segments.append(Segment(start: start, end: end, text: clean))
        segments.sort { $0.start < $1.start }
        while segments.count > 128 { segments.removeFirst() }
        return String(segments.map(\.text).joined(separator: separatesWords ? " " : "").prefix(1_000))
    }
}
