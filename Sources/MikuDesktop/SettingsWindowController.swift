import AppKit

extension Notification.Name {
    static let mikuSettingsChanged = Notification.Name("com.qimake.MikuDesktop.settingsChanged")
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let configuration: AIConfiguration
    private let personalityPopup = NSPopUpButton()
    private let customField = NSTextField()
    private let nicknameField = NSTextField()
    private let replyLanguagePopup = NSPopUpButton()
    private let interfaceLanguagePopup = NSPopUpButton()
    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let launchSwitch = NSSwitch()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private var labelFields: [String: NSTextField] = [:]

    init(configuration: AIConfiguration? = nil) {
        self.configuration = configuration ?? AIConfiguration.shared
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("settings")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        refreshLocalization()
        loadValues()
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshLocalization() {
        window?.title = L10n.text("settings")
        for (key, label) in labelFields { label.stringValue = L10n.text(key) }
        updatePopupTitles(personalityPopup, keys: ["lively", "gentle", "quiet", "custom"])
        updatePopupTitles(replyLanguagePopup, keys: ["automatic", "traditionalChinese", "english", "japanese"])
        updatePopupTitles(interfaceLanguagePopup, keys: ["automatic", "traditionalChinese", "english", "japanese"])
        if !loginStatusLabel.isHidden { loginStatusLabel.stringValue = L10n.text("loginItemError") }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        saveTextValues()
    }

    func windowWillClose(_ notification: Notification) {
        saveTextValues()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        configurePopup(personalityPopup, items: [
            (L10n.text("lively"), "lively"),
            (L10n.text("gentle"), "gentle"),
            (L10n.text("quiet"), "quiet"),
            (L10n.text("custom"), "custom")
        ], action: #selector(personalityChanged))
        configurePopup(replyLanguagePopup, items: languageItems(), action: #selector(replyLanguageChanged))
        configurePopup(interfaceLanguagePopup, items: languageItems(), action: #selector(interfaceLanguageChanged))

        [customField, nicknameField, endpointField, modelField].forEach {
            $0.delegate = self
            $0.target = self
            $0.action = #selector(textFieldCommitted)
        }

        launchSwitch.target = self
        launchSwitch.action = #selector(launchAtLoginChanged)
        loginStatusLabel.textColor = .systemRed
        loginStatusLabel.isHidden = true

        let grid = NSGridView(views: [
            row("personality", personalityPopup),
            row("customPersonality", customField),
            row("nickname", nicknameField),
            row("replyLanguage", replyLanguagePopup),
            row("interfaceLanguage", interfaceLanguagePopup),
            row("aiEndpoint", endpointField),
            row("aiModel", modelField),
            row("launchAtLogin", launchSwitch)
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [grid, loginStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            customField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310),
            endpointField.widthAnchor.constraint(greaterThanOrEqualToConstant: 310)
        ])
    }

    private func row(_ key: String, _ control: NSView) -> [NSView] {
        let text = NSTextField(labelWithString: L10n.text(key))
        text.alignment = .right
        labelFields[key] = text
        return [text, control]
    }

    private func languageItems() -> [(String, String)] {
        [
            (L10n.text("automatic"), "auto"),
            (L10n.text("traditionalChinese"), "zh-Hant"),
            (L10n.text("english"), "en"),
            (L10n.text("japanese"), "ja")
        ]
    }

    private func configurePopup(_ popup: NSPopUpButton, items: [(String, String)], action: Selector) {
        popup.removeAllItems()
        for (title, value) in items {
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
        select(configuration.personalityPreset, in: personalityPopup)
        customField.stringValue = configuration.customPersonality
        nicknameField.stringValue = configuration.nickname
        select(configuration.replyLanguage, in: replyLanguagePopup)
        select(configuration.interfaceLanguage, in: interfaceLanguagePopup)
        endpointField.stringValue = configuration.endpoint
        modelField.stringValue = configuration.model
        launchSwitch.state = LoginItemManager.isEnabled ? .on : .off
        loginStatusLabel.isHidden = true
    }

    private func select(_ value: String, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { ($0.representedObject as? String) == value }) {
            popup.select(item)
        }
    }

    @objc private func personalityChanged() {
        configuration.personalityPreset = personalityPopup.selectedItem?.representedObject as? String ?? "lively"
        saveAndNotify()
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

    @objc private func launchAtLoginChanged() {
        let requested = launchSwitch.state == .on
        do {
            try LoginItemManager.setEnabled(requested)
            configuration.launchAtLogin = requested
            loginStatusLabel.isHidden = true
            saveAndNotify()
        } catch {
            launchSwitch.state = LoginItemManager.isEnabled ? .on : .off
            loginStatusLabel.stringValue = L10n.text("loginItemError")
            loginStatusLabel.isHidden = false
        }
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
