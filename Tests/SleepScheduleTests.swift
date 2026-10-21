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
