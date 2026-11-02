import AppKit

/// A page stand-in that records what the notebook asks of it.
@MainActor
private final class StubPage: NSWindowController, NotebookPage {
    var events: [String] = []
    var savedValue = ""
    var draft = ""
    let body = NSView()
    let maxWidth: CGFloat?

    init(maxWidth: CGFloat?) {
        self.maxWidth = maxWidth
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: window)
        window.contentView = body
    }

    required init?(coder: NSCoder) { fatalError() }

    func notebookPageWillAppear() {
        events.append("appear")
        draft = savedValue
    }
    func notebookPageWillDisappear() {
        events.append("disappear")
        savedValue = draft
    }
    func notebookScroll(to section: String) { events.append("scroll:\(section)") }
    var notebookMaxWidth: CGFloat? { maxWidth }
}

/// Miku's notebook: pages switch, keep their contents, save on leaving, and lay out sensibly.
@MainActor
enum NotebookChecks {
    static func run(_ expect: (Bool, String) -> Void) {
        UserDefaults.standard.removeObject(forKey: "notebook.lastPage")
        var pages: [NotebookWindowController.Page: StubPage] = [:]
        let notebook = NotebookWindowController(settingsSections: ["sectionScene", "sectionGeneral"])
        notebook.pageProvider = { page in
            if let existing = pages[page] { return existing }
            let made = StubPage(maxWidth: page == .settings ? 720 : nil)
            pages[page] = made
            return made
        }

        notebook.show()
        expect(notebook.currentPage == .settings, "the notebook opens on Settings the first time")
        let settings = pages[.settings]!
        expect(settings.events == ["appear"], "the page is told it is about to appear")
        expect(settings.body.window === notebook.window, "the page's contents move into the notebook window")
        expect(settings.window?.contentView !== settings.body, "the page's own window no longer holds them")

        notebook.window?.setContentSize(NSSize(width: 1080, height: 740))
        notebook.window?.contentView?.layoutSubtreeIfNeeded()
        expect(notebook.window?.contentView?.frame.width == 1080, "a narrow page never shrinks the window")
        expect(settings.body.frame.width <= 720, "Settings stays at most 720 points wide")
        let detailWidth = settings.body.superview?.frame.width ?? 0
        expect(abs(settings.body.frame.midX - detailWidth / 2) < 1, "a narrow page is centred")

        settings.draft = "uncommitted settings"
        notebook.show(.settings)
        expect(settings.draft == "uncommitted settings", "opening the visible page preserves its uncommitted fields")
        notebook.show(.settings, section: "sectionGeneral")
        expect(settings.draft == "uncommitted settings", "a section shortcut preserves uncommitted fields on the same page")
        expect(settings.events.last == "scroll:sectionGeneral", "a same-page section shortcut still scrolls")

        notebook.show(.album)
        notebook.window?.contentView?.layoutSubtreeIfNeeded()
        let album = pages[.album]!
        expect(settings.events.last == "disappear", "leaving Settings lets it save its fields")
        expect(settings.savedValue == "uncommitted settings", "switching pages saves the current field draft")
        expect(album.events == ["appear"], "the album appears")
        expect(album.body.frame.width == album.body.superview?.frame.width, "a wide page fills the space")
        expect(settings.body.isHidden && !album.body.isHidden, "only the current page is shown")
        expect(UserDefaults.standard.string(forKey: "notebook.lastPage") == "album", "the last page is remembered")

        notebook.show(.settings, section: "sectionGeneral")
        expect(settings.events.suffix(2) == ["appear", "scroll:sectionGeneral"], "a settings section is scrolled to")
        expect(album.events.last == "disappear", "leaving the album stops what it was doing")

        notebook.show()
        expect(notebook.currentPage == .settings, "with no page asked for, the last one opens")
        let created = pages.count
        notebook.show(.settings)
        expect(pages.count == created, "a page is created only once")

        settings.draft = "saved on close"
        notebook.window?.close()
        expect(settings.events.last == "disappear", "closing the notebook lets the current page save")
        expect(settings.savedValue == "saved on close", "closing the notebook saves its field draft")
        settings.savedValue = "updated while closed"
        notebook.show(.settings)
        expect(settings.draft == "updated while closed", "reopening the notebook refreshes the current page")
        expect(settings.events.suffix(2) == ["disappear", "appear"], "reopening follows the previous close with a fresh appearance")
        notebook.window?.close()
        UserDefaults.standard.removeObject(forKey: "notebook.lastPage")
    }
}
