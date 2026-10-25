import Foundation

@main
struct SpeechMuteTests {
    private static var checks = 0
    private static var failures: [String] = []

    static func main() {
        let suite = "com.qimake.MikuDesktop.speech-mute-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mute = SpeechMute(defaults: defaults)
        expect(!mute.isMuted(at: now), "預設不靜音")

        mute.mute(for: SpeechMute.hour, now: now)
        expect(mute.isMuted(at: now.addingTimeInterval(60)), "靜音 1 小時後一分鐘仍然靜音")
        expect(mute.mutedUntil(at: now) == now.addingTimeInterval(SpeechMute.hour), "記得靜音到幾點")
        expect(SpeechMute(defaults: defaults).isMuted(at: now.addingTimeInterval(60)), "重開 App 後仍然靜音")
        expect(!mute.isMuted(at: now.addingTimeInterval(SpeechMute.hour + 1)), "時間到自動取消靜音")
        expect(!defaults.bool(forKey: SpeechMute.mutedKey), "時間到後清除靜音狀態")

        mute.mute(for: nil, now: now)
        expect(mute.isMuted(at: now.addingTimeInterval(7 * 24 * SpeechMute.hour)), "直到取消的靜音不會自己結束")
        expect(mute.mutedUntil(at: now) == nil, "直到取消的靜音沒有結束時間")

        mute.mute(for: SpeechMute.hour, now: now)
        mute.mute(for: nil, now: now)
        expect(mute.isMuted(at: now.addingTimeInterval(2 * SpeechMute.hour)), "改為直到取消時清除舊的結束時間")

        mute.unmute()
        expect(!mute.isMuted(at: now), "取消靜音")

        // Focus through Shortcuts: its own quiet, which never clears a mute you set yourself.
        mute.setQuietByAutomation(true)
        expect(mute.isMuted(at: now) && !mute.isMutedByHand(at: now), "專注模式開啟時自動靜音")
        mute.setQuietByAutomation(false)
        expect(!mute.isMuted(at: now), "專注模式結束時恢復")
        mute.mute(for: nil, now: now)
        mute.setQuietByAutomation(true)
        mute.setQuietByAutomation(false)
        expect(mute.isMuted(at: now), "專注模式結束不會取消手動靜音")
        mute.setQuietByAutomation(true)
        mute.unmute()
        expect(!mute.isMuted(at: now) && !mute.isQuietByAutomation, "手動取消靜音會清除所有靜音")

        let link = { (text: String) in URL(string: text).flatMap(SpeechLinkCommand.init(url:)) }
        expect(link("miku-desktop://quiet/on") == .quiet(true), "quiet/on")
        expect(link("miku-desktop://quiet/off") == .quiet(false), "quiet/off")
        expect(link("MIKU-DESKTOP://Quiet/On") == .quiet(true), "連結不分大小寫")
        expect(link("miku-desktop://mute") == .mute(minutes: nil), "mute 直到取消")
        expect(link("miku-desktop://mute?minutes=60") == .mute(minutes: 60), "mute 60 分鐘")
        expect(link("miku-desktop://unmute") == .unmute, "unmute")
        expect(link("miku-desktop://mute?minutes=0") == nil, "拒絕 0 分鐘")
        expect(link("miku-desktop://mute?minutes=99999") == nil, "拒絕超過一天")
        expect(link("miku-desktop://mute?minutes=abc") == nil, "拒絕非數字")
        expect(link("miku-desktop://mute?other=1") == nil, "拒絕未知參數")
        expect(link("miku-desktop://quiet/maybe") == nil, "拒絕未知 quiet 值")
        expect(link("miku-desktop://settings/reset") == nil, "其他指令一律不接受")
        expect(link("https://quiet/on") == nil, "其他 scheme 不接受")

        // The voice follows the text: Mandarin text never in the Cantonese voice, and back.
        let voice = SpeechVoice.voice(for:preferred:)
        expect(voice("辛苦了～我哼首輕快的歌陪你好不好？♪", "yue") == "zh", "國語文字不會用粵語聲音念")
        expect(voice("辛苦晒～我哼首輕快啲嘅歌陪你好唔好？♪", "zh") == "yue", "粵語文字不會用國語聲音念")
        expect(voice("我係 Miku，今天的歌很好聽", "yue") == "zh", "國語詞較多時用國語聲音")
        expect(voice("好！", "yue") == "yue", "分不出時跟選擇（粵語）")
        expect(voice("好！", "zh") == "zh", "分不出時跟選擇（國語）")
        expect(voice("好！", "auto") == "zh", "自動且分不出時用國語")
        expect(voice("辛苦啦～", "yue") == "yue", "台灣國語也會說的「啦」不算粵語")
        expect(voice("辛苦啦～", "zh") == "zh", "「啦」本身不會誤判成粵語")
        expect(voice("今日はいい天気だね", "yue") == "ja", "日文文字用日語聲音")
        expect(voice("Good night, Miku!", "yue") == "en", "英文文字用英語聲音")
        expect(voice("你知道〈セカイ〉嗎？", "yue") == "zh", "國語主句不會被日文歌名改成日語")
        expect(voice("我鍾意〈メルト〉呢首歌", "zh") == "yue", "粵語主句不會被日文歌名改成日語")
        expect(voice("I love 〈メルト〉", "zh") == "en", "英文主句不會被日文歌名改成日語")
        expect(voice("今日は〈セカイ〉を聴くよ", "zh") == "ja", "真正日語混合漢字仍用日語")
        expect(voice("〈セカイ〉", "zh") == "ja", "純日文歌名仍用日語")
        expect(SpeechVoice.voice(forReplyLanguage: "yue") == "yue", "選粵語時聲音跟粵語")
        expect(SpeechVoice.voice(forReplyLanguage: "zh-Hant") == "zh", "選國語時聲音跟國語")
        expect(SpeechVoice.voice(forReplyLanguage: "auto") == nil, "自動時沒有固定聲音")

        let chineseVoice = SpeechVoice.chineseVoice(for:)
        expect(chineseVoice(["我今天很累，想休息一下"]) == "zh", "自動辨識國語")
        expect(chineseVoice(["今日好攰"]) == "yue", "自動辨識粵語")
        expect(chineseVoice(["我鍾意〈メルト〉呢首歌"]) == "yue", "自動辨識夾日文歌名的粵語")
        expect(chineseVoice(["好！", "我今日真係好攰"]) == "yue", "簡短中文跟隨先前粵語")
        expect(chineseVoice(["ok", "我今日真係好攰"]) == "yue", "簡短英文跟隨先前粵語")
        expect(chineseVoice(["我今天很累", "我今日真係好攰"]) == "zh", "明確國語可從粵語切換")
        expect(chineseVoice(["今日は元気です", "Good morning", "我今日真係好攰"]) == "yue", "英日文字不會誤判中文方言")
        expect(chineseVoice(["今日は元気です", "Good morning"]) == "zh", "沒有中文線索時預設國語")

        let screens = [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        ]
        expect(SpeechQuietTimes.coversScreen(screens[0], screens: screens), "視窗剛好蓋滿螢幕算全螢幕")
        expect(SpeechQuietTimes.coversScreen(screens[1], screens: screens), "外接螢幕全螢幕也算")
        expect(!SpeechQuietTimes.coversScreen(CGRect(x: 0, y: 0, width: 1512, height: 945), screens: screens), "放大但留著選單列的視窗不算全螢幕")
        expect(!SpeechQuietTimes.coversScreen(CGRect(x: 0, y: 0, width: 800, height: 600), screens: screens), "普通視窗不算全螢幕")

        if failures.isEmpty {
            print("SpeechMute：\(checks) 項檢查通過")
        } else {
            for failure in failures { print("失敗：\(failure)") }
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }
}
