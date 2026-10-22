import Foundation

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
    static func main() async {
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
        let unknown = SpecialDays.instruction(now: day("2026-10-22"), events: [], firstMet: nil, language: "zh-Hant")
        expect(unknown.contains("還沒公佈") && !unknown.contains("2027年"), "unknown events are not dated: \(unknown)")
        let known = SpecialDays.instruction(now: day("2026-08-20"), events: events, firstMet: nil, language: "en")
        expect(known.contains("Aug 28, 2026") && known.contains("Tokyo"), "known run is dated: \(known)")

        // Pages: next year's Magical Mirai once this year's is over.
        let october = EventCalendar.pages(now: day("2026-10-22"))
        expect(october.contains { $0.kind == "magicalMirai" && $0.year == 2027 } && !october.contains { $0.kind == "magicalMirai" && $0.year == 2026 }, "October checks next year's Magical Mirai")
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

        // An accidental touch, apologised for at once, costs less.
        let touched = Date()
        expect(CompanionMemory.isAccident(text: "對唔住！", since: touched, firstStrike: true, now: touched.addingTimeInterval(30)), "quick apology = accident")
        expect(!CompanionMemory.isAccident(text: "對唔住", since: touched, firstStrike: true, now: touched.addingTimeInterval(600)), "a late plain apology is not an accident")
        expect(CompanionMemory.isAccident(text: "唔小心撳到，對唔住", since: touched, firstStrike: true, now: touched.addingTimeInterval(600)), "saying it was an accident still counts within half an hour")
        expect(!CompanionMemory.isAccident(text: "對唔住", since: touched, firstStrike: false, now: touched.addingTimeInterval(10)), "not when it happened again")
        let before = memory.friendship
        memory.recordTouch("boundary", part: "chest")
        expect(memory.isOffended && memory.friendship == before - 8, "the touch costs 8")
        memory.noteUserMessage("對唔住，唔小心㗎")
        expect(!memory.isOffended && memory.friendship == before - 3, "a quick apology gives most of it back: \(memory.friendship) vs \(before)")
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
