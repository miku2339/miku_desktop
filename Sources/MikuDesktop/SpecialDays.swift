import Foundation

extension Notification.Name {
    /// Posted when event dates were (re)loaded from the official sites.
    static let mikuEventsChanged = Notification.Name("com.qimake.MikuDesktop.eventsChanged")
}

/// An event whose dates change every year, read from its official site.
struct FetchedEvent: Codable, Equatable, Sendable {
    /// "magicalMirai" or "snowMiku".
    var kind: String
    var year: Int
    /// "hamamatsu", "osaka", "tokyo", … (Magical Mirai has one run per city).
    var city: String?
    /// The venue as written on the site, when it was next to the dates.
    var venue: String?
    /// yyyy-MM-dd, local dates.
    var start: String
    var end: String
    var source: String
}

/// A day (or a few days) Miku knows about.
struct SpecialDay: Equatable, Sendable {
    /// newYear, snowMiku, mikuDay, tanabata, summerFestival, magicalMirai, birthday, halloween,
    /// christmas, newYearsEve, anniversary
    let key: String
    let start: Date
    let end: Date
    var city: String? = nil
    var venue: String? = nil
    /// For the anniversary: how many years.
    var years: Int? = nil
    /// Dates read from an official site (rather than fixed every year).
    var fetched = false

    func isOn(_ date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }

    func daysUntil(from date: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: start)).day ?? 0
    }
}

/// Which special days are today or coming up, and what to tell the model about them.
enum SpecialDays {
    /// Fixed every year: (key, month, first day, last day).
    static let fixed: [(key: String, month: Int, from: Int, to: Int)] = [
        ("newYear", 1, 1, 3),
        ("mikuDay", 3, 9, 9),
        ("tanabata", 7, 7, 7),
        ("birthday", 8, 31, 31),
        ("halloween", 10, 31, 31),
        ("christmas", 12, 24, 25),
        ("newYearsEve", 12, 31, 31)
    ]

    /// Summer festival season: mid-July to the end of August.
    static let summerFestival = (fromMonth: 7, fromDay: 15, toMonth: 8, toDay: 31)

    /// Every special day of `year` (plus fetched events of any year).
    static func days(inYear year: Int, events: [FetchedEvent], firstMet: Date?, calendar: Calendar = .current) -> [SpecialDay] {
        var result: [SpecialDay] = []
        func date(_ month: Int, _ day: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        }
        for entry in fixed {
            if let start = date(entry.month, entry.from), let end = date(entry.month, entry.to) {
                result.append(SpecialDay(key: entry.key, start: start, end: end))
            }
        }
        if let start = date(summerFestival.fromMonth, summerFestival.fromDay),
           let end = date(summerFestival.toMonth, summerFestival.toDay) {
            result.append(SpecialDay(key: "summerFestival", start: start, end: end))
        }
        if let firstMet {
            let met = calendar.dateComponents([.year, .month, .day], from: firstMet)
            if let metYear = met.year, let month = met.month, let day = met.day, year > metYear {
                // Met on 29 February: celebrate on the 28th in other years.
                var anniversary = date(month, day)
                if let lenient = anniversary, calendar.component(.month, from: lenient) != month {
                    anniversary = date(month, day - 1)
                }
                if let anniversary {
                    result.append(SpecialDay(key: "anniversary", start: anniversary, end: anniversary, years: year - metYear))
                }
            }
        }
        for event in events where event.year == year {
            guard let start = parseDay(event.start, calendar: calendar), let end = parseDay(event.end, calendar: calendar) else { continue }
            result.append(SpecialDay(key: event.kind, start: start, end: end, city: event.city, venue: event.venue, fetched: true))
        }
        return result
    }

    /// Special days on `date`.
    static func today(_ date: Date, events: [FetchedEvent], firstMet: Date?, calendar: Calendar = .current) -> [SpecialDay] {
        let year = calendar.component(.year, from: date)
        return days(inYear: year, events: events, firstMet: firstMet, calendar: calendar).filter { $0.isOn(date, calendar: calendar) }
    }

    /// Special days starting within `days` days after `date` (not today's).
    static func upcoming(_ date: Date, within days: Int, events: [FetchedEvent], firstMet: Date?, calendar: Calendar = .current) -> [SpecialDay] {
        let year = calendar.component(.year, from: date)
        let all = Self.days(inYear: year, events: events, firstMet: firstMet, calendar: calendar)
            + Self.days(inYear: year + 1, events: events, firstMet: firstMet, calendar: calendar)
        return all
            .filter { !$0.isOn(date, calendar: calendar) && (1...days).contains($0.daysUntil(from: date, calendar: calendar)) }
            .sorted { $0.start < $1.start }
    }

    /// The next known run of each fetched event (so she can answer "when is Magical Mirai?").
    static func nextFetched(_ date: Date, events: [FetchedEvent], calendar: Calendar = .current) -> [SpecialDay] {
        let today = calendar.startOfDay(for: date)
        return events.compactMap { event -> SpecialDay? in
            guard let start = parseDay(event.start, calendar: calendar), let end = parseDay(event.end, calendar: calendar),
                  calendar.startOfDay(for: end) >= today else { return nil }
            return SpecialDay(key: event.kind, start: start, end: end, city: event.city, venue: event.venue, fetched: true)
        }
        .sorted { $0.start < $1.start }
    }

    static func parseDay(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Words

    static func name(_ day: SpecialDay, language: String) -> String {
        let names: [String: (zh: String, en: String, ja: String)] = [
            "newYear": ("新年", "New Year", "お正月"),
            "snowMiku": ("SNOW MIKU（札幌雪祭期間的雪初音活動）", "SNOW MIKU (the snow Miku event during the Sapporo Snow Festival)", "SNOW MIKU（さっぽろ雪まつりの時期の雪ミクのイベント）"),
            "mikuDay": ("ミクの日（3月9日）", "Miku Day (3/9)", "ミクの日（3月9日）"),
            "tanabata": ("七夕", "Tanabata", "七夕"),
            "summerFestival": ("夏日祭季節", "summer festival season", "夏祭りの季節"),
            "magicalMirai": ("魔法未來（マジカルミライ）", "Magical Mirai", "マジカルミライ"),
            "birthday": ("你（初音未來）的生日（8月31日）", "your (Hatsune Miku's) birthday (8/31)", "あなた（初音ミク）の誕生日（8月31日）"),
            "halloween": ("萬聖節", "Halloween", "ハロウィン"),
            "christmas": ("聖誕節", "Christmas", "クリスマス"),
            "newYearsEve": ("除夕（大晦日）", "New Year's Eve", "大晦日"),
            "anniversary": ("你和對方認識的週年紀念", "the anniversary of the day you and the user met", "相手と出会った記念日")
        ]
        guard let entry = names[day.key] else { return day.key }
        var text: String
        switch language {
        case "en": text = entry.en
        case "ja": text = entry.ja
        default: text = entry.zh
        }
        if day.key == "anniversary", let years = day.years {
            switch language {
            case "en": text += " (\(years) year\(years == 1 ? "" : "s"))"
            case "ja": text += "（\(years)周年）"
            default: text += "（\(years) 週年）"
            }
        }
        if day.key == "magicalMirai", let city = day.city {
            text += " " + cityName(city, language: language) + (day.venue.map { "（\($0)）" } ?? "")
        }
        return text
    }

    static func cityName(_ key: String, language: String) -> String {
        let names: [String: (zh: String, en: String, ja: String)] = [
            "hamamatsu": ("濱松場", "Hamamatsu", "浜松公演"),
            "osaka": ("大阪場", "Osaka", "大阪公演"),
            "tokyo": ("東京場", "Tokyo", "東京公演"),
            "sendai": ("仙台場", "Sendai", "仙台公演"),
            "sapporo": ("札幌場", "Sapporo", "札幌公演"),
            "nagoya": ("名古屋場", "Nagoya", "名古屋公演"),
            "fukuoka": ("福岡場", "Fukuoka", "福岡公演"),
            "yokohama": ("橫濱場", "Yokohama", "横浜公演")
        ]
        guard let entry = names[key] else { return key }
        switch language {
        case "en": return entry.en
        case "ja": return entry.ja
        default: return entry.zh
        }
    }

    static func range(_ day: SpecialDay, language: String, calendar: Calendar = .current) -> String {
        let s = calendar.dateComponents([.year, .month, .day], from: day.start)
        let e = calendar.dateComponents([.year, .month, .day], from: day.end)
        let sameDay = s == e
        switch language {
        case "en":
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let start = "\(months[(s.month ?? 1) - 1]) \(s.day ?? 1), \(s.year ?? 0)"
            return sameDay ? start : "\(start) – \(months[(e.month ?? 1) - 1]) \(e.day ?? 1)"
        default:
            let start = "\(s.year ?? 0)年\(s.month ?? 1)月\(s.day ?? 1)日"
            return sameDay ? start : "\(start)–\(e.month ?? 1)月\(e.day ?? 1)日"
        }
    }

    /// The lines for the system prompt. Fetched dates are given exactly; for events whose
    /// dates are not known yet she must not guess.
    static func instruction(now: Date, events: [FetchedEvent], firstMet: Date?, language: String, calendar: Calendar = .current) -> String {
        let today = Self.today(now, events: events, firstMet: firstMet, calendar: calendar)
        let soon = upcoming(now, within: 14, events: events, firstMet: firstMet, calendar: calendar)
        let todayKeys = Set(today.map { "\($0.key)-\($0.start)" })
        let soonKeys = Set(soon.map { "\($0.key)-\($0.start)" })
        let known = nextFetched(now, events: events, calendar: calendar)
            .filter { !todayKeys.contains("\($0.key)-\($0.start)") && !soonKeys.contains("\($0.key)-\($0.start)") }
            .prefix(4)
        let knownKinds = Set(nextFetched(now, events: events, calendar: calendar).map(\.key))
        let unknown = ["magicalMirai", "snowMiku"].filter { !knownKinds.contains($0) }
        let todayText = today.map { name($0, language: language) + ($0.fetched ? " " + range($0, language: language, calendar: calendar) : "") }
        let soonText = soon.map { "\(name($0, language: language)) \(range($0, language: language, calendar: calendar))" }
        let knownText = known.map { "\(name($0, language: language)) \(range($0, language: language, calendar: calendar))" }
        let unknownText = unknown.map { name(SpecialDay(key: $0, start: now, end: now), language: language) }

        var lines: [String] = []
        switch language {
        case "en":
            if !todayText.isEmpty { lines.append("Today is special: \(todayText.joined(separator: "; ")). You can mention it naturally and be happy about it, but not in every message.") }
            if !soonText.isEmpty { lines.append("Coming up soon: \(soonText.joined(separator: "; ")).") }
            if !knownText.isEmpty { lines.append("Confirmed dates from the official sites: \(knownText.joined(separator: "; ")).") }
            if !unknownText.isEmpty { lines.append("The next dates of \(unknownText.joined(separator: " and ")) have not been announced (or could not be checked): if asked, say you don't know the exact dates yet; never guess dates or venues.") }
        case "ja":
            if !todayText.isEmpty { lines.append("今日は特別な日：\(todayText.joined(separator: "、"))。自然に触れて喜んでいいけれど、毎回は言わないこと。") }
            if !soonText.isEmpty { lines.append("もうすぐ：\(soonText.joined(separator: "、"))。") }
            if !knownText.isEmpty { lines.append("公式サイトで確認済みの日程：\(knownText.joined(separator: "、"))。") }
            if !unknownText.isEmpty { lines.append("\(unknownText.joined(separator: "と"))の次の日程はまだ発表されていない（または確認できない）ので、聞かれたら「まだ分からない」と言い、日付や会場を推測しないこと。") }
        default:
            if !todayText.isEmpty { lines.append("今天是特別的日子：\(todayText.joined(separator: "、"))。可以自然地提起、表現開心，但不要每句都講。") }
            if !soonText.isEmpty { lines.append("快到了：\(soonText.joined(separator: "、"))。") }
            if !knownText.isEmpty { lines.append("官方網站上已確認的日期：\(knownText.joined(separator: "、"))。") }
            if !unknownText.isEmpty { lines.append("\(unknownText.joined(separator: "和"))的下一次日期還沒公佈（或者未能查到）：被問到就說還不知道確實日期，絕對不要猜日期或場地。") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading dates from an official page

    /// A date range found in page text, with the text around it.
    struct FoundRange: Equatable {
        let start: DateComponents
        let end: DateComponents
        let before: String
        let after: String
    }

    /// Page HTML → plain text, with full-width digits and brackets folded (NFKC).
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["(?is)<script.*?</script>", "(?is)<style.*?</style>", "(?is)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(p|div|li|h[1-6]|dt|dd|tr|section|table)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&#12316;": "〜", "&#65374;": "～"]
        for (entity, value) in entities { text = text.replacingOccurrences(of: entity, with: value) }
        text = text.replacingOccurrences(of: "&#(x[0-9a-fA-F]+|[0-9]+);", with: " ", options: .regularExpression)
        text = text.precomposedStringWithCompatibilityMapping
        text = text.replacingOccurrences(of: "[ \\t\\u{3000}]+", with: " ", options: .regularExpression)
        return text
    }

    private static let rangePattern: NSRegularExpression = {
        let ymd = #"(?:(20\d{2})\s*[年./]\s*)?(\d{1,2})\s*[月./]\s*(\d{1,2})\s*日?"#
        let weekday = #"(?:\s*[(][^()\n]{1,8}[)])?"#
        let dash = #"\s*[~〜\-–—―ー－]\s*"#
        let end = #"(?:(20\d{2})\s*[年./]\s*)?(?:(\d{1,2})\s*[月./]\s*)?(\d{1,2})\s*日?"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: ymd + weekday + dash + end + weekday)
    }()

    /// Every "start – end" date range in `text`. Years left out are taken from `pageYear`.
    static func dateRanges(in text: String, pageYear: Int, calendar: Calendar = .current) -> [FoundRange] {
        let ns = text as NSString
        var found: [FoundRange] = []
        for match in rangePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func int(_ index: Int) -> Int? {
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            // Groups: 1 start year, 2 start month, 3 start day, 4 end year, 5 end month, 6 end day.
            guard match.numberOfRanges >= 7, let startMonth = int(2), let startDay = int(3), let endDay = int(6) else { continue }
            let startYear = int(1) ?? pageYear
            let endMonth = int(5) ?? startMonth
            let endYear = int(4) ?? (endMonth < startMonth ? startYear + 1 : startYear)
            let start = DateComponents(year: startYear, month: startMonth, day: startDay)
            let end = DateComponents(year: endYear, month: endMonth, day: endDay)
            guard let startDate = validDate(start, calendar: calendar), let endDate = validDate(end, calendar: calendar),
                  endDate > startDate,
                  let length = calendar.dateComponents([.day], from: startDate, to: endDate).day, length <= 60 else { continue }
            let beforeStart = max(0, match.range.location - 120)
            let before = ns.substring(with: NSRange(location: beforeStart, length: match.range.location - beforeStart))
            let afterEnd = min(ns.length, match.range.location + match.range.length + 60)
            let after = ns.substring(with: NSRange(location: match.range.location + match.range.length, length: afterEnd - match.range.location - match.range.length))
            found.append(FoundRange(start: start, end: end, before: before, after: after))
        }
        return found
    }

    private static func validDate(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 12)) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == components.year && check.month == components.month && check.day == components.day ? date : nil
    }

    /// Words just before a date that mean it is not the event itself (ticket sales, entry…).
    private static let notTheEvent = ["受付", "販売", "抽選", "応募", "申込", "申し込み", "締切", "配信", "発売", "予約", "募集", "エントリー", "投稿"]

    private static func isAboutSomethingElse(_ before: String) -> Bool {
        let near = String(before.suffix(40))
        return notTheEvent.contains { near.contains($0) }
    }

    private static let places: [(word: String, city: String, venue: String?)] = [
        ("アクトシティ浜松", "hamamatsu", "アクトシティ浜松"), ("浜松", "hamamatsu", nil), ("HAMAMATSU", "hamamatsu", nil),
        ("インテックス大阪", "osaka", "インテックス大阪"), ("大阪", "osaka", nil), ("OSAKA", "osaka", nil),
        ("幕張メッセ", "tokyo", "幕張メッセ"), ("幕張", "tokyo", nil), ("東京", "tokyo", nil), ("TOKYO", "tokyo", nil),
        ("仙台", "sendai", nil), ("SENDAI", "sendai", nil),
        ("札幌", "sapporo", nil), ("SAPPORO", "sapporo", nil),
        ("名古屋", "nagoya", nil), ("NAGOYA", "nagoya", nil),
        ("福岡", "fukuoka", nil), ("FUKUOKA", "fukuoka", nil),
        ("横浜", "yokohama", nil), ("YOKOHAMA", "yokohama", nil)
    ]

    /// The city (and venue, if named) closest to a date range.
    static func place(before: String, after: String) -> (city: String, venue: String?)? {
        var best: (distance: Int, city: String)?
        let upperBefore = before.uppercased()
        let upperAfter = after.uppercased()
        for entry in places {
            let word = entry.word.uppercased()
            if let range = upperBefore.range(of: word, options: .backwards) {
                let distance = upperBefore.distance(from: range.upperBound, to: upperBefore.endIndex)
                if best == nil || distance < best!.distance { best = (distance, entry.city) }
            }
            if let range = upperAfter.range(of: word) {
                // A city named after the dates counts a little less than one right before them.
                let distance = upperAfter.distance(from: upperAfter.startIndex, to: range.lowerBound) + 10
                if best == nil || distance < best!.distance { best = (distance, entry.city) }
            }
        }
        guard let city = best?.city else { return nil }
        let nearby = String(before.suffix(80)) + after
        let venue = places.first { $0.city == city && $0.venue != nil && nearby.contains($0.word) }?.venue
        return (city, venue)
    }

    /// Magical Mirai runs: a few days each, in summer/autumn, one per city.
    static func magicalMirai(fromHTML html: String, year: Int, source: String, calendar: Calendar = .current) -> [FetchedEvent] {
        let text = plainText(fromHTML: html)
        var events: [FetchedEvent] = []
        for found in dateRanges(in: text, pageYear: year, calendar: calendar) {
            guard found.start.year == year, let month = found.start.month, (5...11).contains(month),
                  let startDate = validDate(found.start, calendar: calendar), let endDate = validDate(found.end, calendar: calendar),
                  let length = calendar.dateComponents([.day], from: startDate, to: endDate).day, (1...4).contains(length),
                  !isAboutSomethingElse(found.before),
                  let spot = place(before: found.before, after: found.after) else { continue }
            let event = FetchedEvent(
                kind: "magicalMirai", year: year, city: spot.city, venue: spot.venue,
                start: dayString(startDate, calendar: calendar), end: dayString(endDate, calendar: calendar), source: source
            )
            if let index = events.firstIndex(where: { $0.start == event.start && $0.end == event.end }) {
                if events[index].venue == nil, event.venue != nil, events[index].city == event.city { events[index].venue = event.venue }
            } else if !events.contains(where: { $0.city == event.city }) {
                events.append(event)
            }
        }
        return events.sorted { $0.start < $1.start }
    }

    /// SNOW MIKU: the main period, early in the year (around the Sapporo Snow Festival).
    static func snowMiku(fromHTML html: String, year: Int, source: String, calendar: Calendar = .current) -> FetchedEvent? {
        let text = plainText(fromHTML: html)
        let candidates = dateRanges(in: text, pageYear: year, calendar: calendar).filter { found in
            guard found.start.year == year, let month = found.start.month, let day = found.start.day,
                  let endMonth = found.end.month, found.end.year == year else { return false }
            let startsInSeason = (month == 1 && day >= 15) || month == 2
            return startsInSeason && endMonth <= 3 && !isAboutSomethingElse(found.before)
        }
        func preference(_ found: FoundRange) -> Int {
            let context = String(found.before.suffix(120)).uppercased()
            let line = context.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? context
            let mikuMarkers = ["SNOW MIKU", "雪ミク"]
            if mikuMarkers.contains(where: line.contains) { return 3 }
            if line.contains("雪まつり") { return 0 }
            if mikuMarkers.contains(where: context.contains) { return 2 }
            return ["開催", "会期", "期間"].contains(where: line.contains) ? 1 : 0
        }
        let highest = candidates.map(preference).max() ?? 0
        let preferred = highest > 0 ? candidates.filter { preference($0) == highest } : []
        let pool = preferred.isEmpty ? candidates : preferred
        guard let best = pool.min(by: { lhs, rhs in
            (validDate(lhs.start, calendar: calendar) ?? .distantFuture) < (validDate(rhs.start, calendar: calendar) ?? .distantFuture)
        }), let start = validDate(best.start, calendar: calendar), let end = validDate(best.end, calendar: calendar) else { return nil }
        return FetchedEvent(
            kind: "snowMiku", year: year, city: "sapporo", venue: nil,
            start: dayString(start, calendar: calendar), end: dayString(end, calendar: calendar), source: source
        )
    }
}

/// Keeps the dates of Magical Mirai and SNOW MIKU up to date by reading their official sites
/// every few days. Only dates actually found on the sites are used; nothing is guessed.
@MainActor
final class EventCalendar {
    static let shared = EventCalendar()

    private struct Cache: Codable {
        var checked: Date?
        var events: [FetchedEvent] = []
        var lastResult: [String: String]?
    }

    static let refreshInterval: TimeInterval = 3 * 24 * 3600

    private(set) var events: [FetchedEvent] = []
    private(set) var lastChecked: Date?
    /// Per page: "ok", "nothing" (page read, no dates), "missing" (404) or the error.
    private(set) var lastResult: [String: String] = [:]
    private(set) var isChecking = false
    private var timer: Timer?
    private let fileURL: URL
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "MikuDesktop/1.0 (Macintosh; personal desktop companion)"]
        return URLSession(configuration: configuration)
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("MikuDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("events.json")
        load()
    }

    func start() {
        refreshIfNeeded()
        timer?.invalidate()
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in EventCalendar.shared.refreshIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfNeeded() {
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.refreshInterval { return }
        refresh()
    }

    /// Which pages to read: this year's and next year's while they can still matter.
    static func pages(now: Date, calendar: Calendar = .current) -> [(kind: String, year: Int, url: URL)] {
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        var pages: [(String, Int, URL)] = []
        let miraiYears = month <= 9 ? [year, year + 1] : [year + 1]
        let snowYears = month <= 3 ? [year, year + 1] : [year + 1]
        for y in miraiYears {
            if let url = URL(string: "https://magicalmirai.com/\(y)/") { pages.append(("magicalMirai", y, url)) }
        }
        for y in snowYears {
            if let url = URL(string: "https://snowmiku.com/\(y)/") { pages.append(("snowMiku", y, url)) }
        }
        return pages
    }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        let pages = Self.pages(now: Date())
        let session = session
        Task { [weak self] in
            var results: [String: String] = [:]
            var found: [(kind: String, year: Int, events: [FetchedEvent])] = []
            for page in pages {
                let label = "\(page.kind) \(page.year)"
                do {
                    let (data, response) = try await session.data(from: page.url)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        results[label] = status == 404 ? "missing" : "HTTP \(status)"
                        continue
                    }
                    // Pages for a year not announced yet often redirect to the latest one.
                    if let finalURL = response.url, !finalURL.absoluteString.contains("/\(page.year)") {
                        results[label] = "missing"
                        continue
                    }
                    let html = String(decoding: data, as: UTF8.self)
                    let events: [FetchedEvent]
                    if page.kind == "magicalMirai" {
                        events = SpecialDays.magicalMirai(fromHTML: html, year: page.year, source: page.url.absoluteString)
                    } else {
                        events = SpecialDays.snowMiku(fromHTML: html, year: page.year, source: page.url.absoluteString).map { [$0] } ?? []
                    }
                    results[label] = events.isEmpty ? "nothing" : "ok"
                    if !events.isEmpty { found.append((page.kind, page.year, events)) }
                } catch {
                    results[label] = error.localizedDescription
                }
            }
            self?.merge(found, results: results)
        }
    }

    private func merge(_ found: [(kind: String, year: Int, events: [FetchedEvent])], results: [String: String]) {
        isChecking = false
        var events = self.events
        for page in found {
            // A page read successfully replaces what we had for that event and year.
            events.removeAll { $0.kind == page.kind && $0.year == page.year }
            events.append(contentsOf: page.events)
        }
        // Forget runs that ended more than a year ago.
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        events.removeAll { (SpecialDays.parseDay($0.end) ?? .distantFuture) < cutoff }
        self.events = events.sorted { $0.start < $1.start }
        lastResult = results
        // Only count it as checked if at least one site answered; otherwise try again soon.
        if results.values.contains(where: { ["ok", "nothing", "missing"].contains($0) }) {
            lastChecked = Date()
        }
        save()
        CompanionMemory.shared.logDiagnostic(["type": "events", "results": results, "events": self.events.count])
        NotificationCenter.default.post(name: .mikuEventsChanged, object: self)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(Cache.self, from: data) else { return }
        events = cache.events
        lastChecked = cache.checked
        lastResult = cache.lastResult ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cache = Cache(checked: lastChecked, events: events, lastResult: lastResult)
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - For the pages and the model

    func today(firstMet: Date?, now: Date = Date()) -> [SpecialDay] {
        SpecialDays.today(now, events: events, firstMet: firstMet)
    }

    /// For the character page: what's special today, so she can greet and dress up.
    func payload(firstMet: Date?, now: Date = Date()) -> [String: Any] {
        let today = SpecialDays.today(now, events: events, firstMet: firstMet)
        var keys = today.map(\.key)
        // Dress-up seasons a little before the day itself.
        let calendar = Calendar.current
        let month = calendar.component(.month, from: now)
        let day = calendar.component(.day, from: now)
        if month == 10, day >= 25 { keys.append("halloweenSeason") }
        if month == 12, (18...25).contains(day) { keys.append("christmasSeason") }
        let hour = calendar.component(.hour, from: now)
        return ["today": Array(Set(keys)).sorted(), "day": SpecialDays.dayString(now), "hour": hour]
    }
}
