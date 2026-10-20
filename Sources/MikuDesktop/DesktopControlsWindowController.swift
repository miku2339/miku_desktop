import AppKit
import CoreGraphics

/// A small "♪" grip; dragging it moves the floating control bar.
private final class GripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let note = NSAttributedString(string: "♪", attributes: [
            .font: MikuTheme.font(17, .bold),
            .foregroundColor: MikuTheme.teal
        ])
        let size = note.size()
        note.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

@MainActor
final class DesktopControlsWindowController: NSWindowController, NSWindowDelegate {
    var onOpenChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private static let originKey = "desktopControlsOrigin"
    private let chatButton = MikuPillButton(frame: .zero)
    private let settingsButton = MikuPillButton(frame: .zero)
    private var screenObserver: NSObjectProtocol?
    private var isRestoringPosition = false

    init() {
        let panel = DesktopPanel(
            contentRect: CGRect(x: 0, y: 0, width: 190, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Miku Desktop"
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        super.init(window: panel)
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 23
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = MikuTheme.teal.withAlphaComponent(0.45).cgColor
        panel.contentView = background

        let grip = GripView()
        grip.translatesAutoresizingMaskIntoConstraints = false

        chatButton.style = .primary
        chatButton.symbolName = "bubble.left.and.bubble.right.fill"
        chatButton.controlHeight = 32
        chatButton.target = self
        chatButton.action = #selector(openChat)
        chatButton.setAccessibilityIdentifier("desktop-chat")

        settingsButton.style = .soft
        settingsButton.symbolName = "gearshape.fill"
        settingsButton.iconOnly = true
        settingsButton.controlHeight = 32
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.setAccessibilityIdentifier("desktop-settings")

        let stack = NSStackView(views: [grip, chatButton, settingsButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            grip.widthAnchor.constraint(equalToConstant: 22),
            grip.heightAnchor.constraint(equalToConstant: 32),
            settingsButton.widthAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        refreshLocalization()
        restorePosition()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restorePosition() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func refreshLocalization() {
        chatButton.title = L10n.text("chat")
        settingsButton.title = L10n.text("settingsButton")
        for button in [chatButton, settingsButton] {
            button.toolTip = button.title
            button.setAccessibilityLabel(button.title)
        }
        resizeToFit()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoringPosition, let window else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originKey)
    }

    private func resizeToFit() {
        guard let window, let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let width = 8 + 22 + 6 + chatButton.intrinsicContentSize.width + 6 + 32 + 7
        var frame = window.frame
        frame.size = NSSize(width: width, height: 46)
        isRestoringPosition = true
        window.setFrame(frame, display: true)
        isRestoringPosition = false
    }

    private func restorePosition() {
        guard let window else { return }
        isRestoringPosition = true
        defer { isRestoringPosition = false }
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: window.frame.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame.insetBy(dx: 20, dy: 10)) }) {
                window.setFrameOrigin(origin)
                return
            }
        }
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(CGPoint(
            x: max(visible.minX, visible.maxX - window.frame.width - 20),
            y: visible.minY + 20
        ))
    }

    @objc private func openChat() {
        onOpenChat?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}
