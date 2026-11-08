import AppKit
import CoreServices
import ScreenCaptureKit

/// Lets Miku notice what you're up to and, now and then, say something about it.
///
/// Every source is off until you turn it on in Settings, and everything stays on this Mac:
/// - activity: which app is in front, how long you've been at it, when you come back
/// - media: the song playing in Music or Spotify
/// - video: the YouTube / Niconico video in the browser's current tab (nothing else is read)
/// - screen: a glance at the screen every few minutes, shown only to the local model and
///   never stored
@MainActor
final class AwarenessService {
    static let shared = AwarenessService()

    typealias Source = AwarenessSource

    static let screenMinutesKey = "awareness.screenMinutes"
    /// 0 means "at random" (somewhere between 5 and 30 minutes each time).
    static let screenMinuteChoices = [0, 5, 10, 15, 30]

    nonisolated static func isEnabled(_ source: Source) -> Bool {
        UserDefaults.standard.bool(forKey: "awareness.\(source.rawValue)")
    }

    static func setEnabled(_ source: Source, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "awareness.\(source.rawValue)")
        if #available(macOS 14.0, *), enabled, source == .screen, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        shared.sourcesChanged(source, enabled: enabled)
    }

    nonisolated static var screenMinutes: Int {
        guard UserDefaults.standard.object(forKey: screenMinutesKey) != nil else { return 10 }
        let stored = UserDefaults.standard.integer(forKey: screenMinutesKey)
        return [0, 5, 10, 15, 30].contains(stored) ? stored : 10
    }

    static func screenChoiceTitle(_ minutes: Int) -> String {
        minutes == 0 ? L10n.text("randomInterval") : L10n.format("everyMinutes", String(minutes))
    }

    /// The wait before the next glance at the screen.
    nonisolated static func nextScreenGap() -> TimeInterval {
        let minutes = screenMinutes
        return minutes == 0 ? Double.random(in: 5...30) * 60 : Double(minutes) * 60
    }

    /// Between casual remarks: about 15–35 minutes, never the same twice.
    nonisolated static func nextCasualGap() -> TimeInterval {
        Double.random(in: 15...35) * 60
    }

    /// Between random little moments: 25–70 minutes.
    nonisolated static func nextRandomEventGap() -> TimeInterval {
        Double.random(in: 25...70) * 60
    }

    /// After the interval is changed in Settings.
    func screenIntervalChanged() {
        screenGap = Self.nextScreenGap()
    }

    /// Shows a line she decided to say (speech bubble and chat).
    var onSpeak: ((CompanionReply) -> Void)?
    /// True while you're typing to her in the chat window: no need to interrupt then.
    var isChatting: (() -> Bool)?
    /// The song playing now (nil when nothing is, or music awareness is off).
    var onMusicChanged: ((String?) -> Void)?
    private var reportedMusic: String?
    private var musicReported = false

    private func reportMusic(_ song: String?) {
        guard !musicReported || song != reportedMusic else { return }
        musicReported = true
        reportedMusic = song
        onMusicChanged?(song)
    }

    private struct Observation {
        enum Kind { case welcomeBack, breakTime, app, song, video, screen, randomEvent }
        let kind: Kind
        let detail: String
        let source: Source
        var throttleKey: String? = nil
        var image: Data? = nil

        /// Says what the user is doing on this Mac (an app, the screen, a song or video).
        var revealsActivity: Bool {
            switch kind {
            case .app, .song, .video, .screen: return true
            case .welcomeBack, .breakTime, .randomEvent: return false
            }
        }

        /// Things worth saying soon even if she spoke a little while ago.
        var urgent: Bool { kind == .welcomeBack || kind == .breakTime }
    }

    private let ai = LocalAI(configuration: AIConfiguration.shared)
    private let scriptQueue = DispatchQueue(label: "com.qimake.MikuDesktop.awareness")
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var memoryObservers: [NSObjectProtocol] = []
    private var sleepObserver: NSObjectProtocol?
    private var aiSettingsObserver: NSObjectProtocol?
    private var aiPrivacySettings: (cloud: Bool, shares: Bool)?
    private var started = false
    private var generation = 0
    private var collecting = false
    private var thinking = false
    private var collectionToken: AwarenessCancellationToken?
    private var chatWorkTokens: [UUID: AwarenessCancellationToken] = [:]
    private var responseTask: Task<Void, Never>?

    private var lastSpoke = Date()
    private var frontApp: (name: String, bundle: String, since: Date)?
    /// The supported browser you used last, so a chat message can still look at its tab.
    private var lastBrowserBundle: String?
    /// The last song and video the regular checks saw, in case a fresh read fails.
    private var recentSong: (title: String, at: Date)?
    private var recentVideo: (title: String, at: Date, browserBundle: String)?
    /// Her own recent lines (newest last), so she doesn't say the same thing again.
    private var recentLines: [String] = []
    /// Her lines in a row without a reply from you.
    private var unansweredLines = 0
    private var appComments: [String: Date] = [:]
    private var workStart: Date?
    private var awaySince: Date?
    private var lastBreakReminder = Date.distantPast
    private var lastTrack: String?
    private var lastVideo: String?
    private var lastScreenLook = Date()
    private var screenGap: TimeInterval = AwarenessService.nextScreenGap()
    private var casualGap: TimeInterval = AwarenessService.nextCasualGap()
    private var nextRandomEvent = Date().addingTimeInterval(AwarenessService.nextRandomEventGap())
    private var lastRandomEvent: String?

    nonisolated private static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser"
    ]
    /// Never glance at the screen while these are in front.
    private static let privateApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.systempreferences",
        "com.apple.SecurityAgent", "com.apple.loginwindow"
    ]

    /// Results from the AppleScript queue (written there, read after the group finishes).
    private final class Heard: @unchecked Sendable {
        var song: String?
        var video: String?
    }

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        for name in [Notification.Name.mikuMemoryErased, .mikuMemoryRestored] {
            memoryObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.recentLines.removeAll()
                    self?.unansweredLines = 0
                    self?.invalidatePendingWork()
                }
            })
        }
        sleepObserver = NotificationCenter.default.addObserver(
            forName: .mikuSleepChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidatePendingWork() }
        }
        aiPrivacySettings = (AIConfiguration.shared.usesCloud, AIConfiguration.shared.cloudSharesAwareness)
        aiSettingsObserver = NotificationCenter.default.addObserver(
            forName: .mikuSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.aiPrivacySettingsChanged() }
        }
        refreshMonitoring(resetFrontApp: true)
    }

    private func aiPrivacySettingsChanged() {
        let current = (cloud: AIConfiguration.shared.usesCloud, shares: AIConfiguration.shared.cloudSharesAwareness)
        guard aiPrivacySettings?.cloud != current.cloud || aiPrivacySettings?.shares != current.shares else { return }
        aiPrivacySettings = current
        recentLines.removeAll()
        invalidatePendingWork()
    }

    private func sourcesChanged(_ source: Source, enabled: Bool) {
        invalidatePendingWork()
        // Start counting afresh so switching a source on doesn't trigger a remark at once.
        lastScreenLook = Date()
        screenGap = Self.nextScreenGap()
        if source == .random { nextRandomEvent = Date().addingTimeInterval(Self.nextRandomEventGap()) }
        if source == .media, !enabled {
            recentSong = nil
            reportMusic(nil)
        }
        if source == .video, !enabled {
            recentVideo = nil
            lastBrowserBundle = nil
        }
        lastTrack = nil
        lastVideo = nil
        if source == .activity {
            workStart = nil
            awaySince = nil
        }
        refreshMonitoring(resetFrontApp: enabled && source != .media)
    }

    private func invalidatePendingWork() {
        generation += 1
        collectionToken?.cancel()
        collectionToken = nil
        chatWorkTokens.values.forEach { $0.cancel() }
        chatWorkTokens.removeAll()
        responseTask?.cancel()
        responseTask = nil
        collecting = false
        thinking = false
    }

    private func refreshMonitoring(resetFrontApp: Bool) {
        guard started else { return }
        let enabled = Set(Source.allCases.filter(Self.isEnabled))
        let needsFrontApp = AwarenessPolicy.needsFrontmostApplication(enabledSources: enabled)

        if needsFrontApp, activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = app?.localizedName ?? ""
                let bundle = app?.bundleIdentifier ?? ""
                MainActor.assumeIsolated { self?.appActivated(name: name, bundle: bundle) }
            }
        } else if !needsFrontApp, let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
            frontApp = nil
        }

        if needsFrontApp, (resetFrontApp || frontApp == nil),
           let app = NSWorkspace.shared.frontmostApplication {
            frontApp = nil
            appActivated(name: app.localizedName ?? "", bundle: app.bundleIdentifier ?? "")
        }

        if enabled.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func appActivated(name: String, bundle: String) {
        guard bundle != Bundle.main.bundleIdentifier, !name.isEmpty else { return }
        if frontApp?.bundle != bundle { frontApp = (name, bundle, Date()) }
        if Self.isEnabled(.video), Self.browsers.contains(bundle) { lastBrowserBundle = bundle }
    }

    private var frontmostApplicationIsPrivate: Bool {
        guard let bundle = frontApp?.bundle else { return false }
        return Self.privateApps.contains(bundle)
    }

    // MARK: - Noticing

    private func tick() {
        let enabled = Set(Source.allCases.filter(Self.isEnabled))
        // She's asleep: she doesn't notice anything until she's up again.
        if SleepSchedule.shared.isAsleep() {
            if collecting || thinking { invalidatePendingWork() }
            return
        }
        guard !enabled.isEmpty, !collecting, !thinking else { return }
        collecting = true
        let requestGeneration = generation
        let token = AwarenessCancellationToken()
        collectionToken = token
        let now = Date()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        var observations: [Observation] = []

        if enabled.contains(.activity) {
            observations += noticeActivity(idle: idle, now: now)
        }
        // Music, videos and the screen only matter while you're actually there.
        let present = idle < 120
        if enabled.contains(.random), present, now >= nextRandomEvent {
            let choices = AwarenessPolicy.randomEvents.filter { $0 != lastRandomEvent }
            if let event = choices.randomElement() {
                observations.append(Observation(kind: .randomEvent, detail: event, source: .random))
            }
        }
        let group = DispatchGroup()
        let heard = Heard()
        if enabled.contains(.media) {
            group.enter()
            scriptQueue.async {
                defer { group.leave() }
                guard !token.isCancelled, Self.isEnabled(.media) else { return }
                heard.song = Self.nowPlaying(token: token)
            }
        }
        let videoBrowser: String? = enabled.contains(.video) && present
            ? frontApp.flatMap { Self.browsers.contains($0.bundle) ? $0.bundle : nil }
            : nil
        if let videoBrowser {
            group.enter()
            scriptQueue.async {
                defer { group.leave() }
                guard !token.isCancelled, Self.isEnabled(.video) else { return }
                heard.video = Self.videoTitle(in: videoBrowser, token: token)
            }
        }
        let noticed = observations
        let screen = enabled.contains(.screen) && present
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard requestGeneration == self.generation else { return }
                self.collecting = false
                if self.collectionToken === token { self.collectionToken = nil }
                var found = noticed
                let song = heard.song
                let video = heard.video
                if Self.isEnabled(.media) {
                    self.recentSong = song.map { ($0, now) }
                    self.reportMusic(song)
                }
                if Self.isEnabled(.media), let song, song != self.lastTrack {
                    found.append(Observation(kind: .song, detail: song, source: .media))
                }
                if Self.isEnabled(.video), let videoBrowser, videoBrowser == self.lastBrowserBundle {
                    self.recentVideo = video.map { ($0, now, videoBrowser) }
                    if let video, video != self.lastVideo {
                        found.append(Observation(kind: .video, detail: video, source: .video))
                    }
                }
                self.finishTick(found, screen: screen, now: now, generation: requestGeneration)
            }
        }
    }

    private func finishTick(_ observations: [Observation], screen: Bool, now: Date, generation: Int) {
        guard !(isChatting?() ?? false) else { return }
        if let urgent = observations.first(where: \.urgent),
           AwarenessPolicy.canSpeak(lastSpoke: lastSpoke, now: now, urgent: true, casualGap: casualGap, unanswered: unansweredLines) {
            speak(about: urgent, generation: generation)
            return
        }
        guard AwarenessPolicy.canSpeak(lastSpoke: lastSpoke, now: now, urgent: false, casualGap: casualGap, unanswered: unansweredLines) else { return }
        // Prefer what's new (a song, a video) over the general "what are you doing".
        if let casual = observations.first(where: { $0.kind == .video })
            ?? observations.first(where: { $0.kind == .song })
            ?? observations.first(where: { $0.kind == .randomEvent })
            ?? observations.first(where: { $0.kind == .app }) {
            speak(about: casual, generation: generation)
            return
        }
        if screen, now.timeIntervalSince(lastScreenLook) >= screenGap {
            glanceAtScreen(generation: generation)
        }
    }

    private func noticeActivity(idle: TimeInterval, now: Date) -> [Observation] {
        var found: [Observation] = []
        if idle >= 10 * 60 {
            if awaySince == nil { awaySince = now.addingTimeInterval(-idle) }
            workStart = nil
            return found
        }
        if let away = awaySince, idle < 30 {
            awaySince = nil
            let minutes = Int(now.timeIntervalSince(away) / 60)
            found.append(Observation(kind: .welcomeBack, detail: "\(minutes)", source: .activity))
        }
        if workStart == nil { workStart = now }
        if let start = workStart, now.timeIntervalSince(start) >= 100 * 60, now.timeIntervalSince(lastBreakReminder) >= 100 * 60 {
            lastBreakReminder = now
            found.append(Observation(kind: .breakTime, detail: "\(Int(now.timeIntervalSince(start) / 60))", source: .activity))
        }
        if let app = frontApp, now.timeIntervalSince(app.since) >= 5 * 60,
           now.timeIntervalSince(appComments[app.bundle] ?? .distantPast) >= 3 * 3600,
           !Self.privateApps.contains(app.bundle),
           !Self.browsers.contains(app.bundle) {
            found.append(Observation(kind: .app, detail: app.name, source: .activity, throttleKey: app.bundle))
        }
        return found
    }

    private func glanceAtScreen(generation: Int) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(),
              AIConfiguration.shared.sharesAwarenessWithAI,
              canDeliver(source: .screen, generation: generation), !thinking,
              !frontmostApplicationIsPrivate else { return }
        lastScreenLook = Date()
        screenGap = Self.nextScreenGap()
        thinking = true
        responseTask = Task { [weak self] in
            defer { self?.finishResponse(generation: generation) }
            let image = await Self.captureScreen { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled
                    && AIConfiguration.shared.sharesAwarenessWithAI
                    && self.canDeliver(source: .screen, generation: generation)
                    && !self.frontmostApplicationIsPrivate
            }
            guard let self, !Task.isCancelled, let image,
                  AIConfiguration.shared.sharesAwarenessWithAI,
                  self.canDeliver(source: .screen, generation: generation),
                  !self.frontmostApplicationIsPrivate else { return }
            await self.generateAndDeliver(
                Observation(kind: .screen, detail: self.frontApp?.name ?? "", source: .screen, image: image),
                generation: generation
            )
        }
    }

    // MARK: - Speaking

    private func speak(about observation: Observation, generation: Int) {
        guard !thinking, canDeliver(source: observation.source, generation: generation) else { return }
        thinking = true
        responseTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishResponse(generation: generation) }
            await self.generateAndDeliver(observation, generation: generation)
        }
    }

    private func generateAndDeliver(_ observation: Observation, generation: Int) async {
        guard !Task.isCancelled, canDeliver(source: observation.source, generation: generation) else { return }
        // With a cloud AI, the screen, apps and media stay on this Mac unless the user shares
        // them: she still says welcome back or suggests a break, just without the details.
        let shares = AIConfiguration.shared.sharesAwarenessWithAI
        guard shares || !observation.revealsActivity else { return }
        let memory = CompanionMemory.shared
        var context = memory.context()
        context.confessionDecision = nil
        let history = Array(memory.recentHistory(from: memory.storedMessages).suffix(6))
        let app = frontmostApplicationIsPrivate || !shares ? nil : frontApp?.name
        let instruction = Self.instruction(for: observation, app: app)
            + (shares ? Self.avoidRepeating(recentLines) : "")
        let reply = try? await ai.reply(
            to: instruction,
            image: observation.image,
            history: history,
            memory: context,
            requiresAwarenessSharing: shares
        )
        guard !Task.isCancelled, canDeliver(source: observation.source, generation: generation),
              let reply, !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let onSpeak else { return }
        // Still the same thing as a line she said lately: better to say nothing this time.
        if AwarenessPolicy.isRepeat(reply.text, of: recentLines) {
            lastSpoke = Date()
            casualGap = Self.nextCasualGap()
            return
        }
        onSpeak(reply)
        let deliveredAt = Date()
        lastSpoke = deliveredAt
        casualGap = Self.nextCasualGap()
        unansweredLines += 1
        recentLines = Array((recentLines + [reply.text]).suffix(5))
        switch observation.kind {
        case .app:
            if let key = observation.throttleKey { appComments[key] = deliveredAt }
        case .song:
            lastTrack = observation.detail
        case .video:
            lastVideo = observation.detail
        case .randomEvent:
            lastRandomEvent = observation.detail
            nextRandomEvent = deliveredAt.addingTimeInterval(Self.nextRandomEventGap())
        case .screen, .welcomeBack, .breakTime:
            break
        }
    }

    private func canDeliver(source: Source, generation: Int) -> Bool {
        !SleepSchedule.shared.isAsleep() && AwarenessPolicy.canDeliver(
            requestGeneration: generation,
            currentGeneration: self.generation,
            sourceEnabled: Self.isEnabled(source),
            isChatting: isChatting?() ?? false
        )
    }

    private func finishResponse(generation: Int) {
        guard generation == self.generation else { return }
        thinking = false
        responseTask = nil
    }

    private static var language: String {
        let chosen = UserDefaults.standard.string(forKey: "replyLanguage") ?? "auto"
        if chosen == "yue" { return "zh-Hant" } // Cantonese: Chinese text, Cantonese prompt
        if ["zh-Hant", "en", "ja", "ko"].contains(chosen) { return chosen }
        return AppLanguage.resolved.rawValue
    }

    /// What she noticed, phrased for the model. It's marked as her own observation, not
    /// something the user said, and she's asked to speak like a friend sitting nearby.
    private static func instruction(for observation: Observation, app: String?) -> String {
        if observation.kind == .randomEvent {
            return randomEventInstruction(observation.detail)
        }
        let detail = String(observation.detail.prefix(160))
        switch language {
        case "en":
            let what: String
            switch observation.kind {
            case .welcomeBack: what = "The user just came back to the computer after about \(detail) minutes away."
            case .breakTime: what = "The user has been at the computer for about \(detail) minutes straight\(app.map { ", now in \($0)" } ?? "")."
            case .app: what = "The user has been using \(detail) for a while."
            case .song: what = "The user is listening to: \(detail)."
            case .video: what = "The user is watching this video: \(detail)."
            case .randomEvent: what = ""
            case .screen: what = "This picture is the user's screen right now\(app.map { " (\($0) in front)" } ?? "")."
            }
            return """
            (Not something the user said — this is what you noticed yourself: \(what))
            Say one short, natural line to the user about it (under 20 words), like a friend sitting nearby who happened to see: show interest, care, or chat about it. Don't describe the screen in detail, don't read out private information, and don't mention screenshots or monitoring. If there's nothing worth saying, leave text empty.
            """
        case "ja":
            let what: String
            switch observation.kind {
            case .welcomeBack: what = "相手が約\(detail)分ぶりにパソコンへ戻ってきた。"
            case .breakTime: what = "相手は約\(detail)分ずっとパソコンに向かっている\(app.map { "（今は\($0)）" } ?? "")。"
            case .app: what = "相手はしばらく\(detail)を使っている。"
            case .song: what = "相手が聴いている曲：\(detail)。"
            case .video: what = "相手が見ている動画：\(detail)。"
            case .randomEvent: what = ""
            case .screen: what = "この画像は相手の今の画面\(app.map { "（前面は\($0)）" } ?? "")。"
            }
            return """
            （相手の発言ではなく、あなた自身が気づいたこと：\(what)）
            それについて、そばにいる友だちがふと気づいたように、短く自然なひと言を相手にかけてください（三十文字以内）。興味を示す、気づかう、話題にするなど。画面を細かく説明したり、個人情報を読み上げたり、スクリーンショットや見張っていることには触れないこと。言うことがなければ text は空にしてください。
            """
        case "ko":
            let what: String
            switch observation.kind {
            case .welcomeBack: what = "사용자가 약 \(detail)분 만에 컴퓨터로 돌아왔어."
            case .breakTime: what = "사용자가 약 \(detail)분 동안 컴퓨터를 계속 사용하고 있어\(app.map { " (현재 \($0) 사용 중)" } ?? "")."
            case .app: what = "사용자가 \(detail)을 한동안 사용하고 있어."
            case .song: what = "사용자가 듣고 있는 곡: \(detail)."
            case .video: what = "사용자가 보고 있는 영상: \(detail)."
            case .randomEvent: what = ""
            case .screen: what = "이 이미지는 사용자의 현재 화면이야\(app.map { " (앞에 열린 앱: \($0))" } ?? "")."
            }
            return """
            (사용자가 한 말이 아니라 네가 직접 알아챈 일: \(what))
            옆에 있는 친구처럼 한국어로 짧고 자연스럽게 한마디 해 줘. 관심을 보이거나 가볍게 말을 걸어도 좋아. 화면을 자세히 설명하거나 개인정보를 읽지 말고, 스크린샷이나 감시를 언급하지 마. 할 말이 없으면 text를 비워 둬.
            """
        default:
            let what: String
            switch observation.kind {
            case .welcomeBack: what = "對方離開了大約 \(detail) 分鐘，剛剛回到電腦前。"
            case .breakTime: what = "對方已經連續用電腦大約 \(detail) 分鐘\(app.map { "（現在在用 \($0)）" } ?? "")。"
            case .app: what = "對方用 \(detail) 用了一段時間。"
            case .song: what = "對方正在聽：\(detail)。"
            case .video: what = "對方正在看這部影片：\(detail)。"
            case .randomEvent: what = ""
            case .screen: what = "這張圖是對方現在的畫面\(app.map { "（前景是 \($0)）" } ?? "")。"
            }
            return """
            （這不是對方說的話，是你自己留意到的：\(what)）
            就這件事，像坐在旁邊的朋友碰巧看到一樣，主動跟對方說一句簡短自然的話（二十五字以內），可以表示興趣、關心或聊聊。不要詳細描述畫面、不要念出個人資料，也不要提到截圖或監視。若沒什麼好說，text 留空。
            """
        }
    }

    /// A random little moment, phrased for the model as something happening to her.
    private static func randomEventInstruction(_ event: String) -> String {
        let moments: [String: (zh: String, en: String, ja: String)] = [
            "hum": ("你突然很想唱歌，正在小聲哼歌。可以說說你在哼的感覺，不要說出你不肯定的歌曲作者。",
                    "You suddenly feel like singing and start humming softly. Say something about it; don't name song credits you're unsure of.",
                    "急に歌いたくなって、小さく鼻歌を歌っている。そのことをひと言。自信のない曲の作者名は出さないこと。"),
            "question": ("你突然好奇，想多了解對方一點，問一個輕鬆的小問題（例如喜歡吃什麼、最近在忙什麼、今天過得怎樣），不要問私隱。",
                         "You suddenly get curious about the user and ask one light question (favourite food, what they've been up to, how their day is going) — nothing private.",
                         "ふと相手のことをもっと知りたくなって、気軽な質問をひとつする（好きな食べ物、最近がんばっていること、今日どうだったか など）。プライベートなことは聞かない。"),
            "game": ("你有點悶，想邀對方一起玩個小遊戲：包剪揼、Vocaloid 歌曲問答或者打拍子，揀一個問對方要不要玩。",
                     "You're a bit bored and want to play a little game with the user: rock-paper-scissors, a Vocaloid song quiz or a rhythm tapping game. Pick one and ask if they want to play.",
                     "ちょっと退屈で、相手と小さなゲームをしたくなった：じゃんけん、ボカロ曲クイズ、リズムタップのどれかを選んで、やらないか誘う。"),
            "snack": ("你突然肚子有點餓，很想吃東西（例如大蔥或甜點），跟對方說說。",
                      "You suddenly feel a little hungry and crave a snack (leeks, or something sweet). Tell the user.",
                      "急に小腹がすいて、何か食べたくなった（ネギや甘いものなど）。それを相手に言う。"),
            "idea": ("你剛剛想到一句新歌的歌詞靈感（自己即興想一句短句），想跟對方分享並問意見。",
                     "You just had an idea for a lyric (make up one short line yourself) and want to share it and ask what the user thinks.",
                     "新しい歌詞のアイデアを思いついた（自分で短い一節を考える）。相手に聞かせて感想をたずねる。"),
            "stretch": ("你坐久了想伸展一下，順便叫對方一起放鬆、飲口水。",
                        "You've been sitting a while and want to stretch; invite the user to relax and have some water too.",
                        "座りっぱなしで体を伸ばしたくなった。相手にも一緒にひと休みして水を飲もうと誘う。"),
            "remember": ("你突然想起之前和對方聊過的一件事（只用記憶或摘要裡真的有的事；沒有的話就問對方近況）。",
                         "You suddenly remember something you talked about with the user before (only something really in your memory or summary; if there's nothing, ask how they've been).",
                         "前に相手と話したことをふと思い出した（記憶や要約に本当にあることだけ。なければ最近どうかたずねる）。"),
            "daydream": ("你在發呆，想到一個有趣的小念頭（例如如果可以去旅行想去哪裡、雲像什麼），跟對方分享。",
                         "You were daydreaming and had a fun little thought (where you'd travel if you could, what a cloud looks like…). Share it.",
                         "ぼんやりしていて、ちょっと楽しいことを思いついた（旅行するならどこへ行きたいか、雲が何に見えるか など）。相手に話す。")
        ]
        let moment = moments[event] ?? moments["daydream"]!
        switch language {
        case "en":
            return """
            (Not something the user said — this just happened to you: \(moment.en))
            Say one short, natural line to the user (under 25 words), as yourself, and pick a matching action.
            """
        case "ja":
            return """
            （相手の発言ではなく、あなたに起きたこと：\(moment.ja)）
            自分から相手に、短く自然なひと言をかけてください（三十五文字以内）。合う動作も選ぶこと。
            """
        case "ko":
            return """
            (사용자가 한 말이 아니라 네게 방금 생긴 일: \(moment.en))
            한국어로 짧고 자연스럽게 먼저 한마디 하고, 어울리는 동작을 골라 줘. 기억에 없는 일을 지어내거나 확실하지 않은 곡 정보를 말하지 마.
            """
        default:
            return """
            （這不是對方說的話，是你自己發生的事：\(moment.zh)）
            主動跟對方說一句簡短自然的話（三十字以內），並選一個配合的動作。
            """
        }
    }

    /// You said something to her: she may speak up on her own again.
    func userSpoke() {
        unansweredLines = 0
    }

    /// Her last few lines, so the next one is about something else.
    private static func avoidRepeating(_ lines: [String]) -> String {
        let quoted = lines.suffix(3).map { "「\(String($0.prefix(40)))」" }.joined(separator: " ")
        guard !quoted.isEmpty else { return "" }
        switch language {
        case "en": return "\nYou recently said \(quoted). Say something different this time: don't repeat those lines or start the same way."
        case "ja": return "\n最近こう言いました：\(quoted)。今回は別のことを話し、同じ言い回しや出だしを繰り返さないでください。"
        case "ko": return "\n최근에 이렇게 말했어: \(quoted). 이번엔 다른 이야기를 하고, 같은 문장이나 시작을 반복하지 마."
        default: return "\n你最近主動說過：\(quoted)。這次換別的話題，不要重複這些句子或用同樣的開頭。"
        }
    }

    // MARK: - For a chat reply

    /// What you're listening to and watching, read right now for a chat reply: the song in
    /// Music or Spotify, and the YouTube or Niconico tab of the browser you used last. Nil when
    /// both "Music" and "Video" are off. Falls back to what the regular checks saw lately.
    func listeningForChat() async -> ListeningContext? {
        // With a cloud AI, what's playing stays on this Mac unless the user shares it.
        guard AIConfiguration.shared.sharesAwarenessWithAI else { return nil }
        let media = Self.isEnabled(.media)
        let video = Self.isEnabled(.video)
        guard media || video else { return nil }
        let browser = video ? lastBrowserBundle : nil
        let started = Date()
        let requestGeneration = generation
        let readID = UUID()
        let token = AwarenessCancellationToken()
        chatWorkTokens[readID] = token
        defer { chatWorkTokens.removeValue(forKey: readID) }
        let queue = scriptQueue
        // Keep any completed read even if the other app takes longer than the deadline.
        let read: PendingChatRead.Snapshot = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let pending = PendingChatRead()
                queue.async {
                    if media, !token.isCancelled {
                        let song = Self.nowPlaying(token: token, recordPermission: pending.recordPermission)
                        if !token.isCancelled { pending.recordSong(song) }
                    }
                    if let browser, !token.isCancelled {
                        let title = Self.videoTitle(in: browser, token: token, recordPermission: pending.recordPermission)
                        if !token.isCancelled { pending.recordVideo(title) }
                    }
                    if let snapshot = pending.take() { continuation.resume(returning: snapshot) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    token.cancel()
                    if let snapshot = pending.take() { continuation.resume(returning: snapshot) }
                }
            }
        } onCancel: {
            token.cancel()
        }
        guard !Task.isCancelled, requestGeneration == generation else { return nil }

        let now = Date()
        var result = ListeningContext()
        if media, Self.isEnabled(.media) {
            switch read.song {
            case .completed(let title):
                recentSong = title.map { ($0, now) }
                result.song = title
            case .unfinished:
                result.song = recentSong.flatMap { now.timeIntervalSince($0.at) < 180 ? $0.title : nil }
                result.songIsRecent = result.song != nil
            }
        }
        if Self.isEnabled(.video), let browser, browser == lastBrowserBundle, Self.isRunningBrowser(browser) {
            switch read.video {
            case .completed(let title):
                recentVideo = title.map { ($0, now, browser) }
                result.video = title
            case .unfinished:
                if let recentVideo, recentVideo.browserBundle == browser, now.timeIntervalSince(recentVideo.at) < 600 {
                    result.video = recentVideo.title
                    result.videoIsRecent = true
                }
            }
        }
        requestAutomationConsent(for: read.permissions, generation: requestGeneration)
        logListening(media: media, video: video, browser: browser, read: read, started: started)
        return result.isEmpty ? nil : result
    }

    /// Apps already asked to approve Automation this session (one prompt each, not one per message).
    private var consentRequested: Set<String> = []

    /// Ask after the chat read completes so the system prompt cannot occupy the read queue.
    private func requestAutomationConsent(for permissions: [String: Int], generation: Int) {
        guard generation == self.generation else { return }
        for (bundle, status) in permissions where status == Int(errAEEventWouldRequireUserConsent) {
            let source: Source = Self.browsers.contains(bundle) ? .video : .media
            guard Self.isEnabled(source), source != .video || bundle == lastBrowserBundle,
                  Self.isRunningTarget(bundle), consentRequested.insert(bundle).inserted else { continue }

            let requestID = UUID()
            let token = AwarenessCancellationToken()
            chatWorkTokens[requestID] = token
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let shouldAsk = !token.isCancelled && Self.isEnabled(source) && Self.isRunningTarget(bundle)
                if shouldAsk { _ = Self.automationPermission(for: bundle, ask: true) }
                Task { @MainActor [weak self] in
                    self?.chatWorkTokens.removeValue(forKey: requestID)
                    if !shouldAsk { self?.consentRequested.remove(bundle) }
                }
            }
        }
    }

    /// Sending Apple Events to `bundle`: noErr, -1743 (not allowed), -1744 (needs your OK) or
    /// -600 (not running).
    nonisolated static func automationPermission(for bundle: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, strlen($0), &target) }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    /// One line in diagnostics.log per chat read: what was tried and how it went, never titles.
    private func logListening(
        media: Bool,
        video: Bool,
        browser: String?,
        read: PendingChatRead.Snapshot,
        started: Date
    ) {
        func outcome(_ title: PendingChatRead.Snapshot.Title, on: Bool) -> String {
            guard on else { return "off" }
            switch title {
            case .unfinished: return "timeout"
            case .completed(let value): return value == nil ? "none" : "found"
            }
        }
        var payload: [String: Any] = [
            "type": "listening",
            "song": outcome(read.song, on: media),
            "video": video ? (browser == nil ? "noBrowser" : outcome(read.video, on: true)) : "off",
            "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)
        ]
        if let browser { payload["browser"] = browser }
        if !read.permissions.isEmpty { payload["permissions"] = read.permissions }
        CompanionMemory.shared.logDiagnostic(payload)
    }

    // MARK: - Sources

    /// "Title — Artist" from Music or Spotify, if one of them is open and playing.
    nonisolated private static func nowPlaying(
        token: AwarenessCancellationToken,
        recordPermission: (String, OSStatus) -> Void = { _, _ in }
    ) -> String? {
        for bundle in ["com.apple.Music", "com.spotify.client"] {
            guard !token.isCancelled, isEnabled(.media) else { return nil }
            guard isRunningTarget(bundle) else { continue }
            let status = automationPermission(for: bundle, ask: false)
            recordPermission(bundle, status)
            guard status == noErr, isEnabled(.media), isRunningTarget(bundle) else { continue }
            let script = """
            tell application id "\(bundle)"
              if player state is playing then return (name of current track) & " — " & (artist of current track)
            end tell
            return ""
            """
            if let result = run(script, token: token), !result.isEmpty { return result }
        }
        return nil
    }

    nonisolated private static func isRunningBrowser(_ bundle: String) -> Bool {
        browsers.contains(bundle) && isRunningTarget(bundle)
    }

    nonisolated private static func isRunningTarget(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// The video title, but only when the running browser's current tab is YouTube or Niconico.
    nonisolated private static func videoTitle(
        in browser: String,
        token: AwarenessCancellationToken,
        recordPermission: (String, OSStatus) -> Void = { _, _ in }
    ) -> String? {
        guard !token.isCancelled, isEnabled(.video), isRunningBrowser(browser) else { return nil }
        let status = automationPermission(for: browser, ask: false)
        recordPermission(browser, status)
        guard status == noErr else { return nil }
        let safari = browser == "com.apple.Safari"
        let tab = safari ? "current tab of front window" : "active tab of front window"
        let urlScript = """
        tell application id "\(browser)"
          if (count of windows) is 0 then return ""
          set targetTab to \(tab)
          return URL of targetTab
        end tell
        """
        guard !token.isCancelled, isEnabled(.video), isRunningBrowser(browser),
              let firstURL = run(urlScript, token: token), let url = URL(string: firstURL),
              let site = AwarenessPolicy.videoSite(for: url),
              let firstURLLiteral = AwarenessPolicy.appleScriptStringLiteral(firstURL) else { return nil }

        let titleProperty = safari ? "name" : "title"
        let titleScript = """
        tell application id "\(browser)"
          if (count of windows) is 0 then return ""
          set targetTab to \(tab)
          if (URL of targetTab) is not \(firstURLLiteral) then return ""
          return (URL of targetTab) & "\\n" & (\(titleProperty) of targetTab)
        end tell
        """
        guard !token.isCancelled, isEnabled(.video), isRunningBrowser(browser),
              let result = run(titleScript, token: token) else { return nil }
        let parts = result.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == firstURL else { return nil }
        var title = parts[1]
        for suffix in [" - YouTube", " - ニコニコ動画", " - ニコニコ"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        guard !title.isEmpty else { return nil }
        return "\(title)（\(site == .youtube ? "YouTube" : "ニコニコ動画")）"
    }

    nonisolated private static func run(_ source: String, token: AwarenessCancellationToken) -> String? {
        guard !token.isCancelled else { return nil }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The main display without Miku's own windows, as a JPEG for the local model.
    @available(macOS 14.0, *)
    private static func captureScreen(gate: @escaping @MainActor () -> Bool) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled, gate() else { return nil }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return nil
            }
            let excluded = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier || privateApps.contains($0.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = min(1, ChatImage.maxSide / CGFloat(max(display.width, display.height)))
            configuration.width = Int(CGFloat(display.width) * scale)
            configuration.height = Int(CGFloat(display.height) * scale)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return ChatImage.jpeg(from: NSImage(cgImage: image, size: .zero))
        } catch {
            return nil
        }
    }
}

/// Collects completed reads until the script queue finishes or the deadline wins.
private final class PendingChatRead: @unchecked Sendable {
    struct Snapshot: Sendable {
        enum Title: Sendable {
            case unfinished
            case completed(String?)
        }

        var song = Title.unfinished
        var video = Title.unfinished
        var permissions: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var snapshot: Snapshot? = Snapshot()

    func recordSong(_ title: String?) {
        lock.lock()
        defer { lock.unlock() }
        snapshot?.song = .completed(title)
    }

    func recordVideo(_ title: String?) {
        lock.lock()
        defer { lock.unlock() }
        snapshot?.video = .completed(title)
    }

    func recordPermission(_ bundle: String, _ status: OSStatus) {
        lock.lock()
        defer { lock.unlock() }
        snapshot?.permissions[bundle] = Int(status)
    }

    func take() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        defer { snapshot = nil }
        return snapshot
    }
}
