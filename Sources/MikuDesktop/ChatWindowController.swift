import AppKit

@MainActor
final class ChatWindowController: NSWindowController, NSTextFieldDelegate {
    var onReply: ((CompanionReply) -> Void)?

    private let ai: LocalAI
    private var messages: [ChatMessage] = []
    private var failedText: String?
    private var isSending = false

    private let messageStack = NSStackView()
    private let scrollView = NSScrollView()
    private let inputField = NSTextField()
    private let sendButton = NSButton()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton()

    init(ai: LocalAI? = nil) {
        self.ai = ai ?? LocalAI(configuration: AIConfiguration.shared)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Miku"
        window.minSize = NSSize(width: 360, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        refreshLocalization()
        showWindow(nil)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputField)
    }

    func refreshLocalization() {
        window?.title = "Miku"
        inputField.placeholderString = L10n.text("messagePlaceholder")
        sendButton.title = L10n.text("send")
        retryButton.title = L10n.text("retry")
        setSending(isSending, failed: failedText != nil && !isSending)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int,
              movement == NSReturnTextMovement else { return }
        sendCurrentMessage()
    }

    @objc private func sendCurrentMessage() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputField.stringValue = ""
        send(text)
    }

    @objc private func retry() {
        guard let failedText else { return }
        send(failedText, appendUser: false)
    }

    private func send(_ text: String, appendUser: Bool = true) {
        guard !isSending else { return }
        failedText = nil
        setSending(true)
        let history = messages
        if appendUser {
            let userMessage = ChatMessage(role: .user, text: text)
            messages.append(userMessage)
            appendBubble(userMessage)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await ai.reply(to: text, history: history)
                let assistantMessage = ChatMessage(role: .assistant, text: reply.text)
                messages.append(assistantMessage)
                appendBubble(assistantMessage)
                setSending(false)
                onReply?(reply)
            } catch {
                failedText = text
                setSending(false, failed: true)
            }
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 10
        messageStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        messageStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            messageStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            messageStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            messageStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        root.addArrangedSubview(scrollView)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        retryButton.title = L10n.text("retry")
        retryButton.bezelStyle = .inline
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isHidden = true
        statusRow.addArrangedSubview(progressIndicator)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(retryButton)
        root.addArrangedSubview(statusRow)

        let inputRow = NSStackView()
        inputRow.orientation = .horizontal
        inputRow.spacing = 8
        inputField.placeholderString = L10n.text("messagePlaceholder")
        inputField.delegate = self
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.title = L10n.text("send")
        sendButton.keyEquivalent = "\r"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendCurrentMessage)
        inputRow.addArrangedSubview(inputField)
        inputRow.addArrangedSubview(sendButton)
        root.addArrangedSubview(inputRow)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }

    private func appendBubble(_ message: ChatMessage) {
        let label = NSTextField(wrappingLabelWithString: message.text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        label.backgroundColor = message.role == .user
            ? NSColor.controlAccentColor.withAlphaComponent(0.16)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        label.drawsBackground = true
        label.isBezeled = false
        label.isEditable = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 330
        label.alignment = message.role == .user ? .right : .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        if message.role == .user {
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(label)
        } else {
            row.addArrangedSubview(label)
            row.addArrangedSubview(NSView())
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        messageStack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: messageStack.widthAnchor, constant: -16),
            label.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.82)
        ])
        scrollToBottom()
    }

    private func setSending(_ sending: Bool, failed: Bool = false) {
        isSending = sending
        inputField.isEnabled = !sending
        sendButton.isEnabled = !sending
        retryButton.isHidden = !failed
        statusLabel.stringValue = failed ? L10n.text("replyFailed") : (sending ? L10n.text("sending") : "")
        statusLabel.textColor = failed ? .systemRed : .secondaryLabelColor
        if sending { progressIndicator.startAnimation(nil) } else { progressIndicator.stopAnimation(nil) }
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let documentView = scrollView.documentView else { return }
            documentView.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
