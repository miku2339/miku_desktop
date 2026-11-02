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
            titleField.widthAnchor.constraint(equalTo: fields.widthAnchor),
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
    private static func text(_ zh: String, _ en: String, _ ja: String, _ ko: String) -> String {
        switch AppLanguage.resolved {
        case .traditionalChinese: return zh
        case .japanese: return ja
        case .korean: return ko
        default: return en
        }
    }

    static var locale: Locale {
        switch AppLanguage.resolved {
        case .traditionalChinese: return Locale(identifier: "zh_Hant_TW")
        case .japanese: return Locale(identifier: "ja_JP")
        case .korean: return Locale(identifier: "ko_KR")
        default: return Locale(identifier: "en_US")
        }
    }

    static var title: String { text("共同回憶相簿", "Shared Memories", "思い出アルバム", "함께한 추억") }
    static var capture: String { text("拍照留念", "Take a photo", "記念写真を撮る", "사진 찍기") }
    static var capturing: String { text("拍攝中…", "Taking photo…", "撮影中…", "사진 찍는 중…") }
    static var preservation: String { text("這些由你拍下的照片會獨立保存；重設對話記憶不會刪除相簿。", "Photos you take are stored separately. Resetting conversation memory will not delete this album.", "撮影した写真は会話の記憶とは別に保存されます。会話の記憶をリセットしても削除されません。", "직접 찍은 사진은 따로 보관돼요. 대화 기억을 초기화해도 이 앨범은 삭제되지 않아요.") }
    static var empty: String { text("還沒有共同回憶。按「拍照留念」保存此刻。", "No shared memories yet. Take a photo to save this moment.", "まだ思い出はありません。「記念写真を撮る」で今を残しましょう。", "아직 함께한 추억이 없어요. 사진을 찍어 이 순간을 남겨 보세요.") }
    static var loadFailed: String { text("暫時讀不到相簿資料；現有照片檔案仍原樣保留。", "The album data couldn’t be read. Existing photo files were left untouched.", "アルバムのデータを読み込めません。既存の写真ファイルはそのまま残されています。", "앨범 자료를 읽을 수 없어요. 기존 사진 파일은 그대로 유지했어요.") }
    static var emptyDetail: String { text("選擇一張照片，或拍下新的回憶。", "Choose a photo or capture a new memory.", "写真を選ぶか、新しい思い出を撮影してください。", "사진을 고르거나 새로운 추억을 찍어 보세요.") }
    static var untitled: String { text("未命名的回憶", "Untitled memory", "無題の思い出", "제목 없는 추억") }
    static var photoTitle: String { text("標題", "Title", "タイトル", "제목") }
    static var titlePlaceholder: String { text("為這刻起個名字", "Name this moment", "この瞬間に名前をつける", "이 순간에 이름 붙이기") }
    static var note: String { text("小記", "Note", "メモ", "메모") }
    static var categoryTitle: String { text("類別", "Category", "カテゴリー", "분류") }
    static var add: String { text("加入相簿", "Add to album", "アルバムに追加", "앨범에 추가") }
    static var save: String { text("儲存", "Save", "保存", "저장") }
    static var export: String { text("匯出", "Export", "書き出す", "내보내기") }
    static var delete: String { text("刪除", "Delete", "削除", "삭제") }
    static var cancel: String { text("取消", "Cancel", "キャンセル", "취소") }
    static var ok: String { text("好", "OK", "OK", "확인") }
    static var tryAgain: String { text("請稍後再試。", "Please try again in a moment.", "しばらくしてからもう一度お試しください。", "잠시 후 다시 시도해 주세요.") }
    static var captureFailed: String { text("暫時未能拍下這一刻", "Couldn’t capture this moment", "この瞬間を撮影できませんでした", "이 순간을 촬영할 수 없어요") }
    static var saveFailed: String { text("未能儲存這張回憶", "Couldn’t save this memory", "この思い出を保存できませんでした", "이 추억을 저장할 수 없어요") }
    static var saveFailureDetail: String { text("照片未加入相簿，現有內容沒有改動。請檢查儲存空間後再試。", "The photo wasn’t added and the existing album was unchanged. Check available storage and try again.", "写真は追加されず、既存のアルバムも変更されていません。空き容量を確認して、もう一度お試しください。", "사진을 추가하지 못했어요. 기존 앨범은 그대로예요. 저장 공간을 확인한 뒤 다시 시도해 주세요.") }
    static var exportFailed: String { text("未能匯出照片", "Couldn’t export the photo", "写真を書き出せませんでした", "사진을 내보낼 수 없어요") }
    static var deleteFailed: String { text("未能刪除照片", "Couldn’t delete the photo", "写真を削除できませんでした", "사진을 삭제할 수 없어요") }
    static var deleteConfirm: String { text("刪除這張共同回憶？", "Delete this shared memory?", "この思い出を削除しますか？", "이 추억을 삭제할까요?") }
    static var deleteDetail: String { text("照片及小記會永久刪除。", "The photo and its note will be permanently deleted.", "写真とメモは完全に削除されます。", "사진과 메모가 영구 삭제돼요.") }

    static func captureFailureDetail(_ error: Error) -> String {
        guard let error = error as? MemoryPhotoCaptureError else { return tryAgain }
        switch error {
        case .notReady:
            return text("Miku 或場景仍在準備中，請稍後再拍。", "Miku or the scene is still getting ready. Try again shortly.", "ミクまたはシーンを準備中です。少し待ってから撮影してください。", "미쿠나 장면을 준비 중이에요. 잠시 후 다시 촬영해 주세요.")
        case .emptyLayer:
            return text("拍到的畫面是空白，因此沒有儲存。", "The captured image was blank, so nothing was saved.", "撮影した画像が空白だったため、保存されませんでした。", "촬영된 이미지가 비어 있어 저장하지 않았어요.")
        case .sceneUnavailable:
            return text("暫時未能辨識目前場景，因此沒有儲存。", "The current scene couldn’t be identified, so nothing was saved.", "現在のシーンを確認できなかったため、保存されませんでした。", "현재 장면을 확인할 수 없어 저장하지 않았어요.")
        case .snapshotFailed:
            return text("暫時無法擷取目前畫面，因此沒有儲存。", "The current view couldn’t be captured, so nothing was saved.", "現在の画面を撮影できなかったため、保存されませんでした。", "현재 화면을 촬영할 수 없어 저장하지 않았어요.")
        }
    }

    static func category(_ category: MemoryAlbum.Category) -> String {
        switch category {
        case .everyday: return text("日常", "Everyday", "日常", "일상")
        case .firstMeeting: return text("初次見面", "First meeting", "初めて会った日", "처음 만난 날")
        case .birthday: return text("生日", "Birthday", "誕生日", "생일")
        case .achievement: return text("一起完成的事", "Something we achieved", "一緒に成し遂げたこと", "함께 이룬 일")
        }
    }

    static func sceneName(_ scene: String) -> String {
        let names: [String: (String, String, String, String)] = [
            "shibuya": ("澀谷", "Shibuya", "渋谷", "시부야"),
            "shibuya-station": ("澀谷站", "Shibuya Station", "渋谷駅", "시부야역"),
            "ikebukuro": ("池袋", "Ikebukuro", "池袋", "이케부쿠로"),
            "akihabara": ("秋葉原", "Akihabara", "秋葉原", "아키하바라"),
            "shinjuku": ("新宿", "Shinjuku", "新宿", "신주쿠"),
            "hallway": ("走廊", "Hallway", "廊下", "복도"),
            "musicroom": ("音樂室", "Music room", "音楽室", "음악실"),
            "room": ("房間", "Room", "部屋", "방")
        ]
        guard let name = names[scene] else { return scene }
        return text(name.0, name.1, name.2, name.3)
    }
}

// MARK: - In Miku's notebook

extension MemoryAlbumWindowController: NotebookPage {
    func notebookPageWillAppear() {
        refreshLocalization()
    }

    /// Leaving the album stops a photo that is still being taken, as closing it did.
    func notebookPageWillDisappear() {
        captureToken = nil
        captureTask?.cancel()
        captureTask = nil
        captureButton.isEnabled = true
    }

    /// "Take a memory photo" from a menu: shows the album and takes the picture.
    func captureInNotebook() {
        startCapture()
    }
}
