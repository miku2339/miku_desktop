import Foundation

private final class EventFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: (Int, String)] = [:]
    private static var requested: [URL] = []

    static func use(_ values: [String: (Int, String)]) {
        lock.lock()
        defer { lock.unlock() }
        fixtures = values
        requested = []
    }

    static var requests: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requested.append(url)
        let fixture = Self.fixtures[url.absoluteString] ?? (503, "")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: fixture.0, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SpecialDaysTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    static func day(_ text: String, hour: Int = 12) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    @MainActor
    static func eventQueryChecks() async {
        let expoSource = "https://mikuexpo.com/europe2026/"
        let announcement = "https://www.scla.com.cn/Cn/Index/pageView/catid/17/id/4728/ip/16.html"
        let expo = """
        <p>Tickets on sale November 1st</p>
        <ul class="concert_list">
        <li><div class="concert_list_city"><h3 class="city"><span class="city_txt">London</span></h3></div>
        <div class="concert_list_info"><div class="date"><p>DATE</p>
        <div class="concert_list_datetime"><p>November 12th (Thu.)</p><div class="times">20:00</div></div></div>
        <div class="venue"><p>VENUE</p><p><a href="https://venue.invalid">Sample Hall<span>arrow_forward_ios</span></a></p></div>
        <div class="ticket">November 2nd</div></div></li>
        <li><span class="city_txt">Madrid</span>
        <div class="concert_list_datetime"><p>November 24th (Tue.)</p><div>20:00</div></div>
        <div class="concert_list_datetime"><p>November 25th (Wed.)</p><div>20:00</div></div>
        <div class="venue"><p>VENUE</p><p>Sample Arena</p></div></li>
        <li><span class="city_txt">No date</span><div class="venue_txt">Other Hall</div></li>
        <li><span class="city_txt">No venue</span><p class="date_txt">November 28th</p></li>
        </ul>
        """
        let expoEvents = SpecialDays.mikuExpo(fromHTML: expo, year: 2026, source: expoSource)
        expect(expoEvents.count == 3, "EXPO keeps single dates and two dates in one city")
        expect(expoEvents.allSatisfy { $0.start == $0.end && $0.source == expoSource }, "EXPO dates remain single-day with official provenance")
        expect(expoEvents.first?.city == "London" && expoEvents.first?.venue == "Sample Hall", "EXPO city and venue come from the same item")
        expect(!expoEvents.contains { $0.start == "2026-11-01" || $0.start == "2026-11-02" }, "EXPO ignores sales dates")
        let northAmerica = """
        <ul class='concert_list'><li><div class='city'><p class='city_txt'>Chicago, IL</p></div>
        <div class='venue'><p class='venue_txt'>Sample Theatre</p></div>
        <div class='info_area'><div class='date'><p class='date_txt'>April 12th Sun.</p></div></div>
        <div class='info_area'><div class='date'><p class='date_txt'>April 13th Mon.</p></div></div></li>
        <li><p class='city_txt'>Denver, CO</p><p class='venue_txt'>Sample Ballroom</p><p class='date_txt'>April 15th Wed.</p></li>
        <li><p class='city_txt'>Invalid City</p><p class='venue_txt'>Sample Venue</p><p class='date_txt'>February 30th</p></li></ul>
        """
        let naEvents = SpecialDays.mikuExpo(fromHTML: northAmerica, year: 2026, source: "https://mikuexpo.com/na2026/")
        expect(naEvents.count == 3 && naEvents.filter { $0.city == "Chicago, IL" }.count == 2, "EXPO North America layout keeps both dates")
        expect(SpecialDays.mikuExpo(fromHTML: "<p>MIKU EXPO 2027 coming soon</p>", year: 2027, source: expoSource).isEmpty, "EXPO never invents unlisted dates")

        let withYou = """
        <h1>初音未来·未来有你2026｜正式官宣</h1>
        <p>发布：2026年9月12日</p><p>售票时间：2026年9月20日</p>
        <p>时间：2026年10月31日-11月1日（日场&amp;夜场）</p><p>地点：上海静安体育中心</p>
        """
        let withYouEvents = SpecialDays.mikuWithYou(fromHTML: withYou, year: 2026, source: announcement)
        expect(withYouEvents.count == 1 && withYouEvents.first?.start == "2026-10-31" && withYouEvents.first?.end == "2026-11-01", "MIKU WITH YOU parses a cross-month performance")
        expect(withYouEvents.first?.city == "shanghai" && withYouEvents.first?.venue == "上海静安体育中心", "MIKU WITH YOU uses adjacent performance location")
        expect(SpecialDays.mikuWithYou(fromHTML: withYou, year: 2027, source: announcement).isEmpty, "MIKU WITH YOU announcement does not imply next-year dates")
        expect(SpecialDays.mikuWithYou(fromHTML: "<h1>未来有你2027</h1><p>发布时间：2027年1月1日</p>", year: 2027, source: announcement).isEmpty, "publication date alone is not a performance")
        expect(SpecialDays.mikuWithYou(fromHTML: "<h1>未来有你2027</h1><p>售票时间：2027年9月20日</p><p>地点：上海某场馆</p>", year: 2027, source: announcement).isEmpty, "ticket-sale time next to a venue is not a performance time")
        expect(SpecialDays.mikuWithYou(fromHTML: "<h1>未来有你2027</h1><p>时间：2027年10月30日</p><p>地点：北京某场馆</p>", year: 2027, source: announcement).count == 1, "MIKU WITH YOU supports an explicit single day")
        expect(SpecialDays.mikuWithYou(fromHTML: "<h1>未来有你2027</h1><p>时间：2027年2月30日-3月1日</p><p>地点：上海某场馆</p>", year: 2027, source: announcement).isEmpty, "invalid announcement dates are rejected")

        let discovery = """
        <a href="europe2026/">2026 EUROPE</a><a href="/na2026/">North America</a>
        <a href="asia2025/">2025 ASIA</a><a href="/europe2027/">2027 EUROPE</a>
        <a href="https://evil.example/europe2026/">Other</a><a href="//evil.example/na2026/">Other</a>
        <a href="http://mikuexpo.com/na2026/">Insecure</a><a href="/na2026/?token=x">Query</a>
        <a href="/na2026/#ticket">Fragment</a><a href="https://user@mikuexpo.com/na2026/">Credentials</a>
        """
        let tours = SpecialDays.eventPages(fromHTML: discovery, kind: "mikuExpo", base: URL(string: "https://mikuexpo.com/")!, years: [2026, 2027])
        expect(tours.count == 3 && tours.allSatisfy { $0.url.host == "mikuexpo.com" }, "EXPO discovery rejects other hosts, years, credentials, query and fragment")
        let manyTours = (1...10).map { "<a href='/tour\($0)2026/'>Tour</a>" }.joined()
        expect(SpecialDays.eventPages(fromHTML: manyTours, kind: "mikuExpo", base: URL(string: "https://mikuexpo.com/")!, years: [2026]).count == 6, "EXPO discovery is bounded")
        let articles = """
        <a href="/Cn/Index/pageView/catid/17/id/4728/ip/16.html">未来有你2026｜正式官宣</a>
        <a href="/Cn/Index/pageView/catid/17/id/5000/ip/16.html">未来有你2027演唱会</a>
        <a href="/Cn/Index/pageView/catid/17/id/4000/ip/16.html">未来有你2025｜正式官宣</a>
        <a href="https://evil.example/Cn/Index/pageView/catid/17/id/1/ip/16.html">未来有你2026官宣</a>
        <a href="/Cn/Index/pageView/catid/17/id/3000/ip/16.html">其他活动2026官宣</a>
        """
        let announcements = SpecialDays.eventPages(fromHTML: articles, kind: "mikuWithYou", base: SpecialDays.eventSource(kind: "mikuWithYou")!, years: [2026, 2027])
        expect(announcements.count == 2 && announcements.map(\.year) == [2026, 2027], "MIKU WITH YOU follows only matching official announcements")
        for (text, kind) in [("魔法未来2026", "magicalMirai"), ("Magical Mirai", "magicalMirai"), ("マジカルミライ", "magicalMirai"), ("매지컬 미라이", "magicalMirai"), ("未來有你", "mikuWithYou"), ("未来有你", "mikuWithYou"), ("MIKU WITH YOU", "mikuWithYou"), ("MIKUEXPO", "mikuExpo"), ("미쿠 엑스포", "mikuExpo"), ("雪ミク", "snowMiku")] {
            expect(SpecialDays.eventQuery(in: text)?.kinds == [kind], "event alias recognised: \(text)")
        }
        expect(SpecialDays.eventQuery(in: "MIKU EXPO ２０１９")?.year == 2019, "an older explicit year is not silently replaced")
        expect(SpecialDays.eventQuery(in: "生日快樂") == nil && SpecialDays.queriedEvents(query: "不知道的活動", events: expoEvents).isEmpty, "unknown queries do not list all events")
        let all = expoEvents + withYouEvents + [FetchedEvent(kind: "mikuExpo", year: 2027, city: "Future City", venue: "Future Venue", start: "2027-05-01", end: "2027-05-01", source: "https://mikuexpo.com/na2027/")]
        expect(SpecialDays.queriedEvents(query: "2026", events: all, now: day("2026-11-03")).count == 4, "year-only query includes past dates from that year")
        expect(SpecialDays.queriedEvents(query: "", events: all, now: day("2026-11-03")).count == 4, "empty browsing query excludes ended events")
        expect(SpecialDays.queriedEvents(query: "MIKU EXPO 2027", events: all, now: day("2026-11-03")).count == 1, "named year query does not mix years")
        expect(SpecialDays.queriedEvents(query: "未來有你2026", events: all, now: day("2026-11-03")).count == 1, "an explicit past event remains queryable")
        let prompt = SpecialDays.eventQueryInstruction(query: "MIKU EXPO2026", events: all, language: "en", now: day("2026-11-03"))
        expect(prompt.contains(expoSource) && prompt.contains("not a fresh live lookup") && !prompt.contains("May 1, 2027"), "chat context preserves sources and requested year without claiming a live lookup")
        let unknown = SpecialDays.eventQueryInstruction(query: "未來有你2027", events: all, language: "zh-Hant", now: day("2026-11-03"))
        expect(unknown.contains("目前無法確認") && unknown.contains("不可斷言"), "unknown schedule does not establish an unannounced event")
        expect(SpecialDays.eventQueryInstruction(query: "２０２６", events: all, language: "en").isEmpty, "year-only browsing does not inject named-event chat context")
        for language in ["zh-Hant", "en", "ja", "ko"] {
            expect(!SpecialDays.eventQueryInstruction(query: "MIKU WITH YOU2026", events: all, language: language, now: day("2026-11-03")).contains("mikuWithYou"), "event names are localized: \(language)")
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-event-tests-\(UUID())")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let file = folder.appendingPathComponent("events.json")
        struct OldCache: Encodable {
            let checked: Date
            let events: [FetchedEvent]
            let lastResult: [String: String]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try! encoder.encode(OldCache(checked: day("2026-11-03"), events: withYouEvents, lastResult: ["magicalMirai 2027": "missing"])).write(to: file)
        let store = EventCalendar(fileURL: file, session: session, logsDiagnostics: false)
        expect(store.lastChecked == nil && store.events == withYouEvents, "old cache retains dates while new sources get an initial refresh")
        EventFixtureProtocol.use([
            "https://magicalmirai.com/2027/": (404, ""),
            "https://snowmiku.com/2027/": (200, "<p>Dates later</p>"),
            "https://mikuexpo.com/": (200, discovery),
            expoSource: (200, expo),
            "https://mikuexpo.com/na2026/": (200, northAmerica),
            "https://mikuexpo.com/europe2027/": (503, ""),
            SpecialDays.eventSource(kind: "mikuWithYou")!.absoluteString: (200, articles),
            announcement: (200, withYou)
        ])
        await store.refreshNow(now: day("2026-11-03"))
        expect(store.events.filter { $0.kind == "mikuExpo" }.count == 6, "refresh merges both EXPO tours without replacing the earlier tour")
        expect(store.events.contains { $0.kind == "mikuWithYou" && $0.end == "2026-11-01" }, "refresh keeps the official MIKU WITH YOU announcement")
        expect(EventFixtureProtocol.requests.allSatisfy(EventCalendar.isOfficialURL), "fixture refresh makes only official-host requests")
        expect(!EventFixtureProtocol.requests.contains { $0.host == "evil.example" || $0.host == "venue.invalid" }, "ticket and venue links never become fetch requests")
        let retained = store.events
        EventFixtureProtocol.use([:])
        await store.refreshNow(now: day("2026-11-04"))
        expect(store.events == retained, "HTTP failure preserves cached official dates")
        expect(store.lastResult.values.allSatisfy { $0 == "HTTP 503" }, "HTTP failures remain failures, not no-announcement results")
        let reloaded = EventCalendar(fileURL: file, session: session, logsDiagnostics: false)
        expect(reloaded.events == retained && reloaded.lastResult == store.lastResult, "new event sources and failure state survive cache reload")
    }

    @MainActor
    static func main() async {
        await eventQueryChecks()
        // Magical Mirai: three cities, mixed formats, full-width digits, a ticket period to skip.
        let mirai = """
        <html><head><style>.x{}</style><script>var d="2026年1月1日~2日";</script></head><body>
        <h2>マジカルミライ 2026</h2>
        <section><h3>HAMAMATSU</h3><p>2026.7.24(金)-26(日)</p><p>アクトシティ浜松</p></section>
        <section><h3>OSAKA</h3><p>2026年8月14日(金)～8月16日(日)</p><p>インテックス大阪 6号館</p></section>
        <section><h3>TOKYO</h3><p>２０２６年８月２８日（金）〜３０日（日）</p><p>幕張メッセ 国際展示場</p></section>
        <p>チケット抽選受付 2026年5月1日(金)～5月10日(日)</p>
        <p>東京公演 先行抽選受付 2026年6月1日～6月3日</p>
        </body></html>
        """
        let events = SpecialDays.magicalMirai(fromHTML: mirai, year: 2026, source: "test")
        expect(events.count == 3, "three Magical Mirai runs, got \(events)")
        expect(events.first?.city == "hamamatsu" && events.first?.start == "2026-07-24" && events.first?.end == "2026-07-26", "Hamamatsu run")
        expect(events.first?.venue == "アクトシティ浜松", "Hamamatsu venue")
        expect(events.contains { $0.city == "osaka" && $0.start == "2026-08-14" && $0.end == "2026-08-16" && $0.venue == "インテックス大阪" }, "Osaka run")
        expect(events.contains { $0.city == "tokyo" && $0.start == "2026-08-28" && $0.end == "2026-08-30" && $0.venue == "幕張メッセ" }, "Tokyo run (full-width digits)")
        expect(!events.contains { $0.start == "2026-06-01" }, "ticket period skipped")

        // A page for a year with no dates yet: nothing found, nothing guessed.
        expect(SpecialDays.magicalMirai(fromHTML: "<p>マジカルミライ 2027 開催決定！詳細は後日発表</p>", year: 2027, source: "t").isEmpty, "no dates → nothing")

        // SNOW MIKU: the main period, not the goods pre-order.
        let snow = """
        <p>グッズ予約受付 2027年1月20日(水)～1月31日(日)</p>
        <p>SNOW MIKU 2027 開催期間：2027年2月5日(金)～3月7日(日)</p>
        <p>さっぽろ雪まつり 2027年2月4日(木)～2月11日(木・祝)</p>
        """
        let snowEvent = SpecialDays.snowMiku(fromHTML: snow, year: 2027, source: "t")
        expect(snowEvent?.start == "2027-02-05" && snowEvent?.end == "2027-03-07", "SNOW MIKU period, got \(String(describing: snowEvent))")
        let snowFestivalFirst = """
        <p>さっぽろ雪まつり 2028年2月4日(金)～2月11日(金・祝)</p>
        <h2>雪ミク</h2><p>開催期間：2028年2月6日(日)～2月12日(土)</p>
        """
        let snowAfterFestival = SpecialDays.snowMiku(fromHTML: snowFestivalFirst, year: 2028, source: "t")
        expect(snowAfterFestival?.start == "2028-02-06" && snowAfterFestival?.end == "2028-02-12", "explicit Snow Miku period wins over the snow festival")

        // Fixed days and the anniversary.
        expect(SpecialDays.today(day("2026-08-31"), events: [], firstMet: nil).contains { $0.key == "birthday" }, "birthday on 8/31")
        expect(SpecialDays.today(day("2027-03-09"), events: [], firstMet: nil).contains { $0.key == "mikuDay" }, "Miku Day")
        expect(SpecialDays.today(day("2026-12-25"), events: [], firstMet: nil).contains { $0.key == "christmas" }, "Christmas")
        expect(SpecialDays.today(day("2027-01-02"), events: [], firstMet: nil).contains { $0.key == "newYear" }, "New Year")
        expect(SpecialDays.today(day("2026-08-01"), events: [], firstMet: nil).contains { $0.key == "summerFestival" }, "summer festival season")
        expect(!SpecialDays.today(day("2026-10-22"), events: [], firstMet: nil).contains { $0.key == "summerFestival" }, "no festival in October")
        let met = day("2025-10-22", hour: 20)
        let anniversary = SpecialDays.today(day("2026-10-22"), events: [], firstMet: met).first { $0.key == "anniversary" }
        expect(anniversary?.years == 1, "first anniversary")
        expect(SpecialDays.today(day("2025-10-22"), events: [], firstMet: met).first { $0.key == "anniversary" } == nil, "no anniversary on the day you met")
        let leap = SpecialDays.today(day("2025-02-28"), events: [], firstMet: day("2024-02-29"))
        expect(leap.contains { $0.key == "anniversary" }, "29 Feb anniversary on the 28th")

        // Fetched events count on their days, and come up in "upcoming".
        let onTokyo = SpecialDays.today(day("2026-08-29"), events: events, firstMet: nil)
        expect(onTokyo.contains { $0.key == "magicalMirai" && $0.city == "tokyo" }, "Magical Mirai Tokyo today")
        let soon = SpecialDays.upcoming(day("2026-08-20"), within: 14, events: events, firstMet: nil)
        expect(soon.contains { $0.key == "magicalMirai" && $0.city == "tokyo" }, "Tokyo run coming up")
        expect(soon.contains { $0.key == "birthday" }, "birthday coming up")

        // The prompt never invents dates for events that aren't known.
        let koreanBirthday = SpecialDay(key: "birthday", start: day("2026-08-31"), end: day("2026-08-31"))
        expect(SpecialDays.name(koreanBirthday, language: "ko").contains("생일"), "韓語生日名稱")
        expect(SpecialDays.range(koreanBirthday, language: "ko").contains("2026년 8월 31일"), "韓語日期")
        expect(SpecialDays.instruction(now: day("2026-08-31"), events: [], firstMet: nil, language: "ko").contains("오늘은 특별한 날"), "韓語節日提示")
        let unknown = SpecialDays.instruction(now: day("2026-10-22"), events: [], firstMet: nil, language: "zh-Hant")
        expect(unknown.contains("還沒公佈") && !unknown.contains("2027年"), "unknown events are not dated: \(unknown)")
        let known = SpecialDays.instruction(now: day("2026-08-20"), events: events, firstMet: nil, language: "en")
        expect(known.contains("Aug 28, 2026") && known.contains("Tokyo"), "known run is dated: \(known)")

        // Pages: next year's Magical Mirai once this year's is over.
        let october = EventCalendar.pages(now: day("2026-10-22"))
        expect(october.contains { $0.kind == "magicalMirai" && $0.year == 2027 } && october.contains { $0.kind == "magicalMirai" && $0.year == 2026 }, "October retains current-year history and checks next year's Magical Mirai")
        expect(october.contains { $0.kind == "snowMiku" && $0.year == 2027 }, "October checks next SNOW MIKU")

        // Diary days start at 5:00.
        expect(CompanionMemory.diaryDay(for: day("2026-10-23", hour: 2)) == "2026-10-22", "2 a.m. belongs to the evening before")
        expect(CompanionMemory.diaryDay(for: day("2026-10-23", hour: 9)) == "2026-10-23", "morning is a new day")

        // A deleted diary entry is not written again.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-diary-tests-\(UUID())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.qimake.MikuDesktop.diary-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let memory = CompanionMemory(fileURL: folder.appendingPathComponent("memory.json"), defaults: defaults)
        let now = Date()
        memory.record([ChatMessage(role: .user, text: "今日去咗秋葉原", date: now), ChatMessage(role: .assistant, text: "好玩嗎？", date: now)])
        let today = CompanionMemory.diaryDay(for: now)
        expect(memory.needsDiary(for: today), "a day with a chat needs a diary entry")
        memory.saveDiary(day: today, text: "今日佢去咗秋葉原。")
        expect(!memory.needsDiary(for: today), "written once")
        memory.deleteDiary(day: today)
        expect(!memory.needsDiary(for: today), "a deleted entry is not written again")
        memory.saveDiary(day: today, text: "late write")
        expect(memory.diary.isEmpty, "a write that finishes after the delete is dropped")

        // An explicitly confirmed accident is not an offence.
        expect(!CompanionMemory.isAccidentExplanation("對唔住！"), "an apology alone does not invent an accident")
        expect(CompanionMemory.isAccidentExplanation("唔小心撳到，對唔住"), "an explicit explanation confirms an accidental touch")
        expect(CompanionMemory.isAccidentExplanation("我剛才點錯了"), "a clear misclick explanation is recognised")
        expect(!CompanionMemory.isAccidentExplanation("不是不小心"), "denying an accident does not confirm one")
        let before = memory.friendship
        memory.recordTouch("boundary", part: "chest")
        expect(memory.isOffended && memory.friendship == before - 8, "the touch costs 8")
        memory.noteUserMessage("對唔住，唔小心㗎")
        expect(!memory.isOffended && memory.friendship == before, "a confirmed accident restores the full penalty: \(memory.friendship) vs \(before)")
        expect(memory.context().forgaveAccident, "she knows it was an accident")
        memory.recordTouch("boundary", part: "chest")
        memory.recordTouch("boundary", part: "chest")
        let upset = memory.friendship
        memory.noteUserMessage("對唔住")
        expect(memory.friendship == upset + 2 && !memory.context().forgaveAccident, "doing it again: only the normal apology")

        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)

        if failures.isEmpty {
            print("special days: \(checks) checks passed")
        } else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            exit(EXIT_FAILURE)
        }
    }
}
