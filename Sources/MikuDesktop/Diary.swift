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
    private let eventSearch = NSSearchField()
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
        eventSearch.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

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
        let eventsCard = card(symbol: "ticket", title: eventText("演出活動", "Concert Events", "ライブ・イベント", "공연 일정"), body: eventRows())
        let diaryCard = card(symbol: "book.closed", title: L10n.text("diaryTitle"), body: diaryRows())
        for card in [eventsCard, daysCard, diaryCard] {
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
    }

    private var languageCode: String { AppLanguage.resolved.rawValue }

    private func eventText(_ zh: String, _ en: String, _ ja: String, _ ko: String) -> String {
        switch AppLanguage.resolved {
        case .english: return en
        case .japanese: return ja
        case .korean: return ko
        default: return zh
        }
    }

    private func eventRows() -> [NSView] {
        eventSearch.placeholderString = eventText("活動名稱或年份，例如 MIKU EXPO 2026", "Event or year, e.g. MIKU EXPO 2026", "イベント名・年（例：MIKU EXPO 2026）", "행사명 또는 연도 (예: MIKU EXPO 2026)")
        eventSearch.setAccessibilityIdentifier("event-query")
        eventSearch.target = self
        eventSearch.action = #selector(checkEvents)
        eventSearch.sendsSearchStringImmediately = false
        eventSearch.sendsWholeSearchString = true
        eventSearch.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let check = MikuPillButton(frame: .zero)
        check.title = EventCalendar.shared.isChecking ? L10n.text("eventChecking") : eventText("查詢", "Search", "検索", "조회")
        check.style = .soft
        check.symbolName = "magnifyingglass"
        check.controlHeight = 26
        check.isEnabled = !EventCalendar.shared.isChecking
        check.target = self
        check.action = #selector(checkEvents)
        let searchRow = NSStackView(views: [eventSearch, check])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        var rows: [NSView] = [searchRow]
        let calendar = EventCalendar.shared
        var status = calendar.isChecking ? L10n.text("eventChecking") : L10n.text("eventNeverChecked")
        if !calendar.isChecking, let checked = calendar.lastChecked {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            status = L10n.format("eventChecked", formatter.string(from: checked))
        }
        if calendar.lastResult.values.contains(where: { !["ok", "nothing", "missing"].contains($0) }) {
            status += " · " + eventText("部分來源暫時無法更新，保留已儲存的資料。", "Some sources could not be updated; saved records are retained.", "一部の情報を更新できません。保存済みの情報を表示します。", "일부 출처를 업데이트하지 못했어요. 저장된 정보를 유지해요.")
        }
        rows.append(label(status, size: 11, color: MikuTheme.secondaryText))
        let query = eventSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let filter = SpecialDays.eventQuery(in: query) else {
            rows.append(label(eventText("可查詢魔法未來、未來有你、MIKU EXPO 或 SNOW MIKU。", "Search for Magical Mirai, Miku With You, MIKU EXPO or SNOW MIKU.", "マジカルミライ、未来有你、MIKU EXPO、SNOW MIKUを検索できます。", "매지컬 미라이, Miku With You, MIKU EXPO, SNOW MIKU를 검색할 수 있어요."), size: 12, color: MikuTheme.secondaryText))
            return rows
        }
        let now = Date()
        let results = SpecialDays.queriedEvents(query: query, events: EventCalendar.shared.events, now: now)
        for kind in filter.kinds {
            let title = SpecialDays.name(SpecialDay(key: kind, start: now, end: now), language: languageCode)
            let heading = label(title, size: 12.5, weight: .semibold, color: MikuTheme.deepTeal)
            let official = eventSourceButton(title: eventText("官方網站", "Official Site", "公式サイト", "공식 사이트"), url: SpecialDays.eventSource(kind: kind))
            let header = NSStackView(views: [heading, official])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            rows.append(header)
            let matches = results.filter { $0.kind == kind }
            if matches.isEmpty {
                rows.append(label(eventText("目前尚未查到可確認的日程；可查看官方網站。", "No confirmed dates are available here yet. Check the official site.", "確認できる日程はまだありません。公式サイトをご確認ください。", "아직 확인된 일정이 없어요. 공식 사이트를 확인해 주세요."), size: 12, color: MikuTheme.secondaryText))
            }
            for event in matches.prefix(12) {
                guard let start = SpecialDays.parseDay(event.start), let end = SpecialDays.parseDay(event.end) else { continue }
                let day = SpecialDay(key: kind, start: start, end: end, city: event.city, venue: event.venue, fetched: true)
                let place = [event.city.map { SpecialDays.cityName($0, language: languageCode) }, event.venue].compactMap { $0 }.joined(separator: " · ")
                var summary = SpecialDays.range(day, language: languageCode)
                if !place.isEmpty { summary += " · " + place }
                if Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: now) {
                    summary += " · " + eventText("已結束", "Ended", "終了", "종료")
                }
                rows.append(label(summary, size: 12))
                rows.append(eventSourceButton(title: eventText("查看來源", "View Source", "出典を見る", "출처 보기"), url: URL(string: event.source)))
            }
            if matches.count > 12 {
                rows.append(label(eventText("僅顯示前 12 場，完整資訊請查看官方網站。", "Showing the first 12 shows. See the official site for all dates.", "先頭12公演を表示しています。全日程は公式サイトをご確認ください。", "첫 12개 공연만 표시해요. 전체 일정은 공식 사이트를 확인해 주세요."), size: 11, color: MikuTheme.secondaryText))
            }
        }
        return rows
    }

    private func eventSourceButton(title: String, url: URL?) -> NSButton {
        let button = MikuPillButton(frame: .zero)
        button.title = title
        button.style = .soft
        button.controlHeight = 22
        button.font = MikuTheme.font(11, .semibold)
        button.symbolName = "arrow.up.right"
        button.identifier = url.map { NSUserInterfaceItemIdentifier($0.absoluteString) }
        button.isEnabled = url != nil
        button.target = self
        button.action = #selector(openEventSource(_:))
        return button
    }

    @objc private func openEventSource(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw), url.scheme == "https",
              let host = url.host?.lowercased(),
              ["magicalmirai.com", "snowmiku.com", "mikuexpo.com", "www.scla.com.cn", "scla.com.cn"].contains(host) else { return }
        NSWorkspace.shared.open(url)
    }

    private func specialDayRows() -> [NSView] {
        let memory = CompanionMemory.shared
        let now = Date()
        let firstMet = memory.isEnabled ? memory.firstMet : nil
        var rows: [NSView] = []
        let today = SpecialDays.today(now, events: [], firstMet: firstMet)
        for day in today {
            rows.append(label("🎉 " + L10n.text("specialToday") + " " + SpecialDays.name(day, language: languageCode), size: 13, weight: .semibold, color: MikuTheme.pink))
        }
        let soon = SpecialDays.upcoming(now, within: 60, events: [], firstMet: firstMet)
        for day in soon {
            let days = day.daysUntil(from: now)
            rows.append(label("• \(SpecialDays.name(day, language: languageCode))  \(SpecialDays.range(day, language: languageCode))  " + L10n.format("specialInDays", String(days)), size: 12.5))
        }
        if today.isEmpty && soon.isEmpty {
            rows.append(label(L10n.text("specialNone"), size: 12.5, color: MikuTheme.secondaryText))
        }
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
        case "ko":
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월 d일 EEEE"
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

// MARK: - In Miku's notebook

extension DiaryWindowController: NotebookPage {
    func notebookPageWillAppear() {
        reload()
    }

    var notebookMaxWidth: CGFloat? { 680 }
}
