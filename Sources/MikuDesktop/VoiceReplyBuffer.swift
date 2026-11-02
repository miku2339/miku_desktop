import Foundation

/// Keep the actually completed audio separate from the full generated answer when a
/// caller interrupts during a sentence or while the following sentence is generating.
struct VoiceReplyProgress {
    private(set) var completedText = ""
    private(set) var hasStarted = false

    mutating func started() {
        hasStarted = true
    }

    mutating func segmentFinished(_ text: String) {
        completedText += text
    }
}

/// Only complete spoken phrases leave the buffer. A rewritten response cannot replay
/// a different ending after part of the original response has already been spoken.
struct VoiceReplyBuffer {
    enum Failure: Error { case changedPrefix, tooLong, alreadyFinished }

    private(set) var text = ""
    private var pending = ""
    private var finished = false

    mutating func append(_ cumulative: String, final: Bool = false) throws -> [String] {
        guard !finished else { throw Failure.alreadyFinished }
        guard cumulative.count <= 16_000 else { throw Failure.tooLong }
        guard cumulative.hasPrefix(text) else { throw Failure.changedPrefix }
        pending += cumulative.dropFirst(text.count)
        text = cumulative
        var phrases: [String] = []
        while let boundary = phraseBoundary(final: final) {
            let phrase = String(pending[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(..<boundary)
            if phrase.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                phrases.append(phrase)
            }
        }
        if final {
            finished = true
            let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                phrases.append(tail)
            }
            pending = ""
        }
        return phrases
    }

    private func phraseBoundary(final: Bool) -> String.Index? {
        let closers: Set<Character> = ["」", "』", "）", ")", "\"", "”", "’"]
        for index in pending.indices {
            let character = pending[index]
            let next = pending.index(after: index)
            let isFullStop = character == "." && (next < pending.endIndex
                ? pending[next].isWhitespace : final)
            let isSentence = "。！？!?\n".contains(character) || isFullStop
            let length = pending.distance(from: pending.startIndex, to: next)
            let isPhrase = length >= 80 && "，,；;".contains(character)
            guard isSentence || isPhrase else { continue }
            var end = next
            while end < pending.endIndex, closers.contains(pending[end]) || "。！？!?".contains(pending[end]) {
                end = pending.index(after: end)
            }
            return end
        }
        return nil
    }
}
