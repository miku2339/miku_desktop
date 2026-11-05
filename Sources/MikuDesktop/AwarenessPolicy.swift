import Foundation

final class AwarenessCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum AwarenessSource: String, CaseIterable, Hashable {
    case activity, media, video, screen
    /// Little things she does on her own at random times (hums, asks you something, wants to play).
    case random
}

enum AwarenessPolicy {
    enum VideoSite: Equatable {
        case youtube, niconico
    }

    static func needsFrontmostApplication(enabledSources: Set<AwarenessSource>) -> Bool {
        !enabledSources.isDisjoint(with: [.activity, .video, .screen])
    }

    static func videoSite(for url: URL) -> VideoSite? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)

        if matches(host, domain: "youtube.com"), url.path == "/watch" {
            let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "v" })?.value
            return videoID?.isEmpty == false ? .youtube : nil
        }
        if matches(host, domain: "youtu.be"), components.count == 1 {
            return .youtube
        }
        if matches(host, domain: "nicovideo.jp"), components.count == 2,
           components.first == "watch", !components[1].isEmpty {
            return .niconico
        }
        return nil
    }

    static func canDeliver(
        requestGeneration: Int,
        currentGeneration: Int,
        sourceEnabled: Bool,
        isChatting: Bool
    ) -> Bool {
        requestGeneration == currentGeneration && sourceEnabled && !isChatting
    }

    /// `casualGap` is how long she waits between casual remarks (randomised by the service
    /// so she doesn't speak up like clockwork).
    /// Whether she may speak up on her own now. `unanswered` is how many of her lines in a row
    /// have had no reply: after one, even "welcome back" waits the usual gap; after two she stays
    /// quiet until you talk to her (persona §7: don't interrupt, don't nag, don't chase).
    static func canSpeak(
        lastSpoke: Date,
        now: Date,
        urgent: Bool,
        casualGap: TimeInterval = 20 * 60,
        unanswered: Int = 0
    ) -> Bool {
        if unanswered >= maximumUnanswered { return false }
        let gap = urgent && unanswered == 0 ? 3 * 60 : casualGap
        return now.timeIntervalSince(lastSpoke) >= gap
    }

    /// Her own lines in a row without a reply before she waits for you.
    static let maximumUnanswered = 2

    /// A new line that says the same as one she said lately: the same words, or the same
    /// opening ("回來啦？剛剛去哪裡了呀？" again and again).
    static func isRepeat(_ line: String, of recent: [String]) -> Bool {
        let new = normalizedLine(line)
        guard new.count >= 2 else { return false }
        return recent.map(normalizedLine).contains { old in
            guard old.count >= 2 else { return false }
            if new == old || new.contains(old) || old.contains(new) { return true }
            let opening = min(6, new.count, old.count)
            if opening >= 4 && new.prefix(opening) == old.prefix(opening) { return true }
            // Mostly the same words ("歡迎回來～剛剛去哪裡了呀" after "回來啦？剛剛去哪裡了呀").
            let shared = longestSharedRun(Array(new), Array(old))
            return shared >= 5 && Double(shared) >= Double(min(new.count, old.count)) * 0.6
        }
    }

    private static func longestSharedRun(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var best = 0
        for i in 1...a.count {
            var current = [Int](repeating: 0, count: b.count + 1)
            for j in 1...b.count where a[i - 1] == b[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }

    private static func normalizedLine(_ line: String) -> String {
        let folded = line.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(Character.init))
    }

    /// The things that can happen at random; the model turns one into a line of her own.
    static let randomEvents = ["hum", "question", "game", "snack", "idea", "stretch", "remember", "daydream"]

    static func appleScriptStringLiteral(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func matches(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
