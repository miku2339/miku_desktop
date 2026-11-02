import AppKit

extension Notification.Name {
    static let mikuSettingsChanged = Notification.Name("com.qimake.MikuDesktop.settingsChanged")
}

enum SceneRotation {
    static let defaultsKey = "sceneRotationSeconds"
    static let choices: [(key: String, seconds: Int)] = [
        ("minutes5", 300), ("minutes15", 900), ("minutes30", 1800), ("hour1", 3600)
    ]

    static var seconds: Int {
        let stored = UserDefaults.standard.integer(forKey: defaultsKey)
        return choices.contains { $0.seconds == stored } ? stored : 300
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onSceneChanged: ((String) -> Void)?
    var onRotationChanged: ((Int) -> Void)?
    var onResetPosition: (() -> Void)?
    var onInteractiveChanged: ((Bool) -> Void)?
    var onAmbientChanged: ((Bool) -> Void)?
    var onWeatherSettingsChanged: (() -> Void)?

    private let configuration: AIConfiguration
    private let ai: LocalAI
    private let sceneKeys = ["shibuya", "ikebukuro", "akihabara", "shinjuku", "hallway", "musicroom", "room"]
    private let personalityKeys = ["lively", "gentle", "quiet", "custom"]
    private let languageKeys = ["automatic", "traditionalChinese", "english", "japanese", "korean"]
    private let languageValues = ["auto", "zh-Hant", "en", "ja", "ko"]
    // What Miku speaks: Chinese can be Mandarin or Cantonese (the app itself has no
    // Cantonese interface, so this list is separate from the interface languages).
    private let replyLanguageKeys = ["automatic", "replyMandarin", "replyCantonese", "japanese", "english", "korean"]
    private let replyLanguageValues = ["auto", "zh-Hant", "yue", "ja", "en", "ko"]

    private let titleLabel = NSTextField.mikuLabel("", size: 20, weight: .bold, color: MikuTheme.deepTeal)
    private let subtitleLabel = NSTextField.mikuLabel("", size: 12.5, color: MikuTheme.secondaryText)
    private let footerLabel = NSTextField.mikuLabel("", size: 11, color: MikuTheme.secondaryText)

    private let scenePopup = NSPopUpButton()
    private let automaticSceneSwitch = NSSwitch()
    private let rotationPopup = NSPopUpButton()
    private let positionLabel = NSTextField.mikuLabel("", size: 12.5, color: MikuTheme.secondaryText)
    private let resetPositionButton = MikuPillButton(frame: .zero)
    private let personalitySegment = NSSegmentedControl()
    private let customField = NSTextField()
    private let nicknameField = NSTextField()
    private let replyLanguagePopup = NSPopUpButton()
    private let interfaceLanguagePopup = NSPopUpButton()
    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let testButton = MikuPillButton(frame: .zero)
    private let connectionDot = StatusDotView()
    private let connectionLabel = NSTextField.mikuLabel("", size: 12, color: MikuTheme.secondaryText)
    private let vocadbSwitch = NSSwitch()
    private let vocadbHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let speechSwitch = NSSwitch()
    private let speechLanguagePopup = NSPopUpButton()
    private let speechPreviewButton = MikuPillButton(frame: .zero)
    private let speechStopButton = MikuPillButton(frame: .zero)
    private let humFolderButton = MikuPillButton(frame: .zero)
    private let humHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let speechTestButton = MikuPillButton(frame: .zero)
    private let speechStatusLabel = NSTextField.mikuLabel("", size: 12, color: MikuTheme.secondaryText)
    private let speechEndpointField = NSTextField()
    private let speechModelCombo = NSComboBox()
    private let interactionSwitch = NSSwitch()
    private let ambientSwitch = NSSwitch()
    private let ambientHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let weatherPopup = NSPopUpButton()
    private let cityPopup = NSPopUpButton()
    private let weatherStatusLabel = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private var lastWeather: WeatherSnapshot?
    private var lastWeatherError = false
    private let interactionHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let launchSwitch = NSSwitch()
    private let loginStatusLabel = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.pink)
    private let openLoginSettingsButton = MikuPillButton(frame: .zero)

    private let memorySwitch = NSSwitch()
    private let memoryHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let memoryStatusLabel = NSTextField.mikuLabel("", size: 12, color: MikuTheme.secondaryText)
    private let factsStack = NSStackView()
    private let eraseMemoryButton = MikuPillButton(frame: .zero)
    private let restoreMemoryButton = MikuPillButton(frame: .zero)
    private let deleteBackupButton = MikuPillButton(frame: .zero)
    private var memoryObserver: NSObjectProtocol?

    private var awarenessSwitches: [AwarenessService.Source: NSSwitch] = [:]
    private let screenIntervalPopup = NSPopUpButton()
    private let awarenessHint = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)

    private var rowLabels: [String: NSTextField] = [:]
    private var sectionLabels: [String: NSTextField] = [:]
    private var connectionTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var discoveredSpeechModels: [String] = []

    init(configuration: AIConfiguration? = nil) {
        self.configuration = configuration ?? AIConfiguration.shared
        self.ai = LocalAI(configuration: configuration ?? AIConfiguration.shared)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("settingsTitle")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 540, height: 480)
        window.maxSize = NSSize(width: 760, height: 1400)
        window.isReleasedWhenClosed = false
        window.contentView = MikuBackgroundView()
        super.init(window: window)
        window.delegate = self
        buildUI()
        MikuSpeech.shared.onStateChanged = { [weak self] in self?.refreshSpeech() }
        loadValues()
        window.center()
        memoryObserver = NotificationCenter.default.addObserver(forName: .mikuMemoryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMemory() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        refreshLocalization()
        loadValues()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshLocalization() {
        window?.title = L10n.text("settingsTitle")
        titleLabel.stringValue = L10n.text("settingsTitle")
        subtitleLabel.stringValue = L10n.text("settingsSubtitle")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        footerLabel.stringValue = L10n.format("footer", version)
        for (key, label) in rowLabels { label.stringValue = L10n.text(key) }
        for (key, label) in sectionLabels { label.stringValue = L10n.text(key) }
        updatePopupTitles(scenePopup, keys: sceneKeys)
        updatePopupTitles(rotationPopup, keys: SceneRotation.choices.map { $0.key })
        updatePopupTitles(replyLanguagePopup, keys: replyLanguageKeys)
        updatePopupTitles(interfaceLanguagePopup, keys: languageKeys)
        updatePopupTitles(speechLanguagePopup, keys: [
            "speechLanguageAuto", "speechLanguageCantonese", "speechLanguageMandarin",
            "speechLanguageJapanese", "speechLanguageEnglish", "speechLanguageKorean"
        ])
        for (index, key) in personalityKeys.enumerated() {
            personalitySegment.setLabel(L10n.text(key), forSegment: index)
        }
        customField.placeholderString = L10n.text("customPlaceholder")
        nicknameField.placeholderString = L10n.text("nicknamePlaceholder")
        resetPositionButton.title = L10n.text("resetPosition")
        testButton.title = L10n.text("testConnection")
        speechPreviewButton.title = L10n.text("speechPreview")
        speechStopButton.title = L10n.text("speechStop")
        humFolderButton.title = L10n.text("humOpenFolder")
        refreshHumHint()
        speechTestButton.title = L10n.text("testConnection")
        speechEndpointField.placeholderString = MikuSpeechAuthorization.defaultEndpoint
        speechModelCombo.placeholderString = L10n.text("speechModelPlaceholder")
        updateSpeechModels(discoveredSpeechModels)
        openLoginSettingsButton.title = L10n.text("openSystemSettings")
        interactionHint.stringValue = L10n.text("interactionHint")
        ambientHint.stringValue = L10n.text("ambientHint")
        updatePopupTitles(weatherPopup, keys: WeatherService.modes.map { "weather\($0)" })
        updatePopupTitles(cityPopup, keys: WeatherService.cities.map { "city\($0.key)" })
        refreshWeatherStatus()
        refreshSceneSelection()
        refreshPosition()
        refreshLoginState()
        memoryHint.stringValue = L10n.text("memoryHint")
        vocadbHint.stringValue = L10n.text("vocadbHint")
        vocadbSwitch.state = UserDefaults.standard.bool(forKey: VocaDBLookup.enabledKey) ? .on : .off
        eraseMemoryButton.title = L10n.text("memoryErase")
        restoreMemoryButton.title = L10n.text("memoryRestore")
        deleteBackupButton.title = L10n.text("memoryBackupDelete")
        refreshMemory()
        refreshAwareness()
        refreshSpeech()
    }

    // MARK: - Awareness

    func refreshAwareness() {
        for (source, toggle) in awarenessSwitches {
            toggle.state = AwarenessService.isEnabled(source) ? .on : .off
            if source == .screen, #unavailable(macOS 14.0) {
                toggle.isEnabled = false
            }
        }
        screenIntervalPopup.isEnabled = AwarenessService.isEnabled(.screen)
        if #unavailable(macOS 14.0) { screenIntervalPopup.isEnabled = false }
        for (item, minutes) in zip(screenIntervalPopup.itemArray, AwarenessService.screenMinuteChoices) {
            item.title = AwarenessService.screenChoiceTitle(minutes)
        }
        select(String(AwarenessService.screenMinutes), in: screenIntervalPopup)
        var hint = L10n.text("awarenessHint")
        if #unavailable(macOS 14.0) {
            hint += "\n" + L10n.text("awarenessScreenUnavailable")
        } else if AwarenessService.isEnabled(.screen), !CGPreflightScreenCaptureAccess() {
            hint += "\n" + L10n.text("awarenessScreenPermission")
        }
        awarenessHint.stringValue = hint
    }

    @objc private func awarenessToggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let source = AwarenessService.Source(rawValue: raw) else { return }
        AwarenessService.setEnabled(source, sender.state == .on)
        refreshAwareness()
    }

    @objc private func screenIntervalChanged() {
        guard let value = screenIntervalPopup.selectedItem?.representedObject as? String, let minutes = Int(value) else { return }
        UserDefaults.standard.set(minutes, forKey: AwarenessService.screenMinutesKey)
        AwarenessService.shared.screenIntervalChanged()
    }

    // MARK: - Memory

    func refreshMemory() {
        let memory = CompanionMemory.shared
        restoreMemoryButton.isHidden = !memory.hasResetBackup
        deleteBackupButton.isHidden = !memory.hasResetBackup
        memorySwitch.state = memory.isEnabled ? .on : .off
        let level = CompanionMemory.level(for: Double(memory.friendship))
        let relationship = memory.relationshipStatus == .dating ? L10n.text("relationshipDating") : L10n.text("friendLevel\(level)")
        var status = L10n.format("memoryStatus", String(memory.facts.count), String(memory.friendship), relationship)
        if memory.isOffended { status += "\n" + L10n.text("memoryUpset") }
        memoryStatusLabel.stringValue = status
        memoryStatusLabel.textColor = memory.isOffended ? MikuTheme.pink : MikuTheme.secondaryText

        for view in factsStack.arrangedSubviews {
            factsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let facts = memory.facts.prefix(30)
        if facts.isEmpty {
            factsStack.addArrangedSubview(NSTextField.mikuLabel(L10n.text("memoryNone"), size: 12, color: MikuTheme.secondaryText))
        }
        for fact in facts {
            let label = NSTextField.mikuLabel(fact.text, size: 12.5)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.preferredMaxLayoutWidth = 250
            label.isSelectable = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let delete = MikuPillButton(frame: .zero)
            delete.style = .soft
            delete.symbolName = "xmark"
            delete.iconOnly = true
            delete.controlHeight = 22
            delete.toolTip = L10n.text("memoryDelete")
            delete.setAccessibilityLabel(L10n.text("memoryDelete"))
            delete.identifier = NSUserInterfaceItemIdentifier(fact.id.uuidString)
            delete.target = self
            delete.action = #selector(deleteFact(_:))
            let row = NSStackView(views: [delete, label])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            factsStack.addArrangedSubview(row)
        }
    }

    /// Off by default: song titles you ask about go to vocadb.net only while this is on.
    @objc private func vocadbToggled() {
        let enabled = vocadbSwitch.state == .on
        UserDefaults.standard.set(enabled, forKey: VocaDBLookup.enabledKey)
        if !enabled { Task { await VocaDBLookup.shared.clearCache() } }
    }

    @objc private func openHumFolder() {
        HumPlayer.shared.revealFolder()
        refreshHumHint()
    }

    private func refreshHumHint() {
        let count = HumPlayer.shared.clips().count
        humHint.stringValue = count == 0
            ? L10n.text("humHintEmpty")
            : L10n.format("humHintCount", String(count))
    }

    @objc private func memoryToggled() {
        CompanionMemory.shared.isEnabled = memorySwitch.state == .on
    }

    @objc private func deleteFact(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        CompanionMemory.shared.deleteFact(id: id)
    }

    @objc private func eraseMemory() {
        MikuSpeech.shared.stop()
        MemoryResetConfirmation.run()
    }

    @objc private func restoreMemory() {
        let alert = NSAlert()
        alert.messageText = L10n.text("memoryRestoreConfirm")
        alert.informativeText = L10n.text("memoryRestoreDetail")
        alert.addButton(withTitle: L10n.text("cancel"))
        alert.addButton(withTitle: L10n.text("memoryRestore"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        MikuSpeech.shared.stop()
        if !CompanionMemory.shared.restoreResetBackup() { showMemoryError() }
    }

    @objc private func deleteMemoryBackup() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("memoryBackupDeleteConfirm")
        alert.informativeText = L10n.text("memoryBackupDeleteDetail")
        alert.addButton(withTitle: L10n.text("cancel"))
        let delete = alert.addButton(withTitle: L10n.text("memoryBackupDelete"))
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if !CompanionMemory.shared.deleteResetBackup() { showMemoryError() }
    }

    private func showMemoryError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("memoryOperationFailed")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func refreshSceneSelection() {
        let selected = UserDefaults.standard.string(forKey: "selectedScene") ?? "auto"
        let automatic = selected == "auto"
        let manual = automatic ? UserDefaults.standard.string(forKey: "lastManualScene") ?? "shibuya" : selected
        select(manual, in: scenePopup)
        automaticSceneSwitch.state = automatic ? .on : .off
        scenePopup.isEnabled = !automatic
        rotationPopup.isEnabled = automatic
        if let index = SceneRotation.choices.firstIndex(where: { $0.seconds == SceneRotation.seconds }) {
            rotationPopup.selectItem(at: index)
        }
    }

    func refreshPosition() {
        let pinned = UserDefaults.standard.object(forKey: "pinnedAnchor") != nil
        positionLabel.stringValue = L10n.text(pinned ? "positionPinned" : "positionFree")
        resetPositionButton.isHidden = !pinned
    }

    func updateWeather(_ snapshot: WeatherSnapshot, failed: Bool) {
        lastWeather = snapshot
        lastWeatherError = failed
        refreshWeatherStatus()
    }

    private func refreshWeatherStatus() {
        let city = L10n.text("city\(WeatherService.city.key)")
        if WeatherService.mode != "auto" {
            weatherStatusLabel.stringValue = "\(L10n.text("weatherFixed")) · \(L10n.text("weather\(WeatherService.mode)"))"
        } else if let weather = lastWeather, weather.isLive {
            var parts = [city, L10n.text("weather\(weather.kind)")]
            if let temperature = weather.temperature { parts.append("\(Int(temperature.rounded()))°C") }
            weatherStatusLabel.stringValue = parts.joined(separator: " · ")
        } else if lastWeatherError {
            weatherStatusLabel.stringValue = L10n.text("weatherUnavailable")
        } else {
            weatherStatusLabel.stringValue = "\(city) · \(L10n.text("statusChecking"))"
        }
        cityPopup.isEnabled = true
    }

    func refreshInteraction() {
        let enabled = UserDefaults.standard.object(forKey: "interactiveMode") as? Bool ?? true
        interactionSwitch.state = enabled ? .on : .off
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        saveTextValues()
    }

    func windowWillClose(_ notification: Notification) {
        saveTextValues()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The user may have just approved the login item in System Settings.
        refreshLoginState()
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        configurePopup(scenePopup, titles: sceneKeys.map(L10n.text), values: sceneKeys, action: #selector(sceneChanged))
        configurePopup(rotationPopup, titles: SceneRotation.choices.map { L10n.text($0.key) }, values: SceneRotation.choices.map { String($0.seconds) }, action: #selector(rotationChanged))
        configurePopup(replyLanguagePopup, titles: replyLanguageKeys.map(L10n.text), values: replyLanguageValues, action: #selector(replyLanguageChanged))
        configurePopup(interfaceLanguagePopup, titles: languageKeys.map(L10n.text), values: languageValues, action: #selector(interfaceLanguageChanged))
        automaticSceneSwitch.target = self
        automaticSceneSwitch.action = #selector(automaticSceneChanged)
        configurePopup(weatherPopup, titles: WeatherService.modes.map { L10n.text("weather\($0)") }, values: WeatherService.modes, action: #selector(weatherModeChanged))
        configurePopup(cityPopup, titles: WeatherService.cities.map { L10n.text("city\($0.key)") }, values: WeatherService.cities.map { $0.key }, action: #selector(cityChanged))
        ambientSwitch.target = self
        ambientSwitch.action = #selector(ambientChanged)
        weatherStatusLabel.lineBreakMode = .byWordWrapping
        weatherStatusLabel.maximumNumberOfLines = 2
        weatherStatusLabel.preferredMaxLayoutWidth = 280

        personalitySegment.segmentCount = personalityKeys.count
        personalitySegment.trackingMode = .selectOne
        personalitySegment.segmentStyle = .rounded
        personalitySegment.selectedSegmentBezelColor = MikuTheme.teal
        personalitySegment.target = self
        personalitySegment.action = #selector(personalityChanged)
        for (index, key) in personalityKeys.enumerated() {
            personalitySegment.setLabel(L10n.text(key), forSegment: index)
            personalitySegment.setWidth(0, forSegment: index)
        }

        for field in [customField, nicknameField, endpointField, modelField] {
            field.bezelStyle = .roundedBezel
            field.font = MikuTheme.font(13)
            field.delegate = self
            field.target = self
            field.action = #selector(textFieldCommitted)
        }

        resetPositionButton.style = .soft
        resetPositionButton.symbolName = "figure.walk"
        resetPositionButton.controlHeight = 26
        resetPositionButton.font = MikuTheme.font(12, .semibold)
        resetPositionButton.target = self
        resetPositionButton.action = #selector(resetPosition)

        testButton.style = .primary
        testButton.symbolName = "bolt.horizontal.fill"
        testButton.controlHeight = 28
        testButton.target = self
        testButton.action = #selector(testConnection)
        connectionDot.isHidden = true
        connectionDot.translatesAutoresizingMaskIntoConstraints = false
        connectionLabel.lineBreakMode = .byWordWrapping
        connectionLabel.maximumNumberOfLines = 3
        connectionLabel.preferredMaxLayoutWidth = 240
        connectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configurePopup(
            speechLanguagePopup,
            titles: [
                "speechLanguageAuto", "speechLanguageCantonese", "speechLanguageMandarin",
                "speechLanguageJapanese", "speechLanguageEnglish", "speechLanguageKorean"
            ].map(L10n.text),
            values: MikuSpeech.Language.allCases.map(\.rawValue),
            action: #selector(speechLanguageChanged)
        )
        speechSwitch.target = self
        speechSwitch.action = #selector(speechEnabledChanged)
        for (button, symbol, action) in [
            (speechPreviewButton, "speaker.wave.2.fill", #selector(previewSpeech)),
            (speechStopButton, "stop.fill", #selector(stopSpeech)),
            (speechTestButton, "network", #selector(testSpeechConnection)),
            (humFolderButton, "folder", #selector(openHumFolder))
        ] {
            button.style = .soft
            button.symbolName = symbol
            button.controlHeight = 26
            button.font = MikuTheme.font(12, .semibold)
            button.target = self
            button.action = action
        }
        speechStatusLabel.lineBreakMode = .byWordWrapping
        speechStatusLabel.maximumNumberOfLines = 3
        speechStatusLabel.preferredMaxLayoutWidth = 250
        for field in [speechEndpointField, speechModelCombo] {
            field.font = MikuTheme.font(13)
            field.target = self
            field.action = #selector(speechConfigurationChanged)
        }
        speechEndpointField.bezelStyle = .roundedBezel
        speechModelCombo.isEditable = true
        speechModelCombo.completes = true
        speechModelCombo.numberOfVisibleItems = 8

        interactionSwitch.target = self
        interactionSwitch.action = #selector(interactionChanged)
        launchSwitch.target = self
        launchSwitch.action = #selector(launchAtLoginChanged)
        loginStatusLabel.isHidden = true
        loginStatusLabel.lineBreakMode = .byWordWrapping
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.preferredMaxLayoutWidth = 300
        openLoginSettingsButton.style = .soft
        openLoginSettingsButton.symbolName = "gearshape"
        openLoginSettingsButton.controlHeight = 26
        openLoginSettingsButton.font = MikuTheme.font(12, .semibold)
        openLoginSettingsButton.target = self
        openLoginSettingsButton.action = #selector(openLoginSettings)
        openLoginSettingsButton.isHidden = true

        // Header
        let avatar = MikuAvatarView(size: 54)
        subtitleLabel.lineBreakMode = .byWordWrapping
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [avatar, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        // Cards
        let positionStack = NSStackView(views: [positionLabel, resetPositionButton])
        positionStack.orientation = .vertical
        positionStack.alignment = .leading
        positionStack.spacing = 6

        let ambientStack = NSStackView(views: [ambientSwitch, ambientHint])
        ambientStack.orientation = .horizontal
        ambientStack.alignment = .centerY
        ambientStack.spacing = 10
        let weatherStack = NSStackView(views: [weatherPopup, weatherStatusLabel])
        weatherStack.orientation = .vertical
        weatherStack.alignment = .leading
        weatherStack.spacing = 6
        let sceneCard = card("sectionScene", symbol: "photo.on.rectangle.angled", rows: [
            row("autoSceneRotation", automaticSceneSwitch),
            row("rotationInterval", rotationPopup),
            row("background", scenePopup),
            row("ambientBackground", ambientStack),
            row("weather", weatherStack),
            row("weatherCity", cityPopup),
            row("position", positionStack)
        ])

        let characterCard = card("sectionCharacter", symbol: "music.note", rows: [
            row("personality", personalitySegment),
            row("customPersonality", customField),
            row("nickname", nicknameField)
        ])

        let languageCard = card("sectionLanguage", symbol: "character.bubble", rows: [
            row("replyLanguage", replyLanguagePopup),
            row("interfaceLanguage", interfaceLanguagePopup)
        ])

        let connectionRow = NSStackView(views: [testButton, connectionDot, connectionLabel])
        connectionRow.orientation = .horizontal
        connectionRow.alignment = .centerY
        connectionRow.spacing = 8
        vocadbSwitch.target = self
        vocadbSwitch.action = #selector(vocadbToggled)
        vocadbHint.lineBreakMode = .byWordWrapping
        vocadbHint.maximumNumberOfLines = 4
        vocadbHint.preferredMaxLayoutWidth = 260
        let vocadbStack = NSStackView(views: [vocadbSwitch, vocadbHint])
        vocadbStack.orientation = .horizontal
        vocadbStack.alignment = .centerY
        vocadbStack.spacing = 10
        let aiCard = card("sectionAI", symbol: "cpu", rows: [
            row("aiEndpoint", endpointField),
            row("aiModel", modelField),
            [NSGridCell.emptyContentView, connectionRow],
            row("vocadbLookup", vocadbStack)
        ])

        let speechButtons = NSStackView(views: [speechPreviewButton, speechStopButton])
        speechButtons.orientation = .horizontal
        speechButtons.alignment = .centerY
        speechButtons.spacing = 8
        let speechConnection = NSStackView(views: [speechTestButton, speechStatusLabel])
        speechConnection.orientation = .horizontal
        speechConnection.alignment = .centerY
        speechConnection.spacing = 8
        humHint.lineBreakMode = .byWordWrapping
        humHint.maximumNumberOfLines = 4
        humHint.preferredMaxLayoutWidth = 300
        let humStack = NSStackView(views: [humFolderButton, humHint])
        humStack.orientation = .vertical
        humStack.alignment = .leading
        humStack.spacing = 6
        let speechCard = card("sectionSpeech", symbol: "waveform", rows: [
            row("speechEnabled", speechSwitch),
            row("speechLanguage", speechLanguagePopup),
            row("speechEndpoint", speechEndpointField),
            row("speechModel", speechModelCombo),
            row("speechPlayback", speechButtons),
            row("speechConnection", speechConnection),
            row("humClips", humStack)
        ])

        let interactionStack = NSStackView(views: [interactionSwitch, interactionHint])
        interactionStack.orientation = .horizontal
        interactionStack.alignment = .centerY
        interactionStack.spacing = 10
        let loginStack = NSStackView(views: [launchSwitch, loginStatusLabel, openLoginSettingsButton])
        loginStack.orientation = .vertical
        loginStack.alignment = .leading
        loginStack.spacing = 6
        memorySwitch.target = self
        memorySwitch.action = #selector(memoryToggled)
        memoryHint.lineBreakMode = .byWordWrapping
        memoryHint.maximumNumberOfLines = 2
        memoryHint.preferredMaxLayoutWidth = 260
        memoryStatusLabel.lineBreakMode = .byWordWrapping
        memoryStatusLabel.maximumNumberOfLines = 3
        memoryStatusLabel.preferredMaxLayoutWidth = 300
        factsStack.orientation = .vertical
        factsStack.alignment = .leading
        factsStack.spacing = 6
        eraseMemoryButton.style = .soft
        eraseMemoryButton.symbolName = "trash"
        eraseMemoryButton.controlHeight = 26
        eraseMemoryButton.font = MikuTheme.font(12, .semibold)
        eraseMemoryButton.target = self
        eraseMemoryButton.action = #selector(eraseMemory)
        let memoryToggleStack = NSStackView(views: [memorySwitch, memoryHint])
        memoryToggleStack.orientation = .horizontal
        memoryToggleStack.alignment = .centerY
        memoryToggleStack.spacing = 10
        for (button, symbol, action) in [
            (restoreMemoryButton, "arrow.uturn.backward", #selector(restoreMemory)),
            (deleteBackupButton, "trash.slash", #selector(deleteMemoryBackup))
        ] {
            button.style = .soft
            button.symbolName = symbol
            button.controlHeight = 26
            button.font = MikuTheme.font(12, .semibold)
            button.target = self
            button.action = action
        }
        let backupStack = NSStackView(views: [restoreMemoryButton, deleteBackupButton])
        backupStack.orientation = .horizontal
        backupStack.spacing = 8
        let memoryListStack = NSStackView(views: [memoryStatusLabel, factsStack, eraseMemoryButton, backupStack])
        memoryListStack.orientation = .vertical
        memoryListStack.alignment = .leading
        memoryListStack.spacing = 8
        let memoryCard = card("sectionMemory", symbol: "heart.text.square", rows: [
            row("memoryEnabled", memoryToggleStack),
            row("memoryFacts", memoryListStack)
        ])

        // What she notices (all off by default, all on this Mac)
        var awarenessRows: [[NSView]] = []
        for source in AwarenessService.Source.allCases {
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(awarenessToggled(_:))
            toggle.identifier = NSUserInterfaceItemIdentifier(source.rawValue)
            awarenessSwitches[source] = toggle
            if source == .screen {
                configurePopup(
                    screenIntervalPopup,
                    titles: AwarenessService.screenMinuteChoices.map(AwarenessService.screenChoiceTitle),
                    values: AwarenessService.screenMinuteChoices.map(String.init),
                    action: #selector(screenIntervalChanged)
                )
                let screenStack = NSStackView(views: [toggle, screenIntervalPopup])
                screenStack.orientation = .horizontal
                screenStack.alignment = .centerY
                screenStack.spacing = 10
                awarenessRows.append(row("awareness_\(source.rawValue)", screenStack))
            } else {
                let stack = NSStackView(views: [toggle])
                stack.orientation = .horizontal
                awarenessRows.append(row("awareness_\(source.rawValue)", stack))
            }
        }
        awarenessHint.lineBreakMode = .byWordWrapping
        awarenessHint.maximumNumberOfLines = 4
        awarenessHint.preferredMaxLayoutWidth = 300
        awarenessRows.append([NSGridCell.emptyContentView, awarenessHint])
        let awarenessCard = card("sectionAwareness", symbol: "eye", rows: awarenessRows)

        let generalCard = card("sectionGeneral", symbol: "slider.horizontal.3", rows: [
            row("interaction", interactionStack),
            row("launchAtLogin", loginStack)
        ])

        footerLabel.alignment = .center

        let stack = NSStackView(views: [header, sceneCard, characterCard, memoryCard, awarenessCard, languageCard, speechCard, aiCard, generalCard, footerLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(20, after: header)
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        var constraints = [
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            footerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
            customField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            endpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            speechEndpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            speechModelCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            connectionDot.widthAnchor.constraint(equalToConstant: 8),
            connectionDot.heightAnchor.constraint(equalToConstant: 8)
        ]
        for card in [sceneCard, characterCard, memoryCard, awarenessCard, languageCard, speechCard, aiCard, generalCard] {
            constraints.append(card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44))
        }
        NSLayoutConstraint.activate(constraints)
        refreshLocalization()
    }

    private func card(_ titleKey: String, symbol: String, rows: [[NSView]]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = MikuTheme.teal
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let title = NSTextField.mikuLabel(L10n.text(titleKey), size: 14, weight: .bold, color: MikuTheme.deepTeal)
        sectionLabels[titleKey] = title
        let titleRow = NSStackView(views: [icon, title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .centerY

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 104
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        for index in 0..<grid.numberOfRows {
            let rowViews = rows[index]
            if rowViews.count > 1, rowViews[1] is NSStackView || rowViews[1] is NSSwitch {
                grid.row(at: index).yPlacement = .center
                grid.row(at: index).rowAlignment = .none
            }
            if rowViews.count > 1, rowViews[1] is NSTextField {
                grid.cell(for: rowViews[1])?.xPlacement = .fill
            }
        }

        let content = NSStackView(views: [titleRow, grid])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = MikuCardView()
        card.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        return card
    }

    private func row(_ key: String, _ control: NSView) -> [NSView] {
        let text = NSTextField.mikuLabel(L10n.text(key), size: 13, weight: .medium, color: MikuTheme.primaryText)
        text.alignment = .right
        rowLabels[key] = text
        return [text, control]
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], values: [String], action: Selector) {
        popup.removeAllItems()
        for (title, value) in zip(titles, values) {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = value
        }
        popup.target = self
        popup.action = action
    }

    private func updatePopupTitles(_ popup: NSPopUpButton, keys: [String]) {
        for (item, key) in zip(popup.itemArray, keys) {
            item.title = L10n.text(key)
        }
    }

    private func loadValues() {
        refreshSceneSelection()
        select(WeatherService.mode, in: weatherPopup)
        select(WeatherService.city.key, in: cityPopup)
        ambientSwitch.state = WeatherService.ambientEnabled ? .on : .off
        refreshPosition()
        refreshInteraction()
        personalitySegment.selectedSegment = personalityKeys.firstIndex(of: configuration.personalityPreset) ?? 0
        customField.stringValue = configuration.customPersonality
        nicknameField.stringValue = configuration.nickname
        select(configuration.replyLanguage, in: replyLanguagePopup)
        select(configuration.interfaceLanguage, in: interfaceLanguagePopup)
        endpointField.stringValue = configuration.endpoint
        modelField.stringValue = configuration.model
        speechEndpointField.stringValue = MikuSpeech.shared.endpoint
        speechModelCombo.stringValue = displayedSpeechModel(MikuSpeech.shared.configuredModelID)
        updateSpeechModels([])
        refreshSpeech()
        refreshLoginState()
    }

    private func select(_ value: String, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) {
            popup.select(item)
        }
    }

    // MARK: - Actions

    @objc private func personalityChanged() {
        let index = personalitySegment.selectedSegment
        configuration.personalityPreset = personalityKeys.indices.contains(index) ? personalityKeys[index] : "lively"
        saveAndNotify()
    }

    @objc private func sceneChanged() {
        guard let scene = scenePopup.selectedItem?.representedObject as? String else { return }
        onSceneChanged?(scene)
    }

    @objc private func automaticSceneChanged() {
        let scene = automaticSceneSwitch.state == .on
            ? "auto"
            : scenePopup.selectedItem?.representedObject as? String ?? "shibuya"
        onSceneChanged?(scene)
    }

    @objc private func rotationChanged() {
        let index = rotationPopup.indexOfSelectedItem
        guard SceneRotation.choices.indices.contains(index) else { return }
        let seconds = SceneRotation.choices[index].seconds
        UserDefaults.standard.set(seconds, forKey: SceneRotation.defaultsKey)
        onRotationChanged?(seconds)
    }

    @objc private func weatherModeChanged() {
        guard let mode = weatherPopup.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(mode, forKey: WeatherService.modeKey)
        refreshWeatherStatus()
        onWeatherSettingsChanged?()
    }

    @objc private func cityChanged() {
        guard let city = cityPopup.selectedItem?.representedObject as? String else { return }
        UserDefaults.standard.set(city, forKey: WeatherService.cityKey)
        lastWeather = nil
        lastWeatherError = false
        refreshWeatherStatus()
        onWeatherSettingsChanged?()
    }

    @objc private func ambientChanged() {
        let enabled = ambientSwitch.state == .on
        UserDefaults.standard.set(enabled, forKey: WeatherService.ambientKey)
        onAmbientChanged?(enabled)
    }

    @objc private func resetPosition() {
        onResetPosition?()
        refreshPosition()
    }

    @objc private func replyLanguageChanged() {
        configuration.replyLanguage = replyLanguagePopup.selectedItem?.representedObject as? String ?? "auto"
        saveAndNotify()
        refreshSpeech()
    }

    @objc private func interfaceLanguageChanged() {
        configuration.interfaceLanguage = interfaceLanguagePopup.selectedItem?.representedObject as? String ?? "auto"
        saveAndNotify()
    }

    @objc private func textFieldCommitted() {
        saveTextValues()
    }

    @objc private func interactionChanged() {
        onInteractiveChanged?(interactionSwitch.state == .on)
    }

    @objc private func speechEnabledChanged() {
        MikuSpeech.shared.enabled = speechSwitch.state == .on
        refreshSpeech()
    }

    @objc private func speechLanguageChanged() {
        guard let raw = speechLanguagePopup.selectedItem?.representedObject as? String,
              let language = MikuSpeech.Language(rawValue: raw) else { return }
        MikuSpeech.shared.language = language
        refreshSpeech()
    }

    @objc private func previewSpeech() {
        let fixed = SpeechVoice.voice(forReplyLanguage: configuration.replyLanguage)
            .flatMap(MikuSpeech.Language.init(rawValue:))
        MikuSpeech.shared.playSample(language: fixed ?? MikuSpeech.shared.language)
    }

    @objc private func stopSpeech() {
        MikuSpeech.shared.stop()
    }

    @objc private func testSpeechConnection() {
        do {
            try saveSpeechConfiguration()
        } catch {
            speechStatusLabel.stringValue = error.localizedDescription
            return
        }
        speechTask?.cancel()
        speechTestButton.isEnabled = false
        speechStatusLabel.stringValue = L10n.text("statusChecking")
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await MikuSpeech.shared.testConnection()
                guard !Task.isCancelled else { return }
                discoveredSpeechModels = models
                updateSpeechModels(models)
                speechStatusLabel.stringValue = models.isEmpty
                    ? L10n.text("speechConnectionOKManualModel")
                    : L10n.format("speechConnectionOKModels", String(models.count))
            } catch {
                speechStatusLabel.stringValue = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            speechTask = nil
            speechTestButton.isEnabled = true
        }
    }

    @objc private func speechConfigurationChanged() {
        do {
            try saveSpeechConfiguration()
            refreshSpeech()
        } catch {
            speechStatusLabel.stringValue = error.localizedDescription
        }
    }

    private func refreshSpeech() {
        let speech = MikuSpeech.shared
        speechSwitch.state = speech.enabled ? .on : .off
        // With a speaking language chosen for Miku, her voice follows it (and the text
        // itself, see SpeechVoice); the voice language only matters on Automatic.
        if let fixed = SpeechVoice.voice(forReplyLanguage: configuration.replyLanguage) {
            select(fixed, in: speechLanguagePopup)
            speechLanguagePopup.isEnabled = false
            speechLanguagePopup.toolTip = L10n.text("speechLanguageFollows")
        } else {
            select(speech.language.rawValue, in: speechLanguagePopup)
            speechLanguagePopup.isEnabled = true
            speechLanguagePopup.toolTip = nil
        }
        speechPreviewButton.isEnabled = speech.hasConfiguredModel && speech.enabled
        speechStopButton.isEnabled = speech.isBusy
        speechTestButton.isEnabled = speechTask == nil
        if speech.status.isEmpty {
            speechStatusLabel.stringValue = L10n.text("speechReady")
        } else {
            speechStatusLabel.stringValue = speech.status
        }
    }

    private func saveSpeechConfiguration() throws {
        let value = speechModelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = value == L10n.text("speechAutomaticModel") ? MikuSpeech.automaticModelID : value
        try MikuSpeech.shared.configure(
            endpoint: speechEndpointField.stringValue,
            modelID: modelID
        )
        speechEndpointField.stringValue = MikuSpeech.shared.endpoint
        speechModelCombo.stringValue = displayedSpeechModel(MikuSpeech.shared.configuredModelID)
    }

    private func displayedSpeechModel(_ modelID: String) -> String {
        modelID == MikuSpeech.automaticModelID ? L10n.text("speechAutomaticModel") : modelID
    }

    private func updateSpeechModels(_ models: [String]) {
        let configured = MikuSpeech.shared.configuredModelID
        let displayed = displayedSpeechModel(configured)
        speechModelCombo.removeAllItems()
        if configured == MikuSpeech.automaticModelID || MikuSpeech.ownerModelIDs.isSubset(of: Set(models)) {
            speechModelCombo.addItem(withObjectValue: L10n.text("speechAutomaticModel"))
        }
        speechModelCombo.addItems(withObjectValues: models)
        speechModelCombo.stringValue = displayed
    }

    @objc private func testConnection() {
        saveTextValues()
        connectionTask?.cancel()
        testButton.isEnabled = false
        connectionDot.isHidden = false
        connectionDot.color = MikuTheme.checking
        connectionLabel.stringValue = L10n.text("statusChecking")
        connectionLabel.textColor = MikuTheme.secondaryText
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let result = await ai.checkConnection()
            guard !Task.isCancelled else { return }
            testButton.isEnabled = true
            connectionLabel.stringValue = result.message
            if !result.reachable {
                connectionDot.color = MikuTheme.offline
                connectionLabel.textColor = MikuTheme.pink
            } else if result.modelAvailable == false {
                connectionDot.color = MikuTheme.checking
                connectionLabel.textColor = MikuTheme.primaryText
            } else {
                connectionDot.color = MikuTheme.online
                connectionLabel.textColor = MikuTheme.deepTeal
            }
        }
    }

    @objc private func launchAtLoginChanged() {
        let requested = launchSwitch.state == .on
        do {
            try LoginItemManager.setEnabled(requested)
            configuration.launchAtLogin = requested
            saveAndNotify()
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginStatusLabel.stringValue = L10n.text("loginItemError")
            loginStatusLabel.isHidden = false
        }
    }

    @objc private func openLoginSettings() {
        LoginItemManager.openSystemSettings()
    }

    private func refreshLoginState() {
        let state = LoginItemManager.state
        launchSwitch.state = state == .disabled ? .off : .on
        let needsApproval = state == .requiresApproval
        loginStatusLabel.stringValue = needsApproval ? L10n.text("loginItemApproval") : ""
        loginStatusLabel.isHidden = !needsApproval
        openLoginSettingsButton.isHidden = !needsApproval
    }

    private func saveTextValues() {
        configuration.customPersonality = customField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.nickname = nicknameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveAndNotify()
    }

    private func saveAndNotify() {
        configuration.save()
        NotificationCenter.default.post(name: .mikuSettingsChanged, object: nil)
    }
}

// MARK: - In Miku's notebook

extension SettingsWindowController: NotebookPage {
    /// The settings sections, in page order, that the notebook sidebar can jump to.
    static let notebookSections = [
        "sectionScene", "sectionCharacter", "sectionMemory", "sectionAwareness",
        "sectionLanguage", "sectionSpeech", "sectionAI", "sectionGeneral"
    ]

    func notebookPageWillAppear() {
        refreshLocalization()
        loadValues()
        refreshLoginState()
    }

    func notebookPageWillDisappear() {
        saveTextValues()
    }

    func notebookPageDidBecomeKey() {
        // The user may have just approved the login item in System Settings.
        refreshLoginState()
    }

    var notebookMaxWidth: CGFloat? { 720 }

    /// Scrolls so the section's title sits just below the top of the page.
    func notebookScroll(to key: String) {
        guard let label = sectionLabels[key],
              let scroll = label.enclosingScrollView,
              let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let rect = label.convert(label.bounds, to: document)
        let maxY = max(0, document.bounds.height - clip.bounds.height)
        let target = document.isFlipped ? rect.minY - 56 : document.bounds.height - rect.maxY - 56
        clip.setBoundsOrigin(NSPoint(x: 0, y: min(maxY, max(0, target))))
        scroll.reflectScrolledClipView(clip)
    }
}
