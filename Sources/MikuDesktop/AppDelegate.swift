import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var server: StaticHTTPServer?
    private var wallpaperController: WallpaperWindowController?
    private var desktopControlsController: DesktopControlsWindowController?
    private var chatController: ChatWindowController?
    private var settingsController: SettingsWindowController?
    private var notebookController: DiaryWindowController?
    private var albumController: MemoryAlbumWindowController?
    private var knowledgeController: SongKnowledgeWindowController?
    private var rhythmController: RhythmGameWindowController?
    private var settingsObserver: NSObjectProtocol?
    private var speechMuteObserver: NSObjectProtocol?
    private let weatherService = WeatherService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        replaceOtherInstances()
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "♪"
        statusItem.button?.toolTip = "Miku Desktop"
        rebuildMenu()

        MikuSpeech.shared.onPlayback = { [weak self] event in
            self?.wallpaperController?.speechPlayback(event)
            self?.afterSpeech(event)
        }
        // Retries and failures of reading aloud, so an occasional silent reply can be traced.
        MikuSpeech.shared.onDiagnostic = { payload in CompanionMemory.shared.logDiagnostic(payload) }
        HumPlayer.shared.onEvent = { [weak self] event in
            switch event {
            case let .started(duration):
                self?.wallpaperController?.speechPlayback(.started(text: HumText.mouthText, duration: duration))
            case .ended:
                self?.wallpaperController?.speechPlayback(.ended)
                self?.flushPendingMusic()
            }
        }

        let awareness = AwarenessService.shared
        awareness.onSpeak = { [weak self] reply in self?.deliverProactive(reply) }
        awareness.isChatting = { [weak self] in self?.chatController?.isChatting ?? false }
        awareness.onMusicChanged = { [weak self] song in self?.wallpaperController?.setMusic(song) }
        awareness.start()
        EventCalendar.shared.start()
        CompanionDiary.shared.start()

        // Muting (or a timed mute running out) changes the ♪ menu.
        speechMuteObserver = NotificationCenter.default.addObserver(
            forName: .mikuSpeechMuteChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
                // Muted: the hum stops too, like her voice.
                if MikuSpeech.shared.isMuted || !MikuSpeech.shared.enabled {
                    self?.pendingHum = nil
                    HumPlayer.shared.stop()
                }
            }
        }

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
                self?.albumController?.refreshLocalization()
                self?.knowledgeController?.refreshLocalization()
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
                    self.weatherService.onUpdate = { [weak self] snapshot in
                        guard let self else { return }
                        wallpaperController?.setWeather(snapshot)
                        settingsController?.updateWeather(snapshot, failed: weatherService.lastError != nil)
                    }
                    self.weatherService.start()
                    let controls = DesktopControlsWindowController()
                    controls.onOpenChat = { [weak self] in self?.openChat(nil) }
                    controls.onOpenAlbum = { [weak self] in self?.openAlbum(nil) }
                    controls.onOpenSettings = { [weak self] in self?.openSettings(nil) }
                    self.desktopControlsController = controls
                case .failure:
                    self.presentStartupError()
                }
            }
        }
    }

    /// Only one Miku at a time: a fresh launch replaces any copy that is already running
    /// (for example an older build in /Applications started by the login item).
    private func replaceOtherInstances() {
        let current = NSRunningApplication.current
        let identifier = Bundle.main.bundleIdentifier ?? "com.qimake.MikuDesktop"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != current.processIdentifier }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MikuSpeech.shared.stop()
        server?.stop()
        CompanionMemory.shared.saveNow()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `miku-desktop://` links: only the voice commands in SpeechLinkCommand (for Shortcuts
    /// automations, e.g. keeping Miku quiet during a Focus). Anything else is ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = SpeechLinkCommand(url: url) else { continue }
            MikuSpeech.shared.handle(command)
        }
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

        let notebook = NSMenuItem(title: L10n.text("notebookMenu"), action: #selector(openNotebook(_:)), keyEquivalent: "")
        notebook.target = self
        menu.addItem(notebook)

        for (key, action) in [
            ("comeOver", #selector(callCompanionOver(_:))),
            ("memoryAlbum", #selector(openAlbum(_:))),
            ("takeMemoryPhoto", #selector(takeMemoryPhoto(_:))),
            ("songKnowledge", #selector(openKnowledge(_:)))
        ] {
            let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        // Miku's voice: mute for a while without turning reading aloud off.
        let speech = MikuSpeech.shared
        if speech.enabled {
            let voiceMenu = NSMenu()
            if speech.isMuted {
                if speech.isQuietByAutomation {
                    let note = NSMenuItem(title: L10n.text("speechQuietByFocus"), action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    voiceMenu.addItem(note)
                } else if let until = speech.mutedUntil {
                    let note = NSMenuItem(title: L10n.format("speechMutedUntil", until.formatted(date: .omitted, time: .shortened)), action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    voiceMenu.addItem(note)
                }
                let unmute = NSMenuItem(title: L10n.text("speechUnmute"), action: #selector(unmuteSpeech(_:)), keyEquivalent: "")
                unmute.target = self
                voiceMenu.addItem(unmute)
            } else {
                for (key, action) in [
                    ("speechMuteHour", #selector(muteSpeechForAnHour(_:))),
                    ("speechMuteIndefinite", #selector(muteSpeechUntilUnmuted(_:)))
                ] {
                    let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
                    item.target = self
                    voiceMenu.addItem(item)
                }
            }
            voiceMenu.addItem(.separator())
            let focus = NSMenuItem(title: L10n.text("speechFollowFocus"), action: #selector(explainFocusAutomation(_:)), keyEquivalent: "")
            focus.target = self
            voiceMenu.addItem(focus)
            let voice = NSMenuItem(title: L10n.text(speech.isMuted ? "speechMenuMuted" : "speechMenu"), action: nil, keyEquivalent: "")
            voice.submenu = voiceMenu
            menu.addItem(voice)
        }

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
            (L10n.text("musicroom"), "musicroom"),
            (L10n.text("room"), "room")
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
        let resetMemory = NSMenuItem(title: L10n.text("resetMemoryMenu"), action: #selector(resetMemory(_:)), keyEquivalent: "")
        resetMemory.target = self
        menu.addItem(resetMemory)
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

    /// Something she noticed and wanted to say: speech bubble on the desktop, and in the chat.
    private func deliverProactive(_ reply: CompanionReply) {
        // Something she says on her own stays silent while she's meant to be asleep.
        voice(reply, awake: !SleepSchedule.shared.isAsleep(), speakEvenIfSilent: false)
        if let chatController {
            chatController.receiveProactive(reply)
        } else {
            CompanionMemory.shared.appendAssistantMessage(reply.text)
        }
    }

    // MARK: - Her voice, a hum, then the song you asked for

    /// Shows her reply and plays what goes with it, one after another: her voice (reading aloud),
    /// then a hum clip if she hummed, then a song you asked her to play.
    /// `speakEvenIfSilent`: chat replies still go through speech so its status updates.
    private func voice(_ reply: CompanionReply, awake: Bool, speakEvenIfSilent: Bool) {
        let speech = MikuSpeech.shared
        let speaks = awake && speech.willSpeakAutomatically
        let hums = awake && HumText.containsHum(reply.text) && humAllowed && HumText.hasClips()
        wallpaperController?.receiveReply(reply, voiced: speaks || hums)
        // A new reply: whatever the previous one was waiting for no longer applies to it.
        pendingHum = nil
        musicArmed = false

        guard speaks else {
            // Reading aloud is off or blocked; chat replies still update the speech status.
            if speakEvenIfSilent { speech.speak(reply.text) }
            if !(hums && HumPlayer.shared.play()) { flushPendingMusic() }
            return
        }
        // The hum waits for her voice; set before speaking, as speech can fail at once.
        if hums { pendingHum = false }
        speech.speak(hums ? HumText.removingHum(reply.text) : reply.text)
        if pendingHum != nil { pendingHum = true }
        musicArmed = true
        // Speech gave up straight away and no hum is playing: the song needn't wait.
        if !speech.isBusy, !HumPlayer.shared.isPlaying, pendingHum == nil { flushPendingMusic() }
    }

    /// Muted, a call or full screen: no hum either.
    private var humAllowed: Bool {
        !MikuSpeech.shared.isMuted && !SpeechQuietTimes.isQuietNow()
    }

    /// A hum waiting for her voice to finish; true once that speech has started.
    private var pendingHum: Bool?

    private func afterSpeech(_ event: MikuSpeech.PlaybackEvent) {
        switch event {
        case .started:
            return
        case .interrupted:
            // Cut off (muted, stopped): the hum is dropped. A newer line cutting in arrives
            // before that reply is armed, so it is ignored here.
            guard musicArmed else { return }
            pendingHum = nil
            flushPendingMusic()
        case .ended, .failed:
            if pendingHum != nil {
                // .failed can come at once, before the speech counts as started.
                if case .ended = event, pendingHum == false { return }
                pendingHum = nil
                if humAllowed, HumPlayer.shared.play() { return }
                flushPendingMusic()
                return
            }
            guard musicArmed else { return }
            flushPendingMusic()
        }
    }

    /// Waiting for her to finish (voice and hum), so the song doesn't play over her.
    private var pendingMusic: MusicPlan?
    private var pendingMusicTimer: Timer?
    /// The reply that the song waits for has been voiced; its end means "play".
    private var musicArmed = false

    private func queueMusic(_ plan: MusicPlan) {
        pendingMusic = plan
        musicArmed = false
        pendingMusicTimer?.invalidate()
        // In case the audio never reports back.
        pendingMusicTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingMusic() }
        }
        // Her reply is delivered right after this. If none comes (she couldn't answer), play now.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingMusic == plan, !self.musicArmed,
                  !MikuSpeech.shared.isBusy, !HumPlayer.shared.isPlaying else { return }
            self.flushPendingMusic()
        }
    }

    private func flushPendingMusic() {
        pendingMusicTimer?.invalidate()
        pendingMusicTimer = nil
        musicArmed = false
        guard let plan = pendingMusic else { return }
        pendingMusic = nil
        Task { await MusicPlayback.shared.perform(plan) }
    }

    @objc private func openChat(_ sender: Any?) {
        if chatController == nil {
            let controller = ChatWindowController()
            controller.onReply = { [weak self] reply in
                self?.voice(reply, awake: true, speakEvenIfSilent: true)
            }
            controller.onPlayMusic = { [weak self] plan in self?.queueMusic(plan) }
            controller.onThinking = { [weak self] thinking in
                self?.wallpaperController?.setThinking(thinking)
                // You've said something new: an old hum stops.
                if thinking {
                    self?.pendingHum = nil
                    HumPlayer.shared.stop()
                }
            }
            controller.onOpenSettings = { [weak self] in
                self?.openSettings(nil)
            }
            controller.onCallOver = { [weak self] in self?.callCompanionOver(nil) }
            controller.onOpenAlbum = { [weak self] in self?.openAlbum(nil) }
            controller.onTakeMemoryPhoto = { [weak self] in self?.takeMemoryPhoto(nil) }
            controller.onOpenKnowledge = { [weak self] in self?.openKnowledge(nil) }
            controller.onGameEvent = { [weak self] event in
                switch event {
                case let .rps(hand, outcome):
                    self?.wallpaperController?.playRPS(hand: hand, outcome: outcome)
                case .rhythm:
                    self?.openRhythmGame()
                }
            }
            chatController = controller
        }
        chatController?.present()
    }

    @objc private func callCompanionOver(_ sender: Any?) {
        if SleepSchedule.shared.isAsleep() { SleepSchedule.shared.wake(minutes: 30) }
        wallpaperController?.callCompanionOver()
    }

    private func prepareAlbum() -> MemoryAlbumWindowController {
        if let albumController { return albumController }
        let controller = MemoryAlbumWindowController(capture: { [weak self] in
            guard let wallpaper = self?.wallpaperController else {
                throw NSError(domain: "MikuDesktop.Album", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L10n.text("memoryPhotoUnavailable")
                ])
            }
            return try await wallpaper.captureMemoryPhoto()
        })
        albumController = controller
        return controller
    }

    @objc private func openAlbum(_ sender: Any?) {
        prepareAlbum().present()
    }

    @objc private func takeMemoryPhoto(_ sender: Any?) {
        prepareAlbum().presentAndCapture()
    }

    @objc private func openKnowledge(_ sender: Any?) {
        if knowledgeController == nil { knowledgeController = SongKnowledgeWindowController() }
        knowledgeController?.present()
    }

    @objc private func muteSpeechForAnHour(_ sender: Any?) {
        MikuSpeech.shared.setMuted(true, for: SpeechMute.hour)
    }

    @objc private func muteSpeechUntilUnmuted(_ sender: Any?) {
        MikuSpeech.shared.setMuted(true)
    }

    @objc private func unmuteSpeech(_ sender: Any?) {
        MikuSpeech.shared.setMuted(false)
    }

    /// macOS doesn't let this app read Focus directly, but a Shortcuts automation can tell
    /// it: explain the two automations and offer to open Shortcuts.
    @objc private func explainFocusAutomation(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.text("speechFocusTitle")
        alert.informativeText = L10n.text("speechFocusSteps")
        alert.addButton(withTitle: L10n.text("speechFocusOpenShortcuts"))
        alert.addButton(withTitle: L10n.text("speechFocusCopyOn"))
        alert.addButton(withTitle: L10n.text("cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let shortcuts = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                NSWorkspace.shared.openApplication(at: shortcuts, configuration: NSWorkspace.OpenConfiguration())
            }
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("open -g \"miku-desktop://quiet/on\"", forType: .string)
        default:
            break
        }
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
            controller.onAmbientChanged = { [weak self] enabled in self?.wallpaperController?.setAmbientEnabled(enabled) }
            controller.onWeatherSettingsChanged = { [weak self] in self?.weatherService.refresh() }
            controller.updateWeather(weatherService.latest, failed: weatherService.lastError != nil)
            settingsController = controller
        }
        settingsController?.present()
    }

    private func openRhythmGame() {
        if rhythmController == nil {
            let controller = RhythmGameWindowController()
            controller.onBeat = { [weak self] in self?.wallpaperController?.rhythmBeat() }
            controller.onFinish = { [weak self] score, _ in self?.chatController?.finishRhythmGame(score: score) }
            rhythmController = controller
        }
        rhythmController?.start()
    }

    @objc private func openNotebook(_ sender: Any?) {
        if notebookController == nil { notebookController = DiaryWindowController() }
        notebookController?.present()
    }

    @objc private func resetMemory(_ sender: Any?) {
        MikuSpeech.shared.stop()
        MemoryResetConfirmation.run()
    }

    @objc private func quit(_ sender: Any?) {
        MikuSpeech.shared.stop()
        NSApp.terminate(nil)
    }

    private func presentStartupError() {
        statusItem.button?.title = "♪!"
        statusItem.button?.toolTip = "Miku Desktop — Wallpaper unavailable"
    }
}
