import Foundation

@main
struct SpeechMutePlaybackTests {
    @MainActor
    static func main() {
        let suite = "com.qimake.MikuDesktop.speech-mute-playback-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "speechEnabled")
        defaults.set("http://127.0.0.1:65535/v1", forKey: "speechLocalEndpoint")
        defaults.set("test-local-model", forKey: "speechLocalModel")

        let speech = MikuSpeech(defaults: defaults)
        speech.setMuted(true)
        speech.speak("User-requested replay", userInitiated: true)
        expect(speech.isBusy, "使用者重播在靜音時仍開始")
        let replayStatus = speech.status

        speech.speak("Automatic reply")
        expect(speech.isBusy, "被靜音擋下的自動回覆不清除重播 busy 狀態")
        expect(speech.status == replayStatus, "被擋下的自動回覆不覆寫重播狀態")

        speech.setMuted(false)
        expect(speech.isBusy, "重播期間取消靜音不清除 busy 狀態")
        expect(speech.status == replayStatus, "重播期間取消靜音不覆寫播放狀態")

        speech.stop()
        expect(!speech.isBusy, "停止播放會清除 busy 狀態")
        print("SpeechMutePlayback：6 項檢查通過")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("失敗：\(message)\n", stderr)
            exit(1)
        }
    }
}
