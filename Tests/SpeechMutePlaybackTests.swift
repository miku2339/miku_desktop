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
        let koreanChecks = KoreanSpeechChecks.run(expect: { expect($0, $1) })
        let originChecks = PlaybackOriginChecks.run(expect: { expect($0, $1) })
        let voiceReplyChecks = VoiceReplyChecks.run(expect: { expect($0, $1) })
        let pcmChecks = PCMReplyChecks.run(expect: { expect($0, $1) })
        let retryChecks = RetryChecks.run(expect: { expect($0, $1) })
        print("SpeechMutePlayback：\(12 + humChecks + retryChecks + koreanChecks + originChecks + voiceReplyChecks + pcmChecks) 項檢查通過")
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
        for text in ["那 Miku 要聽喔！ ♪ 啦啦啦～♪ 怎麼樣？", "ららら～♪", "la la la~", "La-la-la ♪", "ふんふ～ん♪", "라라라~♪", "哼哼～", "♪～♪"] {
            check(HumText.containsHum(text), "a hum is spotted: \(text)")
        }
        for text in ["真乖～♪ 那我們繼續聽歌吧！", "好耶！♪", "啦", "Lalaland is a film", "라라랜드 영화를 봤어", "嗯，好的", "その曲いいね♪"] {
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


@MainActor
enum KoreanSpeechChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); count += 1 }
        guard let port = ProcessInfo.processInfo.environment["MIKU_FAKE_TTS_PORT"] else {
            check(false, "韓語測試需要本機假服務")
            return count
        }
        for model in [MikuSpeech.automaticModelID, "miku-gpt-sovits", "miku-gpt-sovits-ja", "korean-check"] {
            let suite = "com.qimake.MikuDesktop.korean-speech-tests.\(UUID())"
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
            speech.speak("오늘도 수고했어", userInitiated: true)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !events.contains(where: { event in
                if case .started = event { return true }
                return event == .failed
            }) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            if model == "korean-check" {
                check(events.contains { if case .started = $0 { return true }; return false }, "自備韓語模型以ko成功請求")
            } else {
                check(events == [.failed], "四語私人模型不嘗試讀韓語：\(model)")
                check(diagnostics.last?["code"] as? String == "korean-model-required", "不相容模型有明確狀態")
            }
            speech.stop()
        }
        return count
    }
}


@MainActor
enum PlaybackOriginChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); count += 1 }
        let suite = "com.qimake.MikuDesktop.playback-origin-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "speechEnabled")
        defaults.set("http://127.0.0.1:65535/v1", forKey: "speechLocalEndpoint")
        defaults.set("fixture", forKey: "speechLocalModel")
        let output = FakeVoiceReplyOutput()
        output.automaticallyCompletes = true
        let speech = MikuSpeech(defaults: defaults, voiceReplyOutput: output.driver)
        var events: [(MikuSpeech.PlaybackEvent, MikuSpeech.PlaybackSource)] = []
        speech.onPlaybackWithSource = { events.append(($0, $1)) }
        speech.speak("A call reply", userInitiated: true, source: .voiceCall)
        speech.stop()
        check(events.count == 1 && events[0].0 == .interrupted && events[0].1 == .voiceCall,
              "stopping a call during generation reports its own interruption")
        events.removeAll()
        speech.speak("A call reply", userInitiated: true, source: .voiceCall)
        speech.playSample(language: .english)
        check(events.contains { $0.0 == .interrupted && $0.1 == .voiceCall },
              "a preview replacing a generating call cancels the call first")
        speech.stop()
        events.removeAll()
        speech.enabled = false
        speech.speak("A call reply", userInitiated: true, source: .voiceCall)
        check(events.count == 1 && events[0].0 == .failed && events[0].1 == .voiceCall,
              "a synchronous failure keeps the requesting call origin")
        speech.enabled = true
        guard let port = ProcessInfo.processInfo.environment["MIKU_FAKE_TTS_PORT"] else {
            check(false, "the stand-in voice service is running")
            return count
        }
        defaults.set("http://127.0.0.1:\(port)/v1", forKey: "speechLocalEndpoint")
        events.removeAll()
        speech.speak("Hello", userInitiated: true, source: .voiceCall)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !events.contains(where: { $0.0 == .ended || $0.0 == .failed }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check(events.contains { event, source in
            if case .started = event { return source == .voiceCall }
            return false
        }, "call audio starts with the call origin")
        check(events.contains { $0.0 == .ended && $0.1 == .voiceCall }, "call audio ends with the same origin")
        speech.stop()
        return count
    }
}

@MainActor
final class FakeVoiceReplyOutput {
    var automaticallyCompletes = false
    var starts = 0
    var stops = 0
    var completions: [@MainActor (Bool) -> Void] = []
    var supportsPCM = false
    var pcmStarts = 0
    var pcmPackets = 0
    var pcmBytes = 0
    var pcmFinished = false
    var holdPCMAppend = false
    var pcmAppendWaiter: CheckedContinuation<Void, Error>?
    var pcmActivity: (@MainActor (Bool) -> Void)?
    var pcmCompletion: (@MainActor (Bool) -> Void)?

    var driver: MikuSpeech.VoiceReplyOutput {
        MikuSpeech.VoiceReplyOutput(
            play: { [unowned self] _, completion in
                starts += 1
                completions.append(completion)
                if automaticallyCompletes { completion(true) }
                return 0.3
            },
            stop: { [unowned self] in
                stops += 1
                let waiter = pcmAppendWaiter; pcmAppendWaiter = nil
                waiter?.resume(throwing: CancellationError())
            },
            pcm: supportsPCM ? .init(
                begin: { [unowned self] _, activity, completion in
                    pcmStarts += 1; pcmActivity = activity; pcmCompletion = completion
                },
                append: { [unowned self] data in
                    pcmPackets += 1; pcmBytes += data.count; pcmActivity?(true)
                    if holdPCMAppend { try await withCheckedThrowingContinuation { pcmAppendWaiter = $0 } }
                },
                finish: { [unowned self] in pcmFinished = true }
            ) : nil
        )
    }

    func complete(_ success: Bool = true) {
        guard !completions.isEmpty else { return }
        completions.removeFirst()(success)
    }
}

@MainActor
enum PCMReplyChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var count = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); count += 1 }
        guard let port = ProcessInfo.processInfo.environment["MIKU_FAKE_TTS_PORT"] else { return 0 }
        func fixture(_ model: String) -> (MikuSpeech, FakeVoiceReplyOutput, UserDefaults, String) {
            let suite = "com.qimake.MikuDesktop.pcm-reply-tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "speechEnabled")
            defaults.set("http://127.0.0.1:\(port)/v1", forKey: "speechLocalEndpoint")
            defaults.set(model, forKey: "speechLocalModel")
            let output = FakeVoiceReplyOutput(); output.supportsPCM = true
            return (MikuSpeech(defaults: defaults, voiceReplyOutput: output.driver), output, defaults, suite)
        }
        func spin(_ condition: () -> Bool, timeout: TimeInterval = 4) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func options(_ model: String) -> [String: Any] {
            let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/options?model=\(model)")!)
            return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        func terminal(_ events: [MikuSpeech.PlaybackEvent]) -> [MikuSpeech.PlaybackEvent] {
            events.filter { $0 == .ended || $0 == .failed || $0 == .interrupted }
        }
        do {
            let (speech, output, defaults, suite) = fixture("pcm-reply")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []; var heard: [String] = []
            speech.onPlayback = { events.append($0) }; speech.onVoiceSegmentFinished = { heard.append($0) }
            let token = speech.beginVoiceReply(style: .happy)!
            speech.appendVoiceReply("An incremental sentence.", token: token); speech.finishVoiceReply(token: token)
            spin({ output.pcmPackets > 0 })
            check(output.pcmStarts == 1 && output.starts == 0, "宣告PCM能力時使用共享stream driver，不用整段WAV")
            check(events == [.streamingStarted(text: "An incremental sentence.")], "首塊實播才開始嘴形，不宣告虛構總時長")
            check(!output.pcmFinished && heard.isEmpty, "未收end就開始播放，但不能記成整句聽過")
            output.pcmActivity?(false); output.pcmActivity?(true)
            check(events.suffix(2) == [.streamingStopped, .streamingStarted(text: "An incremental sentence.")], "網路underflow暫停嘴形，新音訊到達再啟動")
            spin({ output.pcmFinished })
            check(output.pcmBytes == 8_000 && terminal(events).isEmpty && heard.isEmpty,
                  "合法end只結束網路，仍等待真正播完")
            let sent = options("pcm-reply")
            check(sent["style"] as? String == "neutral" && sent["stream"] as? Bool == true && sent["response_format"] as? String == "pcm_s16le",
                  "未宣告happy風格退neutral，PCM請求欄位正確")
            output.pcmCompletion?(true)
            spin({ terminal(events) == [.ended] })
            check(heard == ["An incremental sentence."] && terminal(events) == [.ended], "最後buffer實播完成才記整句與整輪結束")
            output.pcmCompletion?(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            check(heard.count == 1 && terminal(events) == [.ended], "PCM完成回調重複不會重複記憶或結束")
        }
        for model in ["pcm-no-stream", "pcm-wrong-model", "voice-reply-legacy-style"] {
            let (speech, output, defaults, suite) = fixture(model)
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            let token = speech.beginVoiceReply(style: .happy)!
            speech.appendVoiceReply("A compatible sentence.", token: token); speech.finishVoiceReply(token: token)
            spin({ output.starts == 1 })
            check(output.starts == 1 && output.pcmStarts == 0, "\(model)：未明確驗收串流能力就走WAV")
            let sent = options(model)
            check(sent["response_format"] as? String == "wav" && sent["stream"] == nil, "\(model)：舊WAV請求不帶stream欄位")
            check(model == "pcm-no-stream" ? sent["style"] as? String == "neutral" : sent["style"] == nil,
                  "\(model)：只有有效能力才送已宣告風格")
        }
        do {
            let (speech, _, defaults, suite) = fixture("style-both")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            speech.onPlayback = { events.append($0) }
            speech.speak("A gentle line.", userInitiated: true, style: .gentle)
            spin({ events.contains { if case .started = $0 { return true }; return $0 == .failed } })
            check(options("style-both")["style"] as? String == "gentle", "一般朗讀也只傳服務宣告的gentle風格")
        }
        do {
            let (speech, output, defaults, suite) = fixture("pcm-delayed")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            output.holdPCMAppend = true
            var events: [MikuSpeech.PlaybackEvent] = []; var heard: [String] = []
            speech.onPlayback = { events.append($0) }; speech.onVoiceSegmentFinished = { heard.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("A blocked stream.", token: token); speech.finishVoiceReply(token: token)
            spin({ output.pcmAppendWaiter != nil })
            RunLoop.main.run(until: Date().addingTimeInterval(0.7))
            check(output.pcmPackets == 1 && !output.pcmFinished, "播放器無容量時網路reader不再提交後續PCM")
            let oldCompletion = output.pcmCompletion; let oldActivity = output.pcmActivity
            speech.setMuted(true)
            spin({ terminal(events) == [.interrupted] })
            check(output.pcmAppendWaiter == nil && heard.isEmpty && !speech.isBusy, "靜音取消reader、釋放backpressure等待且不記未播完句子")
            oldCompletion?(true); oldActivity?(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            check(terminal(events) == [.interrupted] && heard.isEmpty, "取消後舊PCM完成與開始事件不能復活")
        }
        do {
            let (speech, output, defaults, suite) = fixture("pcm-reentrant")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var heard: [String] = []
            speech.onVoiceSegmentFinished = { heard.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("A completed old sentence.", token: token); speech.finishVoiceReply(token: token)
            spin({ output.pcmFinished })
            speech.onPlayback = { event in if event == .streamingStopped { speech.stop() } }
            output.pcmCompletion?(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            check(heard.isEmpty, "streamingStopped回調中取消，不能再將舊句推入已重設的記憶")
        }
        do {
            let (speech, output, defaults, suite) = fixture("pcm-replaced")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            output.holdPCMAppend = true
            var events: [MikuSpeech.PlaybackEvent] = []; var heard: [String] = []
            speech.onPlayback = { events.append($0) }; speech.onVoiceSegmentFinished = { heard.append($0) }
            let old = speech.beginVoiceReply()!
            speech.appendVoiceReply("The interrupted stream.", token: old)
            spin({ output.pcmAppendWaiter != nil })
            let oldCompletion = output.pcmCompletion
            try! speech.configure(endpoint: "http://127.0.0.1:\(port)/v1", modelID: "voice-reply-after-pcm")
            let next = speech.beginVoiceReply()!
            speech.appendVoiceReply("The new sentence.", token: next); speech.finishVoiceReply(token: next)
            oldCompletion?(true)
            spin({ output.starts == 1 })
            check(output.pcmAppendWaiter == nil && heard.isEmpty && terminal(events) == [.interrupted], "新回覆取消舊PCM容量等待與完成事件")
            output.complete()
            spin({ !speech.isBusy })
            check(heard == ["The new sentence."] && terminal(events) == [.interrupted, .ended], "PCM被新WAV取代後只有新句算已聽完")
        }
        for model in ["pcm-truncated", "pcm-error", "pcm-sequence", "pcm-end-junk"] {
            let (speech, output, defaults, suite) = fixture(model)
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []; var heard: [String] = []
            speech.onPlayback = { events.append($0) }; speech.onVoiceSegmentFinished = { heard.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("A stream that fails.", token: token); speech.finishVoiceReply(token: token)
            spin({ terminal(events) == [.failed] })
            check(terminal(events) == [.failed] && !output.pcmFinished && heard.isEmpty, "\(model)：協定錯誤不能當成功end或記憶")
            output.pcmCompletion?(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            check(heard.isEmpty && terminal(events) == [.failed], "\(model)：失敗後晚到播放器完成仍無效")
        }
        return count
    }
}

@MainActor
enum VoiceReplyChecks {
    static func run(expect: (Bool, String) -> Void) -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { expect(condition, message); checks += 1 }
        guard let port = ProcessInfo.processInfo.environment["MIKU_FAKE_TTS_PORT"] else {
            check(false, "串流語音測試需要本機假服務")
            return checks
        }
        func fixture(_ model: String) -> (MikuSpeech, FakeVoiceReplyOutput, UserDefaults, String) {
            let suite = "com.qimake.MikuDesktop.voice-reply-tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "speechEnabled")
            defaults.set("http://127.0.0.1:\(port)/v1", forKey: "speechLocalEndpoint")
            defaults.set(model, forKey: "speechLocalModel")
            let output = FakeVoiceReplyOutput()
            return (MikuSpeech(defaults: defaults, voiceReplyOutput: output.driver), output, defaults, suite)
        }
        func spin(_ predicate: () -> Bool, seconds: TimeInterval = 5) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !predicate() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        func settle(_ seconds: TimeInterval = 0.1) { spin({ false }, seconds: seconds) }
        func requests(_ model: String) -> Int {
            let url = URL(string: "http://127.0.0.1:\(port)/counts?model=\(model)")!
            guard let data = try? Data(contentsOf: url),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return -1 }
            return body["count"] ?? -1
        }
        func starts(_ events: [MikuSpeech.PlaybackEvent]) -> [String] {
            events.compactMap { if case let .started(text, _) = $0 { return text }; return nil }
        }
        func terminals(_ events: [MikuSpeech.PlaybackEvent]) -> [MikuSpeech.PlaybackEvent] {
            events.filter { if case .started = $0 { return false }; return true }
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-overlap")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            var sources: [MikuSpeech.PlaybackSource] = []
            var finished: [String] = []
            speech.onPlaybackWithSource = { events.append($0); sources.append($1) }
            speech.onVoiceSegmentFinished = { finished.append($0) }
            guard let token = speech.beginVoiceReply() else { check(false, "可開始串流語音"); return checks }
            speech.appendVoiceReply("First sentence.", token: token)
            spin({ output.starts == 1 })
            check(starts(events) == ["First sentence."], "finish前第一句已播放")
            check(finished.isEmpty, "開始播放不代表句子已聽完")
            check(terminals(events).isEmpty && speech.isBusy, "等候後續句子時不提早結束")
            speech.appendVoiceReply("Second sentence.", token: token)
            spin({ requests("voice-reply-overlap") == 2 })
            settle()
            check(output.starts == 1 && requests("voice-reply-overlap") == 2, "前句播放期間已產生下一句")
            speech.appendVoiceReply("Third sentence.", token: token)
            settle()
            check(requests("voice-reply-overlap") == 2, "已預取一句時不持續堆積音訊")
            output.complete()
            spin({ output.starts == 2 })
            check(starts(events) == ["First sentence.", "Second sentence."], "依序播放已預取句子")
            check(finished == ["First sentence."], "實際播完第一句即回報已聽前綴")
            speech.finishVoiceReply(token: token)
            speech.finishVoiceReply(token: token)
            spin({ requests("voice-reply-overlap") == 3 })
            settle()
            output.complete()
            spin({ output.starts == 3 })
            output.complete()
            spin({ !speech.isBusy })
            check(starts(events) == ["First sentence.", "Second sentence.", "Third sentence."], "三句皆只播放一次")
            check(terminals(events) == [.ended], "finish且佇列播完後只結束一次")
            check(finished == ["First sentence.", "Second sentence.", "Third sentence."], "每句真正播完才依序回報")
            check(sources.allSatisfy { $0 == .voiceCall }, "所有分段事件保留通話來源")
            let eventCount = events.count
            speech.appendVoiceReply("Late sentence.", token: token)
            speech.finishVoiceReply(token: token)
            speech.stop()
            settle()
            check(events.count == eventCount, "結束後的append與finish沒有副作用")
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-slow")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            speech.onPlayback = { events.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("Cancelled before generation.", token: token)
            spin({ requests("voice-reply-slow") > 0 })
            speech.stop()
            speech.stop()
            speech.appendVoiceReply("Stale append.", token: token)
            speech.finishVoiceReply(token: token)
            settle(0.6)
            check(output.starts == 0, "遲到的生成結果不恢復播放")
            check(events == [.interrupted] && !speech.isBusy, "產生中取消只發一次interrupted")
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-late-playback")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [(MikuSpeech.PlaybackEvent, MikuSpeech.PlaybackSource)] = []
            var finished: [String] = []
            speech.onPlaybackWithSource = { events.append(($0, $1)) }
            speech.onVoiceSegmentFinished = { finished.append($0) }
            let old = speech.beginVoiceReply()!
            speech.appendVoiceReply("Old call.", token: old)
            spin({ output.starts == 1 })
            let lateCompletion = output.completions.first
            let current = speech.beginVoiceReply()!
            speech.appendVoiceReply("New call.", token: current)
            speech.finishVoiceReply(token: current)
            lateCompletion?(true)
            output.complete(false)
            spin({ output.starts == 2 })
            output.complete()
            spin({ !speech.isBusy })
            check(terminals(events.map(\.0)) == [.interrupted, .ended], "舊播放器的遲到失敗不影響新一輪")
            check(events.allSatisfy { $0.1 == .voiceCall }, "取代舊通話保留原事件來源")
            check(finished == ["New call."], "取消後遲到的成功或失敗都不回報已聽內容")
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-slow")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            var finished: [String] = []
            speech.onPlayback = { events.append($0) }
            speech.onVoiceSegmentFinished = { finished.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("Heard before prefetch finishes.", token: token)
            spin({ output.starts == 1 })
            let priorRequests = requests("voice-reply-slow")
            speech.appendVoiceReply("Still generating.", token: token)
            spin({ requests("voice-reply-slow") == priorRequests + 1 })
            output.complete()
            spin({ !finished.isEmpty })
            check(output.starts == 1 && finished == ["Heard before prefetch finishes."],
                  "後句仍在生成時立即回報已播完的前句")
            speech.stop()
            settle(0.5)
            check(finished == ["Heard before prefetch finishes."] && terminals(events) == [.interrupted],
                  "生成空檔插話仍保留已聽前句且取消後句")
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-finished-cancel")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            var finished: [String] = []
            speech.onPlayback = { events.append($0) }
            speech.onVoiceSegmentFinished = { text in
                finished.append(text)
                speech.stop()
            }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("A completed sentence.", token: token)
            speech.appendVoiceReply("Do not start this sentence.", token: token)
            speech.finishVoiceReply(token: token)
            spin({ output.starts == 1 })
            spin({ requests("voice-reply-finished-cancel") == 2 })
            settle()
            let duplicateCompletion = output.completions.first
            output.complete()
            duplicateCompletion?(true)
            settle()
            check(finished == ["A completed sentence."], "完成回呼可重入取消且不重複回報")
            check(output.starts == 1 && terminals(events) == [.interrupted] && !speech.isBusy,
                  "完成回呼取消後不播放下一句或多發ended")
        }

        for action in ["mute", "disable", "quiet"] {
            let (speech, output, defaults, suite) = fixture("voice-reply-\(action)")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            var finished: [String] = []
            speech.onPlayback = { events.append($0) }
            speech.onVoiceSegmentFinished = { finished.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("Speaking now.", token: token)
            speech.appendVoiceReply("Discard this sentence.", token: token)
            spin({ output.starts == 1 })
            switch action {
            case "mute": speech.setMuted(true)
            case "disable": speech.enabled = false
            default: speech.setQuietByAutomation(true)
            }
            output.complete()
            speech.finishVoiceReply(token: token)
            settle()
            check(output.starts == 1 && output.stops == 1, "\(action)停止輸出並清空預取句")
            check(terminals(events) == [.interrupted] && !speech.isBusy, "\(action)只發一次中斷事件")
            check(finished.isEmpty, "\(action)不把已取消句子當作播完")
            check(speech.beginVoiceReply() == nil, "\(action)不開始新朗讀")
            check(terminals(events) == [.interrupted, .failed], "\(action)拒絕開始時同步回報失敗")
        }

        do {
            let (speech, output, defaults, suite) = fixture("voice-reply-fails-second")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            var diagnostics: [[String: Any]] = []
            speech.onPlayback = { events.append($0) }
            speech.onDiagnostic = { diagnostics.append($0) }
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("A private first sentence.", token: token)
            spin({ output.starts == 1 })
            speech.appendVoiceReply("A private failing sentence.", token: token)
            speech.finishVoiceReply(token: token)
            spin({ terminals(events) == [.failed] })
            output.complete()
            settle()
            check(output.starts == 1 && output.stops == 1 && !speech.isBusy, "後句失敗清除正在播放及預取內容")
            check(terminals(events) == [.failed] && requests("voice-reply-fails-second") == 2, "後句失敗只報一次且不重試整輪")
            check(!String(describing: diagnostics).contains("private") && !String(describing: diagnostics).contains(token.uuidString), "診斷不含通話原文或token")
        }

        for model in ["voice-reply-oversized", "voice-reply-limit"] {
            let (speech, output, defaults, suite) = fixture(model)
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            speech.onPlayback = { events.append($0) }
            let token = speech.beginVoiceReply()!
            if model == "voice-reply-limit" {
                for _ in 0..<33 { speech.appendVoiceReply("Bounded queue.", token: token) }
            } else {
                speech.appendVoiceReply("Oversized audio.", token: token)
            }
            spin({ terminals(events) == [.failed] })
            check(events == [.failed] && output.starts == 0 && !speech.isBusy, "\(model)超限停止且不開始播放")
        }

        do {
            let (speech, _, defaults, suite) = fixture("")
            defer { speech.stop(); defaults.removePersistentDomain(forName: suite) }
            var events: [MikuSpeech.PlaybackEvent] = []
            speech.onPlayback = { events.append($0) }
            check(speech.beginVoiceReply() == nil && events == [.failed], "未設定模型時同步失敗")
            defaults.set("voice-reply-empty", forKey: "speechLocalModel")
            events.removeAll()
            let token = speech.beginVoiceReply()!
            speech.appendVoiceReply("🎵", token: token)
            speech.finishVoiceReply(token: token)
            speech.finishVoiceReply(token: token)
            check(events == [.ended] && !speech.isBusy, "沒有可讀句子時finish只結束一次")
        }
        return checks
    }
}
