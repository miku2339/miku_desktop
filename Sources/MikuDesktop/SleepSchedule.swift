import Foundation

extension Notification.Name {
    /// Posted when Miku is told to go to bed or get up (both page layers follow it).
    static let mikuSleepChanged = Notification.Name("com.qimake.MikuDesktop.sleepChanged")
}

@MainActor
final class BedtimeScheduler {
    private var task: Task<Void, Never>?
    private var sequence = 0

    var hasPendingTask: Bool { task != nil }

    func schedule(
        afterNanoseconds delay: UInt64,
        ifStillCurrent: @escaping @MainActor () -> Bool,
        action: @escaping @MainActor () -> Void
    ) {
        cancel()
        let token = sequence
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            defer {
                if sequence == token { task = nil }
            }
            guard !Task.isCancelled, sequence == token, ifStillCurrent() else { return }
            action()
        }
    }

    func cancel() {
        sequence &+= 1
        task?.cancel()
        task = nil
    }
}

/// When Miku sleeps. She sleeps from 1:00 to 7:00 on her own; saying good night sends her
/// to bed early, waking her (or chatting to her) keeps her up for a while. The temporary
/// override is kept here so both page layers, the chat and the next launch all agree.
@MainActor
final class SleepSchedule {
    static let shared = SleepSchedule()

    static let startHour = 1
    static let endHour = 7
    private static let overrideAsleepKey = "sleep.override.asleep"
    private static let overrideUntilKey = "sleep.override.until"

    private let defaults: UserDefaults
    private(set) var override: (asleep: Bool, until: Date)?
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let until = defaults.double(forKey: Self.overrideUntilKey)
        if until > now.timeIntervalSince1970, defaults.object(forKey: Self.overrideAsleepKey) != nil {
            override = (defaults.bool(forKey: Self.overrideAsleepKey), Date(timeIntervalSince1970: until))
        }
    }

    static func scheduledAsleep(at date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= startHour && hour < endHour
    }

    func isAsleep(at date: Date = Date()) -> Bool {
        if let override, date < override.until { return override.asleep }
        return Self.scheduledAsleep(at: date)
    }

    /// For the page: `{ override: { asleep, until (ms) } | null }`.
    var payload: [String: Any] {
        guard let override, override.until > Date() else { return ["override": NSNull()] }
        let value: [String: Any] = ["asleep": override.asleep, "until": (override.until.timeIntervalSince1970 * 1000).rounded()]
        return ["override": value]
    }

    func set(asleep: Bool, until: Date) {
        revision &+= 1
        override = (asleep, until)
        defaults.set(asleep, forKey: Self.overrideAsleepKey)
        defaults.set(until.timeIntervalSince1970, forKey: Self.overrideUntilKey)
        NotificationCenter.default.post(name: .mikuSleepChanged, object: self)
    }

    /// "Good night": late in the evening she sleeps until morning; earlier it's a nap.
    func goToBed(now: Date = Date()) {
        let hour = Calendar.current.component(.hour, from: now)
        if hour >= 20 || hour < Self.endHour {
            set(asleep: true, until: Self.next(hour: Self.endHour, after: now))
        } else {
            set(asleep: true, until: now.addingTimeInterval(45 * 60))
        }
    }

    /// Up for a while (woken by a touch, a message or "good morning").
    func wake(minutes: Double, now: Date = Date()) {
        set(asleep: false, until: now.addingTimeInterval(minutes * 60))
    }

    /// "Good morning": up for the day, until her usual bedtime.
    func goodMorning(now: Date = Date()) {
        set(asleep: false, until: Self.next(hour: Self.startHour, after: now))
    }

    private static func next(hour: Int, after date: Date) -> Date {
        let calendar = Calendar.current
        let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
        return candidate > date ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    // MARK: - Recognising good night / good morning

    static func isGoodNight(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["晚安", "早唞", "good night", "goodnight", "nighty night", "おやすみ", "お休み"].contains { lowered.contains($0) }
    }

    static func isGoodMorning(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["早晨", "早安", "早上好", "good morning", "morning!", "おはよう"].contains { lowered.contains($0) }
    }
}
