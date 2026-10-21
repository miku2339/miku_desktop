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
    private let sceneKeys = ["shibuya", "ikebukuro", "akihabara", "shinjuku", "hallway", "musicroom"]
    private let personalityKeys = ["lively", "gentle", "quiet", "custom"]
    private let languageKeys = ["automatic", "traditionalChinese", "english", "japanese"]
    private let languageValues = ["auto", "zh-Hant", "en", "ja"]

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
    private var memoryObserver: NSObjectProtocol?

    private var rowLabels: [String: NSTextField] = [:]
    private var sectionLabels: [String: NSTextField] = [:]
    private var connectionTask: Task<Void, Never>?

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
        updatePopupTitles(replyLanguagePopup, keys: languageKeys)
        updatePopupTitles(interfaceLanguagePopup, keys: languageKeys)
        for (index, key) in personalityKeys.enumerated() {
            personalitySegment.setLabel(L10n.text(key), forSegment: index)
        }
        customField.placeholderString = L10n.text("customPlaceholder")
        nicknameField.placeholderString = L10n.text("nicknamePlaceholder")
        resetPositionButton.title = L10n.text("resetPosition")
        testButton.title = L10n.text("testConnection")
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
        eraseMemoryButton.title = L10n.text("memoryErase")
        refreshMemory()
    }

    // MARK: - Memory

    func refreshMemory() {
        let memory = CompanionMemory.shared
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

    @objc private func memoryToggled() {
        CompanionMemory.shared.isEnabled = memorySwitch.state == .on
    }

    @objc private func deleteFact(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        CompanionMemory.shared.deleteFact(id: id)
    }

    @objc private func eraseMemory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("memoryEraseConfirm")
        alert.informativeText = L10n.text("memoryEraseDetail")
        alert.addButton(withTitle: L10n.text("memoryErase"))
        alert.addButton(withTitle: L10n.text("cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { CompanionMemory.shared.eraseAll() }
        }
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
        configurePopup(replyLanguagePopup, titles: languageKeys.map(L10n.text), values: languageValues, action: #selector(replyLanguageChanged))
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
        let aiCard = card("sectionAI", symbol: "cpu", rows: [
            row("aiEndpoint", endpointField),
            row("aiModel", modelField),
            [NSGridCell.emptyContentView, connectionRow]
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
        let memoryListStack = NSStackView(views: [memoryStatusLabel, factsStack, eraseMemoryButton])
        memoryListStack.orientation = .vertical
        memoryListStack.alignment = .leading
        memoryListStack.spacing = 8
        let memoryCard = card("sectionMemory", symbol: "heart.text.square", rows: [
            row("memoryEnabled", memoryToggleStack),
            row("memoryFacts", memoryListStack)
        ])

        let generalCard = card("sectionGeneral", symbol: "slider.horizontal.3", rows: [
            row("interaction", interactionStack),
            row("launchAtLogin", loginStack)
        ])

        footerLabel.alignment = .center

        let stack = NSStackView(views: [header, sceneCard, characterCard, memoryCard, languageCard, aiCard, generalCard, footerLabel])
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
            connectionDot.widthAnchor.constraint(equalToConstant: 8),
            connectionDot.heightAnchor.constraint(equalToConstant: 8)
        ]
        for card in [sceneCard, characterCard, memoryCard, languageCard, aiCard, generalCard] {
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
