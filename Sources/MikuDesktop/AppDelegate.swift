import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var server: StaticHTTPServer?
    private var wallpaperController: WallpaperWindowController?
    private var desktopControlsController: DesktopControlsWindowController?
    private var chatController: ChatWindowController?
    private var settingsController: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "♪"
        statusItem.button?.toolTip = "Miku Desktop"
        rebuildMenu()

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .mikuSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.chatController?.refreshLocalization()
                self?.settingsController?.refreshLocalization()
                self?.desktopControlsController?.refreshLocalization()
                self?.settingsController?.refreshInteraction()
                self?.wallpaperController?.setLanguage(AppLanguage.resolved.rawValue)
            }
        }

        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Wallpaper", isDirectory: true) else {
            presentStartupError()
            return
        }
        let server = StaticHTTPServer(rootURL: resourceURL)
        self.server = server
        server.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let url):
                    let controller = WallpaperWindowController(url: url)
                    controller.onPinnedAnchorChanged = { [weak self] in
                        Task { @MainActor in
                            self?.settingsController?.refreshPosition()
                            self?.rebuildMenu()
                        }
                    }
                    self.wallpaperController = controller
                    let controls = DesktopControlsWindowController()
                    controls.onOpenChat = { [weak self] in self?.openChat(nil) }
                    controls.onOpenSettings = { [weak self] in self?.openSettings(nil) }
                    self.desktopControlsController = controls
                case .failure:
                    self.presentStartupError()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openChat(nil)
        return true
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let chat = NSMenuItem(title: L10n.text("chat"), action: #selector(openChat(_:)), keyEquivalent: "")
        chat.target = self
        menu.addItem(chat)

        let interaction = NSMenuItem(title: L10n.text("interaction"), action: #selector(toggleInteraction(_:)), keyEquivalent: "")
        interaction.target = self
        interaction.state = (UserDefaults.standard.object(forKey: "interactiveMode") as? Bool ?? true) ? .on : .off
        menu.addItem(interaction)

        let sceneMenu = NSMenu()
        let sceneChoices: [(String, String)] = [
            (L10n.text("autoScene"), "auto"),
            (L10n.text("shibuya"), "shibuya"),
            (L10n.text("ikebukuro"), "ikebukuro"),
            (L10n.text("akihabara"), "akihabara"),
            (L10n.text("shinjuku"), "shinjuku"),
            (L10n.text("hallway"), "hallway"),
            (L10n.text("musicroom"), "musicroom")
        ]
        let selectedScene = UserDefaults.standard.string(forKey: "selectedScene") ?? "auto"
        for (title, value) in sceneChoices {
            let item = NSMenuItem(title: title, action: #selector(selectScene(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = selectedScene == value ? .on : .off
            sceneMenu.addItem(item)
        }
        let scene = NSMenuItem(title: L10n.text("scene"), action: nil, keyEquivalent: "")
        scene.submenu = sceneMenu
        menu.addItem(scene)

        if UserDefaults.standard.object(forKey: WallpaperWindowController.pinnedAnchorKey) != nil {
            let roam = NSMenuItem(title: L10n.text("resetPositionMenu"), action: #selector(resetPosition(_:)), keyEquivalent: "")
            roam.target = self
            menu.addItem(roam)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: L10n.text("settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.text("quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Miku Desktop")
        let mainChat = NSMenuItem(title: L10n.text("chat"), action: #selector(openChat(_:)), keyEquivalent: "")
        mainChat.target = self
        appMenu.addItem(mainChat)
        let mainSettings = NSMenuItem(title: L10n.text("settings"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        mainSettings.target = self
        appMenu.addItem(mainSettings)
        appMenu.addItem(.separator())
        let mainQuit = NSMenuItem(title: L10n.text("quit"), action: #selector(quit(_:)), keyEquivalent: "q")
        mainQuit.target = self
        appMenu.addItem(mainQuit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("edit"))
        editMenu.addItem(responderItem("undo", action: "undo:", key: "z"))
        let redo = responderItem("redo", action: "redo:", key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem("cut", action: "cut:", key: "x"))
        editMenu.addItem(responderItem("copy", action: "copy:", key: "c"))
        editMenu.addItem(responderItem("paste", action: "paste:", key: "v"))
        editMenu.addItem(responderItem("selectAll", action: "selectAll:", key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func responderItem(_ titleKey: String, action: String, key: String) -> NSMenuItem {
        NSMenuItem(title: L10n.text(titleKey), action: Selector((action)), keyEquivalent: key)
    }

    @objc private func openChat(_ sender: Any?) {
        if chatController == nil {
            let controller = ChatWindowController()
            controller.onReply = { [weak self] reply in
                self?.wallpaperController?.receiveReply(reply)
            }
            controller.onThinking = { [weak self] thinking in
                self?.wallpaperController?.setThinking(thinking)
            }
            controller.onOpenSettings = { [weak self] in
                self?.openSettings(nil)
            }
            chatController = controller
        }
        chatController?.present()
    }

    @objc private func toggleInteraction(_ sender: NSMenuItem) {
        applyInteractive(sender.state != .on)
    }

    private func applyInteractive(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "interactiveMode")
        wallpaperController?.setInteractive(enabled)
        settingsController?.refreshInteraction()
        rebuildMenu()
    }

    @objc private func resetPosition(_ sender: Any?) {
        wallpaperController?.resetPinnedPosition()
    }

    @objc private func selectScene(_ sender: NSMenuItem) {
        guard let scene = sender.representedObject as? String else { return }
        applyScene(scene)
    }

    private func applyScene(_ scene: String) {
        UserDefaults.standard.set(scene, forKey: "selectedScene")
        if scene != "auto" { UserDefaults.standard.set(scene, forKey: "lastManualScene") }
        wallpaperController?.setScene(scene)
        settingsController?.refreshSceneSelection()
        rebuildMenu()
    }

    @objc private func openSettings(_ sender: Any?) {
        if settingsController == nil {
            let controller = SettingsWindowController()
            controller.onSceneChanged = { [weak self] scene in self?.applyScene(scene) }
            controller.onRotationChanged = { [weak self] seconds in self?.wallpaperController?.setRotationInterval(seconds) }
            controller.onResetPosition = { [weak self] in self?.wallpaperController?.resetPinnedPosition() }
            controller.onInteractiveChanged = { [weak self] enabled in self?.applyInteractive(enabled) }
            settingsController = controller
        }
        settingsController?.present()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func presentStartupError() {
        statusItem.button?.title = "♪!"
        statusItem.button?.toolTip = "Miku Desktop — Wallpaper unavailable"
    }
}
