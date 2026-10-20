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

final class WallpaperWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var panel: NSPanel!
    private(set) var webView: WKWebView!
    private var backgroundPanel: NSPanel!
    private var backgroundWebView: WKWebView!

    private var characterRect: CGRect = .zero
    private var pointerTimer: Timer?
    private var interactiveMode: Bool
    private var selectedScene: String
    private var pageReady = false
    private var backgroundReady = false
    private var screenObserver: NSObjectProtocol?

    init(url: URL) {
        interactiveMode = UserDefaults.standard.object(forKey: "interactiveMode") as? Bool ?? true
        selectedScene = UserDefaults.standard.string(forKey: "selectedScene") ?? "auto"
        super.init()

        let characterContentController = WKUserContentController()
        characterContentController.add(self, name: "miku")
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

        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
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

        backgroundWebView.load(URLRequest(url: layerURL(url, layer: "background"), cachePolicy: .reloadIgnoringLocalCacheData))
        webView.load(URLRequest(url: layerURL(url, layer: "character"), cachePolicy: .reloadIgnoringLocalCacheData))
        startPointerPolling()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateScreenFrame()
        }
    }

    deinit {
        pointerTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "miku")
    }

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

    func interact(type: String, x: Double? = nil, y: Double? = nil) {
        var payload: [String: Any] = ["type": type]
        if let x { payload["x"] = x }
        if let y { payload["y"] = y }
        call(webView: webView, function: "interact", payload: payload)
    }

    func receiveReply(_ reply: CompanionReply) {
        call(webView: webView, function: "receiveReply", payload: [
            "text": reply.text,
            "emotion": reply.emotion,
            "action": reply.action
        ])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === backgroundWebView {
            backgroundReady = true
            configurePage(backgroundWebView, interactive: false)
        } else {
            pageReady = true
            configurePage(self.webView, interactive: interactiveMode)
        }
    }

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
        default:
            break
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }

    private func startPointerPolling() {
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            self?.updateMousePassthrough()
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }

    private func updateMousePassthrough() {
        guard interactiveMode, characterRect.width > 0, characterRect.height > 0 else {
            panel.ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse), frame.width > 0, frame.height > 0 else {
            panel.ignoresMouseEvents = true
            return
        }
        let point = CGPoint(
            x: (mouse.x - frame.minX) / frame.width,
            y: 1 - ((mouse.y - frame.minY) / frame.height)
        )
        panel.ignoresMouseEvents = !characterRect.contains(point)
    }

    private func updateScreenFrame() {
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let frame = (mouseScreen ?? NSScreen.main)?.frame ?? panel.frame
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

    private func layerURL(_ url: URL, layer: String) -> URL {
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
        let script = """
        (function waitForMiku(attempt) {
          const companion = window.mikuCompanion;
          if (companion) {
            companion.setInteractive(\(interactive ? "true" : "false"));
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
