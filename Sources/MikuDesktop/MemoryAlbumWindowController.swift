import AppKit
import UniformTypeIdentifiers

@MainActor
final class MemoryAlbumWindowController: NSWindowController, NSWindowDelegate {
    typealias CaptureAction = @MainActor () async throws -> CapturedScene

    private let album: MemoryAlbum
    private let capture: CaptureAction
    private let listStack = NSStackView()
    private let preview = NSImageView()
    private let headingLabel = NSTextField.mikuLabel("", size: 19, weight: .bold, color: MikuTheme.deepTeal)
    private let preservationLabel = NSTextField.mikuLabel("", size: 12, color: MikuTheme.secondaryText)
    private let photoTitleLabel = NSTextField.mikuLabel("", size: 12, weight: .semibold, color: MikuTheme.deepTeal)
    private let noteLabel = NSTextField.mikuLabel("", size: 12, weight: .semibold, color: MikuTheme.deepTeal)
    private let categoryLabel = NSTextField.mikuLabel("", size: 12, weight: .semibold, color: MikuTheme.deepTeal)
    private let titleField = NSTextField()
    private let noteView = NSTextView()
    private let categoryButton = NSPopUpButton()
    private let metadataLabel = NSTextField.mikuLabel("", size: 12, color: MikuTheme.secondaryText)
    private let emptyLabel = NSTextField.mikuLabel("", size: 13, color: MikuTheme.secondaryText)
    private let captureButton = MikuPillButton(frame: .zero)
    private let saveButton = MikuPillButton(frame: .zero)
    private let exportButton = MikuPillButton(frame: .zero)
    private let deleteButton = MikuPillButton(frame: .zero)
    private var selectedID: UUID?
    private var pendingCapture: CapturedScene?
    private var captureTask: Task<Void, Never>?
    private var captureToken: UUID?
    private var observer: NSObjectProtocol?
    private var detailLoaded = false

    private struct DetailDraft {
        let selectedID: UUID?
        let hasPendingCapture: Bool
        let title: String
        let note: String
        let category: MemoryAlbum.Category
    }

    init(album: MemoryAlbum = .shared, capture: @escaping CaptureAction) {
        self.album = album
        self.capture = capture
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 780, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = MikuBackgroundView()
        super.init(window: window)
        window.delegate = self
        buildUI()
        refreshLocalization()
        window.center()
        observer = NotificationCenter.default.addObserver(
            forName: MemoryAlbum.changed,
            object: album,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        captureTask?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func present() {
        refreshLocalization()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func presentAndCapture() {
        present()
        startCapture()
    }

    public func refreshLocalization() {
        let draft = currentDraft()
        window?.title = AlbumText.title
        headingLabel.stringValue = AlbumText.title
        preservationLabel.stringValue = AlbumText.preservation
        photoTitleLabel.stringValue = AlbumText.photoTitle
        noteLabel.stringValue = AlbumText.note
        categoryLabel.stringValue = AlbumText.categoryTitle
        titleField.placeholderString = AlbumText.titlePlaceholder
        categoryButton.removeAllItems()
        categoryButton.addItems(withTitles: MemoryAlbum.Category.allCases.map(AlbumText.category))
        reload(preserving: draft)
    }

    func windowWillClose(_ notification: Notification) {
        captureToken = nil
        captureTask?.cancel()
        captureTask = nil
        captureButton.isEnabled = true
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 38, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        captureButton.style = .primary
        captureButton.symbolName = "camera.fill"
        captureButton.target = self
        captureButton.action = #selector(captureNow)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [MikuAvatarView(size: 44), headingLabel, spacer, captureButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        root.addArrangedSubview(header)

        preservationLabel.lineBreakMode = .byWordWrapping
        preservationLabel.maximumNumberOfLines = 0
        preservationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(preservationLabel)

        let list = makeList()
        let detail = makeDetail()
        let split = NSStackView(views: [list, detail])
        split.orientation = .horizontal
        split.alignment = .top
        split.spacing = 14
        root.addArrangedSubview(split)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            preservationLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            list.widthAnchor.constraint(equalToConstant: 310),
            list.heightAnchor.constraint(equalTo: split.heightAnchor),
            detail.heightAnchor.constraint(equalTo: split.heightAnchor)
        ])
    }

    private func makeList() -> NSView {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8
        listStack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 6)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }

    private func makeDetail() -> NSView {
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 12
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = MikuTheme.font(14, .semibold)
        titleField.focusRingType = .none

        noteView.font = MikuTheme.font(13)
        noteView.textColor = MikuTheme.primaryText
        noteView.backgroundColor = .clear
        noteView.isRichText = false
        noteView.isAutomaticQuoteSubstitutionEnabled = false
        noteView.isVerticallyResizable = true
        noteView.isHorizontallyResizable = false
        noteView.autoresizingMask = [.width]
        noteView.textContainer?.widthTracksTextView = true
        noteView.textContainerInset = NSSize(width: 8, height: 7)
        let noteScroll = NSScrollView()
        noteScroll.documentView = noteView
        noteScroll.hasVerticalScroller = true
        noteScroll.autohidesScrollers = true
        noteScroll.drawsBackground = false
        noteScroll.borderType = .bezelBorder
        noteScroll.translatesAutoresizingMaskIntoConstraints = false

        categoryButton.font = MikuTheme.font(13)

        saveButton.style = .primary
        saveButton.symbolName = "checkmark"
        saveButton.target = self
        saveButton.action = #selector(saveDetails)
        exportButton.style = .soft
        exportButton.symbolName = "square.and.arrow.up"
        exportButton.target = self
        exportButton.action = #selector(exportPhoto)
        deleteButton.style = .accent
        deleteButton.symbolName = "trash"
        deleteButton.target = self
        deleteButton.action = #selector(deletePhoto)
        let actions = NSStackView(views: [saveButton, exportButton, deleteButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.lineBreakMode = .byWordWrapping

        let fields = NSStackView(views: [
            preview,
            labelled(photoTitleLabel, titleField),
            labelled(noteLabel, noteScroll),
            labelled(categoryLabel, categoryButton),
            metadataLabel,
            actions,
            emptyLabel
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.translatesAutoresizingMaskIntoConstraints = false
        let card = MikuCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(fields)
        NSLayoutConstraint.activate([
            fields.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            fields.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            fields.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            fields.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            preview.widthAnchor.constraint(equalTo: fields.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            noteScroll.widthAnchor.constraint(equalTo: fields.widthAnchor),
            noteScroll.heightAnchor.constraint(equalToConstant: 70),
            emptyLabel.widthAnchor.constraint(equalTo: fields.widthAnchor)
        ])
        return card
    }

    private func reload(preserving draft: DetailDraft? = nil) {
        window?.title = AlbumText.title
        captureButton.title = captureTask == nil ? AlbumText.capture : AlbumText.capturing
        if captureTask == nil { captureButton.isEnabled = album.loadError == nil }
        for view in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if selectedID == nil, pendingCapture == nil { selectedID = album.entries.first?.id }
        if let selectedID, !album.entries.contains(where: { $0.id == selectedID }) { self.selectedID = album.entries.first?.id }

        if album.loadError != nil {
            let empty = wrappingLabel(AlbumText.loadFailed, size: 13, color: MikuTheme.pink)
            empty.alignment = .center
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -8).isActive = true
        } else if album.entries.isEmpty {
            let empty = wrappingLabel(AlbumText.empty, size: 13, color: MikuTheme.secondaryText)
            empty.alignment = .center
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -8).isActive = true
        } else {
            for entry in album.entries {
                let row = photoRow(entry)
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -8).isActive = true
            }
        }
        reloadDetail(preserving: draft)
    }

    private func photoRow(_ entry: MemoryAlbum.Entry) -> NSView {
        let thumbnail = NSImageView()
        thumbnail.image = album.imageURL(for: entry).flatMap(NSImage.init(contentsOf:))
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 8
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        let title = entry.title.isEmpty ? AlbumText.untitled : entry.title
        let titleLabel = wrappingLabel(title, size: 13, weight: .semibold)
        let detailLabel = wrappingLabel("\(AlbumText.category(entry.category)) · \(displayDate(entry.capturedAt))", size: 11.5, color: MikuTheme.secondaryText)
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let content = NSStackView(views: [thumbnail, labels])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = MikuCardView()
        card.fillColor = selectedID == entry.id ? MikuTheme.mikuBubble : MikuTheme.cardBackground
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        let button = NSButton()
        button.isBordered = false
        button.isTransparent = true
        button.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
        button.target = self
        button.action = #selector(selectPhoto(_:))
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(button)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 88),
            thumbnail.widthAnchor.constraint(equalToConstant: 104),
            thumbnail.heightAnchor.constraint(equalToConstant: 68),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            button.topAnchor.constraint(equalTo: card.topAnchor),
            button.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func reloadDetail(preserving draft: DetailDraft? = nil) {
        let entry = selectedID.flatMap { id in album.entries.first { $0.id == id } }
        let capture = pendingCapture
        let hasContent = capture != nil || entry != nil
        preview.image = capture?.image ?? entry.flatMap { album.imageURL(for: $0).flatMap(NSImage.init(contentsOf:)) }
        titleField.stringValue = capture != nil ? "" : entry?.title ?? ""
        noteView.string = capture != nil ? "" : entry?.note ?? ""
        let category = capture != nil ? MemoryAlbum.Category.everyday : entry?.category ?? .everyday
        categoryButton.selectItem(at: MemoryAlbum.Category.allCases.firstIndex(of: category) ?? 0)
        let date = capture?.capturedAt ?? entry?.capturedAt
        let scene = capture?.scene ?? entry?.scene
        metadataLabel.stringValue = date.map { "\(displayDate($0)) · \(AlbumText.sceneName(scene ?? ""))" } ?? ""
        saveButton.title = capture != nil ? AlbumText.add : AlbumText.save
        exportButton.title = AlbumText.export
        deleteButton.title = AlbumText.delete
        saveButton.isEnabled = hasContent
        exportButton.isEnabled = entry != nil && capture == nil
        deleteButton.isEnabled = entry != nil && capture == nil
        titleField.isEnabled = hasContent
        noteView.isEditable = hasContent
        categoryButton.isEnabled = hasContent
        emptyLabel.stringValue = hasContent ? "" : AlbumText.emptyDetail
        emptyLabel.isHidden = hasContent
        if let draft,
           draft.selectedID == selectedID,
           draft.hasPendingCapture == (pendingCapture != nil),
           hasContent {
            titleField.stringValue = draft.title
            noteView.string = draft.note
            categoryButton.selectItem(at: MemoryAlbum.Category.allCases.firstIndex(of: draft.category) ?? 0)
        }
        detailLoaded = true
    }

    private func currentDraft() -> DetailDraft? {
        guard detailLoaded, selectedID != nil || pendingCapture != nil else { return nil }
        let selectedIndex = categoryButton.indexOfSelectedItem
        let category = MemoryAlbum.Category.allCases.indices.contains(selectedIndex)
            ? MemoryAlbum.Category.allCases[selectedIndex]
            : .everyday
        return DetailDraft(
            selectedID: selectedID,
            hasPendingCapture: pendingCapture != nil,
            title: titleField.stringValue,
            note: noteView.string,
            category: category
        )
    }

    @objc private func captureNow() {
        startCapture()
    }

    private func startCapture() {
        guard captureTask == nil, album.loadError == nil else { return }
        captureButton.isEnabled = false
        captureButton.title = AlbumText.capturing
        let capture = self.capture
        let token = UUID()
        captureToken = token
        captureTask = Task { [weak self] in
            do {
                let result = try await capture()
                try Task.checkCancellation()
                guard let self, self.captureToken == token else { return }
                self.pendingCapture = result
                self.selectedID = nil
                self.captureToken = nil
                self.captureTask = nil
                self.captureButton.isEnabled = true
                self.reload()
            } catch is CancellationError {
                guard let self, self.captureToken == token else { return }
                self.captureToken = nil
                self.captureTask = nil
                self.captureButton.isEnabled = true
                self.reload()
            } catch {
                guard let self, self.captureToken == token else { return }
                self.captureToken = nil
                self.captureTask = nil
                self.captureButton.isEnabled = true
                self.reload()
                self.showError(AlbumText.captureFailed, detail: AlbumText.captureFailureDetail(error))
            }
        }
    }

    @objc private func selectPhoto(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        pendingCapture = nil
        selectedID = id
        reload()
    }

    @objc private func saveDetails() {
        let category = MemoryAlbum.Category.allCases.indices.contains(categoryButton.indexOfSelectedItem)
            ? MemoryAlbum.Category.allCases[categoryButton.indexOfSelectedItem]
            : .everyday
        do {
            if let pendingCapture {
                let entry = try album.add(
                    pendingCapture,
                    title: titleField.stringValue,
                    note: noteView.string,
                    category: category
                )
                self.pendingCapture = nil
                selectedID = entry.id
            } else if let selectedID {
                try album.update(
                    id: selectedID,
                    title: titleField.stringValue,
                    note: noteView.string,
                    category: category
                )
            }
            reload()
        } catch {
            showError(AlbumText.saveFailed, detail: AlbumText.saveFailureDetail)
        }
    }

    @objc private func exportPhoto() {
        guard let id = selectedID, let entry = album.entries.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        let base = entry.title.isEmpty ? "Miku-\(Self.fileDate(entry.capturedAt))" : entry.title
        panel.nameFieldStringValue = Self.safeExportName(base) + ".jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try album.export(id: id, to: url)
        } catch {
            showError(AlbumText.exportFailed)
        }
    }

    @objc private func deletePhoto() {
        guard let id = selectedID else { return }
        let alert = NSAlert()
        alert.messageText = AlbumText.deleteConfirm
        alert.informativeText = AlbumText.deleteDetail
        alert.addButton(withTitle: AlbumText.cancel)
        let delete = alert.addButton(withTitle: AlbumText.delete)
        delete.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try album.delete(id: id)
            selectedID = album.entries.first?.id
            reload()
        } catch {
            showError(AlbumText.deleteFailed)
        }
    }

    private func showError(_ message: String, detail: String = AlbumText.tryAgain) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: AlbumText.ok)
        alert.runModal()
    }

    private func labelled(_ label: NSTextField, _ view: NSView) -> NSView {
        let stack = NSStackView(views: [label, view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func wrappingLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = MikuTheme.primaryText
    ) -> NSTextField {
        let label = NSTextField.mikuLabel(text, size: size, weight: weight, color: color)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AlbumText.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private static func safeExportName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Miku" : cleaned).prefix(80))
    }
}

private enum AlbumText {
    private static func text(_ zh: String, _ en: String, _ ja: String) -> String {
        switch AppLanguage.resolved {
        case .traditionalChinese: return zh
        case .japanese: return ja
        default: return en
        }
    }

    static var locale: Locale {
        switch AppLanguage.resolved {
        case .traditionalChinese: return Locale(identifier: "zh_Hant_TW")
        case .japanese: return Locale(identifier: "ja_JP")
        default: return Locale(identifier: "en_US")
        }
    }

    static var title: String { text("共同回憶相簿", "Shared Memories", "思い出アルバム") }
    static var capture: String { text("拍照留念", "Take a photo", "記念写真を撮る") }
    static var capturing: String { text("拍攝中…", "Taking photo…", "撮影中…") }
    static var preservation: String { text("這些由你拍下的照片會獨立保存；重設對話記憶不會刪除相簿。", "Photos you take are stored separately. Resetting conversation memory will not delete this album.", "撮影した写真は会話の記憶とは別に保存されます。会話の記憶をリセットしても削除されません。") }
    static var empty: String { text("還沒有共同回憶。按「拍照留念」保存此刻。", "No shared memories yet. Take a photo to save this moment.", "まだ思い出はありません。「記念写真を撮る」で今を残しましょう。") }
    static var loadFailed: String { text("暫時讀不到相簿資料；現有照片檔案仍原樣保留。", "The album data couldn’t be read. Existing photo files were left untouched.", "アルバムのデータを読み込めません。既存の写真ファイルはそのまま残されています。") }
    static var emptyDetail: String { text("選擇一張照片，或拍下新的回憶。", "Choose a photo or capture a new memory.", "写真を選ぶか、新しい思い出を撮影してください。") }
    static var untitled: String { text("未命名的回憶", "Untitled memory", "無題の思い出") }
    static var photoTitle: String { text("標題", "Title", "タイトル") }
    static var titlePlaceholder: String { text("為這刻起個名字", "Name this moment", "この瞬間に名前をつける") }
    static var note: String { text("小記", "Note", "メモ") }
    static var categoryTitle: String { text("類別", "Category", "カテゴリー") }
    static var add: String { text("加入相簿", "Add to album", "アルバムに追加") }
    static var save: String { text("儲存", "Save", "保存") }
    static var export: String { text("匯出", "Export", "書き出す") }
    static var delete: String { text("刪除", "Delete", "削除") }
    static var cancel: String { text("取消", "Cancel", "キャンセル") }
    static var ok: String { text("好", "OK", "OK") }
    static var tryAgain: String { text("請稍後再試。", "Please try again in a moment.", "しばらくしてからもう一度お試しください。") }
    static var captureFailed: String { text("暫時未能拍下這一刻", "Couldn’t capture this moment", "この瞬間を撮影できませんでした") }
    static var saveFailed: String { text("未能儲存這張回憶", "Couldn’t save this memory", "この思い出を保存できませんでした") }
    static var saveFailureDetail: String { text("照片未加入相簿，現有內容沒有改動。請檢查儲存空間後再試。", "The photo wasn’t added and the existing album was unchanged. Check available storage and try again.", "写真は追加されず、既存のアルバムも変更されていません。空き容量を確認して、もう一度お試しください。") }
    static var exportFailed: String { text("未能匯出照片", "Couldn’t export the photo", "写真を書き出せませんでした") }
    static var deleteFailed: String { text("未能刪除照片", "Couldn’t delete the photo", "写真を削除できませんでした") }
    static var deleteConfirm: String { text("刪除這張共同回憶？", "Delete this shared memory?", "この思い出を削除しますか？") }
    static var deleteDetail: String { text("照片及小記會永久刪除。", "The photo and its note will be permanently deleted.", "写真とメモは完全に削除されます。") }

    static func captureFailureDetail(_ error: Error) -> String {
        guard let error = error as? MemoryPhotoCaptureError else { return tryAgain }
        switch error {
        case .notReady:
            return text("Miku 或場景仍在準備中，請稍後再拍。", "Miku or the scene is still getting ready. Try again shortly.", "ミクまたはシーンを準備中です。少し待ってから撮影してください。")
        case .emptyLayer:
            return text("拍到的畫面是空白，因此沒有儲存。", "The captured image was blank, so nothing was saved.", "撮影した画像が空白だったため、保存されませんでした。")
        case .sceneUnavailable:
            return text("暫時未能辨識目前場景，因此沒有儲存。", "The current scene couldn’t be identified, so nothing was saved.", "現在のシーンを確認できなかったため、保存されませんでした。")
        case .snapshotFailed:
            return text("暫時無法擷取目前畫面，因此沒有儲存。", "The current view couldn’t be captured, so nothing was saved.", "現在の画面を撮影できなかったため、保存されませんでした。")
        }
    }

    static func category(_ category: MemoryAlbum.Category) -> String {
        switch category {
        case .everyday: return text("日常", "Everyday", "日常")
        case .firstMeeting: return text("初次見面", "First meeting", "初めて会った日")
        case .birthday: return text("生日", "Birthday", "誕生日")
        case .achievement: return text("一起完成的事", "Something we achieved", "一緒に成し遂げたこと")
        }
    }

    static func sceneName(_ scene: String) -> String {
        let names: [String: (String, String, String)] = [
            "shibuya": ("澀谷", "Shibuya", "渋谷"),
            "shibuya-station": ("澀谷站", "Shibuya Station", "渋谷駅"),
            "ikebukuro": ("池袋", "Ikebukuro", "池袋"),
            "akihabara": ("秋葉原", "Akihabara", "秋葉原"),
            "shinjuku": ("新宿", "Shinjuku", "新宿"),
            "hallway": ("走廊", "Hallway", "廊下"),
            "musicroom": ("音樂室", "Music room", "音楽室"),
            "room": ("房間", "Room", "部屋")
        ]
        guard let name = names[scene] else { return scene }
        return text(name.0, name.1, name.2)
    }
}
