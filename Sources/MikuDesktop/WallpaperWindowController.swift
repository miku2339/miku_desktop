import AppKit
import CoreGraphics
import WebKit

final class DesktopPanel: NSPanel {
    var rendersBehindDesktopIcons = false

    // Finder's transparent icon window must not suspend wallpaper rendering.
    override var occlusionState: NSWindow.OcclusionState {
        let state = super.occlusionState
        return rendersBehindDesktopIcons && isVisible ? state.union(.visible) : state
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// WKUserContentController retains its handlers strongly; this proxy breaks the cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

final class WallpaperWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let pinnedAnchorKey = "pinnedAnchor"

    /// Called when the user drags Miku to a new spot (or the pin is cleared).
    var onPinnedAnchorChanged: (() -> Void)?

    private(set) var panel: NSPanel!
    private(set) var webView: WKWebView!
    private var backgroundPanel: NSPanel!
    private var backgroundWebView: WKWebView!
    private let characterURL: URL
    private let backgroundURL: URL

    private var characterRect: CGRect = .zero
    private var pointerTimer: Timer?
    private var interactiveMode: Bool
    private var selectedScene: String
    private var pageReady = false
    private var backgroundReady = false
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var memoryObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var eventsObserver: NSObjectProtocol?
    private var specialDayTimer: Timer?

    // Pixel-accurate mouse pass-through state.
    private var hitTestInFlight = false
    private var lastHitPoint: CGPoint?
    private var lastHitResult = false
    private var lastHitTime: TimeInterval = 0
    private var dragActive = false
    private var hoverZone: String?
    private var weather: WeatherSnapshot = .fallback

    init(url: URL) {
        interactiveMode = UserDefaults.standard.object(forKey: "interactiveMode") as? Bool ?? true
        selectedScene = UserDefaults.standard.string(forKey: "selectedScene") ?? "auto"
        characterURL = Self.layerURL(url, layer: "character")
        backgroundURL = Self.layerURL(url, layer: "background")
        super.init()

        let characterContentController = WKUserContentController()
        characterContentController.add(WeakScriptMessageHandler(self), name: "miku")
        let characterConfiguration = WKWebViewConfiguration()
        characterConfiguration.userContentController = characterContentController
        characterConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        characterConfiguration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: characterConfiguration)
        webView.navigationDelegate = self
        // WebKit's macOS transparency SPI removes the native backdrop behind transparent HTML.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear

        let backgroundConfiguration = WKWebViewConfiguration()
        backgroundConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        backgroundConfiguration.mediaTypesRequiringUserActionForPlayback = .all
        backgroundWebView = WKWebView(frame: .zero, configuration: backgroundConfiguration)
        backgroundWebView.navigationDelegate = self

        let screenFrame = Self.targetScreenFrame()
        backgroundPanel = makePanel(
            frame: screenFrame,
            contentView: backgroundWebView,
            level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1),
            transparent: false
        )
        backgroundPanel.title = "Miku Desktop Background"
        backgroundPanel.ignoresMouseEvents = true
        backgroundPanel.orderFrontRegardless()

        panel = makePanel(
            frame: screenFrame,
            contentView: webView,
            level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1),
            transparent: true
        )
        panel.title = "Miku Desktop Character"
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        backgroundWebView.load(URLRequest(url: backgroundURL, cachePolicy: .reloadIgnoringLocalCacheData))
        webView.load(URLRequest(url: characterURL, cachePolicy: .reloadIgnoringLocalCacheData))
        startPointerPolling()
        sleepObserver = NotificationCenter.default.addObserver(
            forName: .mikuSleepChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSleep() }
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: .mikuMemoryChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushRelationship() }
        }
        eventsObserver = NotificationCenter.default.addObserver(
            forName: .mikuEventsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSpecialDays() }
        }
        // Special days change at midnight; checking every quarter hour is plenty.
        let specialDayTimer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushSpecialDays() }
        }
        RunLoop.main.add(specialDayTimer, forMode: .common)
        self.specialDayTimer = specialDayTimer
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateScreenFrame()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateScreenFrame()
        }
    }

    deinit {
        specialDayTimer?.invalidate()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        pointerTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "miku")
    }

    // MARK: - Public API

    func setInteractive(_ enabled: Bool) {
        interactiveMode = enabled
        UserDefaults.standard.set(enabled, forKey: "interactiveMode")
        if !enabled { panel.ignoresMouseEvents = true }
        guard pageReady else { return }
        evaluate("window.mikuCompanion?.setInteractive(\(enabled ? "true" : "false"))")
    }

    func setScene(_ scene: String) {
        selectedScene = scene
        UserDefaults.standard.set(scene, forKey: "selectedScene")
        if backgroundReady { call(webView: backgroundWebView, function: "setScene", payload: scene) }
        if pageReady { call(webView: webView, function: "setScene", payload: scene) }
    }

    func setRotationInterval(_ seconds: Int) {
        if backgroundReady { call(webView: backgroundWebView, function: "setRotationInterval", payload: seconds) }
        if pageReady { call(webView: webView, function: "setRotationInterval", payload: seconds) }
    }

    func resetPinnedPosition() {
        UserDefaults.standard.removeObject(forKey: Self.pinnedAnchorKey)
        if pageReady { evaluate("window.mikuCompanion?.setPinnedAnchor(null)") }
        onPinnedAnchorChanged?()
    }

    /// Same weather and sun for both layers, so Miku is lit like the scene behind her.
    func setWeather(_ snapshot: WeatherSnapshot) {
        weather = snapshot
        for (view, ready) in [(backgroundWebView!, backgroundReady), (webView!, pageReady)] where ready {
            applyWeather(to: view)
        }
    }

    func setAmbientEnabled(_ enabled: Bool) {
        guard backgroundReady else { return }
        evaluate("window.mikuCompanion?.setAmbientEnabled?.(\(enabled ? "true" : "false"))", in: backgroundWebView)
    }

    private func applyWeather(to view: WKWebView) {
        call(webView: view, function: "setWeather", payload: weather.payload)
        if let sunrise = weather.sunrise, let sunset = weather.sunset {
            evaluate("window.mikuCompanion?.setSunTimes?.(\(sunrise), \(sunset))", in: view)
        }
    }

    func setThinking(_ thinking: Bool) {
        guard pageReady else { return }
        evaluate("window.mikuCompanion?.setThinking(\(thinking ? "true" : "false"))")
    }

    func callCompanionOver() {
        guard pageReady else { return }
        evaluate("window.mikuCompanion?.callOver?.()")
    }

    /// Friendship and whether she's upset, so her reactions match what she remembers.
    @MainActor
    func pushRelationship() {
        guard pageReady else { return }
        call(webView: webView, function: "setRelationship", payload: CompanionMemory.shared.relationshipPayload())
    }

    /// When she should be asleep, for both layers (the background switches to her room).
    @MainActor
    func pushSleep() {
        let payload = SleepSchedule.shared.payload
        if pageReady { call(webView: webView, function: "setSleep", payload: payload) }
        if backgroundReady { call(webView: backgroundWebView, function: "setSleep", payload: payload) }
    }

    private var music: String?

    /// Music playing on the Mac: now and then she listens along with a hand on her headphones.
    @MainActor
    func setMusic(_ title: String?) {
        music = title
        guard pageReady else { return }
        call(webView: webView, function: "setMusic", payload: ["playing": title != nil, "title": title ?? ""])
    }

    /// Rock-paper-scissors from the chat: she throws her hand on the desktop.
    @MainActor
    func playRPS(hand: String, outcome: String) {
        guard pageReady else { return }
        call(webView: webView, function: "playRPS", payload: ["hand": hand, "outcome": outcome])
    }

    /// A beat of the rhythm game: she bounces along.
    @MainActor
    func rhythmBeat() {
        guard pageReady else { return }
        evaluate("window.mikuCompanion?.rhythmBeat()", in: webView)
    }

    /// Festivals, her birthday, your anniversary…: greetings and dressing up on the day.
    @MainActor
    func pushSpecialDays() {
        guard pageReady else { return }
        let memory = CompanionMemory.shared
        let payload = EventCalendar.shared.payload(firstMet: memory.isEnabled ? memory.firstMet : nil)
        call(webView: webView, function: "setSpecialDays", payload: payload)
    }

    func receiveReply(_ reply: CompanionReply) {
        call(webView: webView, function: "receiveReply", payload: [
            "text": reply.text,
            "emotion": reply.emotion,
            "action": reply.action
        ])
    }

    /// Photographs only the two app-rendered wallpaper layers. This never reads the desktop
    /// or other applications and therefore does not need Screen Recording permission.
    @MainActor
    func captureMemoryPhoto() async throws -> CapturedScene {
        guard backgroundReady, pageReady,
              backgroundWebView.bounds.width > 1, backgroundWebView.bounds.height > 1,
              webView.bounds.size == backgroundWebView.bounds.size else {
            throw MemoryPhotoCaptureError.notReady
        }

        let status = try await MemoryPhotoCapture.companionStatus(in: webView)
        guard (status["ready"] as? Bool) == true,
              (status["mode"] as? String) == "webgl-mmd" else {
            throw MemoryPhotoCaptureError.notReady
        }
        guard let scene = status["scene"] as? String, !scene.isEmpty else {
            throw MemoryPhotoCaptureError.sceneUnavailable
        }
        return try await MemoryPhotoCapture.capture(
            background: backgroundWebView,
            character: webView,
            scene: scene
        )
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === backgroundWebView {
            backgroundReady = true
            configurePage(backgroundWebView, interactive: false)
        } else {
            pageReady = true
            configurePage(self.webView, interactive: interactiveMode)
        }
        // The page module loads asynchronously; give it a moment before sending the environment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak webView] in
            guard let self, let webView else { return }
            applyWeather(to: webView)
            if webView === backgroundWebView { setAmbientEnabled(WeatherService.ambientEnabled) }
            else { MainActor.assumeIsolated { self.pushRelationship(); self.pushSpecialDays(); self.setMusic(self.music) } }
            MainActor.assumeIsolated { self.pushSleep() }
        }
    }

    /// WebGL pages can be killed under memory pressure; reload instead of leaving a blank desktop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Miku web content process terminated; reloading %@", webView === backgroundWebView ? "background" : "character")
        if webView === backgroundWebView {
            backgroundReady = false
            backgroundWebView.load(URLRequest(url: backgroundURL, cachePolicy: .reloadIgnoringLocalCacheData))
        } else {
            pageReady = false
            dragActive = false
            characterRect = .zero
            panel.ignoresMouseEvents = true
            self.webView.load(URLRequest(url: characterURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    // MARK: - Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "miku", let payload = message.body as? [String: Any],
              let type = payload["type"] as? String else { return }

        switch type {
        case "bounds":
            guard let rect = payload["rect"] as? [String: Any],
                  let x = number(rect["x"]), let y = number(rect["y"]),
                  let width = number(rect["width"]), let height = number(rect["height"]) else { return }
            characterRect = CGRect(
                x: max(0, min(1, x)),
                y: max(0, min(1, y)),
                width: max(0, min(1, width)),
                height: max(0, min(1, height))
            )
        case "haptic":
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case "hover-haptic":
            // A lighter tap when the cursor first touches her (felt only with a finger on the trackpad).
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        case "drag":
            dragActive = (payload["active"] as? Bool) ?? false
            if dragActive { panel.ignoresMouseEvents = false }
        case "sleep":
            // She was woken up by a touch: stay up for a while (the other layer follows).
            guard (payload["asleep"] as? Bool) == false else { return }
            let minutes = max(1, min(120, number(payload["minutes"]) ?? 20))
            MainActor.assumeIsolated { SleepSchedule.shared.wake(minutes: minutes) }
        case "touch":
            guard let kind = payload["kind"] as? String, kind.count <= 24 else { return }
            let part = (payload["part"] as? String).flatMap { ["chest", "skirt"].contains($0) ? $0 : nil }
            MainActor.assumeIsolated { CompanionMemory.shared.recordTouch(kind, part: part) }
        case "diag":
            // Only plain values from the page; nothing it sends is executed.
            let entry = payload.filter { $0.value is String || $0.value is NSNumber || $0.value is NSNull }
            MainActor.assumeIsolated { CompanionMemory.shared.logDiagnostic(entry) }
        case "pin":
            if let x = number(payload["x"]), x.isFinite {
                UserDefaults.standard.set(max(0, min(1, x)), forKey: Self.pinnedAnchorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pinnedAnchorKey)
            }
            onPinnedAnchorChanged?()
        default:
            break
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    // MARK: - Mouse pass-through

    private func startPointerPolling() {
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateMousePassthrough()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    /// The bounding box only tells us the mouse is *near* Miku. The page then raycasts
    /// against the model so the transparent space around her stays clickable for the desktop.
    private func updateMousePassthrough() {
        guard interactiveMode, pageReady, characterRect.width > 0, characterRect.height > 0 else {
            panel.ignoresMouseEvents = true
            leaveHover()
            return
        }
        if dragActive {
            // Keep receiving events while Miku is being dragged, even if the cursor outruns her.
            panel.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse), frame.width > 0, frame.height > 0 else {
            panel.ignoresMouseEvents = true
            lastHitPoint = nil
            leaveHover()
            return
        }
        let point = CGPoint(
            x: (mouse.x - frame.minX) / frame.width,
            y: 1 - ((mouse.y - frame.minY) / frame.height)
        )
        guard characterRect.insetBy(dx: -0.01, dy: -0.01).contains(point) else {
            panel.ignoresMouseEvents = true
            lastHitPoint = nil
            leaveHover()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let moved = lastHitPoint.map { hypot($0.x - point.x, ($0.y - point.y)) > 0.0008 } ?? true
        guard !hitTestInFlight, moved || now - lastHitTime > 0.25 else { return }
        hitTestInFlight = true
        lastHitPoint = point
        lastHitTime = now
        let script = "window.mikuCompanion?.hitTest(\(point.x), \(point.y)) ?? false"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self else { return }
            hitTestInFlight = false
            // The page answers with the body zone it hit ("head", "hand", "body") or false.
            let zone = result as? String
            lastHitResult = zone != nil || (result as? Bool) == true
            panel.ignoresMouseEvents = !lastHitResult
            if lastHitResult {
                hoverZone = zone ?? "body"
                (hoverZone == "head" ? NSCursor.openHand : NSCursor.pointingHand).set()
            } else if hoverZone != nil {
                hoverZone = nil
                NSCursor.arrow.set()
            }
        }
    }

    /// The cursor moved off Miku without a final hit test (e.g. it left her bounding box).
    private func leaveHover() {
        guard hoverZone != nil else { return }
        hoverZone = nil
        NSCursor.arrow.set()
        if pageReady { evaluate("window.mikuCompanion?.endHover?.()") }
    }

    func setLanguage(_ language: String) {
        guard pageReady else { return }
        call(webView: webView, function: "setLanguage", payload: language)
    }

    // MARK: - Windows

    /// Always use the primary display (the one with the menu bar) so the wallpaper,
    /// character and floating controls stay together.
    private static func targetScreenFrame() -> CGRect {
        (NSScreen.screens.first ?? NSScreen.main)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func updateScreenFrame() {
        let frame = Self.targetScreenFrame()
        backgroundPanel.setFrame(frame, display: true)
        panel.setFrame(frame, display: true)
    }

    private func makePanel(frame: CGRect, contentView: NSView, level: NSWindow.Level, transparent: Bool) -> NSPanel {
        let result = DesktopPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        result.contentView = contentView
        result.rendersBehindDesktopIcons = !transparent
        result.backgroundColor = transparent ? .clear : .black
        result.isOpaque = !transparent
        result.hasShadow = false
        result.hidesOnDeactivate = false
        result.isReleasedWhenClosed = false
        result.acceptsMouseMovedEvents = transparent
        result.isMovable = false
        result.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        result.level = level
        result.setFrame(frame, display: false)
        return result
    }

    private static func layerURL(_ url: URL, layer: String) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "layer", value: layer))
        components.queryItems = items
        return components.url!
    }

    private func call(webView: WKWebView, function: String, payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.mikuCompanion?.\(function)(\(json))", in: webView)
    }

    private func configurePage(_ webView: WKWebView, interactive: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: selectedScene, options: .fragmentsAllowed),
              let sceneJSON = String(data: data, encoding: .utf8) else { return }
        let pinned = (UserDefaults.standard.object(forKey: Self.pinnedAnchorKey) as? Double).map { String($0) } ?? "null"
        let script = """
        (function waitForMiku(attempt) {
          const companion = window.mikuCompanion;
          if (companion) {
            companion.setInteractive(\(interactive ? "true" : "false"));
            companion.setRotationInterval?.(\(SceneRotation.seconds));
            companion.setPinnedAnchor?.(\(pinned));
            companion.setLanguage?.("\(AppLanguage.resolved.rawValue)");
            if (companion.setScene(\(sceneJSON)) !== false) return;
          }
          if (attempt < 100) setTimeout(() => waitForMiku(attempt + 1), 100);
        })(0)
        """
        evaluate(script, in: webView)
    }

    private func evaluate(_ script: String, in webView: WKWebView? = nil) {
        (webView ?? self.webView).evaluateJavaScript(script) { _, error in
            if let error { NSLog("Miku web bridge: %@", error.localizedDescription) }
        }
    }
}
