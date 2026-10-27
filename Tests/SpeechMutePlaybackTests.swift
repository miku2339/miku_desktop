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

        // Mouth sync: the page only waits for audio that will really be attempted.
        var events: [MikuSpeech.PlaybackEvent] = []
        speech.onPlayback = { events.append($0) }
        speech.setMuted(true)
        expect(!speech.willSpeakAutomatically, "靜音時回覆不會自動朗讀，嘴形照文字")
        speech.speak("Automatic reply while muted")
        expect(events == [.failed], "被靜音擋下的自動回覆通知頁面沒有語音")
        speech.setMuted(false)

        events.removeAll()
        speech.enabled = false
        expect(!speech.willSpeakAutomatically, "關閉朗讀時不等待語音")
        speech.speak("Reply with reading aloud off")
        expect(events == [.failed], "關閉朗讀時通知頁面沒有語音")
        speech.enabled = true

        events.removeAll()
        speech.speak("🎵🎵")
        expect(events == [.failed], "清理後沒有可讀文字時通知頁面沒有語音")

        defaults.set("", forKey: "speechLocalModel")
        expect(!speech.willSpeakAutomatically, "未設定模型時不等待語音")
        let humChecks = HumChecks.run(expect: { expect($0, $1) })
        let retryChecks = RetryChecks.run(expect: { expect($0, $1) })
        print("SpeechMutePlayback：\(12 + humChecks + retryChecks) 項檢查通過")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("失敗：\(message)\n", stderr)
            exit(1)
        }
    }
}

/// Hum detection and the local clip folder (no sound is played).
@MainActor
enum HumChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); count += 1 }

        // What counts as humming in her reply.
        for text in ["那 Miku 要聽喔！ ♪ 啦啦啦～♪ 怎麼樣？", "ららら～♪", "la la la~", "La-la-la ♪", "ふんふ～ん♪", "哼哼～", "♪～♪"] {
            check(HumText.containsHum(text), "a hum is spotted: \(text)")
        }
        for text in ["真乖～♪ 那我們繼續聽歌吧！", "好耶！♪", "啦", "Lalaland is a film", "嗯，好的", "その曲いいね♪"] {
            check(!HumText.containsHum(text), "not a hum: \(text)")
        }
        let spoken = HumText.removingHum("那 Miku 要聽喔！ ♪ 啦啦啦～♪ 怎麼樣？Miku 哼得好不好聽？")
        check(!spoken.contains("啦"), "hum syllables are left out of what is read aloud: \(spoken)")
        check(spoken.contains("怎麼樣"), "the rest of the reply is still read aloud: \(spoken)")
        check(HumText.removingHum("啦啦啦～♪").isEmpty, "a reply that is only a hum reads nothing aloud")

        // The folder: only short audio files directly inside it count.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("miku-hums-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        check(!HumText.hasClips(in: folder), "an empty folder has no clips")
        check(!HumText.hasClips(in: folder.appendingPathComponent("missing")), "a missing folder has no clips")
        let short = folder.appendingPathComponent("hum-1.wav")
        let long = folder.appendingPathComponent("song.wav")
        try? silentWAV(seconds: 2).write(to: short)
        try? silentWAV(seconds: 12).write(to: long)
        try? Data("not audio".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try? FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.wav"), withDestinationURL: short)
        check(HumText.hasClips(in: folder), "a wav file counts as a clip")
        let clips = HumPlayer(folder: folder).clips().map(\.lastPathComponent)
        check(clips == ["hum-1.wav"], "only short audio files count, not long ones, text or links: \(clips)")
        check(HumPlayer(folder: folder.appendingPathComponent("missing")).play() == false, "nothing plays without clips")
        return count
    }

    /// A mono 16-bit PCM WAV of silence.
    static func silentWAV(seconds: Double, rate: Int = 8_000) -> Data {
        let samples = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}

/// One retry for a service hiccup, and a text-free line in diagnostics for each retry or failure.
@MainActor
enum RetryChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); count += 1 }

        check(MikuSpeech.isRetryableGeneration(MikuSpeech.SpeechError.serverResponse(500)), "a 500 is retried")
        check(MikuSpeech.isRetryableGeneration(MikuSpeech.SpeechError.serverResponse(503)), "a 503 is retried")
        check(!MikuSpeech.isRetryableGeneration(MikuSpeech.SpeechError.serverResponse(404)), "a 404 is not retried")
        check(!MikuSpeech.isRetryableGeneration(MikuSpeech.SpeechError.invalidAudio), "bad audio is not retried")
        check(MikuSpeech.isRetryableGeneration(URLError(.timedOut)), "a timeout is retried")
        check(MikuSpeech.isRetryableGeneration(URLError(.networkConnectionLost)), "a dropped connection is retried")
        check(MikuSpeech.diagnosticCode(MikuSpeech.SpeechError.serverResponse(500)) == "http-500", "HTTP errors are logged by status")
        check(MikuSpeech.diagnosticCode(URLError(.cannotConnectToHost)) == "url-1004", "network errors are logged by code")
        check(MikuSpeech.generationTimeout >= 60, "generating audio waits at least a minute")

        guard let port = ProcessInfo.processInfo.environment["MIKU_FAKE_TTS_PORT"], !port.isEmpty else {
            check(false, "the stand-in TTS service is running")
            return count
        }
        for (model, expected) in [("flaky", ["retry", "recovered"]), ("broken", ["retry", "failed"])] {
            let suite = "com.qimake.MikuDesktop.speech-retry-tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "speechEnabled")
            defaults.set("http://127.0.0.1:\(port)/v1", forKey: "speechLocalEndpoint")
            defaults.set(model, forKey: "speechLocalModel")
            let speech = MikuSpeech(defaults: defaults)
            var events: [MikuSpeech.PlaybackEvent] = []
            var diagnostics: [[String: Any]] = []
            speech.onPlayback = { events.append($0) }
            speech.onDiagnostic = { diagnostics.append($0) }
            let secret = "A private line of conversation"
            speech.speak(secret, userInitiated: true)
            let finished: () -> Bool = {
                events.contains { event in
                    if case .started = event { return true }
                    return event == .failed
                }
            }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !finished() {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            speech.stop()
            let whats = diagnostics.compactMap { $0["what"] as? String }
            check(whats == expected, "\(model): diagnostics are \(expected), got \(whats)")
            check((diagnostics.first?["code"] as? String) == "http-500", "\(model): the first problem is logged as http-500")
            check(diagnostics.allSatisfy { ($0["chars"] as? Int) == secret.count && $0["language"] != nil },
                  "\(model): length and language are logged")
            let logged = diagnostics.map { "\($0)" }.joined()
            check(!logged.contains("private line"), "\(model): the text itself is never logged")
            if model == "flaky" {
                check(events.contains { if case .started = $0 { return true }; return false }, "flaky: the retry plays the audio")
            } else {
                check(events.last == .failed, "broken: it gives up after one retry")
                check((diagnostics.last?["attempt"] as? Int) == 2, "broken: two attempts are logged")
            }
        }
        return count
    }
}
