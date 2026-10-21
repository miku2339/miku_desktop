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

    static func canSpeak(lastSpoke: Date, now: Date, urgent: Bool) -> Bool {
        now.timeIntervalSince(lastSpoke) >= (urgent ? 3 * 60 : 20 * 60)
    }

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
