import AppKit

@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onReply: ((CompanionReply) -> Void)?
    var onVoiceReply: ((CompanionReply) -> Void)?
    var onVoiceReplyBegan: (() -> Void)?
    var onVoicePhrase: ((String) -> Void)?
    var onVoiceCallStop: (() -> Void)?
    /// A song you asked her to play; called just before her reply is delivered.
    var onPlayMusic: ((MusicPlan) -> Void)?
    var onThinking: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onCallOver: (() -> Void)?
    var onOpenAlbum: (() -> Void)?
    var onTakeMemoryPhoto: (() -> Void)?
    var onOpenKnowledge: (() -> Void)?
    var onGameEvent: ((GameEvent) -> Void)?

    private let ai: LocalAI
    private let memory = CompanionMemory.shared
    private var messages: [ChatMessage] = []
    private var failedText: String?
    private var failedImage: Data?
    private var isSending = false
    private var chatTask: Task<Void, Never>?
    private let bedtimeScheduler = BedtimeScheduler()
    private var conversationGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var hasPositionedWindow = false
    private let voiceCall = VoiceCallController()
    private var sendingVoiceTurn = false
    private var interruptingVoiceCall = false
    private var awaitingVoicePlayback = false
    private var voiceReplyToken: UUID?
    private var voiceReplyStyle = MikuSpeech.VoiceStyle.neutral
    private var voiceReplyBuffer = VoiceReplyBuffer()
    private var voiceReplyProgress = VoiceReplyProgress()
    private var voiceExchangeUser: ChatMessage?
    private var voiceExchangeReplyID: UUID?
    private var messageLabels: [UUID: NSTextField] = [:]
    private var pendingVoiceBedtime: (sleepRevision: Int, generation: Int, requiresLateEvening: Bool)?

    // Header
    private let headerAvatar = MikuAvatarView(size: 40)
    private let nameLabel = NSTextField.mikuLabel("Miku", size: 16, weight: .bold)
    private let statusDot = StatusDotView()
    private let statusLabel = NSTextField.mikuLabel("", size: 11.5, color: MikuTheme.secondaryText)
    private let settingsButton = MikuPillButton(frame: .zero)
    private let gameButton = MikuPillButton(frame: .zero)
    private let companionButton = MikuPillButton(frame: .zero)
    private let callButton = MikuPillButton(frame: .zero)
    /// Mutes Miku's voice in one click (shown only while reading aloud is on).
    private let muteButton = MikuPillButton(frame: .zero)
    private var activeGame: GameSession?
    private var choiceRow: NSView?
    private var lastReplyText: String?

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

    // Voice call
    private let voiceCallCard = MikuCardView()
    private let voiceCallStatusLabel = NSTextField.mikuLabel("", size: 12.5, weight: .semibold)
    private let voiceCallSubtitleLabel = NSTextField.mikuLabel("", size: 12)
    private let voiceCallPrivacyLabel = NSTextField.mikuLabel("", size: 10.5, color: MikuTheme.secondaryText)
    private let voiceCallMicButton = MikuPillButton(frame: .zero)
    private let voiceCallEndButton = MikuPillButton(frame: .zero)
    private let voiceCallInterruptButton = MikuPillButton(frame: .zero)
    private let voiceCallLanguageButton = MikuPillButton(frame: .zero)
    private var messagesBelowHeader: NSLayoutConstraint?
    private var messagesBelowVoiceCall: NSLayoutConstraint?

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
        voiceCall.onChange = { [weak self] in self?.voiceCallChanged() }
        voiceCall.onInterrupt = { [weak self] in self?.interruptVoiceOutput() }
        voiceCall.onUtterance = { [weak self] text in
            guard let self, voiceCall.isActive, !isSending else { return }
            send(text, voiceOrigin: true)
        }
        if let value = UserDefaults.standard.string(forKey: "voiceCallLanguage"),
           let language = VoiceCallLanguage(rawValue: value) {
            voiceCall.selectLanguage(language)
        }
        showEmptyState()
        restoreConversation()
        NotificationCenter.default.addObserver(self, selector: #selector(memoryErased), name: .mikuMemoryErased, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshMuteButton), name: .mikuSpeechMuteChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryRestored), name: .mikuMemoryRestored, object: nil)
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

    /// A line she said on her own (she noticed what you were doing).
    func receiveProactive(_ reply: CompanionReply) {
        guard !voiceCall.isActive else { return }
        lastReplyText = reply.text
        let message = ChatMessage(role: .assistant, text: reply.text)
        hideEmptyState()
        messages.append(message)
        appendBubble(message)
        memory.record(messages)
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    /// Whether you're in the middle of talking to her here.
    var isChatting: Bool {
        voiceCall.isActive || isSending || (window?.isKeyWindow == true && !inputField.stringValue.isEmpty)
    }

    var isVoiceCallActive: Bool { voiceCall.isActive }

    func receiveVoicePlayback(_ event: MikuSpeech.PlaybackEvent) {
        guard voiceCall.isActive else { return }
        switch event {
        case .started, .streamingStarted:
            guard awaitingVoicePlayback else {
                pauseVoiceCallForExternalAudio(cancelPendingReply: true)
                return
            }
            voiceReplyProgress.started()
            voiceCall.playbackStarted()
        case .streamingStopped:
            break
        case .ended:
            guard awaitingVoicePlayback else { return }
            awaitingVoicePlayback = false
            settleVoiceExchange(completed: true)
            if let bedtime = pendingVoiceBedtime {
                let sleep = SleepSchedule.shared
                let shouldSleep = bedtime.generation == conversationGeneration
                    && bedtime.sleepRevision == sleep.revision
                    && (!bedtime.requiresLateEvening || SleepSchedule.isLateEvening())
                pendingVoiceBedtime = nil
                if shouldSleep {
                    endVoiceCall()
                    sleep.goToBed()
                    return
                }
            }
            voiceCall.playbackFinished()
        case .failed:
            guard awaitingVoicePlayback else { return }
            awaitingVoicePlayback = false
            pendingVoiceBedtime = nil
            settleVoiceExchange(completed: false)
            voiceReplyToken = nil
            conversationGeneration &+= 1
            chatTask?.cancel()
            chatTask = nil
            sendingVoiceTurn = false
            memory.discardPendingConfessionDecision()
            setSending(false)
            onVoiceCallStop?()
            voiceCall.replyFailed()
        case .interrupted:
            if !interruptingVoiceCall { endVoiceCall() }
        }
    }

    func receiveVoiceSegmentFinished(_ text: String) {
        guard voiceCall.isActive, awaitingVoicePlayback else { return }
        voiceReplyProgress.segmentFinished(text)
    }

    func pauseVoiceCallForExternalAudio(cancelPendingReply: Bool = false) {
        guard voiceCall.isActive else { return }
        if !voiceCall.isMicrophoneMuted { voiceCall.toggleMicrophone() }
        if cancelPendingReply, sendingVoiceTurn || awaitingVoicePlayback {
            settleVoiceExchange(completed: false)
            pendingVoiceBedtime = nil
            awaitingVoicePlayback = false
            conversationGeneration &+= 1
            chatTask?.cancel()
            chatTask = nil
            sendingVoiceTurn = false
            memory.discardPendingConfessionDecision()
            cancelPendingBedtime()
            setSending(false)
            voiceCall.interruptAndListen()
        }
    }

    func endVoiceCall() {
        let wasActive = voiceCall.isActive || sendingVoiceTurn
        settleVoiceExchange(completed: false)
        pendingVoiceBedtime = nil
        awaitingVoicePlayback = false
        voiceReplyToken = nil
        voiceReplyBuffer = VoiceReplyBuffer()
        voiceCall.end()
        if sendingVoiceTurn { cancelActiveConversation(endingVoiceCall: false) }
        if wasActive {
            onVoiceCallStop?()
            MikuSpeech.shared.stop()
        }
        refreshVoiceCallUI()
    }

    func windowWillClose(_ notification: Notification) {
        endVoiceCall()
    }

    // MARK: - Mini games

    enum GameEvent {
        /// Her rock-paper-scissors hand and how the round went for her.
        case rps(hand: String, outcome: String)
        /// Open the rhythm game window.
        case rhythm
    }

    @objc private func showGames(_ sender: NSButton) {
        let menu = NSMenu()
        for game in MiniGame.allCases {
            let item = NSMenuItem(title: L10n.text(game.titleKey), action: #selector(gameChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = game.rawValue
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func gameChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let game = MiniGame(rawValue: raw) else { return }
        startGame(game)
    }

    /// Starts a game in the chat (also when you ask for one by typing).
    func startGame(_ game: MiniGame) {
        guard !isSending else { return }
        endVoiceCall()
        MikuSpeech.shared.stop()
        hideEmptyState()
        removeChoiceRow()
        activeGame = nil
        switch game {
        case .rps:
            let session = RPSSession()
            activeGame = session
            showGameLines(session.start())
        case .quiz:
            let session = QuizSession()
            activeGame = session
            showGameLines(session.start())
        case .rhythm:
            showGameLines([GameLine(
                text: MiniGame.text("打拍子！數完 1、2、3、4，就跟著拍子按空白鍵～", yue: "打拍子！數完 1、2、3、4，就跟住拍子撳空白鍵～", "Rhythm time! After 1, 2, 3, 4, tap the space bar on every beat~", "リズムゲーム！1、2、3、4のあと、拍に合わせてスペースキーを押してね～", "리듬 게임이야! 하나, 둘, 셋, 넷을 세고 박자에 맞춰 스페이스 바를 눌러 줘~"),
                emotion: "happy", action: "clap"
            )])
            onGameEvent?(.rhythm)
        }
    }

    /// The rhythm game finished: she tells you how it went.
    func finishRhythmGame(score: Int) {
        memory.recordPlay()
        showGameLines([RhythmJudge.comment(score: score)])
    }

    private func showGameLines(_ lines: [GameLine]) {
        for line in lines {
            let message = ChatMessage(role: .assistant, text: line.text)
            messages.append(message)
            appendBubble(message)
        }
        memory.record(messages)
        if let last = lines.last {
            lastReplyText = last.text
            onReply?(CompanionReply(text: last.text, emotion: last.emotion, action: last.rps == nil ? last.action : "idle"))
        }
        if let rps = lines.compactMap(\.rps).last {
            onGameEvent?(.rps(hand: rps.hand, outcome: rps.outcome))
        }
        if let choices = lines.last?.choices, !choices.isEmpty {
            showChoices(choices)
        }
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    private func showChoices(_ choices: [GameLine.Choice]) {
        removeChoiceRow()
        let buttons = choices.map { choice -> NSView in
            let button = MikuPillButton(frame: .zero)
            button.title = choice.title
            button.style = .soft
            button.controlHeight = 28
            button.font = MikuTheme.font(13, .semibold)
            button.identifier = NSUserInterfaceItemIdentifier(choice.id)
            button.target = self
            button.action = #selector(choiceTapped(_:))
            return button
        }
        let stack = NSStackView(views: buttons)
        // Long answers (song titles) go one per line; short ones side by side.
        let long = choices.contains { $0.title.count > 8 }
        stack.orientation = long ? .vertical : .horizontal
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addRow(content: stack, fromMiku: true)
        choiceRow = stack.superview
    }

    private func removeChoiceRow() {
        guard let choiceRow else { return }
        messageStack.removeArrangedSubview(choiceRow)
        choiceRow.removeFromSuperview()
        self.choiceRow = nil
    }

    @objc private func choiceTapped(_ sender: NSButton) {
        guard let game = activeGame, let id = sender.identifier?.rawValue, !isSending else { return }
        MikuSpeech.shared.stop()
        removeChoiceRow()
        let (said, lines) = game.choose(id)
        guard !lines.isEmpty else { return }
        let message = ChatMessage(role: .user, text: said)
        messages.append(message)
        appendBubble(message)
        memory.record(messages)
        if game.isOver {
            activeGame = nil
            memory.recordPlay()
        }
        // A short pause, as if she's thinking (or throwing her hand).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated { self?.showGameLines(lines) }
        }
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

    @objc private func memoryRestored() {
        cancelActiveConversation(preserveVoiceHistory: false)
        failedText = nil
        failedImage = nil
        showEmptyState()
        restoreConversation()
    }

    @objc private func memoryErased() {
        cancelActiveConversation(preserveVoiceHistory: false)
        messages.removeAll()
        lastReplyText = nil
        failedText = nil
        failedImage = nil
        showEmptyState()
    }

    /// Picks up where you left off last time (only the latest turns are drawn).
    private func restoreConversation() {
        messages = memory.storedMessages
        lastReplyText = messages.last(where: { $0.role == .assistant })?.text
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
        gameButton.toolTip = L10n.text("gamesMenu")
        gameButton.setAccessibilityLabel(L10n.text("gamesMenu"))
        companionButton.toolTip = L10n.text("companionTools")
        companionButton.setAccessibilityLabel(L10n.text("companionTools"))
        refreshMuteButton()
        refreshVoiceCallUI()
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

    // MARK: - Voice call

    @objc private func toggleVoiceCall() {
        if voiceCall.isActive {
            endVoiceCall()
            return
        }
        guard !isSending else { return }
        let speech = MikuSpeech.shared
        guard speech.enabled else {
            showError(L10n.text("voiceCallNeedsSpeech"))
            return
        }
        guard speech.hasConfiguredModel else {
            showError(L10n.text("voiceCallNeedsModel"))
            return
        }
        guard !speech.isMuted else {
            showError(L10n.text("voiceCallNeedsUnmute"))
            return
        }
        cancelPendingBedtime()
        pendingVoiceBedtime = nil
        awaitingVoicePlayback = false
        activeGame = nil
        removeChoiceRow()
        removeErrorRow()
        onVoiceCallStop?()
        speech.stop()
        let sleep = SleepSchedule.shared
        if sleep.isAsleep() { sleep.wake(minutes: 30) }
        voiceCall.start()
    }

    @objc private func toggleVoiceMicrophone() {
        voiceCall.toggleMicrophone()
    }

    private func voiceLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        for language in VoiceCallLanguage.allCases {
            let item = NSMenuItem(title: L10n.text(language.localizationKey), action: #selector(voiceLanguageChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == voiceCall.language ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showVoiceLanguageMenu(_ sender: NSButton) {
        voiceLanguageMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func voiceLanguageChosen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let language = VoiceCallLanguage(rawValue: value) else { return }
        UserDefaults.standard.set(value, forKey: "voiceCallLanguage")
        voiceCall.selectLanguage(language)
        refreshVoiceCallUI()
    }

    @objc private func endVoiceCallPressed() {
        endVoiceCall()
    }

    @objc private func interruptVoiceCall() {
        guard voiceCall.isActive else { return }
        interruptVoiceOutput()
        voiceCall.interruptAndListen()
    }

    private func voiceCallChanged() {
        MikuTrainingActivity.shared.setVoiceCallActive(voiceCall.isActive)
        if voiceCall.phase == .failed, sendingVoiceTurn || awaitingVoicePlayback || voiceReplyToken != nil {
            onVoiceCallStop?()
            cancelActiveConversation(endingVoiceCall: false)
        }
        refreshVoiceCallUI()
    }

    /// A spoken interruption keeps the microphone and its opening words alive.
    private func interruptVoiceOutput() {
        guard voiceCall.isActive else { return }
        interruptingVoiceCall = true
        awaitingVoicePlayback = false
        pendingVoiceBedtime = nil
        onVoiceCallStop?()
        cancelActiveConversation(endingVoiceCall: false)
        interruptingVoiceCall = false
    }

    private func receiveVoiceText(_ text: String, generation: Int) {
        guard generation == conversationGeneration, sendingVoiceTurn, voiceCall.isActive else { return }
        do {
            let phrases = try voiceReplyBuffer.append(text)
            try appendVoicePhrases(phrases)
        } catch {
            chatTask?.cancel()
            interruptVoiceOutput()
            voiceCall.replyFailed()
        }
    }

    private func appendVoicePhrases(_ phrases: [String]) throws {
        let spoken = phrases.map(HumText.removingHum).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !spoken.isEmpty else { return }
        if voiceReplyToken == nil {
            awaitingVoicePlayback = true
            voiceCall.replyReady()
            onVoiceReplyBegan?()
            voiceReplyToken = MikuSpeech.shared.beginVoiceReply(style: voiceReplyStyle)
        }
        guard let token = voiceReplyToken, voiceCall.isActive else { throw CancellationError() }
        for phrase in spoken {
            MikuSpeech.shared.appendVoiceReply(phrase, token: token)
        }
        onVoicePhrase?(voiceReplyBuffer.text)
    }

    private func finishVoiceReply(_ reply: CompanionReply) throws {
        voiceReplyStyle = .fromEmotion(reply.emotion)
        if let token = voiceReplyToken {
            MikuSpeech.shared.setVoiceReplyStyle(voiceReplyStyle, token: token)
        }
        let phrases = try voiceReplyBuffer.append(reply.text, final: true)
        try appendVoicePhrases(phrases)
        guard voiceReplyToken != nil else { throw CancellationError() }
    }

    private func settleVoiceExchange(completed: Bool) {
        guard let user = voiceExchangeUser else { return }
        defer {
            voiceExchangeUser = nil
            voiceExchangeReplyID = nil
            voiceReplyProgress = VoiceReplyProgress()
        }
        if completed {
            if let id = voiceExchangeReplyID, let reply = messages.first(where: { $0.id == id }) {
                memory.record(messages)
                memory.didExchange(user: user, reply: reply, ai: ai)
            }
            return
        }
        guard voiceReplyProgress.hasStarted else {
            if let id = voiceExchangeReplyID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages.remove(at: index)
                if let label = messageLabels.removeValue(forKey: id) { label.stringValue = L10n.text("voiceCallReplyInterrupted") }
                lastReplyText = messages.last(where: { $0.role == .assistant })?.text
                memory.record(messages)
            }
            return
        }
        let heard = voiceReplyProgress.completedText
        let text = heard + (heard.isEmpty ? "" : "\n") + L10n.text("voiceCallReplyInterrupted")
        if let id = voiceExchangeReplyID, let index = messages.firstIndex(where: { $0.id == id }) {
            let old = messages[index]
            messages[index] = ChatMessage(id: id, role: .assistant, text: text, date: old.date)
            messageLabels[id]?.stringValue = text
        } else {
            let reply = ChatMessage(role: .assistant, text: text)
            messages.append(reply)
            appendBubble(reply)
        }
        lastReplyText = heard.isEmpty ? nil : heard
        memory.record(messages)
    }

    private func refreshVoiceCallUI() {
        let active = voiceCall.isActive
        let showsCard = active || voiceCall.phase == .failed
        voiceCallCard.isHidden = !showsCard
        if showsCard {
            messagesBelowHeader?.isActive = false
            messagesBelowVoiceCall?.isActive = true
        } else {
            messagesBelowVoiceCall?.isActive = false
            messagesBelowHeader?.isActive = true
        }

        let callTitle = L10n.text(active ? "voiceCallEnd" : "voiceCallStart")
        callButton.symbolName = active ? "phone.down.fill" : "phone.fill"
        callButton.style = active ? .accent : .soft
        callButton.toolTip = callTitle
        callButton.setAccessibilityLabel(callTitle)
        callButton.isEnabled = active || !isSending

        let statusKey: String
        switch voiceCall.phase {
        case .inactive: statusKey = "voiceCallStart"
        case .preparing:
            statusKey = voiceCall.preparation == .downloading
                ? "voiceCallDownloadingResources" : "voiceCallPreparingResources"
        case .listening: statusKey = "voiceCallListening"
        case .thinking:
            statusKey = voiceCall.automaticInterruptionAvailable && !voiceCall.isMicrophoneMuted
                ? "voiceCallThinkingListening" : "voiceCallThinking"
        case .speaking:
            statusKey = voiceCall.automaticInterruptionAvailable && !voiceCall.isMicrophoneMuted
                ? "voiceCallSpeakingListening" : "voiceCallSpeaking"
        case .paused: statusKey = "voiceCallPaused"
        case .failed: statusKey = voiceCall.errorKey ?? "voiceCallFailed"
        }
        voiceCallStatusLabel.stringValue = L10n.text(statusKey)
        voiceCallStatusLabel.textColor = voiceCall.phase == .failed ? MikuTheme.offline : MikuTheme.primaryText
        voiceCallStatusLabel.setAccessibilityLabel(L10n.text(statusKey))
        voiceCallSubtitleLabel.stringValue = voiceCall.transcript.isEmpty
            ? L10n.text("voiceCallSubtitlePlaceholder") : voiceCall.transcript
        voiceCallPrivacyLabel.stringValue = L10n.text("voiceCallPrivacy")
        voiceCallLanguageButton.title = L10n.text(voiceCall.language.localizationKey)
        voiceCallLanguageButton.toolTip = L10n.text("voiceCallLanguage")
        voiceCallLanguageButton.setAccessibilityLabel(L10n.text("voiceCallLanguage"))
        let micTitle = L10n.text(voiceCall.isMicrophoneMuted ? "voiceCallUnmuteMic" : "voiceCallMuteMic")
        voiceCallMicButton.symbolName = voiceCall.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
        voiceCallMicButton.toolTip = micTitle
        voiceCallMicButton.setAccessibilityLabel(micTitle)
        voiceCallMicButton.isEnabled = active && voiceCall.phase != .preparing
        voiceCallEndButton.toolTip = L10n.text("voiceCallEnd")
        voiceCallEndButton.setAccessibilityLabel(L10n.text("voiceCallEnd"))
        voiceCallInterruptButton.title = L10n.text("voiceCallInterrupt")
        voiceCallInterruptButton.setAccessibilityLabel(L10n.text("voiceCallInterrupt"))
        voiceCallInterruptButton.isHidden = voiceCall.phase != .thinking && voiceCall.phase != .speaking
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
            let model = AIConfiguration.shared.activeModel
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
        endVoiceCall()
        inputField.stringValue = ""
        removePendingImage()
        // "Let's play rock-paper-scissors!": straight into the game.
        if image == nil, let game = MiniGame.requested(in: text) {
            hideEmptyState()
            let message = ChatMessage(role: .user, text: text)
            messages.append(message)
            appendBubble(message)
            memory.record(messages)
            startGame(game)
            return
        }
        send(text, image: image)
    }

    @objc private func suggestionTapped(_ sender: MikuPillButton) {
        guard !isSending else { return }
        endVoiceCall()
        send(sender.title)
    }

    @objc private func retry() {
        guard let failedText else { return }
        endVoiceCall()
        send(failedText, image: failedImage, appendUser: false)
    }

    @objc private func confirmClearChat() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("clearChatConfirm")
        alert.informativeText = L10n.text("clearChatDetail")
        let clear = alert.addButton(withTitle: L10n.text("clearChat"))
        clear.hasDestructiveAction = true
        alert.addButton(withTitle: L10n.text("cancel"))
        // Cancel is the default (Return), so a hurried keypress doesn't clear anything.
        clear.keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearChat()
    }

    private func clearChat() {
        guard !isSending else { return }
        endVoiceCall()
        MikuSpeech.shared.stop()
        activeGame = nil
        choiceRow = nil
        messages.removeAll()
        lastReplyText = nil
        failedText = nil
        memory.clearConversation()
        showEmptyState()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func replayLastReply() {
        guard let lastReplyText else { return }
        endVoiceCall()
        // You asked to hear it, so it plays even while she's muted.
        MikuSpeech.shared.speak(lastReplyText, userInitiated: true)
    }

    @objc private func toggleMute() {
        let speech = MikuSpeech.shared
        speech.setMuted(!speech.isMuted)
    }

    /// Speaker icon: what clicking it will do, and whether she's muted now.
    @objc func refreshMuteButton() {
        let speech = MikuSpeech.shared
        if voiceCall.isActive, !speech.enabled || speech.isMuted { endVoiceCall() }
        muteButton.isHidden = !speech.enabled
        let muted = speech.isMuted
        muteButton.symbolName = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let title: String
        if muted, speech.isQuietByAutomation {
            title = L10n.text("speechQuietByFocusUnmute")
        } else if muted, let until = speech.mutedUntil {
            title = L10n.format("speechMutedUntilUnmute", until.formatted(date: .omitted, time: .shortened))
        } else {
            title = L10n.text(muted ? "speechUnmute" : "speechMuteButton")
        }
        muteButton.toolTip = title
        muteButton.setAccessibilityLabel(title)
    }

    @objc private func stopSpeech() {
        MikuSpeech.shared.stop()
    }

    @objc private func showCompanionTools(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (key, action) in [
            ("comeOver", #selector(callOver)),
            ("takeMemoryPhoto", #selector(takeMemoryPhoto)),
            ("memoryAlbum", #selector(openAlbum)),
            ("songKnowledge", #selector(openKnowledge))
        ] {
            let item = NSMenuItem(title: L10n.text(key), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let replay = NSMenuItem(title: L10n.text("speechReplay"), action: #selector(replayLastReply), keyEquivalent: "")
        replay.target = self
        replay.isEnabled = lastReplyText != nil && MikuSpeech.shared.enabled
        menu.addItem(replay)
        let stop = NSMenuItem(title: L10n.text("speechStop"), action: #selector(stopSpeech), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = MikuSpeech.shared.isBusy
        menu.addItem(stop)
        menu.addItem(.separator())
        let language = NSMenuItem(title: L10n.text("voiceCallLanguage"), action: nil, keyEquivalent: "")
        language.submenu = voiceLanguageMenu()
        menu.addItem(language)
        // Kept out of the header (it was easy to hit by accident) and asked about first.
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.text("clearChatMenu"), action: #selector(confirmClearChat), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !isSending && !messages.isEmpty
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func callOver() { onCallOver?() }
    @objc private func takeMemoryPhoto() { onTakeMemoryPhoto?() }
    @objc private func openAlbum() { onOpenAlbum?() }
    @objc private func openKnowledge() { onOpenKnowledge?() }

    private func send(_ text: String, image: Data? = nil, appendUser: Bool = true, voiceOrigin: Bool = false) {
        guard !isSending, !voiceOrigin || voiceCall.isActive else { return }
        if !voiceOrigin { endVoiceCall() }
        sendingVoiceTurn = voiceOrigin
        voiceReplyStyle = .neutral
        voiceReplyToken = nil
        voiceReplyBuffer = VoiceReplyBuffer()
        cancelPendingBedtime()
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
        voiceExchangeUser = voiceOrigin ? userMessage : nil
        voiceExchangeReplyID = nil
        voiceReplyProgress = VoiceReplyProgress()
        // A picture on its own still needs a sentence for the model to answer.
        let prompt = text.isEmpty && image != nil ? L10n.text("imagePrompt") : text
        // Talking to her wakes her up; "good morning" gets her up for the day.
        let sleep = SleepSchedule.shared
        let goodNight = SleepSchedule.isBedtimeRequest(text)
        if SleepSchedule.isGoodMorning(text) {
            sleep.goodMorning()
        } else if sleep.isAsleep(), !goodNight {
            sleep.wake(minutes: 30)
        }
        let sleepRevision = sleep.revision
        if appendUser, CompanionRequest.isComeOver(text) { onCallOver?() }
        // You answered: she may speak up on her own again later.
        if appendUser { AwarenessService.shared.userSpoke() }
        // Her last lines, for "what would you like to hear?" — "Tell Your World", and for
        // "open it on YouTube" about a song she named a moment ago.
        let recentAssistant = appendUser
            ? Array(messages.dropLast().filter { $0.role == .assistant }.suffix(3).reversed().map(\.text))
            : []
        let previousAssistant = recentAssistant.first
        let rememberSongPreferences = memory.isEnabled
        memory.record(messages)
        setSending(true)

        let generation = conversationGeneration
        chatTask = Task { [weak self] in
            guard let self else { return }
            var musicPlan: MusicPlan?
            do {
                if appendUser {
                    let player = MusicPlayback.shared
                    if let request = MusicRequestParser.parse(
                        text,
                        previousAssistant: previousAssistant,
                        recentAssistant: Array(recentAssistant.dropFirst()),
                        knownTitles: await player.knownTitles()
                    ) {
                        musicPlan = await player.plan(for: request)
                    }
                }
                let classificationHistory = memory.recentHistory(from: completedHistory())
                let relationshipIntent = try await ai.relationshipIntent(
                    for: text,
                    history: classificationHistory
                )
                guard !Task.isCancelled, generation == conversationGeneration else { return }

                // An apology can settle things before she answers. A relationship change
                // waits until the matching reply is ready and still current.
                memory.noteUserMessage(
                    text,
                    relationshipIntent: relationshipIntent,
                    deferRelationshipChange: true
                )
                let history = memory.recentHistory(from: completedHistory())
                let context = memory.context()
                let initialDecision = context.confessionDecision
                let confessionToken = context.confessionToken
                let voiceTextHandler: (@Sendable (String) async -> Void)?
                if voiceOrigin {
                    voiceTextHandler = { [weak self] partial in
                        guard let self else { return }
                        await self.receiveVoiceText(partial, generation: generation)
                    }
                } else {
                    voiceTextHandler = nil
                }
                // What you're listening to or watching, so "what am I listening to?" has an answer.
                let listening = await AwarenessService.shared.listeningForChat()
                guard !Task.isCancelled, generation == conversationGeneration else { return }
                var reply = try await ai.reply(
                    to: prompt, image: image, history: history, memory: context,
                    rememberSongPreferences: rememberSongPreferences,
                    relationshipIntent: relationshipIntent,
                    music: musicPlan,
                    listening: listening,
                    mode: voiceOrigin ? .voice : .text,
                    onVoiceText: voiceTextHandler
                )
                guard !Task.isCancelled, generation == conversationGeneration else { return }

                if var decision = initialDecision {
                    guard let confessionToken else { throw CancellationError() }
                    while true {
                        guard let current = memory.revalidateConfessionDecision(
                            for: text,
                            relationshipIntent: relationshipIntent,
                            token: confessionToken
                        ) else {
                            throw CancellationError()
                        }
                        if current != decision {
                            reply = await ai.fallbackConfessionReply(
                                for: current,
                                level: memory.context().level,
                                to: text,
                                history: history
                            )
                            guard !Task.isCancelled, generation == conversationGeneration else { return }
                            decision = current
                            continue
                        }
                        if memory.commitConfessionDecision(
                            decision,
                            for: text,
                            relationshipIntent: relationshipIntent,
                            token: confessionToken
                        ) {
                            break
                        }
                        throw CancellationError()
                    }
                }
                if voiceOrigin { try finishVoiceReply(reply) }
                let assistantMessage = ChatMessage(role: .assistant, text: reply.text)
                chatTask = nil
                setSending(false)
                sendingVoiceTurn = false
                messages.append(assistantMessage)
                if voiceOrigin { voiceExchangeReplyID = assistantMessage.id }
                lastReplyText = reply.text
                appendBubble(assistantMessage)
                if !voiceOrigin {
                    memory.record(messages)
                    memory.didExchange(user: userMessage, reply: assistantMessage, ai: ai)
                }
                // After saying good night back, she goes to bed (once you've read her reply);
                // late at night, her own "good night" means the same.
                let automaticGoodNight = SleepSchedule.shouldAutomaticallySleep(
                    after: reply.text,
                    userText: text
                )
                if voiceOrigin {
                    if goodNight || automaticGoodNight {
                        pendingVoiceBedtime = (sleepRevision, generation, automaticGoodNight && !goodNight)
                    }
                }
                if let musicPlan { onPlayMusic?(musicPlan) }
                if voiceOrigin { onVoiceReply?(reply) } else { onReply?(reply) }
                if voiceOrigin, let token = voiceReplyToken {
                    MikuSpeech.shared.finishVoiceReply(token: token)
                }
                if !voiceOrigin, goodNight || automaticGoodNight {
                    scheduleBedtime(
                        sleep: sleep,
                        sleepRevision: sleepRevision,
                        conversationGeneration: generation,
                        requiresLateEvening: automaticGoodNight && !goodNight
                    )
                }
                if statusDot.color != MikuTheme.online { refreshConnectionStatus() }
            } catch is CancellationError {
                guard generation == conversationGeneration else { return }
                if voiceOrigin { settleVoiceExchange(completed: false) }
                memory.discardPendingConfessionDecision()
                chatTask = nil
                setSending(false)
                sendingVoiceTurn = false
                if voiceOrigin {
                    pendingVoiceBedtime = nil
                    awaitingVoicePlayback = false
                    voiceReplyToken = nil
                    interruptingVoiceCall = true
                    onVoiceCallStop?()
                    MikuSpeech.shared.stop()
                    interruptingVoiceCall = false
                    voiceCall.replyFailed()
                }
            } catch {
                guard !Task.isCancelled, generation == conversationGeneration else { return }
                if voiceOrigin { settleVoiceExchange(completed: false) }
                memory.discardPendingConfessionDecision()
                chatTask = nil
                setSending(false)
                sendingVoiceTurn = false
                if voiceOrigin {
                    pendingVoiceBedtime = nil
                    awaitingVoicePlayback = false
                    voiceReplyToken = nil
                    interruptingVoiceCall = true
                    onVoiceCallStop?()
                    MikuSpeech.shared.stop()
                    interruptingVoiceCall = false
                    voiceCall.replyFailed()
                }
                failedText = text
                failedImage = image
                // She couldn't answer, but the song you asked for still opens.
                if let musicPlan { onPlayMusic?(musicPlan) }
                let configuration = AIConfiguration.shared
                showError(LocalAI.message(
                    for: error,
                    endpoint: configuration.activeEndpoint,
                    model: configuration.activeModel,
                    cloud: configuration.usesCloud
                ))
                refreshConnectionStatus()
            }
        }
    }

    private func cancelActiveConversation(endingVoiceCall: Bool = true, preserveVoiceHistory: Bool = true) {
        if preserveVoiceHistory {
            settleVoiceExchange(completed: false)
        } else {
            voiceExchangeUser = nil
            voiceExchangeReplyID = nil
            voiceReplyProgress = VoiceReplyProgress()
        }
        pendingVoiceBedtime = nil
        awaitingVoicePlayback = false
        voiceReplyToken = nil
        voiceReplyBuffer = VoiceReplyBuffer()
        if endingVoiceCall {
            voiceCall.end()
            onVoiceCallStop?()
        }
        conversationGeneration &+= 1
        chatTask?.cancel()
        chatTask = nil
        sendingVoiceTurn = false
        MikuSpeech.shared.stop()
        memory.discardPendingConfessionDecision()
        cancelPendingBedtime()
        setSending(false)
    }

    private func scheduleBedtime(
        sleep: SleepSchedule,
        sleepRevision: Int,
        conversationGeneration generation: Int,
        requiresLateEvening: Bool
    ) {
        bedtimeScheduler.schedule(
            afterNanoseconds: 6_000_000_000,
            ifStillCurrent: { [weak self] in
                guard let self else { return false }
                return generation == conversationGeneration
                    && sleepRevision == sleep.revision
                    && (!requiresLateEvening || SleepSchedule.isLateEvening())
            },
            action: { sleep.goToBed() }
        )
    }

    private func cancelPendingBedtime() {
        bedtimeScheduler.cancel()
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
        if sending { MikuSpeech.shared.stop() }
        isSending = sending
        inputField.isEnabled = !sending
        updateSendButton()
        suggestionButtons.forEach { $0.isEnabled = !sending }
        onThinking?(sending)
        if sending { showTypingIndicator() } else { removeTypingIndicator() }
        if !sending { window?.makeFirstResponder(inputField) }
        refreshVoiceCallUI()
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

        configureIconButton(settingsButton, symbol: "gearshape.fill", action: #selector(openSettings))
        configureIconButton(gameButton, symbol: "gamecontroller.fill", action: #selector(showGames(_:)))
        configureIconButton(companionButton, symbol: "ellipsis", action: #selector(showCompanionTools(_:)))
        configureIconButton(muteButton, symbol: "speaker.wave.2.fill", action: #selector(toggleMute))
        configureIconButton(callButton, symbol: "phone.fill", action: #selector(toggleVoiceCall))
        muteButton.setAccessibilityIdentifier("chat-speech-mute")
        companionButton.setAccessibilityIdentifier("chat-companion-tools")
        callButton.setAccessibilityIdentifier("chat-voice-call")

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let headerButtons = NSStackView(views: [callButton, muteButton, gameButton, companionButton, settingsButton])
        headerButtons.orientation = .horizontal
        headerButtons.spacing = 4
        let headerStack = NSStackView(views: [headerAvatar, titleStack, spacer, headerButtons])
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

        voiceCallCard.cornerRadius = 14
        voiceCallCard.isHidden = true
        voiceCallCard.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(voiceCallCard)
        voiceCallStatusLabel.lineBreakMode = .byWordWrapping
        voiceCallStatusLabel.maximumNumberOfLines = 3
        voiceCallStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceCallStatusLabel.setAccessibilityIdentifier("voice-call-status")
        configureIconButton(voiceCallMicButton, symbol: "mic.fill", action: #selector(toggleVoiceMicrophone))
        configureIconButton(voiceCallEndButton, symbol: "phone.down.fill", action: #selector(endVoiceCallPressed))
        voiceCallMicButton.setAccessibilityIdentifier("voice-call-microphone")
        voiceCallEndButton.setAccessibilityIdentifier("voice-call-end")
        let voiceTopRow = NSStackView(views: [voiceCallStatusLabel, voiceCallMicButton, voiceCallEndButton])
        voiceTopRow.orientation = .horizontal
        voiceTopRow.alignment = .centerY
        voiceTopRow.spacing = 6
        voiceCallSubtitleLabel.lineBreakMode = .byTruncatingTail
        voiceCallSubtitleLabel.maximumNumberOfLines = 2
        voiceCallSubtitleLabel.preferredMaxLayoutWidth = 300
        voiceCallSubtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceCallSubtitleLabel.setAccessibilityIdentifier("voice-call-transcript")
        voiceCallPrivacyLabel.lineBreakMode = .byWordWrapping
        voiceCallPrivacyLabel.maximumNumberOfLines = 2
        voiceCallPrivacyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceCallInterruptButton.symbolName = "hand.raised.fill"
        voiceCallInterruptButton.style = .soft
        voiceCallInterruptButton.controlHeight = 26
        voiceCallInterruptButton.horizontalPadding = 10
        voiceCallInterruptButton.target = self
        voiceCallInterruptButton.action = #selector(interruptVoiceCall)
        voiceCallInterruptButton.setAccessibilityIdentifier("voice-call-interrupt")
        voiceCallLanguageButton.style = .soft
        voiceCallLanguageButton.controlHeight = 26
        voiceCallLanguageButton.target = self
        voiceCallLanguageButton.action = #selector(showVoiceLanguageMenu(_:))
        voiceCallLanguageButton.setAccessibilityIdentifier("voice-call-language")
        let voiceOptions = NSStackView(views: [voiceCallLanguageButton, voiceCallInterruptButton])
        voiceOptions.orientation = .horizontal
        voiceOptions.spacing = 8
        let voiceContent = NSStackView(views: [voiceTopRow, voiceCallSubtitleLabel, voiceCallPrivacyLabel, voiceOptions])
        voiceContent.orientation = .vertical
        voiceContent.alignment = .leading
        voiceContent.spacing = 6
        voiceContent.translatesAutoresizingMaskIntoConstraints = false
        voiceCallCard.addSubview(voiceContent)
        NSLayoutConstraint.activate([
            voiceCallCard.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            voiceCallCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            voiceCallCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            voiceContent.topAnchor.constraint(equalTo: voiceCallCard.topAnchor, constant: 10),
            voiceContent.bottomAnchor.constraint(equalTo: voiceCallCard.bottomAnchor, constant: -10),
            voiceContent.leadingAnchor.constraint(equalTo: voiceCallCard.leadingAnchor, constant: 12),
            voiceContent.trailingAnchor.constraint(equalTo: voiceCallCard.trailingAnchor, constant: -12),
            voiceTopRow.widthAnchor.constraint(equalTo: voiceContent.widthAnchor),
            voiceCallSubtitleLabel.widthAnchor.constraint(equalTo: voiceContent.widthAnchor),
            voiceCallPrivacyLabel.widthAnchor.constraint(equalTo: voiceContent.widthAnchor)
        ])

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
        let belowHeader = scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor)
        messagesBelowHeader = belowHeader
        messagesBelowVoiceCall = scrollView.topAnchor.constraint(equalTo: voiceCallCard.bottomAnchor, constant: 8)

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

            belowHeader,
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
        messageLabels.removeAll()
        typingRow = nil
        errorRow = nil
        choiceRow = nil
        activeGame = nil
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
        messageLabels[message.id] = label

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
