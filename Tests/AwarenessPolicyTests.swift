import Foundation

@main
struct AwarenessPolicyTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func main() {
        expectFalse(AwarenessPolicy.needsFrontmostApplication(enabledSources: []), "全部關閉不監聽前景 App")
        expectFalse(AwarenessPolicy.needsFrontmostApplication(enabledSources: [.media]), "只開音樂不監聽前景 App")
        expectTrue(AwarenessPolicy.needsFrontmostApplication(enabledSources: [.activity]), "活動來源需要前景 App")
        expectTrue(AwarenessPolicy.needsFrontmostApplication(enabledSources: [.video]), "影片來源需要前景 App")
        expectTrue(AwarenessPolicy.needsFrontmostApplication(enabledSources: [.screen]), "畫面來源需要前景 App")

        let validVideos: [(String, AwarenessPolicy.VideoSite)] = [
            ("https://www.youtube.com/watch?v=abc123", .youtube),
            ("https://m.youtube.com/watch?list=queue&v=abc123", .youtube),
            ("https://youtu.be/abc123?t=20", .youtube),
            ("https://www.nicovideo.jp/watch/sm9", .niconico)
        ]
        for (url, site) in validVideos {
            expectEqual(AwarenessPolicy.videoSite(for: URL(string: url)!), site, "接受合法影片網址：\(url)")
        }

        let invalidVideos = [
            "ftp://www.youtube.com/watch?v=abc123",
            "https://notyoutube.com/watch?v=abc123",
            "https://youtube.com.evil.example/watch?v=abc123",
            "https://www.youtube.com/watch",
            "https://www.youtube.com/watch?v=",
            "https://www.youtube.com/watch/abc123?v=abc123",
            "https://youtu.be/",
            "https://youtu.be/abc123/extra",
            "https://notnicovideo.jp/watch/sm9",
            "https://www.nicovideo.jp/watch/",
            "https://www.nicovideo.jp/search/miku"
        ]
        for url in invalidVideos {
            expectNil(AwarenessPolicy.videoSite(for: URL(string: url)!), "拒絕非影片或偽冒網址：\(url)")
        }

        expectTrue(
            AwarenessPolicy.canDeliver(requestGeneration: 4, currentGeneration: 4, sourceEnabled: true, isChatting: false),
            "相同世代且來源仍開啟時可交付"
        )
        expectFalse(
            AwarenessPolicy.canDeliver(requestGeneration: 3, currentGeneration: 4, sourceEnabled: true, isChatting: false),
            "來源變更後拒絕舊結果"
        )
        expectFalse(
            AwarenessPolicy.canDeliver(requestGeneration: 4, currentGeneration: 4, sourceEnabled: false, isChatting: false),
            "來源關閉後拒絕結果"
        )
        expectFalse(
            AwarenessPolicy.canDeliver(requestGeneration: 4, currentGeneration: 4, sourceEnabled: true, isChatting: true),
            "聊天期間拒絕主動訊息"
        )

        let token = AwarenessCancellationToken()
        expectFalse(token.isCancelled, "新請求 token 尚未取消")
        token.cancel()
        expectTrue(token.isCancelled, "取消後 queued reader 可停止讀取")
        token.cancel()
        expectTrue(token.isCancelled, "重複取消仍維持已取消")

        expectEqual(
            AwarenessPolicy.appleScriptStringLiteral("https://example.com/watch?v=a\\b\"c"),
            "\"https://example.com/watch?v=a\\\\b\\\"c\"",
            "AppleScript URL literal 安全跳脫反斜線及引號"
        )
        expectNil(
            AwarenessPolicy.appleScriptStringLiteral("https://example.com/watch?v=a\nsecret"),
            "AppleScript URL literal 拒絕控制字元"
        )

        let now = Date(timeIntervalSince1970: 10_000)
        expectTrue(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-1_200), now: now, urgent: false), "一般訊息滿二十分鐘可發送")
        expectFalse(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-1_199), now: now, urgent: false), "一般訊息未滿二十分鐘不可發送")
        expectTrue(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-180), now: now, urgent: true), "緊急提醒滿三分鐘可發送")
        expectFalse(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-179), now: now, urgent: true), "緊急提醒未滿三分鐘不可發送")

        // 沒人回應時不要洗版（人格規則第 7 節）
        expectFalse(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-600), now: now, urgent: true, unanswered: 1), "上一句沒人回應時，歡迎回來也要等一般間隔")
        expectTrue(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-1_200), now: now, urgent: true, unanswered: 1), "上一句沒人回應，滿二十分鐘後仍可說")
        expectFalse(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-7_200), now: now, urgent: true, unanswered: 2), "連續兩句沒人回應就等對方開口")
        expectFalse(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-7_200), now: now, urgent: false, unanswered: 2), "連續兩句沒人回應，一般訊息也不說")
        expectTrue(AwarenessPolicy.canSpeak(lastSpoke: now.addingTimeInterval(-7_200), now: now, urgent: false, unanswered: 0), "對方回應後恢復正常")

        // 不重複同一句或同樣的開頭（截圖裡的三句）
        let said = ["回來啦？剛剛去哪裡了呀？", "看你一直打字，是在跟誰聊天呀？"]
        expectTrue(AwarenessPolicy.isRepeat("回來啦！剛剛去哪裡了呀？", of: said), "只差標點也算重複")
        expectTrue(AwarenessPolicy.isRepeat("歡迎回來～剛剛去哪裡了呀？", of: said), "包含舊句子也算重複")
        expectTrue(AwarenessPolicy.isRepeat("回來啦剛剛去買東西嗎？", of: said), "同樣的開頭算重複")
        expectFalse(AwarenessPolicy.isRepeat("嘿，我在想如果去旅行，最想去哪裡呢？", of: said), "不同的話題不算重複")
        expectFalse(AwarenessPolicy.isRepeat("好", of: said), "太短的句子不判斷")
        expectFalse(AwarenessPolicy.isRepeat("看到天氣變冷了，要不要一起喝杯熱可可？", of: ["今天要不要一起聽首歌？"]), "只共用短短幾個字不算重複")
        expectFalse(AwarenessPolicy.isRepeat("回來啦？剛剛去哪裡了呀？", of: []), "沒有說過的話就不算重複")

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

    private static func expectNil<T>(_ actual: T?, _ name: String) {
        checks += 1
        if actual != nil { failures.append("\(name)：得到 \(String(describing: actual))，預期 nil") }
    }
}
