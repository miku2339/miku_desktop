import Foundation

extension Notification.Name {
    /// Posted when event dates were (re)loaded from the official sites.
    static let mikuEventsChanged = Notification.Name("com.qimake.MikuDesktop.eventsChanged")
}

/// An event whose dates change every year, read from its official site.
struct FetchedEvent: Codable, Equatable, Sendable {
    /// One of SpecialDays.eventKinds.
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
    static let eventKinds = ["magicalMirai", "mikuWithYou", "mikuExpo", "snowMiku"]

    static func eventSource(kind: String) -> URL? {
        let sources = [
            "magicalMirai": "https://magicalmirai.com/",
            "mikuWithYou": "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/82/ip/16.html",
            "mikuExpo": "https://mikuexpo.com/",
            "snowMiku": "https://snowmiku.com/"
        ]
        return sources[kind].flatMap(URL.init(string:))
    }

    /// An empty query or a year alone is useful for browsing the notebook.
    static func eventQuery(in text: String) -> (kinds: [String], year: Int?)? {
        let value = text.precomposedStringWithCompatibilityMapping.lowercased()
        let aliases: [String: [String]] = [
            "magicalMirai": ["魔法未來", "魔法未来", "マジカルミライ", "magical mirai", "매지컬 미라이", "매지컬미라이"],
            "mikuWithYou": ["未來有你", "未来有你", "miku with you", "미쿠 위드 유", "미쿠위드유"],
            "mikuExpo": ["miku expo", "mikuexpo", "미쿠 엑스포", "미쿠엑스포", "ミクエキスポ"],
            "snowMiku": ["snow miku", "snowmiku", "雪ミク", "雪初音", "雪未來", "雪未来", "스노우 미쿠", "스노우미쿠", "유키미쿠"]
        ]
        let kinds = eventKinds.filter { kind in
            aliases[kind, default: []].contains { alias in
                if alias.first?.isASCII == true {
                    let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: alias).replacingOccurrences(of: " ", with: #"\s*"#) + "(?![a-z])"
                    return value.range(of: pattern, options: .regularExpression) != nil
                }
                return value.contains(alias)
            }
        }
        let yearText = value.range(of: #"(?<!\d)20\d{2}(?!\d)"#, options: .regularExpression).map { String(value[$0]) }
        let year = yearText.flatMap(Int.init)
        if !kinds.isEmpty { return (kinds, year) }
        let browsing = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if browsing.isEmpty || browsing.range(of: #"^20\d{2}(?:年)?$"#, options: .regularExpression) != nil {
            return (eventKinds, year)
        }
        return nil
    }

    static func queriedEvents(query: String, events: [FetchedEvent], now: Date = Date()) -> [FetchedEvent] {
        guard let request = eventQuery(in: query) else { return [] }
        let today = Calendar.current.startOfDay(for: now)
        return events.filter {
            guard request.kinds.contains($0.kind),
                  let start = parseDay($0.start), let end = parseDay($0.end), end >= start,
                  Calendar.current.component(.year, from: start) == $0.year else { return false }
            if let year = request.year { return $0.year == year }
            return Calendar.current.startOfDay(for: end) >= today
        }.sorted {
            ($0.start, $0.kind, $0.city ?? "", $0.venue ?? "") < ($1.start, $1.kind, $1.city ?? "", $1.venue ?? "")
        }
    }

    /// Only named events trigger chat context; notebook-wide browsing does not.
    static func eventQueryInstruction(query: String, events: [FetchedEvent], language: String, now: Date = Date()) -> String {
        let normalized = query.precomposedStringWithCompatibilityMapping
        guard let request = eventQuery(in: normalized),
              !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.range(of: #"^\s*20\d{2}(?:年)?\s*$"#, options: .regularExpression) == nil else { return "" }
        let matches = queriedEvents(query: query, events: events, now: now)
        let ended = ["en": "ended", "ja": "終了", "ko": "종료", "zh-Hant": "已結束"][language] ?? "已結束"
        let upcoming = ["en": "upcoming or ongoing", "ja": "今後・開催中", "ko": "예정 또는 진행 중", "zh-Hant": "即將舉行或進行中"][language] ?? "即將舉行或進行中"
        var lines: [String] = []
        switch language {
        case "en": lines.append("Event query: use only the app's cached official references below, not a fresh live lookup. Never claim you just browsed the official site. Keep the requested year; do not substitute another year. No ticket availability, prices or dates may be guessed.")
        case "ja": lines.append("イベント照会：以下はアプリに保存済みの公式資料で、今回のリアルタイム検索ではありません。今公式サイトを見たとは言わず、指定年を別の年に置き換えないこと。空席・料金・日程を推測しないこと。")
        case "ko": lines.append("행사 조회: 아래는 앱에 캐시된 공식 자료이며 방금 실시간으로 조회한 결과가 아니야. 방금 공식 사이트를 봤다고 말하지 말고 요청한 연도를 다른 연도로 바꾸지 마. 티켓 잔여석, 가격, 날짜를 추측하지 마.")
        default: lines.append("活動查詢：以下是 App 快取的官方資料，不是本次即時瀏覽；不可說剛剛查過官網。遵守使用者指定年度，不拿其他年度代替，不猜票況、票價或日期。")
        }
        for event in matches.prefix(24) {
            guard let start = parseDay(event.start), let end = parseDay(event.end) else { continue }
            let day = SpecialDay(key: event.kind, start: start, end: end, city: event.city, venue: event.venue, fetched: true)
            let status = Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: now) ? ended : upcoming
            lines.append("\(name(day, language: language)) \(range(day, language: language)) [\(status)]\nSource: \(event.source)")
        }
        for kind in request.kinds where !matches.contains(where: { $0.kind == kind }) {
            let title = name(SpecialDay(key: kind, start: now, end: now), language: language)
            let year = request.year.map { " \($0)" } ?? ""
            let source = eventSource(kind: kind)?.absoluteString ?? ""
            switch language {
            case "en": lines.append("\(title)\(year): no confirmed matching schedule in the app's cache. Say you cannot confirm it; this does not establish that it is unannounced. Source: \(source)")
            case "ja": lines.append("\(title)\(year)：一致する確認済みの日程は保存されていません。確認できないと答え、未発表とは断定しないこと。Source: \(source)")
            case "ko": lines.append("\(title)\(year): 캐시에 확인된 일정이 없어. 확인할 수 없다고 말하고 미발표라고 단정하지 마. Source: \(source)")
            default: lines.append("\(title)\(year)：快取中尚未查到可確認的日程；請說目前無法確認，不可斷言官方尚未公布。Source: \(source)")
            }
        }
        return lines.joined(separator: "\n")
    }

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
        return validDate(DateComponents(year: parts[0], month: parts[1], day: parts[2]), calendar: calendar)
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Words

    static func name(_ day: SpecialDay, language: String) -> String {
        let names: [String: (zh: String, en: String, ja: String, ko: String)] = [
            "newYear": ("新年", "New Year", "お正月", "새해"),
            "snowMiku": ("SNOW MIKU（札幌雪祭期間的雪初音活動）", "SNOW MIKU (the snow Miku event during the Sapporo Snow Festival)", "SNOW MIKU（さっぽろ雪まつりの時期の雪ミクのイベント）", "SNOW MIKU (삿포로 눈축제 기간의 유키미쿠 행사)"),
            "mikuDay": ("ミクの日（3月9日）", "Miku Day (3/9)", "ミクの日（3月9日）", "미쿠의 날 (3월 9일)"),
            "tanabata": ("七夕", "Tanabata", "七夕", "다나바타"),
            "summerFestival": ("夏日祭季節", "summer festival season", "夏祭りの季節", "여름 축제철"),
            "magicalMirai": ("魔法未來（マジカルミライ）", "Magical Mirai", "マジカルミライ", "매지컬 미라이"),
            "mikuWithYou": ("未來有你", "MIKU WITH YOU", "未来有你", "MIKU WITH YOU"),
            "mikuExpo": ("MIKU EXPO", "MIKU EXPO", "MIKU EXPO", "미쿠 엑스포"),
            "birthday": ("你（初音未來）的生日（8月31日）", "your (Hatsune Miku's) birthday (8/31)", "あなた（初音ミク）の誕生日（8月31日）", "너(하츠네 미쿠)의 생일 (8월 31일)"),
            "halloween": ("萬聖節", "Halloween", "ハロウィン", "할로윈"),
            "christmas": ("聖誕節", "Christmas", "クリスマス", "크리스마스"),
            "newYearsEve": ("除夕（大晦日）", "New Year's Eve", "大晦日", "한 해의 마지막 날"),
            "anniversary": ("你和對方認識的週年紀念", "the anniversary of the day you and the user met", "相手と出会った記念日", "사용자와 처음 만난 날의 기념일")
        ]
        guard let entry = names[day.key] else { return day.key }
        var text: String
        switch language {
        case "en": text = entry.en
        case "ja": text = entry.ja
        case "ko": text = entry.ko
        default: text = entry.zh
        }
        if day.key == "anniversary", let years = day.years {
            switch language {
            case "en": text += " (\(years) year\(years == 1 ? "" : "s"))"
            case "ja": text += "（\(years)周年）"
            case "ko": text += " (\(years)주년)"
            default: text += "（\(years) 週年）"
            }
        }
        if eventKinds.contains(day.key), let city = day.city {
            text += " " + cityName(city, language: language) + (day.venue.map { "（\($0)）" } ?? "")
        }
        return text
    }

    static func cityName(_ key: String, language: String) -> String {
        let names: [String: (zh: String, en: String, ja: String, ko: String)] = [
            "hamamatsu": ("濱松場", "Hamamatsu", "浜松公演", "하마마쓰"),
            "osaka": ("大阪場", "Osaka", "大阪公演", "오사카"),
            "tokyo": ("東京場", "Tokyo", "東京公演", "도쿄"),
            "sendai": ("仙台場", "Sendai", "仙台公演", "센다이"),
            "sapporo": ("札幌場", "Sapporo", "札幌公演", "삿포로"),
            "nagoya": ("名古屋場", "Nagoya", "名古屋公演", "나고야"),
            "fukuoka": ("福岡場", "Fukuoka", "福岡公演", "후쿠오카"),
            "yokohama": ("橫濱場", "Yokohama", "横浜公演", "요코하마"),
            "shanghai": ("上海場", "Shanghai", "上海公演", "상하이")
        ]
        guard let entry = names[key] else { return key }
        switch language {
        case "en": return entry.en
        case "ja": return entry.ja
        case "ko": return entry.ko
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
        case "ko":
            let start = "\(s.year ?? 0)년 \(s.month ?? 1)월 \(s.day ?? 1)일"
            return sameDay ? start : "\(start)–\(e.month ?? 1)월 \(e.day ?? 1)일"
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
        let unknown = eventKinds.filter { !knownKinds.contains($0) }
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
            if !unknownText.isEmpty { lines.append("No upcoming dates of \(unknownText.joined(separator: " and ")) are confirmed in the app's cache. If asked, say you cannot confirm the dates; do not assume they are unannounced or guess dates or venues.") }
        case "ja":
            if !todayText.isEmpty { lines.append("今日は特別な日：\(todayText.joined(separator: "、"))。自然に触れて喜んでいいけれど、毎回は言わないこと。") }
            if !soonText.isEmpty { lines.append("もうすぐ：\(soonText.joined(separator: "、"))。") }
            if !knownText.isEmpty { lines.append("公式サイトで確認済みの日程：\(knownText.joined(separator: "、"))。") }
            if !unknownText.isEmpty { lines.append("\(unknownText.joined(separator: "と"))の次の日程はアプリの保存済み資料では確認できません。未発表とは断定せず、日付や会場を推測しないこと。") }
        case "ko":
            if !todayText.isEmpty { lines.append("오늘은 특별한 날: \(todayText.joined(separator: ", ")). 자연스럽게 기뻐하며 이야기해도 되지만 매번 언급하지는 마.") }
            if !soonText.isEmpty { lines.append("다가오는 날: \(soonText.joined(separator: ", ")).") }
            if !knownText.isEmpty { lines.append("공식 사이트에서 확인한 일정: \(knownText.joined(separator: ", ")).") }
            if !unknownText.isEmpty { lines.append("\(unknownText.joined(separator: ", "))의 다음 일정은 앱의 캐시에서 확인하지 못했어. 미발표라고 단정하지 말고 날짜나 장소를 추측하지 마.") }
        default:
            if !todayText.isEmpty { lines.append("今天是特別的日子：\(todayText.joined(separator: "、"))。可以自然地提起、表現開心，但不要每句都講。") }
            if !soonText.isEmpty { lines.append("快到了：\(soonText.joined(separator: "、"))。") }
            if !knownText.isEmpty { lines.append("官方網站上已確認的日期：\(knownText.joined(separator: "、"))。") }
            if !unknownText.isEmpty { lines.append("\(unknownText.joined(separator: "和"))的下一次日程尚未查到可確認的資料；被問到就說目前無法確認，不可當作官方還沒公佈，絕對不要猜日期或場地。") }
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

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let value = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: value.length)).map { match in
            (1..<match.numberOfRanges).map {
                let range = match.range(at: $0)
                return range.location == NSNotFound ? "" : value.substring(with: range)
            }
        }
    }

    private static func classContents(_ name: String, in html: String) -> [String] {
        let key = NSRegularExpression.escapedPattern(for: name)
        return captures(#"<([a-z][a-z0-9]*)\b[^>]*\bclass\s*=\s*["'][^"']*(?<![\w-])"# + key + #"(?![\w-])[^"']*["'][^>]*>(.*?)</\1\s*>"#, in: html).map { $0[1] }
    }

    private static func cleanField(_ html: String) -> String {
        String(plainText(fromHTML: html)
            .replacingOccurrences(of: "arrow_forward_ios", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            .joined(separator: " ").prefix(160))
    }

    /// Each concert list item supplies its own city, venue and dates, never ticket dates.
    static func mikuExpo(fromHTML html: String, year: Int, source: String, calendar: Calendar = .current) -> [FetchedEvent] {
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        var result: [FetchedEvent] = []
        for list in classContents("concert_list", in: html) {
            for item in captures(#"<li\b[^>]*>(.*?)</li\s*>"#, in: list).map({ $0[0] }) {
                guard let cityHTML = classContents("city_txt", in: item).first else { continue }
                let city = cleanField(cityHTML)
                let venue = classContents("venue_txt", in: item).first.map(cleanField)
                    ?? classContents("venue", in: item).first.flatMap {
                        captures(#"<p\b[^>]*>(.*?)</p\s*>"#, in: $0).map { cleanField($0[0]) }
                            .first { !$0.isEmpty && $0.uppercased() != "VENUE" }
                    }
                guard !city.isEmpty, let venue, !venue.isEmpty else { continue }
                // The two official layouts use date_txt or concert_list_datetime.
                let dateBlocks = classContents("date_txt", in: item)
                    + classContents("concert_list_datetime", in: item).compactMap {
                        captures(#"<p\b[^>]*>(.*?)</p\s*>"#, in: $0).first?.first
                    }
                for block in dateBlocks {
                    let date = cleanField(block).lowercased()
                    for found in captures(#"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, in: date) {
                        guard let month = months.firstIndex(of: found[0].lowercased()).map({ $0 + 1 }),
                              let day = Int(found[1]),
                              let start = validDate(DateComponents(year: year, month: month, day: day), calendar: calendar) else { continue }
                        let event = FetchedEvent(kind: "mikuExpo", year: year, city: city, venue: venue,
                                                 start: dayString(start, calendar: calendar), end: dayString(start, calendar: calendar), source: source)
                        if !result.contains(event) { result.append(event) }
                    }
                }
            }
        }
        return result.sorted { ($0.start, $0.city ?? "") < ($1.start, $1.city ?? "") }
    }

    /// Only an explicit performance time and adjacent location in an announcement are used.
    static func mikuWithYou(fromHTML html: String, year: Int, source: String, calendar: Calendar = .current) -> [FetchedEvent] {
        let text = plainText(fromHTML: html)
        guard text.contains("未来有你") || text.contains("未來有你"),
              text.contains(String(year)) else { return [] }
        let pattern = #"(?:^|\n)\s*(?:时间|時間)\s*[:：]\s*([^\n]{1,120})(?:\n|\s)*(?:地点|地點)\s*[:：]\s*([^\n]{1,160})"#
        var result: [FetchedEvent] = []
        for found in captures(pattern, in: text) {
            let time = found[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let venue = cleanField(found[1])
            guard !venue.isEmpty else { continue }
            let ranges = dateRanges(in: time, pageYear: year, calendar: calendar)
            var dates = ranges.compactMap { range -> (Date, Date)? in
                guard range.start.year == year, let start = validDate(range.start, calendar: calendar),
                      let end = validDate(range.end, calendar: calendar) else { return nil }
                return (start, end)
            }
            if ranges.isEmpty, time.range(of: "[~〜–—-]", options: .regularExpression) == nil {
                for match in captures(#"^(?:(20\d{2})年)?(\d{1,2})月(\d{1,2})日"#, in: time) {
                    guard (Int(match[0]) ?? year) == year, let month = Int(match[1]), let day = Int(match[2]),
                          let date = validDate(DateComponents(year: year, month: month, day: day), calendar: calendar) else { continue }
                    dates.append((date, date))
                }
            }
            let cities = [("上海", "shanghai"), ("北京", "beijing"), ("广州", "guangzhou"), ("廣州", "guangzhou"), ("成都", "chengdu")]
            let city = cities.first { venue.contains($0.0) }?.1
            for (start, end) in dates {
                let event = FetchedEvent(kind: "mikuWithYou", year: year, city: city, venue: venue,
                                         start: dayString(start, calendar: calendar), end: dayString(end, calendar: calendar), source: source)
                if !result.contains(event) { result.append(event) }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Discovers only current/next-year official pages; external ticket links are never followed.
    static func eventPages(fromHTML html: String, kind: String, base: URL, years: Set<Int>) -> [(year: Int, url: URL)] {
        var found: [(year: Int, url: URL)] = []
        for link in captures(#"<a\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#, in: html) {
            guard let url = URL(string: link[0], relativeTo: base)?.absoluteURL,
                  url.scheme == "https", url.host?.lowercased() == base.host?.lowercased(),
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { continue }
            let title = cleanField(link[1])
            let year: Int?
            if kind == "mikuExpo" {
                guard url.host == "mikuexpo.com" else { continue }
                year = captures(#"^/[a-z][a-z0-9-]*(20\d{2})/?$"#, in: url.path).first?.first.flatMap(Int.init)
            } else if kind == "mikuWithYou" {
                guard ["www.scla.com.cn", "scla.com.cn"].contains(url.host ?? ""),
                      url.path.range(of: #"^/Cn/Index/pageView/catid/\d+/id/\d+/ip/\d+\.html$"#, options: .regularExpression) != nil,
                      title.contains("未来有你") || title.contains("未來有你"),
                      ["官宣", "演唱会", "演唱會"].contains(where: title.contains) else { continue }
                year = captures(#"(20\d{2})"#, in: title).first?.first.flatMap(Int.init)
            } else { continue }
            guard let year, years.contains(year), !found.contains(where: { $0.url == url }) else { continue }
            found.append((year, url))
        }
        return Array(found.prefix(kind == "mikuExpo" ? 6 : 3))
    }
}

/// Keeps event dates up to date by reading their official sites
/// every few days. Only dates actually found on the sites are used; nothing is guessed.
private final class EventRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let allowed = request.url.map(EventCalendar.isOfficialURL) == true
            && request.url?.host?.lowercased() == original?.host?.lowercased()
        completionHandler(allowed ? request : nil)
    }
}

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
    private let logsDiagnostics: Bool
    private let session: URLSession

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpAdditionalHeaders = ["User-Agent": "MikuDesktop/1.0 (Macintosh; personal desktop companion)"]
        return URLSession(configuration: configuration, delegate: EventRedirectDelegate(), delegateQueue: nil)
    }

    init(fileURL: URL? = nil, session: URLSession? = nil, logsDiagnostics: Bool = true) {
        self.session = session ?? Self.makeSession()
        self.logsDiagnostics = logsDiagnostics
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = base.appendingPathComponent("MikuDesktop", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("events.json")
        }
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
        var pages: [(String, Int, URL)] = []
        let miraiYears = [year, year + 1]
        let snowYears = [year, year + 1]
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
        Task { [weak self] in
            await self?.refreshPages(now: Date())
        }
    }

    /// Allows deterministic fixture sessions without touching the production cache.
    func refreshNow(now: Date = Date()) async {
        guard !isChecking else { return }
        isChecking = true
        await refreshPages(now: now)
    }

    nonisolated static func isOfficialURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil
            && ["magicalmirai.com", "snowmiku.com", "mikuexpo.com", "www.scla.com.cn", "scla.com.cn"].contains(url.host?.lowercased() ?? "")
    }

    private func pageHTML(_ url: URL) async throws -> String {
        guard Self.isOfficialURL(url) else { throw URLError(.unsupportedURL) }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EventPageError.http(status) }
        guard let final = response.url, Self.isOfficialURL(final),
              final.host?.lowercased() == url.host?.lowercased(),
              final.path == url.path else { throw EventPageError.redirect }
        guard data.count <= 2_000_000 else { throw EventPageError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private enum EventPageError: Error {
        case http(Int), redirect, tooLarge
        var status: String {
            switch self {
            case .http(404): return "missing"
            case .http(let status): return "HTTP \(status)"
            case .redirect: return "redirect"
            case .tooLarge: return "too large"
            }
        }
    }

    private func refreshPages(now: Date) async {
        var results: [String: String] = [:]
        var found: [(kind: String, year: Int, events: [FetchedEvent])] = []
        for page in Self.pages(now: now) {
            let label = "\(page.kind) \(page.year)"
            do {
                let html = try await pageHTML(page.url)
                let events = page.kind == "magicalMirai"
                    ? SpecialDays.magicalMirai(fromHTML: html, year: page.year, source: page.url.absoluteString)
                    : SpecialDays.snowMiku(fromHTML: html, year: page.year, source: page.url.absoluteString).map { [$0] } ?? []
                results[label] = events.isEmpty ? "nothing" : "ok"
                if !events.isEmpty { found.append((page.kind, page.year, events)) }
            } catch {
                results[label] = (error as? EventPageError)?.status ?? "unreachable"
            }
        }
        let year = Calendar.current.component(.year, from: now)
        let years = Set([year, year + 1])
        for kind in ["mikuExpo", "mikuWithYou"] {
            guard let index = SpecialDays.eventSource(kind: kind) else { continue }
            var pages: [(year: Int, url: URL)] = []
            do {
                let html = try await pageHTML(index)
                pages = SpecialDays.eventPages(fromHTML: html, kind: kind, base: index, years: years)
                results["\(kind) index"] = pages.isEmpty ? "nothing" : "ok"
            } catch {
                results["\(kind) index"] = (error as? EventPageError)?.status ?? "unreachable"
            }
            // A verified announcement is also a discovery seed, not a date prediction.
            if kind == "mikuWithYou", years.contains(2026),
               let seed = URL(string: "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/4728/ip/16.html"),
               !pages.contains(where: { $0.url == seed }) {
                pages = Array(pages.prefix(2)) + [(2026, seed)]
            }
            var byYear: [Int: [FetchedEvent]] = [:]
            for page in pages {
                let label = "\(kind) \(page.year) \(page.url.lastPathComponent)"
                do {
                    let html = try await pageHTML(page.url)
                    let events = kind == "mikuExpo"
                        ? SpecialDays.mikuExpo(fromHTML: html, year: page.year, source: page.url.absoluteString)
                        : SpecialDays.mikuWithYou(fromHTML: html, year: page.year, source: page.url.absoluteString)
                    results[label] = events.isEmpty ? "nothing" : "ok"
                    if !events.isEmpty { byYear[page.year, default: []].append(contentsOf: events) }
                } catch {
                    results[label] = (error as? EventPageError)?.status ?? "unreachable"
                }
            }
            for (year, events) in byYear { found.append((kind, year, events)) }
        }
        merge(found, results: results, now: now)
    }

    private func merge(_ found: [(kind: String, year: Int, events: [FetchedEvent])], results: [String: String], now: Date) {
        isChecking = false
        var events = self.events
        for page in found {
            // A page read successfully replaces what we had for that event and year.
            let sources = Set(page.events.map(\.source))
            // Another tour/announcement of the same year may temporarily be unreachable.
            events.removeAll { $0.kind == page.kind && $0.year == page.year && sources.contains($0.source) }
            events.append(contentsOf: page.events)
        }
        // Forget runs that ended more than a year ago.
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        events.removeAll { (SpecialDays.parseDay($0.end) ?? .distantFuture) < cutoff }
        self.events = events.sorted { $0.start < $1.start }
        lastResult = results
        // Only count it as checked if at least one site answered; otherwise try again soon.
        if results.values.contains(where: { ["ok", "nothing", "missing"].contains($0) }) {
            lastChecked = now
        }
        save()
        if logsDiagnostics { CompanionMemory.shared.logDiagnostic(["type": "events", "results": results, "events": self.events.count]) }
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
        if !lastResult.keys.contains("mikuExpo index") || !lastResult.keys.contains("mikuWithYou index") {
            lastChecked = nil
        }
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
