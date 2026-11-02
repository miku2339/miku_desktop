import AppKit

/// A page shown inside Miku's notebook window. Each page keeps its own window controller (and
/// its code) and hands its built contents to the notebook once.
@MainActor
protocol NotebookPage: NSWindowController {
    /// Refresh before the page comes into view.
    func notebookPageWillAppear()
    /// Save or stop what is in progress before another page takes over or the window closes.
    func notebookPageWillDisappear()
    /// The notebook window became key again (for example after visiting System Settings).
    func notebookPageDidBecomeKey()
    /// Extra space above a page that was laid out under a normal title bar.
    var notebookTopInset: CGFloat { get }
    /// The widest the page should be; nil to fill the space.
    var notebookMaxWidth: CGFloat? { get }
    /// Scrolls to one of the sections listed under the page in the sidebar.
    func notebookScroll(to section: String)
}

extension NotebookPage {
    func notebookPageWillAppear() {}
    func notebookPageWillDisappear() {}
    func notebookPageDidBecomeKey() {}
    var notebookTopInset: CGFloat { 0 }
    var notebookMaxWidth: CGFloat? { nil }
    func notebookScroll(to section: String) {}
}

/// Settings, the memory album, song knowledge and her diary in one window with a sidebar.
/// Chat stays a window of its own, next to her on the desktop.
@MainActor
final class NotebookWindowController: NSWindowController, NSWindowDelegate {
    enum Page: String, CaseIterable {
        case settings, album, songs, diary

        var symbol: String {
            switch self {
            case .settings: return "gearshape"
            case .album: return "photo.on.rectangle.angled"
            case .songs: return "music.note.list"
            case .diary: return "book.closed"
            }
        }

        var titleKey: String {
            switch self {
            case .settings: return "notebookSettings"
            case .album: return "notebookAlbum"
            case .songs: return "notebookSongs"
            case .diary: return "notebookDiary"
            }
        }
    }

    /// Creates (or returns) the controller behind a page.
    var pageProvider: ((Page) -> NotebookPage)?

    private static let lastPageKey = "notebook.lastPage"
    private static let sidebarWidth: CGFloat = 220

    private let sidebarStack = NSStackView()
    private let detail = NSView()
    private let titleLabel = NSTextField.mikuLabel("", size: 15, weight: .bold, color: MikuTheme.deepTeal)
    private var pageItems: [Page: NotebookSidebarItem] = [:]
    private var sectionItems: [String: NotebookSidebarItem] = [:]
    private let sectionStack = NSStackView()
    private var pages: [Page: NotebookPage] = [:]
    private var contents: [Page: NSView] = [:]
    private var activeConstraints: [NSLayoutConstraint] = []
    private(set) var currentPage: Page?
    /// The settings sections listed under Settings in the sidebar (their localization keys).
    private let settingsSections: [String]

    init(settingsSections: [String]) {
        self.settingsSections = settingsSections
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1000, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = MikuBackgroundView()
        super.init(window: window)
        window.delegate = self
        buildUI()
        window.setFrameAutosaveName("MikuNotebook")
        if window.frame.origin == .zero { window.center() }
        refreshLocalization()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Opens the notebook on `page` (the last one when nil), scrolled to a settings section.
    func show(_ page: Page? = nil, section: String? = nil) {
        let target = page
            ?? UserDefaults.standard.string(forKey: Self.lastPageKey).flatMap(Page.init(rawValue:))
            ?? .settings
        select(target)
        if let section { scrollSettings(to: section) }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The page's controller, created through `pageProvider` if needed.
    func page(_ page: Page) -> NotebookPage? {
        if let existing = pages[page] { return existing }
        guard let made = pageProvider?(page) else { return nil }
        pages[page] = made
        return made
    }

    func refreshLocalization() {
        window?.title = L10n.text("notebookTitle")
        titleLabel.stringValue = L10n.text("notebookTitle")
        for (page, item) in pageItems { item.label = L10n.text(page.titleKey) }
        for (key, item) in sectionItems { item.label = L10n.text(key) }
    }

    // MARK: - Pages

    private func select(_ target: Page) {
        guard let controller = page(target) else { return }
        let needsAppearance = currentPage != target || window?.isVisible != true
        if currentPage != target {
            if let currentPage, let previous = pages[currentPage] { previous.notebookPageWillDisappear() }
            contents.values.forEach { $0.isHidden = true }
            let view = content(for: target, controller: controller)
            view.isHidden = false
            currentPage = target
            UserDefaults.standard.set(target.rawValue, forKey: Self.lastPageKey)
            window?.makeFirstResponder(nil)
        }
        if needsAppearance { controller.notebookPageWillAppear() }
        for (page, item) in pageItems { item.isSelected = page == target }
        sectionStack.isHidden = target != .settings
    }

    /// Takes the page's built contents out of its own (never shown) window, once.
    private func content(for page: Page, controller: NotebookPage) -> NSView {
        if let existing = contents[page] { return existing }
        let view = controller.window?.contentView ?? NSView()
        controller.window?.contentView = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(view)
        var constraints = [
            view.topAnchor.constraint(equalTo: detail.topAnchor, constant: controller.notebookTopInset),
            view.bottomAnchor.constraint(equalTo: detail.bottomAnchor)
        ]
        if let maxWidth = controller.notebookMaxWidth {
            // Below windowSizeStayPut, so a narrow page never shrinks the window to fit itself.
            let fill = view.widthAnchor.constraint(equalTo: detail.widthAnchor)
            fill.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
            constraints += [
                view.centerXAnchor.constraint(equalTo: detail.centerXAnchor),
                view.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
                view.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor),
                fill
            ]
        } else {
            constraints += [
                view.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: detail.trailingAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        contents[page] = view
        return view
    }

    private func scrollSettings(to section: String) {
        pages[.settings]?.notebookScroll(to: section)
        for (key, item) in sectionItems { item.isSelected = key == section }
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let avatar = MikuAvatarView(size: 34)
        let header = NSStackView(views: [avatar, titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.addArrangedSubview(header)
        sidebarStack.setCustomSpacing(18, after: header)

        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 1

        for page in Page.allCases {
            let item = NotebookSidebarItem(symbol: page.symbol, level: 0)
            item.target = self
            item.action = #selector(pageClicked(_:))
            item.identifier = NSUserInterfaceItemIdentifier(page.rawValue)
            pageItems[page] = item
            sidebarStack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
            if page == .settings {
                for key in settingsSections {
                    let section = NotebookSidebarItem(symbol: nil, level: 1)
                    section.target = self
                    section.action = #selector(sectionClicked(_:))
                    section.identifier = NSUserInterfaceItemIdentifier(key)
                    sectionItems[key] = section
                    sectionStack.addArrangedSubview(section)
                    section.widthAnchor.constraint(equalTo: sectionStack.widthAnchor).isActive = true
                }
                sidebarStack.addArrangedSubview(sectionStack)
                sectionStack.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
                sidebarStack.setCustomSpacing(8, after: sectionStack)
            }
        }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = MikuTheme.cardBorder
        divider.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)
        contentView.addSubview(sidebar)
        contentView.addSubview(divider)
        contentView.addSubview(detail)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.topAnchor.constraint(equalTo: contentView.topAnchor),
            detail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            // Below the window buttons, which sit over the sidebar.
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 46),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14)
        ])
    }

    @objc private func pageClicked(_ sender: NotebookSidebarItem) {
        guard let raw = sender.identifier?.rawValue, let page = Page(rawValue: raw) else { return }
        select(page)
        if page != .settings { sectionItems.values.forEach { $0.isSelected = false } }
    }

    @objc private func sectionClicked(_ sender: NotebookSidebarItem) {
        guard let key = sender.identifier?.rawValue else { return }
        select(.settings)
        scrollSettings(to: key)
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        if let currentPage { pages[currentPage]?.notebookPageWillDisappear() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let currentPage { pages[currentPage]?.notebookPageDidBecomeKey() }
    }
}

/// A sidebar row: an icon and a title, highlighted in Miku's teal when selected. Drawn by hand
/// so every title starts at the same place whatever the icon's width.
final class NotebookSidebarItem: NSButton {
    var isSelected = false { didSet { needsDisplay = true } }
    var label = "" { didSet { needsDisplay = true; setAccessibilityLabel(label) } }
    private let level: Int
    private let icon: NSImage?
    private var hovering = false { didSet { needsDisplay = true } }

    /// Where the titles start, so icons of any width line up.
    private static let textX: CGFloat = 40

    init(symbol: String?, level: Int) {
        self.level = level
        icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: level == 0 ? 34 : 26).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || hovering {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 9, yRadius: 9)
            let alpha: CGFloat = isSelected ? (level == 0 ? 0.18 : 0.12) : 0.07
            MikuTheme.teal.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        let color = isSelected ? MikuTheme.deepTeal : (level == 0 ? MikuTheme.primaryText : MikuTheme.secondaryText)
        if let icon {
            let size = icon.size
            let rect = NSRect(x: 10 + (20 - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { frame in
                icon.draw(in: frame)
                color.set()
                frame.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }
        let font = level == 0 ? MikuTheme.font(14, isSelected ? .bold : .semibold) : MikuTheme.font(12.5, isSelected ? .semibold : .medium)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        let x = level == 0 ? Self.textX : Self.textX + 2
        text.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: bounds.width - x - 6, height: size.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
