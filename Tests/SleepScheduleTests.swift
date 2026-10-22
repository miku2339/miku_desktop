import Foundation

@main
struct SleepScheduleTests {
    private static var checks = 0
    private static var failures: [String] = []

    @MainActor
    static func main() async {
        let suite = "com.qimake.MikuDesktop.sleep-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let schedule = SleepSchedule(defaults: defaults, now: now)
        expectEqual(schedule.revision, 0, "新排程沒有狀態變更")

        schedule.goToBed(now: now)
        expectTrue(schedule.isAsleep(at: now), "晚安後進入睡眠")
        let bedtimeRevision = schedule.revision

        schedule.wake(minutes: 20, now: now.addingTimeInterval(1))
        expectFalse(schedule.isAsleep(at: now.addingTimeInterval(1)), "觸摸叫醒後保持清醒")
        expectTrue(schedule.revision != bedtimeRevision, "叫醒使舊晚安排程失效")

        let wakeRevision = schedule.revision
        schedule.goodMorning(now: now.addingTimeInterval(2))
        expectTrue(schedule.revision != wakeRevision, "早安建立新的睡眠狀態版本")

        let restored = SleepSchedule(defaults: defaults, now: now.addingTimeInterval(3))
        expectFalse(restored.isAsleep(at: now.addingTimeInterval(3)), "重新建立排程時保留有效叫醒狀態")

        expectTrue(SleepSchedule.isGoodNight("Good night, Miku"), "辨識英文晚安")
        expectTrue(SleepSchedule.isGoodMorning("早晨，Miku"), "辨識廣東話早晨")
        expectTrue(SleepSchedule.isBedtimeRequest("你還不上床睡覺嗎"), "叫她上床也算晚安")
        expectTrue(SleepSchedule.isBedtimeRequest("我要睡了"), "說自己要睡也算晚安")
        expectTrue(SleepSchedule.isBedtimeRequest("我要睡覺了"), "辨識完整國語睡覺句")
        expectTrue(SleepSchedule.isBedtimeRequest("我已經開始有點想睡覺了"), "辨識逐漸想睡")
        expectTrue(SleepSchedule.isBedtimeRequest("我要瞓喇"), "辨識廣東話要睡")
        expectTrue(SleepSchedule.isBedtimeRequest("I'm off to bed"), "辨識英文上床")
        expectTrue(SleepSchedule.isBedtimeRequest("I'm going to sleep"), "辨識英文準備睡")
        expectTrue(SleepSchedule.isBedtimeRequest("そろそろ寝るね"), "辨識日文要睡")
        expectTrue(SleepSchedule.isBedtimeRequest("もう寝ます"), "辨識日文禮貌句")
        expectFalse(SleepSchedule.isBedtimeRequest("我睡不著"), "睡不著不會送她上床")
        expectFalse(SleepSchedule.isBedtimeRequest("我不想去睡"), "國語拒絕睡覺優先")
        expectFalse(SleepSchedule.isBedtimeRequest("我不用去睡"), "國語不需要睡覺不會誤觸")
        expectFalse(SleepSchedule.isBedtimeRequest("我唔想瞓覺"), "廣東話拒絕睡覺優先")
        expectFalse(SleepSchedule.isBedtimeRequest("I don't want to go to bed"), "英文拒絕睡覺優先")
        expectFalse(SleepSchedule.isBedtimeRequest("I don’t want to go to bed"), "英文智慧引號拒絕睡覺優先")
        expectFalse(SleepSchedule.isBedtimeRequest("I don't need to sleep"), "英文不需要睡覺不會誤觸")
        expectTrue(SleepSchedule.isBedtimeRequest("Why don't you go to bed?"), "英文催睡問句不被否定詞誤擋")
        expectFalse(SleepSchedule.isBedtimeRequest("もう寝る気はない"), "日文拒絕睡覺優先")
        expectFalse(SleepSchedule.isBedtimeRequest("晚安英文怎麼說？"), "詢問晚安翻譯不算睡覺請求")
        expectFalse(SleepSchedule.isBedtimeRequest("不要說晚安"), "拒絕說晚安不算道別")
        expectFalse(SleepSchedule.isBedtimeRequest("How do you say good night in Japanese?"), "英文詢問晚安翻譯不算睡覺請求")
        expectFalse(SleepSchedule.isBedtimeRequest("What does good night mean?"), "英文解釋晚安不算睡覺請求")
        expectFalse(SleepSchedule.isBedtimeRequest("今天好累"), "普通聊天不會送她上床")
        let calendar = Calendar.current
        let beforeLateEvening = calendar.date(bySettingHour: 21, minute: 59, second: 59, of: now)!
        let lateEvening = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: now)!
        let beforeMorning = calendar.date(bySettingHour: 6, minute: 59, second: 59, of: now)!
        let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now)!
        expectFalse(SleepSchedule.isLateEvening(beforeLateEvening), "21:59 尚未進入自動晚安時段")
        expectTrue(SleepSchedule.isLateEvening(lateEvening), "22:00 進入自動晚安時段")
        expectTrue(SleepSchedule.isLateEvening(beforeMorning), "06:59 仍屬自動晚安時段")
        expectFalse(SleepSchedule.isLateEvening(morning), "07:00 結束自動晚安時段")
        expectTrue(SleepSchedule.shouldAutomaticallySleep(after: "晚安，明天見。", userText: "今天辛苦了", at: lateEvening), "深夜真正道晚安會自動睡")
        expectFalse(SleepSchedule.shouldAutomaticallySleep(after: "『晚安』英文是 Good night。", userText: "晚安英文怎麼說？", at: lateEvening), "翻譯晚安不會自動睡")
        expectFalse(SleepSchedule.shouldAutomaticallySleep(after: "那就先說晚安吧。", userText: "我不想睡", at: lateEvening), "使用者拒絕睡覺時不因回覆晚安自動睡")
        expectFalse(SleepSchedule.shouldAutomaticallySleep(after: "Good night!", userText: "今天辛苦了", at: morning), "排程跨過 07:00 時不再自動睡")

        let scheduler = BedtimeScheduler()
        var delivered: [String] = []
        scheduler.schedule(
            afterNanoseconds: 1_000_000_000,
            ifStillCurrent: { true },
            action: { delivered.append("old") }
        )
        scheduler.schedule(
            afterNanoseconds: 200_000_000,
            ifStillCurrent: { true },
            action: { delivered.append("new") }
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        expectTrue(scheduler.hasPendingTask, "舊 Task 恢復後不會清除新 Task handle")
        scheduler.cancel()
        expectFalse(scheduler.hasPendingTask, "取消會立即清除目前晚安排程")
        try? await Task.sleep(nanoseconds: 250_000_000)
        expectEqual(delivered, [], "取消後新舊晚安排程都不會執行")

        scheduler.schedule(
            afterNanoseconds: 5_000_000,
            ifStillCurrent: { true },
            action: { delivered.append("latest") }
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        expectEqual(delivered, ["latest"], "最新晚安排程可正常執行")
        expectFalse(scheduler.hasPendingTask, "完成後只清除自己的 Task handle")

        if failures.isEmpty {
            print("PASS: \(checks) checks")
            return
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        fputs("FAILED: \(failures.count) of \(checks) checks\n", stderr)
        exit(1)
    }

    private static func expectTrue(_ actual: Bool, _ name: String) {
        checks += 1
        if !actual { failures.append("\(name)：得到 false，預期 true") }
    }

    private static func expectFalse(_ actual: Bool, _ name: String) {
        checks += 1
        if actual { failures.append("\(name)：得到 true，預期 false") }
    }

    private static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        checks += 1
        if actual != expected { failures.append("\(name)：得到 \(actual)，預期 \(expected)") }
    }
}
