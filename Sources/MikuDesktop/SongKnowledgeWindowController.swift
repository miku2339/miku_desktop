import AppKit
import UniformTypeIdentifiers

@MainActor
final class SongKnowledgeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Language {
        case traditionalChinese
        case english
        case japanese

        init(_ explicit: String?) {
            let value = explicit ?? Locale.preferredLanguages.first ?? "zh-Hant"
            if value.hasPrefix("ja") { self = .japanese }
            else if value.hasPrefix("en") { self = .english }
            else { self = .traditionalChinese }
        }

        init(_ appLanguage: AppLanguage) {
            switch appLanguage {
            case .traditionalChinese, .auto: self = .traditionalChinese
            case .english: self = .english
            case .japanese: self = .japanese
            }
        }
    }

    private let store: SongKnowledgeStore
    private let languageOverride: Language?
    private var language: Language { languageOverride ?? Language(AppLanguage.resolved) }
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let titleLabel = NSTextField.mikuLabel("", size: 20, weight: .bold)
    private let kindLabel = NSTextField.mikuLabel("", size: 11, weight: .semibold, color: MikuTheme.deepTeal)
    private let contentLabel = NSTextField.mikuLabel("", size: 13)
    private let provenanceLabel = NSTextField.mikuLabel("", size: 11, color: MikuTheme.secondaryText)
    private let statusLabel = NSTextField.mikuLabel("", size: 11, color: MikuTheme.secondaryText)
    private let favoriteButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sourceButton = MikuPillButton(frame: .zero)
    private let updateButton = MikuPillButton(frame: .zero)
    private let importButton = MikuPillButton(frame: .zero)
    private let exportButton = MikuPillButton(frame: .zero)
    private var entries: [SongKnowledgeEntry] = []
    private var filtered: [SongKnowledgeEntry] = []

    init(store: SongKnowledgeStore = .shared, language: String? = nil) {
        self.store = store
        let override = language.flatMap { value -> Language? in
            value == AppLanguage.auto.rawValue ? nil : Language(value)
        }
        languageOverride = override
        let resolvedLanguage = override ?? Language(AppLanguage.resolved)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.text(resolvedLanguage, "歌曲知識庫", "Song Knowledge", "楽曲ナレッジ")
        window.minSize = NSSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshLocalization() {
        window?.title = string("歌曲知識庫", "Song Knowledge", "楽曲ナレッジ")
        searchField.placeholderString = string("搜尋歌曲、創作者或別名", "Search songs, creators, or aliases", "曲・クリエイター・別名を検索")
        favoriteButton.title = string("喜歡的歌", "Favorite song", "お気に入り")
        sourceButton.title = string("查看來源", "View Source", "出典を見る")
        updateButton.title = string("檢查更新", "Check for Updates", "更新を確認")
        importButton.title = string("匯入 JSON", "Import JSON", "JSONを読み込む")
        exportButton.title = string("匯出 JSON", "Export JSON", "JSONを書き出す")
        refresh(select: selectedEntry()?.id)
    }

    private func buildUI() {
        guard let window else { return }
        let root = MikuBackgroundView(frame: .zero)
        window.contentView = root

        searchField.placeholderString = string("搜尋歌曲、創作者或別名", "Search songs, creators, or aliases", "曲・クリエイター・別名を検索")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("knowledge"))
        column.title = string("條目", "Entries", "項目")
        column.minWidth = 210
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        kindLabel.maximumNumberOfLines = 1
        contentLabel.maximumNumberOfLines = 0
        contentLabel.lineBreakMode = .byWordWrapping
        provenanceLabel.maximumNumberOfLines = 2
        provenanceLabel.lineBreakMode = .byCharWrapping
        [titleLabel, kindLabel, contentLabel, provenanceLabel].forEach {
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        favoriteButton.title = string("喜歡的歌", "Favorite song", "お気に入り")
        favoriteButton.font = MikuTheme.font(12, .semibold)
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.setAccessibilityIdentifier("song-knowledge-favorite")

        configure(sourceButton, string("查看來源", "View Source", "出典を見る"), "safari", .soft, #selector(openSource))
        configure(updateButton, string("檢查更新", "Check for Updates", "更新を確認"), "arrow.clockwise", .primary, #selector(checkForUpdates))
        configure(importButton, string("匯入 JSON", "Import JSON", "JSONを読み込む"), "square.and.arrow.down", .soft, #selector(importJSON))
        configure(exportButton, string("匯出 JSON", "Export JSON", "JSONを書き出す"), "square.and.arrow.up", .soft, #selector(exportJSON))

        let detail = MikuCardView(frame: .zero)
        detail.translatesAutoresizingMaskIntoConstraints = false
        let detailStack = NSStackView(views: [titleLabel, kindLabel, contentLabel, provenanceLabel, favoriteButton, sourceButton])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 10
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.addSubview(detailStack)

        let browser = MikuCardView(frame: .zero)
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.addSubview(searchField)
        browser.addSubview(scroll)

        let split = NSStackView(views: [browser, detail])
        split.orientation = .horizontal
        split.distribution = .fill
        split.spacing = 14
        split.translatesAutoresizingMaskIntoConstraints = false
        split.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actions = NSStackView(views: [updateButton, importButton, exportButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        root.addSubview(actions)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: browser.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: browser.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: browser.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: browser.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: browser.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: browser.bottomAnchor, constant: -10),
            browser.widthAnchor.constraint(equalToConstant: 275),

            detailStack.topAnchor.constraint(equalTo: detail.topAnchor, constant: 22),
            detailStack.leadingAnchor.constraint(equalTo: detail.leadingAnchor, constant: 22),
            detailStack.trailingAnchor.constraint(equalTo: detail.trailingAnchor, constant: -22),
            contentLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            provenanceLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: detailStack.widthAnchor),

            split.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            split.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),

            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            statusLabel.leadingAnchor.constraint(equalTo: actions.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: actions.centerYAnchor)
        ])
        showSelection(nil)
    }

    private func configure(
        _ button: MikuPillButton,
        _ title: String,
        _ symbol: String,
        _ style: MikuPillButton.Style,
        _ action: Selector
    ) {
        button.title = title
        button.symbolName = symbol
        button.style = style
        button.target = self
        button.action = action
    }

    private func refresh(select id: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let loaded = await store.allEntries()
            let version = await store.activeVersion()
            entries = loaded
            applySearch(select: id)
            statusLabel.stringValue = string(
                "版本 \(version) · \(loaded.count) 個條目",
                "Version \(version) · \(loaded.count) entries",
                "バージョン \(version)・\(loaded.count)件"
            )
        }
    }

    private func applySearch(select id: String? = nil) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { entry in
                ([entry.id, entry.content.traditionalChinese, entry.content.english, entry.content.japanese]
                    + entry.aliases + entry.creators)
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        tableView.reloadData()
        let target = id.flatMap { id in filtered.firstIndex { $0.id == id } }
            ?? (filtered.isEmpty ? nil : 0)
        if let target {
            tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            tableView.scrollRowToVisible(target)
            showSelection(filtered[target])
        } else {
            showSelection(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applySearch()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("songKnowledgeCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier
            let label = NSTextField.mikuLabel("", size: 13, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            view.textField = label
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        cell.textField?.stringValue = filtered[row].displayTitle
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        showSelection(filtered.indices.contains(row) ? filtered[row] : nil)
    }

    private func showSelection(_ entry: SongKnowledgeEntry?) {
        guard let entry else {
            titleLabel.stringValue = string("選擇一個條目", "Select an entry", "項目を選択")
            kindLabel.stringValue = ""
            contentLabel.stringValue = string("可搜尋內容、查看來源或標記喜歡的歌曲。", "Search the library, view sources, or mark favorite songs.", "検索、出典の確認、お気に入り登録ができます。")
            provenanceLabel.stringValue = ""
            favoriteButton.isHidden = true
            sourceButton.isEnabled = false
            return
        }
        titleLabel.stringValue = entry.displayTitle
        kindLabel.stringValue = kindName(entry.kind)
        contentLabel.stringValue = localizedContent(entry)
        provenanceLabel.stringValue = sourceStatus(entry.sourceStatus) + "\n" + entry.sourceURL
        favoriteButton.isHidden = entry.kind != .song
        sourceButton.isEnabled = true
        Task { [weak self] in
            self?.favoriteButton.state = await self?.store.isFavorite(entry.id) == true ? .on : .off
        }
    }

    private func selectedEntry() -> SongKnowledgeEntry? {
        let row = tableView.selectedRow
        return filtered.indices.contains(row) ? filtered[row] : nil
    }

    @objc private func toggleFavorite() {
        guard let entry = selectedEntry() else { return }
        let favorite = favoriteButton.state == .on
        Task { [weak self] in
            guard let self else { return }
            do {
                try await store.setFavorite(favorite, id: entry.id)
            } catch {
                favoriteButton.state = favorite ? .off : .on
                show(error)
            }
        }
    }

    @objc private func openSource() {
        guard let entry = selectedEntry(), let url = URL(string: entry.sourceURL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        setBusy(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setBusy(false) }
            do {
                let result = try await store.checkForUpdates()
                statusLabel.stringValue = string(
                    "已更新至 \(result.version)",
                    "Updated to \(result.version)",
                    "\(result.version)に更新しました"
                )
                refresh(select: selectedEntry()?.id)
            } catch {
                show(error)
            }
        }
    }

    @objc private func importJSON() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SongKnowledgeStore.maximumDocumentSize else { throw SongKnowledgeError.tooLarge }
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let result = try await self.store.importJSON(data)
                    self.statusLabel.stringValue = self.string(
                        "已匯入 \(result.importedCount) 個條目",
                        "Imported \(result.importedCount) entries",
                        "\(result.importedCount)件を読み込みました"
                    )
                    self.refresh()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    @objc private func exportJSON() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "miku-knowledge-export.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await self.store.exportJSON()
                    try data.write(to: url, options: [.atomic])
                    self.statusLabel.stringValue = self.string("已匯出", "Exported", "書き出しました")
                } catch {
                    self.show(error)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        updateButton.isEnabled = !busy
        importButton.isEnabled = !busy
        exportButton.isEnabled = !busy
        if busy {
            statusLabel.stringValue = string("正在檢查更新…", "Checking for updates…", "更新を確認中…")
        }
    }

    private func show(_ error: Error) {
        let message: String
        switch error {
        case SongKnowledgeError.tooLarge:
            message = string("檔案超過 1 MB 上限。", "The file exceeds the 1 MB limit.", "ファイルが1 MBの上限を超えています。")
        case SongKnowledgeError.invalidJSON,
             SongKnowledgeError.invalidSchema,
             SongKnowledgeError.duplicateID,
             SongKnowledgeError.invalidSourceURL:
            message = string("JSON 格式或內容不符合知識庫規格，原有資料未變更。", "The JSON does not match the knowledge format. Existing data was kept.", "JSONがナレッジ形式に合わないため、既存データを保持しました。")
        case SongKnowledgeError.httpStatus, SongKnowledgeError.invalidResponse:
            message = string("更新伺服器未能提供有效資料，原有資料未變更。", "The update server did not provide valid data. Existing data was kept.", "更新サーバーから有効なデータを取得できなかったため、既存データを保持しました。")
        case is URLError:
            message = string("暫時無法連線檢查更新，請稍後再試。", "Could not connect to check for updates. Please try again later.", "更新を確認できませんでした。時間をおいて再度お試しください。")
        default:
            message = string("操作失敗，原有資料未變更。", "The operation failed. Existing data was kept.", "操作に失敗したため、既存データを保持しました。")
        }
        statusLabel.stringValue = message
    }

    private func localizedContent(_ entry: SongKnowledgeEntry) -> String {
        switch language {
        case .traditionalChinese: return entry.content.traditionalChinese
        case .english: return entry.content.english
        case .japanese: return entry.content.japanese
        }
    }

    private func kindName(_ kind: SongKnowledgeKind) -> String {
        switch kind {
        case .song: return string("歌曲", "Song", "楽曲")
        case .performance: return string("演出", "Performance", "公演")
        case .character: return string("角色", "Character", "キャラクター")
        }
    }

    private func sourceStatus(_ status: SongKnowledgeSourceStatus) -> String {
        switch status {
        case .bundled: return string("內建已核實資料", "Bundled verified data", "内蔵の確認済みデータ")
        case .remote: return string("手動下載更新", "Manually downloaded update", "手動で取得した更新")
        case .manual: return string("使用者手動匯入", "Manually imported by user", "ユーザーが手動で読み込み")
        }
    }

    private func string(_ traditionalChinese: String, _ english: String, _ japanese: String) -> String {
        Self.text(language, traditionalChinese, english, japanese)
    }

    private static func text(_ language: Language, _ traditionalChinese: String, _ english: String, _ japanese: String) -> String {
        switch language {
        case .traditionalChinese: return traditionalChinese
        case .english: return english
        case .japanese: return japanese
        }
    }
}
