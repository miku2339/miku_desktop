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

    /// Explicitly staying awake always wins over a bedtime phrase in the same message.
    static func declinesBedtime(_ text: String) -> Bool {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        if ["why don't you go to sleep", "why don't you go to bed"].contains(where: { lowered.contains($0) }) {
            return false
        }
        return [
            "不想睡", "不想去睡", "不要睡", "不要去睡", "不用睡", "不用去睡", "不需要睡", "不需要去睡", "別睡", "别睡", "不能睡", "我不睡", "睡不著", "睡不着", "不睏", "不困",
            "唔想瞓", "唔想去瞓", "唔好瞓", "唔使瞓", "唔使去瞓", "我唔瞓", "瞓唔着", "瞓唔著",
            "眠れない", "眠くない", "寝たくない", "眠りたくない", "寝られない", "寝ないで", "まだ寝ない", "寝る気はない", "寝る必要はない",
            "can't sleep", "cannot sleep", "can’t sleep", "don't want to sleep", "do not want to sleep", "don't want to go to sleep", "do not want to go to sleep",
            "don't want to go to bed", "do not want to go to bed", "don't go to sleep", "do not go to sleep", "don't go to bed", "do not go to bed",
            "not going to sleep", "not going to bed", "not going to go to sleep", "not going to go to bed",
            "won't go to sleep", "won't go to bed", "don't need to sleep", "do not need to sleep", "don't need to go to bed", "do not need to go to bed",
            "not sleepy", "not tired"
        ].contains { lowered.contains($0) }
    }

    /// Telling her to go to bed, or saying you're off to bed, sends her to bed too, not
    /// just the words "good night" ("你還不上床睡覺嗎", "I'm off to bed", "もう寝るね").
    static func isBedtimeRequest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if declinesBedtime(text) { return false }
        if isGoodNightFarewell(text) { return true }
        return [
            "去睡", "快睡", "睡吧", "睡覺吧", "睡觉吧", "上床", "該睡", "该睡", "早點睡", "早点睡", "要睡了", "要睡覺了", "要睡觉了",
            "想睡了", "想睡覺了", "想睡觉了", "我睡了", "準備睡", "准备睡", "去瞓", "瞓覺", "瞓啦", "瞓喇", "想瞓", "要瞓", "準備瞓",
            "寝よう", "寝てね", "寝なよ", "寝なさい", "もう寝る", "寝るね", "寝るよ", "寝るわ", "寝ます", "眠ります", "そろそろ寝",
            "go to sleep", "go to bed", "going to sleep", "going to bed", "gonna sleep", "gonna go to bed", "time for bed", "time to sleep",
            "off to bed", "heading to bed", "get some sleep", "should sleep", "need to sleep"
        ].contains { lowered.contains($0) }
    }

    /// A farewell rather than a translation, quotation or explanation of the phrase.
    static func isGoodNightFarewell(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard isGoodNight(text) else { return false }
        let explanatory = [
            "晚安的", "晚安是", "晚安英文", "晚安日文", "怎麼說", "怎么说", "翻譯", "翻译", "意思", "說法", "说法",
            "不說晚安", "不说晚安", "別說晚安", "别说晚安", "不要說晚安", "不要说晚安", "還不是晚安", "还不是晚安",
            "good night mean", "what is good night", "good night in ", "how to say good night", "how do you say good night",
            "don't say good night", "do not say good night", "not saying good night", "won't say good night",
            "translate", "translation", "the phrase", "the words", "the word",
            "おやすみの意味", "おやすみは", "おやすみとは", "おやすみという", "おやすみと言わない", "おやすみじゃない", "英語で", "中国語で", "翻訳", "言い方",
            "「", "」", "『", "』", "\"good night\"", "“good night”", "‘good night’"
        ]
        return !explanatory.contains { lowered.contains($0) }
    }

    static func shouldAutomaticallySleep(after reply: String, userText: String, at date: Date = Date()) -> Bool {
        !declinesBedtime(userText) && isLateEvening(date) && isGoodNightFarewell(reply)
    }

    /// Late enough that her saying good night means she's turning in herself.
    static func isLateEvening(_ date: Date = Date()) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 22 || hour < endHour
    }

    static func isGoodMorning(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["早晨", "早安", "早上好", "good morning", "morning!", "おはよう"].contains { lowered.contains($0) }
    }
}
