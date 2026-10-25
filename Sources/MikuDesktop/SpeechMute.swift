import Foundation

extension Notification.Name {
    /// Posted when Miku's voice is muted or unmuted (the chat button and the ♪ menu follow it).
    static let mikuSpeechMuteChanged = Notification.Name("com.qimake.MikuDesktop.speechMuteChanged")
}

/// A quick "be quiet" for Miku's voice, separate from turning reading aloud off in Settings.
///
/// Two independent reasons to be quiet:
/// - you muted her: for a while (say an hour) or until you unmute; a timed mute runs out;
/// - an automation said so (a Shortcuts automation for a Focus, through the
///   `miku-desktop://quiet/on` link) until it says `quiet/off`. Focus turning off only
///   clears its own quiet, never a mute you set yourself.
/// Unmuting by hand clears both. Everything survives a relaunch. While muted nothing is
/// generated; the bubble and her mouth still work, and replays you ask for still play.
struct SpeechMute {
    static let mutedKey = "speechMuted"
    static let untilKey = "speechMutedUntil"
    static let automationKey = "speechQuietByAutomation"
    static let hour: TimeInterval = 60 * 60

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isMuted(at now: Date = Date()) -> Bool {
        isMutedByHand(at: now) || isQuietByAutomation
    }

    /// Muted with the button or the menu (not by an automation).
    func isMutedByHand(at now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: Self.mutedKey) else { return false }
        let until = defaults.double(forKey: Self.untilKey)
        if until > 0, now.timeIntervalSince1970 >= until {
            defaults.removeObject(forKey: Self.mutedKey)
            defaults.removeObject(forKey: Self.untilKey)
            return false
        }
        return true
    }

    var isQuietByAutomation: Bool {
        defaults.bool(forKey: Self.automationKey)
    }

    /// When a timed mute ends; nil when not muted by hand or muted until unmuted.
    func mutedUntil(at now: Date = Date()) -> Date? {
        guard isMutedByHand(at: now) else { return nil }
        let until = defaults.double(forKey: Self.untilKey)
        return until > 0 ? Date(timeIntervalSince1970: until) : nil
    }

    /// `duration` nil mutes until unmuted.
    func mute(for duration: TimeInterval?, now: Date = Date()) {
        defaults.set(true, forKey: Self.mutedKey)
        if let duration, duration > 0 {
            defaults.set(now.addingTimeInterval(duration).timeIntervalSince1970, forKey: Self.untilKey)
        } else {
            defaults.removeObject(forKey: Self.untilKey)
        }
    }

    func setQuietByAutomation(_ quiet: Bool) {
        if quiet {
            defaults.set(true, forKey: Self.automationKey)
        } else {
            defaults.removeObject(forKey: Self.automationKey)
        }
    }

    /// Unmuting by hand: whatever the reason, she may talk again.
    func unmute() {
        defaults.removeObject(forKey: Self.mutedKey)
        defaults.removeObject(forKey: Self.untilKey)
        defaults.removeObject(forKey: Self.automationKey)
    }
}

/// What a `miku-desktop://` link asks for. Only these few, harmless voice commands exist,
/// so a link opened by anything else can at worst mute or unmute her.
///
/// - `miku-desktop://quiet/on` / `quiet/off`: for Shortcuts automations (e.g. a Focus)
/// - `miku-desktop://mute` (until unmuted), `miku-desktop://mute?minutes=60`
/// - `miku-desktop://unmute`
enum SpeechLinkCommand: Equatable {
    case quiet(Bool)
    case mute(minutes: Int?)
    case unmute

    static let scheme = "miku-desktop"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let host = components.host?.lowercased() else { return nil }
        let path = components.path.lowercased()
        switch (host, path) {
        case ("quiet", "/on"):
            guard components.query == nil else { return nil }
            self = .quiet(true)
        case ("quiet", "/off"):
            guard components.query == nil else { return nil }
            self = .quiet(false)
        case ("mute", ""), ("mute", "/"):
            guard components.query != nil else {
                self = .mute(minutes: nil)
                return
            }
            guard let items = components.queryItems, items.count == 1,
                  items[0].name == "minutes", let value = items[0].value,
                  let minutes = Int(value), (1...1_440).contains(minutes) else { return nil }
            self = .mute(minutes: minutes)
        case ("unmute", ""), ("unmute", "/"):
            guard components.query == nil else { return nil }
            self = .unmute
        default:
            return nil
        }
    }
}
