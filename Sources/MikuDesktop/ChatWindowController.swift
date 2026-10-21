import AppKit

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onReply: ((CompanionReply) -> Void)?
    var onThinking: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let ai: LocalAI
    private let memory = CompanionMemory.shared
    private var messages: [ChatMessage] = []
    private var failedText: String?
    private var failedImage: Data?
    private var isSending = false
    private var connectionTask: Task<Void, Never>?
    private var hasPositionedWindow = false

    // Header
    private let headerAvatar = MikuAvatarView(size: 40)
    private let nameLabel = NSTextField.mikuLabel("Miku", size: 16, weight: .bold)
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let clearButton = MikuPillButton(frame: .zero)
    private let settingsButton = MikuPillButton(frame: .zero)

    // Conversation
    private let scrollView = NSScrollView()
    private let messageStack = NSStackView()
    private let emptyState = NSStackView()
    private let greetingTitle = NSTextField.mikuLabel("", size: 18, weight: .bold, color: MikuTheme.deepTeal)
    private let greetingBody = NSTextField.mikuLabel("", size: 13, color: MikuTheme.secondaryText)
    private var suggestionButtons: [MikuPillButton] = []
    private var bubbleLabels: [NSTextField] = []
    private var typingRow: NSView?
    private var errorRow: NSView?

    // Input
    private let inputCard = MikuCardView()
    private let inputField = NSTextField()
    private let sendButton = MikuPillButton(frame: .zero)
    private let attachButton = MikuPillButton(frame: .zero)

    // A picture waiting to be sent
    private var pendingImage: Data?
    private let previewCard = MikuCardView()
    private let previewImage = NSImageView()
    private let removeImageButton = MikuPillButton(frame: .zero)
    private var pasteMonitor: Any?

    init(ai: LocalAI? = nil) {
        self.ai = ai ?? LocalAI(configuration: AIConfiguration.shared)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Miku"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 380, height: 460)
        window.isReleasedWhenClosed = false
        let dropView = ChatDropView()
        window.contentView = dropView
        super.init(window: window)
        dropView.onDropImage = { [weak self] data in self?.attach(data) }
        window.delegate = self
        hasPositionedWindow = window.setFrameAutosaveName("MikuChatWindow") && UserDefaults.standard.string(forKey: "NSWindow Frame MikuChatWindow") != nil
        buildUI()
        showEmptyState()
        restoreConversation()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryErased), name: .mikuMemoryErased, object: nil)
        // ⌘V with a picture on the clipboard attaches it instead of pasting text.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPaste = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "v"
            guard isPaste else { return event }
            let window = event.window
            let handled: Bool = MainActor.assumeIsolated { self?.pastePicture(in: window) ?? false }
            return handled ? nil : event
        }
    }

    /// Attaches a picture from the clipboard. Returns false when there's only text to paste.
    private func pastePicture(in eventWindow: NSWindow?) -> Bool {
        guard eventWindow === window, ChatImage.pasteboardHasPicture(.general) else { return false }
        if let data = ChatImage.jpeg(from: .general) {
            attach(data)
        } else {
            NSSound.beep()
        }
        return true
    }

    // MARK: - Pictures

    private func attach(_ data: Data) {
        guard !isSending else { return }
        pendingImage = data
        previewImage.image = NSImage(data: data)
        previewCard.isHidden = false
        updateSendButton()
        window?.makeFirstResponder(inputField)
    }

    @objc private func removePendingImage() {
        pendingImage = nil
        previewImage.image = nil
        previewCard.isHidden = true
        updateSendButton()
    }

    @objc private func chooseImage() {
        guard let window, !isSending else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                if let data = ChatImage.jpeg(contentsOf: url) {
                    self?.attach(data)
                } else {
                    self?.showError(L10n.text("imageUnreadable"))
                }
            }
        }
    }

    @objc private func memoryErased() {
        messages.removeAll()
        failedText = nil
        failedImage = nil
        removeErrorRow()
        if !isSending { showEmptyState() }
    }

    /// Picks up where you left off last time (only the latest turns are drawn).
    private func restoreConversation() {
        messages = memory.storedMessages
        guard !messages.isEmpty else { return }
        hideEmptyState()
        for message in messages.suffix(60) { appendBubble(message) }
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        refreshLocalization()
        if !hasPositionedWindow {
            window?.center()
            hasPositionedWindow = true
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputField)
        refreshConnectionStatus()
    }

    func refreshLocalization() {
        window?.title = "Miku"
        setPlaceholder()
        clearButton.toolTip = L10n.text("clearChat")
        clearButton.setAccessibilityLabel(L10n.text("clearChat"))
        settingsButton.toolTip = L10n.text("settingsButton")
        settingsButton.setAccessibilityLabel(L10n.text("settingsButton"))
        attachButton.toolTip = L10n.text("attachImage")
        attachButton.setAccessibilityLabel(L10n.text("attachImage"))
        removeImageButton.toolTip = L10n.text("removeImage")
        removeImageButton.setAccessibilityLabel(L10n.text("removeImage"))
        sendButton.toolTip = L10n.text("send")
        sendButton.setAccessibilityLabel(L10n.text("send"))
        greetingTitle.stringValue = L10n.text("chatGreetingTitle")
        greetingBody.stringValue = L10n.text("chatGreetingBody")
        for (index, button) in suggestionButtons.enumerated() {
            button.title = L10n.text("suggestion\(index + 1)")
        }
        refreshConnectionStatus()
    }

    // MARK: - Connection status

    private func refreshConnectionStatus() {
        connectionTask?.cancel()
        setStatus(color: MikuTheme.checking, text: L10n.text("statusChecking"))
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let result = await ai.checkConnection()
            guard !Task.isCancelled else { return }
            applyConnection(result)
        }
    }

    private func applyConnection(_ result: LocalAI.ConnectionCheck) {
        if result.reachable {
            let model = AIConfiguration.shared.model
            let verified = result.modelAvailable == true
            let color = verified ? MikuTheme.online : MikuTheme.checking
            let text = verified ? "\(L10n.text("statusOnline")) · \(model)" : result.message
            setStatus(color: color, text: text)
        } else {
            setStatus(color: MikuTheme.offline, text: L10n.text("statusOffline"))
            statusLabel.toolTip = result.message
        }
    }

    private func setStatus(color: NSColor, text: String) {
        statusDot.color = color
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    // MARK: - Sending

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // Let input methods (Chinese / Japanese) commit their candidate first.
        if textView.hasMarkedText() { return false }
        sendCurrentMessage()
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        updateSendButton()
    }

    @objc private func sendCurrentMessage() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isSending else { return }
        inputField.stringValue = ""
        removePendingImage()
        send(text, image: image)
    }

    @objc private func suggestionTapped(_ sender: MikuPillButton) {
        guard !isSending else { return }
        send(sender.title)
    }

    @objc private func retry() {
        guard let failedText else { return }
        send(failedText, image: failedImage, appendUser: false)
    }

    @objc private func clearChat() {
        guard !isSending else { return }
        messages.removeAll()
        failedText = nil
        memory.clearConversation()
        showEmptyState()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    private func send(_ text: String, image: Data? = nil, appendUser: Bool = true) {
        guard !isSending else { return }
        failedText = nil
        failedImage = nil
        removeErrorRow()
        hideEmptyState()
        let userMessage: ChatMessage
        if appendUser {
            let imageName = image.flatMap { memory.saveImage($0) }
            userMessage = ChatMessage(role: .user, text: text, imageName: imageName)
            messages.append(userMessage)
            appendBubble(userMessage, image: image.flatMap(NSImage.init(data:)))
        } else {
            userMessage = messages.last(where: { $0.role == .user && $0.text == text }) ?? ChatMessage(role: .user, text: text)
        }
        // A picture on its own still needs a sentence for the model to answer.
        let prompt = text.isEmpty && image != nil ? L10n.text("imagePrompt") : text
        // An apology can settle things before she answers, so the reply already knows.
        memory.noteUserMessage(text)
        let history = memory.recentHistory(from: completedHistory())
        let context = memory.context()
        memory.record(messages)
        setSending(true)

        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await ai.reply(to: prompt, image: image, history: history, memory: context)
                let assistantMessage = ChatMessage(role: .assistant, text: reply.text)
                setSending(false)
                messages.append(assistantMessage)
                appendBubble(assistantMessage)
                memory.record(messages)
                memory.didExchange(user: userMessage, reply: assistantMessage, ai: ai)
                onReply?(reply)
                if statusDot.color != MikuTheme.online { refreshConnectionStatus() }
            } catch {
                setSending(false)
                failedText = text
                failedImage = image
                let configuration = AIConfiguration.shared
                showError(LocalAI.message(for: error, endpoint: configuration.endpoint, model: configuration.model))
                refreshConnectionStatus()
            }
        }
    }

    /// Only user turns that received an answer are sent back as context, so a failed
    /// message never shows up as two consecutive user turns.
    private func completedHistory() -> [ChatMessage] {
        var result: [ChatMessage] = []
        for (index, message) in messages.enumerated() {
            if message.role == .assistant {
                result.append(message)
            } else if index + 1 < messages.count, messages[index + 1].role == .assistant {
                result.append(message)
            }
        }
        return result
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        inputField.isEnabled = !sending
        updateSendButton()
        suggestionButtons.forEach { $0.isEnabled = !sending }
        clearButton.isEnabled = !sending
        onThinking?(sending)
        if sending { showTypingIndicator() } else { removeTypingIndicator() }
        if !sending { window?.makeFirstResponder(inputField) }
    }

    private func updateSendButton() {
        let hasText = !inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = (hasText || pendingImage != nil) && !isSending
        attachButton.isEnabled = !isSending
    }

    // MARK: - Layout

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusDot, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .centerY
        let titleStack = NSStackView(views: [nameLabel, statusRow])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(clearButton, symbol: "sparkles", action: #selector(clearChat))
        configureIconButton(settingsButton, symbol: "gearshape.fill", action: #selector(openSettings))

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let headerStack = NSStackView(views: [headerAvatar, titleStack, spacer, clearButton, settingsButton])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill
        headerStack.alignment = .centerY
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerStack)

        let divider = MikuCardView()
        divider.fillColor = MikuTheme.cardBorder
        divider.borderColor = nil
        divider.cornerRadius = 0
        divider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(divider)

        // Messages
        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 10
        messageStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        messageStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(messageStack)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        buildEmptyState()

        // Input
        inputCard.fillColor = MikuTheme.inputBackground
        inputCard.cornerRadius = 23
        inputCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(inputCard)

        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = MikuTheme.font(14)
        inputField.textColor = MikuTheme.primaryText
        inputField.usesSingleLineMode = true
        inputField.cell?.wraps = false
        inputField.cell?.isScrollable = true
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputCard.addSubview(inputField)

        attachButton.symbolName = "photo"
        attachButton.iconOnly = true
        attachButton.controlHeight = 34
        attachButton.style = .soft
        attachButton.target = self
        attachButton.action = #selector(chooseImage)
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        inputCard.addSubview(attachButton)

        previewCard.cornerRadius = 12
        previewCard.isHidden = true
        previewCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(previewCard)
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.wantsLayer = true
        previewImage.layer?.cornerRadius = 8
        previewImage.layer?.masksToBounds = true
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(previewImage)
        removeImageButton.symbolName = "xmark"
        removeImageButton.iconOnly = true
        removeImageButton.controlHeight = 22
        removeImageButton.style = .soft
        removeImageButton.target = self
        removeImageButton.action = #selector(removePendingImage)
        removeImageButton.translatesAutoresizingMaskIntoConstraints = false
        previewCard.addSubview(removeImageButton)

        sendButton.symbolName = "arrow.up"
        sendButton.iconOnly = true
        sendButton.controlHeight = 34
        sendButton.style = .primary
        sendButton.target = self
        sendButton.action = #selector(sendCurrentMessage)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        inputCard.addSubview(sendButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 50),
            headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),

            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputCard.topAnchor, constant: -10),

            messageStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            messageStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            messageStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            messageStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            inputCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            inputCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            inputCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            inputCard.heightAnchor.constraint(equalToConstant: 46),
            attachButton.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 6),
            attachButton.centerYAnchor.constraint(equalTo: inputCard.centerYAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 34),
            attachButton.heightAnchor.constraint(equalToConstant: 34),
            previewCard.leadingAnchor.constraint(equalTo: inputCard.leadingAnchor, constant: 4),
            previewCard.bottomAnchor.constraint(equalTo: inputCard.topAnchor, constant: -8),
            previewCard.widthAnchor.constraint(equalToConstant: 92),
            previewCard.heightAnchor.constraint(equalToConstant: 92),
            previewImage.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 6),
            previewImage.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -6),
            previewImage.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 6),
            previewImage.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor, constant: -6),
            removeImageButton.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 2),
            removeImageButton.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor, constant: -2),
            removeImageButton.widthAnchor.constraint(equalToConstant: 22),
            removeImageButton.heightAnchor.constraint(equalToConstant: 22),
            inputField.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 6),
            inputField.centerYAnchor.constraint(equalTo: inputCard.centerYAnchor),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            sendButton.trailingAnchor.constraint(equalTo: inputCard.trailingAnchor, constant: -6),
            sendButton.centerYAnchor.constraint(equalTo: inputCard.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 34),
            sendButton.heightAnchor.constraint(equalToConstant: 34)
        ])

        refreshLocalization()
        updateSendButton()
    }

    private func configureIconButton(_ button: MikuPillButton, symbol: String, action: Selector) {
        button.symbolName = symbol
        button.iconOnly = true
        button.style = .soft
        button.controlHeight = 30
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func setPlaceholder() {
        inputField.placeholderAttributedString = NSAttributedString(string: L10n.text("messagePlaceholder"), attributes: [
            .font: MikuTheme.font(14),
            .foregroundColor: MikuTheme.secondaryText
        ])
    }

    private func buildEmptyState() {
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let bigAvatar = MikuAvatarView(size: 84)
        greetingTitle.alignment = .center
        greetingBody.alignment = .center
        greetingBody.maximumNumberOfLines = 0
        greetingBody.lineBreakMode = .byWordWrapping
        greetingBody.preferredMaxLayoutWidth = 280

        let chips = NSStackView()
        chips.orientation = .vertical
        chips.alignment = .centerX
        chips.spacing = 8
        for index in 1...3 {
            let chip = MikuPillButton(title: L10n.text("suggestion\(index)"), symbolName: nil, style: .soft, target: self, action: #selector(suggestionTapped(_:)))
            chip.font = MikuTheme.font(13, .medium)
            chip.controlHeight = 30
            suggestionButtons.append(chip)
            chips.addArrangedSubview(chip)
        }

        let topSpacer = NSView()
        topSpacer.translatesAutoresizingMaskIntoConstraints = false
        topSpacer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        emptyState.addArrangedSubview(topSpacer)
        emptyState.addArrangedSubview(bigAvatar)
        emptyState.setCustomSpacing(14, after: bigAvatar)
        emptyState.addArrangedSubview(greetingTitle)
        emptyState.addArrangedSubview(greetingBody)
        emptyState.setCustomSpacing(18, after: greetingBody)
        emptyState.addArrangedSubview(chips)
    }

    private func showEmptyState() {
        for view in messageStack.arrangedSubviews {
            messageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bubbleLabels.removeAll()
        typingRow = nil
        errorRow = nil
        messageStack.addArrangedSubview(emptyState)
        emptyState.widthAnchor.constraint(equalTo: messageStack.widthAnchor, constant: -32).isActive = true
    }

    private func hideEmptyState() {
        guard emptyState.superview != nil else { return }
        messageStack.removeArrangedSubview(emptyState)
        emptyState.removeFromSuperview()
    }

    // MARK: - Rows

    private func appendBubble(_ message: ChatMessage, image: NSImage? = nil) {
        let isUser = message.role == .user
        let picture = image ?? message.imageName.flatMap { memory.imageData(named: $0) }.flatMap(NSImage.init(data:))
        if let picture {
            addRow(content: pictureBubble(picture), fromMiku: !isUser)
            if message.text.isEmpty { return }
        }
        let label = NSTextField(wrappingLabelWithString: message.text)
        label.font = MikuTheme.font(14)
        label.textColor = isUser ? .white : MikuTheme.primaryText
        label.isSelectable = true
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = bubbleTextWidth()
        label.translatesAutoresizingMaskIntoConstraints = false
        bubbleLabels.append(label)

        let bubble = MikuCardView()
        bubble.fillColor = isUser ? MikuTheme.userBubble : MikuTheme.mikuBubble
        bubble.borderColor = nil
        bubble.cornerRadius = 16
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -13),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9)
        ])

        addRow(content: bubble, fromMiku: !isUser)
    }

    /// A sent picture, shown at most 220 pt wide with its own proportions.
    private func pictureBubble(_ image: NSImage) -> NSView {
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        let size = image.size
        let width = min(220, max(60, size.width))
        let height = size.width > 0 ? min(260, width * size.height / size.width) : width
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: width),
            view.heightAnchor.constraint(equalToConstant: height)
        ])
        return view
    }

    private func addRow(content: NSView, fromMiku: Bool) {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        var constraints = [
            content.topAnchor.constraint(equalTo: row.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ]
        if fromMiku {
            let avatar = MikuAvatarView(size: 26)
            row.addSubview(avatar)
            constraints += [
                avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                avatar.topAnchor.constraint(equalTo: row.topAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: avatar.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
                content.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -36)
            ]
        } else {
            constraints += [
                content.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                content.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 56)
            ]
        }
        NSLayoutConstraint.activate(constraints)
        if let typingRow, typingRow.superview != nil, row !== typingRow {
            // Keep the typing indicator last.
            let index = messageStack.arrangedSubviews.firstIndex(of: typingRow) ?? messageStack.arrangedSubviews.count
            messageStack.insertArrangedSubview(row, at: index)
        } else {
            messageStack.addArrangedSubview(row)
        }
        row.widthAnchor.constraint(equalTo: messageStack.widthAnchor, constant: -32).isActive = true
        scrollToBottom()
    }

    private func showTypingIndicator() {
        removeTypingIndicator()
        let bubble = MikuCardView()
        bubble.fillColor = MikuTheme.mikuBubble
        bubble.borderColor = nil
        bubble.cornerRadius = 16
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let notes = NSStackView()
        notes.orientation = .horizontal
        notes.spacing = 5
        notes.translatesAutoresizingMaskIntoConstraints = false
        let start = CACurrentMediaTime()
        for (index, symbol) in ["♪", "♫", "♪"].enumerated() {
            let note = NSTextField.mikuLabel(symbol, size: 15, weight: .bold, color: MikuTheme.teal)
            note.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = start + Double(index) * 0.18
            pulse.fillMode = .backwards
            note.layer?.add(pulse, forKey: "pulse")
            notes.addArrangedSubview(note)
        }
        bubble.addSubview(notes)
        NSLayoutConstraint.activate([
            notes.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            notes.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            notes.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
            notes.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7)
        ])
        bubble.setAccessibilityLabel(L10n.text("sending"))
        bubble.setAccessibilityRole(.staticText)
        typingRow = nil
        addRow(content: bubble, fromMiku: true)
        typingRow = messageStack.arrangedSubviews.last
    }

    private func removeTypingIndicator() {
        guard let typingRow else { return }
        messageStack.removeArrangedSubview(typingRow)
        typingRow.removeFromSuperview()
        self.typingRow = nil
    }

    private func showError(_ message: String) {
        removeErrorRow()
        let card = MikuCardView()
        card.fillColor = MikuTheme.errorBackground
        card.borderColor = MikuTheme.pink.withAlphaComponent(0.35)
        card.cornerRadius = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = MikuTheme.pink
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = MikuTheme.font(12.5)
        label.textColor = MikuTheme.primaryText
        label.isSelectable = true
        label.preferredMaxLayoutWidth = bubbleTextWidth() - 30
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bubbleLabels.append(label)

        let retryButton = MikuPillButton(title: L10n.text("retry"), symbolName: "arrow.clockwise", style: .accent, target: self, action: #selector(retry))
        retryButton.controlHeight = 26
        retryButton.font = MikuTheme.font(12, .semibold)
        retryButton.horizontalPadding = 10

        let textColumn = NSStackView(views: [label, retryButton])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 8

        let content = NSStackView(views: [icon, textColumn])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        addRow(content: card, fromMiku: true)
        errorRow = messageStack.arrangedSubviews.last
    }

    private func removeErrorRow() {
        guard let errorRow else { return }
        messageStack.removeArrangedSubview(errorRow)
        errorRow.removeFromSuperview()
        self.errorRow = nil
    }

    private func bubbleTextWidth() -> CGFloat {
        let width = window?.contentView?.bounds.width ?? 420
        return max(200, min(460, width - 32 - 34 - 36 - 26))
    }

    func windowDidResize(_ notification: Notification) {
        let width = bubbleTextWidth()
        for label in bubbleLabels { label.preferredMaxLayoutWidth = width }
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let documentView = scrollView.documentView else { return }
            documentView.layoutSubtreeIfNeeded()
            let clip = scrollView.contentView
            let target = NSPoint(x: 0, y: max(0, documentView.frame.height - clip.bounds.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                clip.animator().setBoundsOrigin(target)
            }
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
