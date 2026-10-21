import AppKit
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
    static let screenMinuteChoices = [5, 10, 15, 30]

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

    static var screenMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: screenMinutesKey)
        return screenMinuteChoices.contains(stored) ? stored : 10
    }

    /// Shows a line she decided to say (speech bubble and chat).
    var onSpeak: ((CompanionReply) -> Void)?
    /// True while you're typing to her in the chat window: no need to interrupt then.
    var isChatting: (() -> Bool)?

    private struct Observation {
        enum Kind { case welcomeBack, breakTime, app, song, video, screen }
        let kind: Kind
        let detail: String
        let source: Source
        var throttleKey: String? = nil
        var image: Data? = nil

        /// Things worth saying soon even if she spoke a little while ago.
        var urgent: Bool { kind == .welcomeBack || kind == .breakTime }
    }

    private let ai = LocalAI(configuration: AIConfiguration.shared)
    private let scriptQueue = DispatchQueue(label: "com.qimake.MikuDesktop.awareness")
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var memoryObservers: [NSObjectProtocol] = []
    private var started = false
    private var generation = 0
    private var collecting = false
    private var thinking = false
    private var collectionToken: AwarenessCancellationToken?
    private var responseTask: Task<Void, Never>?

    private var lastSpoke = Date()
    private var frontApp: (name: String, bundle: String, since: Date)?
    private var appComments: [String: Date] = [:]
    private var workStart: Date?
    private var awaySince: Date?
    private var lastBreakReminder = Date.distantPast
    private var lastTrack: String?
    private var lastVideo: String?
    private var lastScreenLook = Date()

    private static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "company.thebrowser.Browser": "Arc"
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
                MainActor.assumeIsolated { self?.invalidatePendingWork() }
            })
        }
        refreshMonitoring(resetFrontApp: true)
    }

    private func sourcesChanged(_ source: Source, enabled: Bool) {
        invalidatePendingWork()
        // Start counting afresh so switching a source on doesn't trigger a remark at once.
        lastScreenLook = Date()
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
    }

    private var frontmostApplicationIsPrivate: Bool {
        guard let bundle = frontApp?.bundle else { return false }
        return Self.privateApps.contains(bundle)
    }

    // MARK: - Noticing

    private func tick() {
        let enabled = Set(Source.allCases.filter(Self.isEnabled))
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
        if enabled.contains(.video), present, let app = frontApp, let browser = Self.browsers[app.bundle] {
            group.enter()
            scriptQueue.async {
                defer { group.leave() }
                guard !token.isCancelled, Self.isEnabled(.video) else { return }
                heard.video = Self.videoTitle(in: browser, token: token)
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
                if Self.isEnabled(.media), let song, song != self.lastTrack {
                    found.append(Observation(kind: .song, detail: song, source: .media))
                }
                if Self.isEnabled(.video), let video, video != self.lastVideo {
                    found.append(Observation(kind: .video, detail: video, source: .video))
                }
                self.finishTick(found, screen: screen, now: now, generation: requestGeneration)
            }
        }
    }

    private func finishTick(_ observations: [Observation], screen: Bool, now: Date, generation: Int) {
        guard !(isChatting?() ?? false) else { return }
        if let urgent = observations.first(where: \.urgent),
           AwarenessPolicy.canSpeak(lastSpoke: lastSpoke, now: now, urgent: true) {
            speak(about: urgent, generation: generation)
            return
        }
        guard AwarenessPolicy.canSpeak(lastSpoke: lastSpoke, now: now, urgent: false) else { return }
        // Prefer what's new (a song, a video) over the general "what are you doing".
        if let casual = observations.first(where: { $0.kind == .video })
            ?? observations.first(where: { $0.kind == .song })
            ?? observations.first(where: { $0.kind == .app }) {
            speak(about: casual, generation: generation)
            return
        }
        if screen, now.timeIntervalSince(lastScreenLook) >= Double(Self.screenMinutes * 60) {
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
           Self.browsers[app.bundle] == nil {
            found.append(Observation(kind: .app, detail: app.name, source: .activity, throttleKey: app.bundle))
        }
        return found
    }

    private func glanceAtScreen(generation: Int) {
        guard #available(macOS 14.0, *), CGPreflightScreenCaptureAccess(),
              canDeliver(source: .screen, generation: generation), !thinking,
              !frontmostApplicationIsPrivate else { return }
        lastScreenLook = Date()
        thinking = true
        responseTask = Task { [weak self] in
            defer { self?.finishResponse(generation: generation) }
            let image = await Self.captureScreen { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled
                    && self.canDeliver(source: .screen, generation: generation)
                    && !self.frontmostApplicationIsPrivate
            }
            guard let self, !Task.isCancelled, let image,
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
        let memory = CompanionMemory.shared
        var context = memory.context()
        context.confessionDecision = nil
        let history = Array(memory.recentHistory(from: memory.storedMessages).suffix(6))
        let app = frontmostApplicationIsPrivate ? nil : frontApp?.name
        let instruction = Self.instruction(for: observation, app: app)
        let reply = try? await ai.reply(to: instruction, image: observation.image, history: history, memory: context)
        guard !Task.isCancelled, canDeliver(source: observation.source, generation: generation),
              let reply, !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let onSpeak else { return }
        onSpeak(reply)
        let deliveredAt = Date()
        lastSpoke = deliveredAt
        switch observation.kind {
        case .app:
            if let key = observation.throttleKey { appComments[key] = deliveredAt }
        case .song:
            lastTrack = observation.detail
        case .video:
            lastVideo = observation.detail
        case .screen, .welcomeBack, .breakTime:
            break
        }
    }

    private func canDeliver(source: Source, generation: Int) -> Bool {
        AwarenessPolicy.canDeliver(
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
        if ["zh-Hant", "en", "ja"].contains(chosen) { return chosen }
        return AppLanguage.resolved.rawValue
    }

    /// What she noticed, phrased for the model. It's marked as her own observation, not
    /// something the user said, and she's asked to speak like a friend sitting nearby.
    private static func instruction(for observation: Observation, app: String?) -> String {
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
            case .screen: what = "この画像は相手の今の画面\(app.map { "（前面は\($0)）" } ?? "")。"
            }
            return """
            （相手の発言ではなく、あなた自身が気づいたこと：\(what)）
            それについて、そばにいる友だちがふと気づいたように、短く自然なひと言を相手にかけてください（三十文字以内）。興味を示す、気づかう、話題にするなど。画面を細かく説明したり、個人情報を読み上げたり、スクリーンショットや見張っていることには触れないこと。言うことがなければ text は空にしてください。
            """
        default:
            let what: String
            switch observation.kind {
            case .welcomeBack: what = "對方離開了大約 \(detail) 分鐘，剛剛回到電腦前。"
            case .breakTime: what = "對方已經連續用電腦大約 \(detail) 分鐘\(app.map { "（現在在用 \($0)）" } ?? "")。"
            case .app: what = "對方用 \(detail) 用了一段時間。"
            case .song: what = "對方正在聽：\(detail)。"
            case .video: what = "對方正在看這部影片：\(detail)。"
            case .screen: what = "這張圖是對方現在的畫面\(app.map { "（前景是 \($0)）" } ?? "")。"
            }
            return """
            （這不是對方說的話，是你自己留意到的：\(what)）
            就這件事，像坐在旁邊的朋友碰巧看到一樣，主動跟對方說一句簡短自然的話（二十五字以內），可以表示興趣、關心或聊聊。不要詳細描述畫面、不要念出個人資料，也不要提到截圖或監視。若沒什麼好說，text 留空。
            """
        }
    }

    // MARK: - Sources

    /// "Title — Artist" from Music or Spotify, if one of them is open and playing.
    nonisolated private static func nowPlaying(token: AwarenessCancellationToken) -> String? {
        let players: [(bundle: String, name: String)] = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]
        for player in players {
            guard !token.isCancelled, isEnabled(.media) else { return nil }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundle).isEmpty else { continue }
            let script = """
            tell application "\(player.name)"
              if player state is playing then return (name of current track) & " — " & (artist of current track)
            end tell
            return ""
            """
            if let result = run(script, token: token), !result.isEmpty { return result }
        }
        return nil
    }

    /// The video title, but only when the browser's current tab is YouTube or Niconico.
    nonisolated private static func videoTitle(in browser: String, token: AwarenessCancellationToken) -> String? {
        let tab = browser == "Safari" ? "current tab of front window" : "active tab of front window"
        let urlScript = """
        tell application "\(browser)"
          if (count of windows) is 0 then return ""
          set targetTab to \(tab)
          return URL of targetTab
        end tell
        """
        guard !token.isCancelled, isEnabled(.video),
              let firstURL = run(urlScript, token: token), let url = URL(string: firstURL),
              let site = AwarenessPolicy.videoSite(for: url),
              let firstURLLiteral = AwarenessPolicy.appleScriptStringLiteral(firstURL) else { return nil }

        let titleProperty = browser == "Safari" ? "name" : "title"
        let titleScript = """
        tell application "\(browser)"
          if (count of windows) is 0 then return ""
          set targetTab to \(tab)
          if (URL of targetTab) is not \(firstURLLiteral) then return ""
          return (URL of targetTab) & "\\n" & (\(titleProperty) of targetTab)
        end tell
        """
        guard !token.isCancelled, isEnabled(.video),
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
