import AVFoundation
import Foundation
import SoundAnalysis
import Speech

@MainActor
private final class FakeVoiceInput: VoiceCallInput {
    var automaticInterruptionAvailable = true
    var heldAuthorization = false
    var authorizationError: Error?
    var continuation: CheckedContinuation<Void, Error>?
    var listenError: Error?
    var resultCallbacks: [(String, Bool) -> Void] = []
    var activityCallbacks: [(Bool) -> Void] = []
    var errorCallbacks: [(String) -> Void] = []
    var listens = 0
    var resets = 0
    var stops = 0
    var isRecording = false
    var authorizations = 0
    var preparationReleases = 0
    var configuredLanguages: [VoiceCallLanguage] = []
    var preparationCallbacks: [(VoiceCallPreparation) -> Void] = []

    func configure(language: VoiceCallLanguage, onPreparation: @escaping (VoiceCallPreparation) -> Void) {
        configuredLanguages.append(language)
        preparationCallbacks.append(onPreparation)
    }

    func authorize() async throws {
        authorizations += 1
        if let authorizationError { throw authorizationError }
        if heldAuthorization { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
    func listen(onResult: @escaping (String, Bool) -> Void, onActivity: @escaping (Bool) -> Void, onError: @escaping (String) -> Void) throws {
        if let listenError { throw listenError }
        listens += 1
        isRecording = true
        resultCallbacks.append(onResult)
        activityCallbacks.append(onActivity)
        errorCallbacks.append(onError)
    }
    func resetRecognition() throws { resets += 1 }
    func releasePreparation() { preparationReleases += 1 }
    func stop() { stops += 1; isRecording = false }
    func result(_ text: String, final: Bool = false, input: Int? = nil) { resultCallbacks[input ?? (resultCallbacks.count - 1)](text, final) }
    func activity(_ active: Bool, input: Int? = nil) { activityCallbacks[input ?? (activityCallbacks.count - 1)](active) }
}

@MainActor
private final class FakeVoiceTimer: VoiceCallScheduledTask {
    let deadline: Double
    let action: @MainActor () -> Void
    var cancelled = false
    init(deadline: Double, action: @escaping @MainActor () -> Void) { self.deadline = deadline; self.action = action }
    func cancel() { cancelled = true }
}

@MainActor
private final class FakeVoiceClock: VoiceCallScheduling {
    var now = 0.0
    var timers: [FakeVoiceTimer] = []
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> VoiceCallScheduledTask {
        let timer = FakeVoiceTimer(deadline: now + delay, action: action)
        timers.append(timer)
        return timer
    }
    func advance(_ seconds: Double) {
        let target = now + seconds
        while let next = timers.filter({ !$0.cancelled && $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) {
            next.cancelled = true; now = next.deadline; next.action()
        }
        now = target
    }
}

private final class FeedProbe: @unchecked Sendable {
    var values: [Float] = []
    var endings = 0
    func append(_ buffer: AVAudioPCMBuffer) { values.append(buffer.floatChannelData![0][0]) }
}

@main
struct VoiceCallTests {
    private static var checks = 0

    @MainActor
    static func main() async throws {
        let input = FakeVoiceInput()
        let clock = FakeVoiceClock()
        let call = VoiceCallController(input: input, scheduler: clock)
        var utterances: [String] = []
        var interruptions = 0
        call.onUtterance = { utterances.append($0) }
        call.onInterrupt = { interruptions += 1 }
        check(call.phase == .inactive && !call.isActive && !input.isRecording, "預設不收音")
        call.start()
        check(call.phase == .preparing, "使用者開始後才請求授權")
        await settle()
        check(call.phase == .listening && input.isRecording && call.automaticInterruptionAvailable, "授權後持續輸入可用")
        input.activity(true)
        input.result("一個還沒改變的字")
        clock.advance(4)
        check(utterances.isEmpty, "聲音持續時文字不變也不截斷")
        input.result("這是一個完整句子", final: true)
        clock.advance(1)
        check(utterances.isEmpty, "ASR final不能截斷仍在說話的人")
        input.activity(false)
        clock.advance(0.5)
        input.activity(false)
        clock.advance(0.3)
        check(utterances == ["這是一個完整句子"], "聲音停止後只交句一次，重複quiet不延後送出")
        check(call.phase == .thinking && input.isRecording && input.listens == 1 && input.resets == 1, "送句只輪替ASR，不停engine")
        clock.advance(2)
        check(utterances.count == 1, "舊endpoint timer不重複送出")
        call.replyReady()
        call.playbackStarted()
        check(call.phase == .speaking && input.isRecording, "Miku播放時仍然持續收聽")
        input.result("可能的殘留辨識")
        clock.advance(2)
        check(interruptions == 0 && call.phase == .speaking, "只有文字沒有聲音證據不打斷")
        input.activity(true)
        check(interruptions == 1 && call.phase == .listening && call.transcript == "可能的殘留辨識", "聲學與ASR雙證據同步打斷且保留開頭")
        check(input.listens == 1 && input.resets == 1, "打斷不重建engine或清除當下ASR")
        input.result("等等，我想換一個問題")
        input.activity(false)
        clock.advance(0.8)
        check(utterances.last == "等等，我想換一個問題" && utterances.count == 2, "打斷後新句完整送出")
        call.playbackFinished()
        check(call.phase == .thinking, "舊TTS結束不能完成新輪")
        input.activity(true)
        check(interruptions == 1, "只有活動尚無文字時不取消思考")
        input.result("還有一件事")
        check(interruptions == 2 && call.phase == .listening && call.transcript == "還有一件事", "思考中也可自然插話")
        input.activity(false)
        clock.advance(0.8)
        call.replyReady()
        call.playbackStarted()
        call.toggleMicrophone()
        check(call.phase == .speaking && !input.isRecording && call.isMicrophoneMuted, "麥克風靜音不截斷已開始的回覆")
        call.playbackFinished()
        check(call.phase == .paused && !input.isRecording, "靜音播放完仍暫停")
        input.result("舊麥克風尾回調", final: true, input: 0)
        input.activity(true, input: 0)
        check(call.phase == .paused && call.transcript.isEmpty, "靜音的舊PCM與ASR回調都失效")
        call.toggleMicrophone()
        check(call.phase == .listening && input.isRecording && input.listens == 2, "解除靜音重開輸入")
        input.activity(true)
        input.result("等到一半")
        call.toggleMicrophone()
        clock.advance(30)
        check(call.phase == .paused && call.transcript.isEmpty, "靜音清掉半句與舊timer")
        call.toggleMicrophone()
        input.activity(true)
        input.result(String(repeating: "字", count: 1_200))
        check(call.transcript.count == 1_000, "轉錄上限有界")
        clock.advance(25)
        check(utterances.last?.count == 1_000 && call.phase == .thinking && input.isRecording, "長句上限只交句不停止收音")
        input.result("開頭已經進來")
        let resetsBefore = input.resets
        call.interruptAndListen()
        check(call.phase == .listening && call.transcript == "開頭已經進來" && input.resets == resetsBefore, "手動打斷同樣保留首字")
        call.end()
        let listensAtEnd = input.listens
        check(call.phase == .inactive && !input.isRecording && call.transcript.isEmpty, "結束釋放麥克風與暫存字幕")
        input.result("晚到ASR", final: true, input: 0)
        input.activity(true, input: 0)
        input.errorCallbacks[0]("voiceCallRecognitionFailed")
        call.playbackFinished()
        clock.advance(60)
        check(call.phase == .inactive && input.listens == listensAtEnd, "結束後的所有舊事件不能復活")

        let pendingInput = FakeVoiceInput()
        pendingInput.heldAuthorization = true
        let pending = VoiceCallController(input: pendingInput, scheduler: FakeVoiceClock())
        pending.start(); await settle(); pending.end()
        pendingInput.continuation?.resume(); pendingInput.continuation = nil
        await settle()
        check(pending.phase == .inactive && pendingInput.listens == 0, "授權晚到也不能開麥克風")
        for error in [LocalSpeechInput.Failure.microphoneDenied, .speechDenied, .onDeviceUnavailable, .languageUnsupported, .resourceDownloadFailed] {
            let deniedInput = FakeVoiceInput(); deniedInput.authorizationError = error
            let denied = VoiceCallController(input: deniedInput, scheduler: FakeVoiceClock())
            denied.start(); await settle()
            check(denied.phase == .failed && denied.errorKey == error.key && deniedInput.listens == 0, "權限或本機模型錯誤明確且不雲端替代")
        }
        let fallbackInput = FakeVoiceInput(); fallbackInput.automaticInterruptionAvailable = false
        let fallbackClock = FakeVoiceClock()
        let fallback = VoiceCallController(input: fallbackInput, scheduler: fallbackClock)
        var fallbackTurns = 0; var fallbackInterrupts = 0
        fallback.onUtterance = { _ in fallbackTurns += 1 }
        fallback.onInterrupt = { fallbackInterrupts += 1 }
        fallback.start(); await settle()
        check(!fallback.automaticInterruptionAvailable, "分類器不可用不宣稱自動打斷可用")
        fallbackInput.result("一個句子", final: true)
        check(fallbackTurns == 1 && fallback.phase == .thinking, "無分類器只接受ASR明確句尾")
        fallback.replyReady(); fallback.playbackStarted()
        fallbackInput.activity(true); fallbackInput.result("新問題", final: true)
        check(fallbackInterrupts == 0 && fallback.phase == .speaking, "降級路由不擅自自動打斷")
        fallback.interruptAndListen()
        check(fallbackTurns == 2 && fallback.phase == .thinking, "降級時手動接話仍送出原本已辨識完整的句子")
        fallbackClock.advance(1)
        fallback.replyFailed()
        check(fallback.phase == .failed && !fallbackInput.isRecording, "回覆失敗停止輸入")

        let lossInput = FakeVoiceInput(); let lossClock = FakeVoiceClock()
        let loss = VoiceCallController(input: lossInput, scheduler: lossClock)
        var lossTurns = 0
        loss.onUtterance = { _ in lossTurns += 1 }
        loss.start(); await settle()
        lossInput.activity(true); lossInput.result("辨識尚未完成")
        lossInput.automaticInterruptionAvailable = false
        lossInput.activity(false)
        lossClock.advance(30)
        check(lossTurns == 0 && !loss.automaticInterruptionAvailable, "分類器失效不會以假的quiet事件或idle交句")
        lossInput.result("這才是完整結果", final: true)
        check(lossTurns == 1, "分類器失效後僅ASR明確final能交句")
        loss.end()

        let limitInput = FakeVoiceInput(); let limitClock = FakeVoiceClock()
        let limit = VoiceCallController(input: limitInput, scheduler: limitClock)
        var limitTurns: [String] = []
        limit.onUtterance = { limitTurns.append($0) }
        limit.start(); await settle()
        limitInput.activity(true); limitInput.result("第一句")
        limitInput.activity(false); limitClock.advance(0.8)
        limit.replyReady()
        limitInput.activity(true)
        limitClock.advance(25)
        check(limit.phase == .thinking && limitTurns == ["第一句"], "思考中無轉錄的活動上限到期不交句")
        limit.playbackFinished()
        limitInput.activity(true); limitInput.result("下一句持續說話")
        let renewedLimit = limitClock.timers.last!
        limitClock.advance(25)
        check(limitTurns == ["第一句", "下一句持續說話"], "思考中到期的timer釋放後，下一長句仍有25秒上限")
        limit.interruptAndListen()
        limitInput.activity(true); limitInput.result("另一句持續說話")
        renewedLimit.action()
        limitClock.advance(25)
        check(limitTurns.last == "另一句持續說話" && limitTurns.count == 3, "舊輪timer晚到不會清掉新輪的上限timer")
        limit.end()

        check(VoiceCallLanguage.allCases.map(\.rawValue) == ["zh", "yue", "ja", "en", "ko"], "五語代碼與聲線設定一致")
        check(VoiceCallLanguage.allCases.map(\.localeIdentifier) == ["zh-TW", "zh-HK", "ja-JP", "en-US", "ko-KR"], "收音明確區分國語和香港粵語")
        check(Set(VoiceCallLanguage.allCases.map(\.localizationKey)).count == 5, "五語選項都有獨立翻譯鍵")
        check(VoiceCallLanguage.english.separatesWords && VoiceCallLanguage.korean.separatesWords && !VoiceCallLanguage.japanese.separatesWords, "轉錄片段依語言保留詞間空格")
        let multilingualInput = FakeVoiceInput()
        let multilingual = VoiceCallController(input: multilingualInput, scheduler: FakeVoiceClock())
        var languageInterruptions = 0
        multilingual.onInterrupt = { languageInterruptions += 1 }
        multilingual.selectLanguage(.japanese)
        check(multilingual.language == .japanese && multilingual.phase == .inactive && multilingualInput.configuredLanguages.isEmpty,
              "選擇語言本身不開麥克風或下載資源")
        multilingual.start(); await settle()
        check(multilingualInput.configuredLanguages == [.japanese] && multilingual.phase == .listening, "開始只準備使用者選定的語言")
        multilingualInput.activity(true); multilingualInput.result("こんにちは")
        multilingual.selectLanguage(.korean)
        check(multilingual.language == .korean && multilingual.phase == .preparing && multilingual.transcript.isEmpty && languageInterruptions == 1,
              "通話中切換語言立即取消舊回覆並清掉舊字幕")
        multilingualInput.result("舊日文請求", input: 0)
        multilingualInput.activity(true, input: 0)
        multilingualInput.errorCallbacks[0]("voiceCallRecognitionFailed")
        check(multilingual.phase == .preparing && multilingual.transcript.isEmpty, "語言切換後舊ASR、活動與錯誤事件失效")
        await settle()
        check(multilingualInput.configuredLanguages == [.japanese, .korean] && multilingualInput.listens == 2,
              "切換完成只建立新語言的輸入")
        multilingual.toggleMicrophone()
        multilingual.selectLanguage(.cantonese)
        await settle()
        check(multilingual.language == .cantonese && multilingual.phase == .paused && multilingual.isMicrophoneMuted && !multilingualInput.isRecording,
              "靜音時切換語言維持靜音")
        let currentPreparations = multilingualInput.preparationCallbacks.count
        multilingual.selectLanguage(.cantonese)
        check(multilingualInput.preparationCallbacks.count == currentPreparations, "重選同語言不重建辨識")
        multilingual.end()
        check(multilingualInput.preparationReleases >= 3, "結束與語言切換會釋放已準備的辨識器")

        let downloadingInput = FakeVoiceInput(); downloadingInput.heldAuthorization = true
        let downloading = VoiceCallController(input: downloadingInput, scheduler: FakeVoiceClock())
        downloading.start(); await settle()
        downloadingInput.preparationCallbacks[0](.downloading)
        check(downloading.preparation == .downloading && downloading.phase == .preparing && !downloadingInput.isRecording,
              "資源下載期間回報狀態且不收音")
        let cancelledPreparation = downloadingInput.preparationCallbacks[0]
        downloading.end()
        cancelledPreparation(.ready)
        check(downloading.preparation == nil && downloading.phase == .inactive, "取消下載後晚到的ready不能改狀態")
        downloadingInput.continuation?.resume(); downloadingInput.continuation = nil
        await settle()
        check(downloadingInput.listens == 0, "下載或權限晚完成仍不能啟用取消的通話")
        downloadingInput.heldAuthorization = false
        downloading.start()
        cancelledPreparation(.downloading)
        check(downloading.preparation == .checking, "舊準備事件不能蓋過新通話狀態")
        await settle(); downloading.end()
        let immediatelyCancelledInput = FakeVoiceInput()
        let immediatelyCancelled = VoiceCallController(input: immediatelyCancelledInput, scheduler: FakeVoiceClock())
        immediatelyCancelled.onChange = {
            if immediatelyCancelled.phase == .preparing { immediatelyCancelled.end() }
        }
        immediatelyCancelled.start(); await settle()
        check(immediatelyCancelledInput.authorizations == 0 && immediatelyCancelledInput.listens == 0,
              "開始回調立即取消時不會晚到要求麥克風權限")

        if #available(macOS 26.0, *) {
            let japanese = Locale(identifier: "ja-JP")
            let installed = [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")]
            check(LocalSpeechResources.canUse(status: .supported, locale: japanese, installedLocales: installed),
                  "已安裝日語在inventory僅回supported時仍可直接使用")
            check(LocalSpeechResources.canUse(status: .supported, locale: Locale(identifier: "en-US"), installedLocales: installed),
                  "已安裝英語支援底線與連字號識別碼")
            check(LocalSpeechResources.canUse(status: .installed, locale: japanese, installedLocales: []),
                  "明確installed狀態維持可用")
            check(!LocalSpeechResources.canUse(status: .unsupported, locale: japanese, installedLocales: installed),
                  "unsupported不能被installedLocales覆蓋")
            check(!LocalSpeechResources.canUse(status: .downloading, locale: japanese, installedLocales: installed),
                  "模組仍在下載時不能當成本機可用")
            check(!LocalSpeechResources.canUse(status: .supported, locale: Locale(identifier: "ko-KR"), installedLocales: installed),
                  "supported但未安裝的語言仍需要準備資源")
            check(!LocalSpeechResources.canUse(status: .supported, locale: Locale(identifier: "en-GB"), installedLocales: installed),
                  "不同地區的英語資源不冒充指定語言")
            check(!LocalSpeechResources.canUse(status: .supported, locale: Locale(identifier: "zh-TW"), installedLocales: [Locale(identifier: "zh_HK")]),
                  "粵語資源不能冒充台灣國語")
        }

        var words = VoiceCallTranscript(separatesWords: true)
        check(words.receive("Hello", start: 0, end: 1) == "Hello", "SpeechAnalyzer首段轉錄")
        check(words.receive("there", start: 1, end: 2) == "Hello there", "多個final片段連成一句")
        check(words.receive("world", start: 1, end: 2) == "Hello world", "volatile修訂替換同時間片段而非重複追加")
        words.reset(after: 2.5)
        check(words.receive("Hello world", start: 0, end: 2) == nil, "換輪後舊final不會重播")
        check(words.receive("old and new", start: 2, end: 3) == nil, "跨輪且沒有單字時間資訊的片段不混入舊文字")
        check(words.receive("Next", start: 2.5, end: 3) == "Next", "邊界後首字保留")
        words.reset(after: 1)
        check(words.boundary == 2.5 && words.receive("stale", start: 1, end: 2) == nil, "重設邊界不能倒退")
        check(words.receive("bad", start: .nan, end: 4) == nil && words.receive("bad", start: 4, end: 4) == nil, "非法音訊時間拒絕")
        var characters = VoiceCallTranscript(separatesWords: false)
        _ = characters.receive("今天天氣", start: 0, end: 1)
        check(characters.receive("很好", start: 1, end: 2) == "今天天氣很好", "中日粵分段不插入英文空格")
        characters.reset(after: 2)
        check(characters.receive(String(repeating: "字", count: 1_500), start: 2, end: 3)?.count == 1_000, "新ASR轉錄同樣有字數上限")

        var gate = VoiceCallSpeechActivity()
        check(!gate.observe(speech: 0.95, music: 0.9, singing: 0), "音樂的文字或音量不是人聲證據")
        check(!gate.observe(speech: 0.95, music: 0, singing: 0.9), "歌唱不觸發自動插話")
        check(gate.observe(speech: 0.95, music: 0.1, singing: 0), "可靠speech信心開啟活動")
        check(gate.observe(speech: 0.2, music: 0, singing: 0), "一個短暫低窗不切斷人聲")
        check(!gate.observe(speech: 0.1, music: 0, singing: 0), "兩個低窗確認聲音結束")
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000); request.overlapFactor = 0.5
        check(request.knownClassifications.contains("speech") && request.knownClassifications.contains("music") && request.knownClassifications.contains("singing"), "系統分類器有實際使用的標籤")
        check(request.windowDuration.seconds == 0.5 && request.overlapFactor == 0.5, "系統接受0.5秒窗及0.25秒步距")

        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        func pcm(_ value: Float, count: Int = 800) -> AVAudioPCMBuffer {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            b.frameLength = AVAudioFrameCount(count)
            for n in 0..<count { b.floatChannelData![0][n] = value }
            return b
        }
        let feed = VoiceCallPCMFeed(); let probe = FeedProbe()
        let first = pcm(0.25); feed.append(first); first.floatChannelData![0][0] = 0.9
        feed.replace(append: { probe.append($0) }, end: { probe.endings += 1 })
        check(probe.values == [0.25], "請求間隙的首buffer複製保留，不引用可重用的輸入記憶體")
        feed.append(pcm(0.5)); feed.detach(); feed.append(pcm(0.75))
        feed.replace(append: { probe.append($0) }, end: { probe.endings += 1 })
        check(probe.values == [0.25, 0.5, 0.75] && probe.endings == 1, "request輪替不丟首字、不重播已append的PCM")
        feed.detach()
        for _ in 0..<12 { feed.append(pcm(0.1)) }
        check(feed.queuedFrameCount <= 4_000, "記憶體預卷最多半秒")
        feed.close(); feed.append(pcm(1))
        feed.replace(append: { probe.append($0) }, end: { probe.endings += 1 })
        check(feed.queuedFrameCount == 0 && probe.values.count == 3, "關閉後不保留或提交任何PCM")

        for width in [16, 24, 32] {
            let decoded = try VoiceCallWAV.decode(wav(bits: width))
            check(decoded.frameLength == 4 && decoded.format.channelCount == 1, "合法\(width)bit WAV純記憶體解碼")
            check(abs(decoded.floatChannelData![0][0]) < 0.001, "PCM零值正確")
            check(decoded.floatChannelData![0][1] > 0.99 && decoded.floatChannelData![0][2] <= -0.99, "PCM正負符號正確")
            let converted = try VoiceCallWAV.convert(decoded, to: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
            check(converted.frameLength > 0 && converted.format.sampleRate == 48_000, "播放取樣率轉換不落盤")
        }
        for data in [Data(), Data("not a wav".utf8), wav(bits: 16).dropLast(1), wav(bits: 8)] {
            do { _ = try VoiceCallWAV.decode(Data(data)); check(false, "非法WAV應拒絕") }
            catch { check(true, "非法WAV拒絕") }
        }
        print("VoiceCall: \(checks) checks passed")
    }

    private static func wav(bits: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let width = bits / 8; let count = 4 * width
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count)); data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(8_000 * width)); append(UInt16(width)); append(UInt16(bits))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count))
        for value in [Int32(0), Int32.max, Int32.min, Int32(0)] {
            let shifted = value >> (32 - bits)
            for byte in 0..<width { data.append(UInt8(truncatingIfNeeded: shifted >> (byte * 8))) }
        }
        return data
    }
    @MainActor private static func settle() async { for _ in 0..<6 { await Task.yield() } }
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
