import AppKit

/// Miku writes a short diary entry for each day you spent together: when she goes to sleep,
/// and on the next launch for a day she missed. Entries live in her memory (a reset clears them).
@MainActor
final class CompanionDiary {
    static let shared = CompanionDiary()

    private let ai = LocalAI(configuration: AIConfiguration.shared)
    private var timer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var writing = false
    private var failures: [String: Int] = [:]

    func start() {
        sleepObserver = NotificationCenter.default.addObserver(forName: .mikuSleepChanged, object: nil, queue: .main) { _ in
            // Give the good-night exchange a moment to land in memory first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                MainActor.assumeIsolated { CompanionDiary.shared.check() }
            }
        }
        let timer = Timer(timeInterval: 10 * 60, repeats: true) { _ in
            Task { @MainActor in CompanionDiary.shared.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A day she missed (the Mac was off at bedtime), once the app has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            MainActor.assumeIsolated { CompanionDiary.shared.check() }
        }
    }

    /// Writes yesterday's entry if it was missed, and today's once she's asleep.
    func check(now: Date = Date()) {
        let memory = CompanionMemory.shared
        guard memory.isEnabled, !writing else { return }
        let today = CompanionMemory.diaryDay(for: now)
        let yesterday = CompanionMemory.diaryDay(for: now.addingTimeInterval(-24 * 3600))
        var days = [yesterday]
        if SleepSchedule.shared.isAsleep(at: now) { days.append(today) }
        for day in days where failures[day, default: 0] < 3 && memory.needsDiary(for: day) {
            write(day)
            return
        }
    }

    private func write(_ day: String) {
        guard let material = CompanionMemory.shared.diaryMaterial(for: day) else { return }
        writing = true
        let ai = ai
        Task { [weak self] in
            do {
                let text = try await ai.writeDiary(material)
                CompanionMemory.shared.saveDiary(day: day, text: text)
                CompanionMemory.shared.logDiagnostic(["type": "diary", "day": day, "chars": text.count])
            } catch {
                self?.failures[day, default: 0] += 1
                CompanionMemory.shared.logDiagnostic(["type": "diary", "day": day, "error": error.localizedDescription])
            }
            self?.writing = false
        }
    }
}

/// Miku's notebook: special days coming up, and her diary.
@MainActor
final class DiaryWindowController: NSWindowController, NSWindowDelegate {
    private let stack = NSStackView()
    private var observers: [NSObjectProtocol] = []

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = MikuBackgroundView()
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.center()
        for name in [Notification.Name.mikuMemoryChanged, .mikuEventsChanged, .mikuSettingsChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        reload()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 40, left: 20, bottom: 20, right: 20)
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
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func reload() {
        window?.title = L10n.text("notebookTitle")
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let header = NSStackView(views: [
            MikuAvatarView(size: 44),
            NSTextField.mikuLabel(L10n.text("notebookTitle"), size: 18, weight: .bold, color: MikuTheme.deepTeal)
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        stack.addArrangedSubview(header)

        let daysCard = card(symbol: "calendar", title: L10n.text("specialDaysTitle"), body: specialDayRows())
        let diaryCard = card(symbol: "book.closed", title: L10n.text("diaryTitle"), body: diaryRows())
        for card in [daysCard, diaryCard] {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    private var languageCode: String { AppLanguage.resolved.rawValue }

    private func specialDayRows() -> [NSView] {
        let calendar = EventCalendar.shared
        let memory = CompanionMemory.shared
        let now = Date()
        let firstMet = memory.isEnabled ? memory.firstMet : nil
        var rows: [NSView] = []
        let today = SpecialDays.today(now, events: calendar.events, firstMet: firstMet)
        for day in today {
            rows.append(label("🎉 " + L10n.text("specialToday") + " " + SpecialDays.name(day, language: languageCode), size: 13, weight: .semibold, color: MikuTheme.pink))
        }
        let soon = SpecialDays.upcoming(now, within: 60, events: calendar.events, firstMet: firstMet)
        for day in soon {
            let days = day.daysUntil(from: now)
            rows.append(label("• \(SpecialDays.name(day, language: languageCode))  \(SpecialDays.range(day, language: languageCode))  " + L10n.format("specialInDays", String(days)), size: 12.5))
        }
        if today.isEmpty && soon.isEmpty {
            rows.append(label(L10n.text("specialNone"), size: 12.5, color: MikuTheme.secondaryText))
        }
        // Event dates from the official sites (beyond the next 60 days too).
        let soonStarts = Set(soon.map(\.start))
        let known = SpecialDays.nextFetched(now, events: calendar.events).filter { !soonStarts.contains($0.start) && !$0.isOn(now) }
        for day in known {
            rows.append(label("• \(SpecialDays.name(day, language: languageCode))  \(SpecialDays.range(day, language: languageCode))", size: 12.5))
        }
        let knownKinds = Set(SpecialDays.nextFetched(now, events: calendar.events).map(\.key))
        for kind in ["magicalMirai", "snowMiku"] where !knownKinds.contains(kind) {
            let name = SpecialDays.name(SpecialDay(key: kind, start: now, end: now), language: languageCode)
            rows.append(label("• \(name)  " + L10n.text("eventNotAnnounced"), size: 12.5, color: MikuTheme.secondaryText))
        }

        var status: String
        if calendar.isChecking {
            status = L10n.text("eventChecking")
        } else if let checked = calendar.lastChecked {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            status = L10n.format("eventChecked", formatter.string(from: checked))
        } else {
            status = L10n.text("eventNeverChecked")
        }
        let failed = calendar.lastResult.values.contains { !["ok", "nothing", "missing"].contains($0) }
        if failed { status += " " + L10n.text("eventCheckFailed") }
        let check = MikuPillButton(frame: .zero)
        check.title = L10n.text("eventCheckNow")
        check.style = .soft
        check.symbolName = "arrow.clockwise"
        check.controlHeight = 24
        check.font = MikuTheme.font(12, .semibold)
        check.target = self
        check.action = #selector(checkEvents)
        let footer = NSStackView(views: [label(status, size: 11.5, color: MikuTheme.secondaryText), check])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        rows.append(footer)
        return rows
    }

    private func diaryRows() -> [NSView] {
        let memory = CompanionMemory.shared
        guard memory.isEnabled else { return [label(L10n.text("diaryMemoryOff"), size: 12.5, color: MikuTheme.secondaryText)] }
        let entries = memory.diary
        guard !entries.isEmpty else { return [label(L10n.text("diaryEmpty"), size: 12.5, color: MikuTheme.secondaryText)] }
        return entries.prefix(120).map { entry in
            let date = label(Self.displayDate(entry.day, language: languageCode), size: 12, weight: .bold, color: MikuTheme.deepTeal)
            let delete = MikuPillButton(frame: .zero)
            delete.style = .soft
            delete.symbolName = "xmark"
            delete.iconOnly = true
            delete.controlHeight = 20
            delete.toolTip = L10n.text("diaryDelete")
            delete.setAccessibilityLabel(L10n.text("diaryDelete"))
            delete.identifier = NSUserInterfaceItemIdentifier(entry.day)
            delete.target = self
            delete.action = #selector(deleteEntry(_:))
            let top = NSStackView(views: [date, delete])
            top.orientation = .horizontal
            top.alignment = .centerY
            top.spacing = 6
            let text = label(entry.text, size: 13)
            text.isSelectable = true
            let block = NSStackView(views: [top, text])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            return block
        }
    }

    static func displayDate(_ day: String, language: String) -> String {
        guard let date = SpecialDays.parseDay(day) else { return day }
        let formatter = DateFormatter()
        switch language {
        case "en":
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE, d MMMM yyyy"
        case "ja":
            formatter.locale = Locale(identifier: "ja_JP")
            formatter.dateFormat = "yyyy年M月d日（EEE）"
        default:
            formatter.locale = Locale(identifier: "zh_Hant")
            formatter.dateFormat = "yyyy年M月d日 EEEE"
        }
        return formatter.string(from: date)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = MikuTheme.primaryText) -> NSTextField {
        let label = NSTextField.mikuLabel(text, size: size, weight: weight, color: color)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 360
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func card(symbol: String, title: String, body: [NSView]) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = MikuTheme.teal
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let titleRow = NSStackView(views: [icon, NSTextField.mikuLabel(title, size: 14, weight: .bold, color: MikuTheme.deepTeal)])
        titleRow.orientation = .horizontal
        titleRow.spacing = 6
        let content = NSStackView(views: [titleRow] + body)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = MikuCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        return card
    }

    @objc private func checkEvents() {
        EventCalendar.shared.refresh()
        reload()
    }

    @objc private func deleteEntry(_ sender: NSButton) {
        guard let day = sender.identifier?.rawValue else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("diaryDeleteConfirm")
        alert.addButton(withTitle: L10n.text("cancel"))
        let delete = alert.addButton(withTitle: L10n.text("diaryDelete"))
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        CompanionMemory.shared.deleteDiary(day: day)
    }
}
