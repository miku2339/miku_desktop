import AppKit
import CoreGraphics

@MainActor
final class DesktopControlsWindowController: NSWindowController {
    var onOpenChat: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let chatButton = NSButton()
    private let settingsButton = NSButton()
    private var screenObserver: NSObjectProtocol?

    init() {
        let panel = DesktopPanel(
            contentRect: CGRect(x: 0, y: 0, width: 260, height: 52),
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

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background

        configureButton(chatButton, symbol: "bubble.left.and.bubble.right", action: #selector(openChat))
        configureButton(settingsButton, symbol: "gearshape", action: #selector(openSettings))
        chatButton.setAccessibilityIdentifier("desktop-chat")
        settingsButton.setAccessibilityIdentifier("desktop-settings")

        let stack = NSStackView(views: [chatButton, settingsButton])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8)
        ])

        refreshLocalization()
        updatePosition()
        panel.orderFrontRegardless()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
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
    }

    private func configureButton(_ button: NSButton, symbol: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = action
    }

    private func updatePosition() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
