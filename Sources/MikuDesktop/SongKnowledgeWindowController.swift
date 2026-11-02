import AppKit
import UniformTypeIdentifiers

@MainActor
final class SongKnowledgeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Language {
        case traditionalChinese
        case english
        case japanese
        case korean

        init(_ explicit: String?) {
            let value = explicit ?? Locale.preferredLanguages.first ?? "zh-Hant"
            if value.hasPrefix("ko") { self = .korean }
            else if value.hasPrefix("ja") { self = .japanese }
            else if value.hasPrefix("en") { self = .english }
            else { self = .traditionalChinese }
        }

        init(_ appLanguage: AppLanguage) {
            switch appLanguage {
            case .traditionalChinese, .auto: self = .traditionalChinese
            case .english: self = .english
            case .japanese: self = .japanese
            case .korean: self = .korean
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
    private let aimcpButton = MikuPillButton(frame: .zero)
    private let importButton = MikuPillButton(frame: .zero)
    private let exportButton = MikuPillButton(frame: .zero)
    private var entries: [SongKnowledgeEntry] = []
    private var filtered: [SongKnowledgeEntry] = []
    private var onlineSearchTask: Task<Void, Never>?
    private var searchGeneration = 0

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
        window.title = Self.text(resolvedLanguage, "歌曲知識庫", "Song Knowledge", "楽曲ナレッジ", "노래 지식")
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
        window?.title = string("歌曲知識庫", "Song Knowledge", "楽曲ナレッジ", "노래 지식")
        searchField.placeholderString = string("搜尋離線曲庫；按 Enter 查完整曲庫", "Search offline; press Enter for the full catalog", "オフライン検索・Enterで全曲を検索", "오프라인 검색 · 전체 곡은 Enter로 검색")
        favoriteButton.title = string("喜歡的歌", "Favorite song", "お気に入り", "좋아하는 노래")
        sourceButton.title = string("查看來源", "View Source", "出典を見る", "출처 보기")
        updateButton.title = string("檢查更新", "Check for Updates", "更新を確認", "업데이트 확인")
        aimcpButton.title = string("AIMCP 設定…", "AIMCP Settings…", "AIMCP設定…", "AIMCP 설정…")
        importButton.title = string("匯入 JSON", "Import JSON", "JSONを読み込む", "JSON 가져오기")
        exportButton.title = string("匯出 JSON", "Export JSON", "JSONを書き出す", "JSON 내보내기")
        refresh(select: selectedEntry()?.id)
    }

    private func buildUI() {
        guard let window else { return }
        let root = MikuBackgroundView(frame: .zero)
        window.contentView = root

        searchField.placeholderString = string("搜尋離線曲庫；按 Enter 查完整曲庫", "Search offline; press Enter for the full catalog", "オフライン検索・Enterで全曲を検索", "오프라인 검색 · 전체 곡은 Enter로 검색")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchOnline)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("knowledge"))
        column.title = string("條目", "Entries", "項目", "항목")
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

        favoriteButton.title = string("喜歡的歌", "Favorite song", "お気に入り", "좋아하는 노래")
        favoriteButton.font = MikuTheme.font(12, .semibold)
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)
        favoriteButton.setAccessibilityIdentifier("song-knowledge-favorite")

        configure(sourceButton, string("查看來源", "View Source", "出典を見る", "출처 보기"), "safari", .soft, #selector(openSource))
        configure(updateButton, string("檢查更新", "Check for Updates", "更新を確認", "업데이트 확인"), "arrow.clockwise", .primary, #selector(checkForUpdates))
        configure(aimcpButton, string("AIMCP 設定…", "AIMCP Settings…", "AIMCP設定…", "AIMCP 설정…"), "key", .soft, #selector(configureAIMCP))
        configure(importButton, string("匯入 JSON", "Import JSON", "JSONを読み込む", "JSON 가져오기"), "square.and.arrow.down", .soft, #selector(importJSON))
        configure(exportButton, string("匯出 JSON", "Export JSON", "JSONを書き出す", "JSON 내보내기"), "square.and.arrow.up", .soft, #selector(exportJSON))

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

        let actions = NSStackView(views: [updateButton, aimcpButton, importButton, exportButton])
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

    private func refresh(select id: String? = nil, status: String? = nil) {
        cancelOnlineSearch()
        Task { [weak self] in
            guard let self else { return }
            let loaded = await store.allEntries()
            let version = await store.activeVersion()
            entries = loaded
            applySearch(select: id)
            statusLabel.stringValue = status ?? string(
                "離線曲庫 \(version) · \(loaded.count) 個條目",
                "Offline \(version) · \(loaded.count) entries",
                "オフライン \(version)・\(loaded.count)件", "오프라인 \(version) · 항목 \(loaded.count)개"
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
                    + [entry.content.korean].compactMap { $0 } + entry.aliases + entry.creators)
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
        cancelOnlineSearch()
        applySearch()
        statusLabel.stringValue = string(
            "離線結果 · \(filtered.count) 個條目",
            "Offline results · \(filtered.count) entries",
            "オフライン検索・\(filtered.count)件", "오프라인 검색 결과 · 항목 \(filtered.count)개"
        )
    }

    private func cancelOnlineSearch() {
        searchGeneration += 1
        onlineSearchTask?.cancel()
        onlineSearchTask = nil
    }

    @objc private func searchOnline() {
        cancelOnlineSearch()
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        applySearch()
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        let queryLanguage: String
        switch language {
        case .traditionalChinese: queryLanguage = "zh-Hant"
        case .english: queryLanguage = "en"
        case .japanese: queryLanguage = "ja"
        case .korean: queryLanguage = "ko"
        }
        statusLabel.stringValue = string("正在查詢 AIMCP…", "Searching AIMCP…", "AIMCPを検索中…", "AIMCP 검색 중…")
        onlineSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await store.search(matching: query, language: queryLanguage, match: .title)
                guard !Task.isCancelled, generation == searchGeneration else { return }
                filtered = result.entries
                tableView.reloadData()
                if let entry = filtered.first {
                    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    showSelection(entry)
                } else { showSelection(nil) }
                statusLabel.stringValue = result.searchedOnline
                    ? string("AIMCP 線上結果 · \(filtered.count) 首", "AIMCP online · \(filtered.count) songs", "AIMCPオンライン・\(filtered.count)曲", "AIMCP 온라인 · 노래 \(filtered.count)곡")
                    : filtered.isEmpty
                        ? string("設定 AIMCP 金鑰後可查詢完整曲庫。", "Set an AIMCP key to search the full catalog.", "AIMCPキーを設定すると全曲を検索できます。", "전체 곡을 검색하려면 AIMCP 키를 설정해 주세요.")
                        : string("離線結果 · \(filtered.count) 個條目", "Offline results · \(filtered.count) entries", "オフライン検索・\(filtered.count)件", "오프라인 검색 결과 · 항목 \(filtered.count)개")
            } catch {
                guard !Task.isCancelled, generation == searchGeneration else { return }
                statusLabel.stringValue = string("AIMCP 查詢失敗", "AIMCP lookup failed", "AIMCPの検索に失敗しました", "AIMCP 검색 실패")
                show(error)
            }
        }
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
            titleLabel.stringValue = string("選擇一個條目", "Select an entry", "項目を選択", "항목을 선택하세요")
            kindLabel.stringValue = ""
            contentLabel.stringValue = string("可搜尋內容、查看來源或標記喜歡的歌曲。", "Search the library, view sources, or mark favorite songs.", "検索、出典の確認、お気に入り登録ができます。", "노래를 검색하고 출처를 확인하거나 좋아하는 노래로 표시할 수 있어요.")
            provenanceLabel.stringValue = ""
            favoriteButton.isHidden = true
            sourceButton.isEnabled = false
            return
        }
        titleLabel.stringValue = entry.displayTitle
        kindLabel.stringValue = kindName(entry.kind)
        contentLabel.stringValue = localizedContent(entry)
        provenanceLabel.stringValue = sourceStatus(entry.sourceStatus) + "\n" + entry.sourceURL
        favoriteButton.isHidden = entry.kind != .song || entry.sourceStatus == .online
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
                refresh(select: selectedEntry()?.id, status: updateStatus(result))
            } catch {
                if error is AIMCPKnowledgeConfiguration.ConfigurationError {
                    showConfigurationError(error)
                } else {
                    show(error)
                }
            }
        }
    }

    @objc private func configureAIMCP() {
        let hasKey: Bool
        do {
            hasKey = try AIMCPKnowledgeConfiguration.hasAPIKey()
        } catch {
            showConfigurationError(error)
            return
        }

        let endpointField = NSTextField(labelWithString: AIMCPKnowledgeConfiguration.defaultEndpoint)
        endpointField.isSelectable = true
        endpointField.lineBreakMode = .byTruncatingMiddle
        let keyField = NSSecureTextField()
        keyField.placeholderString = hasKey
            ? string("留空以保留已儲存的 key", "Leave blank to keep the saved key", "空欄のままなら保存済みキーを維持", "비워 두면 저장된 키가 유지돼요")
            : "aimcp_…"

        let endpointLabel = NSTextField.mikuLabel(
            string("AIMCP 端點", "AIMCP endpoint", "AIMCPエンドポイント", "AIMCP 엔드포인트"),
            size: 11,
            color: MikuTheme.secondaryText
        )
        let keyLabel = NSTextField.mikuLabel(
            hasKey
                ? string("API key（已儲存）", "API key (saved)", "APIキー（保存済み）", "API 키(저장됨)")
                : string("API key", "API key", "APIキー", "API 키"),
            size: 11,
            color: MikuTheme.secondaryText
        )
        let fields = NSStackView(views: [endpointLabel, endpointField, keyLabel, keyField])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        endpointField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        keyField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        fields.frame.size = fields.fittingSize

        let alert = NSAlert()
        alert.messageText = string("AIMCP 歌曲知識", "AIMCP Song Knowledge", "AIMCP楽曲ナレッジ", "AIMCP 노래 지식")
        alert.informativeText = string(
            "key 只存於這部 Mac 的鑰匙圈，僅傳送至 mikuwiki.qimake.com。設定後，手動更新、曲庫搜尋與詢問未收錄歌曲時會連線；查詢只送出歌名或你輸入的搜尋文字，不含對話紀錄。",
            "The key stays in this Mac's Keychain and is sent only to mikuwiki.qimake.com. Once configured, manual updates, catalog searches and questions about missing songs connect to the service. Lookups send only the title or search text, never conversation history.",
            "キーはこのMacのキーチェーンにのみ保存し、mikuwiki.qimake.comにだけ送信します。設定後の手動更新、曲庫検索、未収録曲の質問で接続します。検索時に送るのは曲名や検索語だけで、会話履歴は送りません。",
            "키는 이 Mac의 키체인에만 저장하고 mikuwiki.qimake.com으로만 보내요. 설정 후 수동 업데이트, 곡 검색, 미수록 곡 질문 시 연결해요. 검색에는 곡명이나 입력한 검색어만 보내며 대화 기록은 보내지 않아요."
        )
        alert.accessoryView = fields
        alert.addButton(withTitle: string("儲存", "Save", "保存", "저장"))
        alert.addButton(withTitle: string("取消", "Cancel", "キャンセル", "취소"))
        let clearButton = alert.addButton(withTitle: string("清除 key", "Remove Key", "キーを削除", "키 제거"))
        clearButton.isEnabled = hasKey

        let response = alert.runModal()
        let candidate = keyField.stringValue
        keyField.stringValue = ""
        switch response {
        case .alertFirstButtonReturn:
            do {
                try AIMCPKnowledgeConfiguration.save(
                    apiKey: candidate.isEmpty ? nil : candidate
                )
                statusLabel.stringValue = string(
                    "AIMCP 設定已儲存。",
                    "AIMCP settings saved.",
                    "AIMCP設定を保存しました。", "AIMCP 설정을 저장했어요."
                )
            } catch {
                showConfigurationError(error)
            }
        case .alertThirdButtonReturn:
            do {
                try AIMCPKnowledgeConfiguration.clearAPIKey()
                statusLabel.stringValue = string(
                    "已清除 AIMCP key；更新會使用 GitHub。",
                    "AIMCP key removed; updates will use GitHub.",
                    "AIMCPキーを削除しました。更新にはGitHubを使用します。", "AIMCP 키를 제거했어요. 업데이트는 GitHub를 사용해요."
                )
            } catch {
                showConfigurationError(error)
            }
        default:
            break
        }
    }

    @objc private func importJSON() {
        guard let window = searchField.window ?? window else { return }
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
                        "\(result.importedCount)件を読み込みました", "항목 \(result.importedCount)개를 가져왔어요"
                    )
                    self.refresh()
                } catch {
                    self.show(error)
                }
            }
        }
    }

    @objc private func exportJSON() {
        guard let window = searchField.window ?? window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "miku-knowledge-export.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data = try await self.store.exportJSON()
                    try data.write(to: url, options: [.atomic])
                    self.statusLabel.stringValue = self.string("已匯出", "Exported", "書き出しました", "내보냈어요")
                } catch {
                    self.show(error)
                }
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        updateButton.isEnabled = !busy
        aimcpButton.isEnabled = !busy
        importButton.isEnabled = !busy
        exportButton.isEnabled = !busy
        if busy {
            statusLabel.stringValue = string("正在檢查更新…", "Checking for updates…", "更新を確認中…", "업데이트 확인 중…")
        }
    }

    private func show(_ error: Error) {
        let message: String
        switch error {
        case SongKnowledgeError.tooLarge:
            message = string("檔案超過 1 MB 上限。", "The file exceeds the 1 MB limit.", "ファイルが1 MBの上限を超えています。", "파일이 1MB 제한을 초과해요.")
        case SongKnowledgeError.invalidJSON,
             SongKnowledgeError.invalidSchema,
             SongKnowledgeError.duplicateID,
             SongKnowledgeError.invalidSourceURL:
            message = string("JSON 格式或內容不符合知識庫規格，原有資料未變更。", "The JSON does not match the knowledge format. Existing data was kept.", "JSONがナレッジ形式に合わないため、既存データを保持しました。", "JSON이 지식 형식에 맞지 않아요. 기존 자료는 유지했어요.")
        case SongKnowledgeError.httpStatus(401):
            message = string("AIMCP API key 無效，請更新設定。", "The AIMCP API key is invalid. Update it in settings.", "AIMCP APIキーが無効です。設定を更新してください。", "AIMCP API 키가 올바르지 않아요. 설정에서 변경해 주세요.")
        case SongKnowledgeError.httpStatus(403):
            message = string("此 AIMCP key 無法使用，請重新產生。", "This AIMCP key cannot be used. Create a new one.", "このAIMCPキーは使用できません。新しいキーを作成してください。", "이 AIMCP 키는 사용할 수 없어요. 새 키를 만들어 주세요.")
        case SongKnowledgeError.httpStatus(429):
            message = string("AIMCP 請求過於頻繁，請稍後再試。", "Too many AIMCP requests. Please try again later.", "AIMCPへのリクエストが多すぎます。しばらくしてから再試行してください。", "AIMCP 요청이 너무 많아요. 나중에 다시 시도해 주세요.")
        case SongKnowledgeError.httpStatus, SongKnowledgeError.invalidResponse:
            message = string("更新伺服器未能提供有效資料，原有資料未變更。", "The update server did not provide valid data. Existing data was kept.", "更新サーバーから有効なデータを取得できなかったため、既存データを保持しました。", "업데이트 서버에서 올바른 자료를 받지 못했어요. 기존 자료는 유지했어요.")
        case is URLError:
            message = string("暫時無法連線檢查更新，請稍後再試。", "Could not connect to check for updates. Please try again later.", "更新を確認できませんでした。時間をおいて再度お試しください。", "업데이트 확인을 위해 연결할 수 없어요. 나중에 다시 시도해 주세요.")
        default:
            message = string("操作失敗，原有資料未變更。", "The operation failed. Existing data was kept.", "操作に失敗したため、既存データを保持しました。", "작업에 실패했어요. 기존 자료는 유지했어요.")
        }
        statusLabel.stringValue = message
    }

    private func updateStatus(_ result: SongKnowledgeStore.UpdateResult) -> String {
        switch result.source {
        case .aimcp:
            return string(
                "已更新熱門離線曲庫 · \(result.entryCount) 首",
                "Popular offline catalog updated · \(result.entryCount) songs",
                "人気曲をオフライン保存しました・\(result.entryCount)曲", "인기곡 오프라인 목록을 업데이트했어요 · \(result.entryCount)곡"
            )
        case .github:
            return string(
                "已從 GitHub 更新至 \(result.version)",
                "Updated to \(result.version) from GitHub",
                "GitHubから\(result.version)に更新しました", "GitHub에서 \(result.version) 버전으로 업데이트했어요"
            )
        case .githubFallback:
            return string(
                "AIMCP 暫時不可用；已從 GitHub 更新至 \(result.version)",
                "AIMCP was unavailable; updated to \(result.version) from GitHub",
                "AIMCPに接続できないため、GitHubから\(result.version)に更新しました", "AIMCP를 사용할 수 없어 GitHub에서 \(result.version) 버전으로 업데이트했어요"
            )
        }
    }

    private func showConfigurationError(_ error: Error) {
        let message: String
        switch error {
        case AIMCPKnowledgeConfiguration.ConfigurationError.invalidAPIKey:
            message = string("AIMCP API key 格式無效。", "The AIMCP API key format is invalid.", "AIMCP APIキーの形式が無効です。", "AIMCP API 키 형식이 올바르지 않아요.")
        case AIMCPKnowledgeConfiguration.ConfigurationError.missingAPIKey:
            message = string("請輸入 AIMCP API key。", "Enter an AIMCP API key.", "AIMCP APIキーを入力してください。", "AIMCP API 키를 입력해 주세요.")
        case AIMCPKnowledgeConfiguration.ConfigurationError.keychainFailure(let status):
            message = string(
                "無法存取 Mac 鑰匙圈；如 macOS 顯示授權提示，請允許後重試（錯誤碼 \(status)）。",
                "Could not access the Mac Keychain. If macOS asks for access, allow it and try again (error \(status)).",
                "Macのキーチェーンにアクセスできません。macOSの確認が表示された場合は許可して再試行してください（エラー \(status)）。", "Mac 키체인에 접근할 수 없어요. macOS에서 접근 권한을 요청하면 허용한 뒤 다시 시도해 주세요(오류 \(status))."
            )
        default:
            message = string(
                "未能儲存 AIMCP 設定，請再試一次。",
                "Could not save the AIMCP settings. Please try again.",
                "AIMCP設定を保存できませんでした。もう一度お試しください。", "AIMCP 설정을 저장할 수 없어요. 다시 시도해 주세요."
            )
        }
        statusLabel.stringValue = message
    }

    private func localizedContent(_ entry: SongKnowledgeEntry) -> String {
        switch language {
        case .traditionalChinese: return entry.content.traditionalChinese
        case .english: return entry.content.english
        case .japanese: return entry.content.japanese
        case .korean: return entry.content.korean.flatMap { $0.isEmpty ? nil : $0 } ?? entry.content.english
        }
    }

    private func kindName(_ kind: SongKnowledgeKind) -> String {
        switch kind {
        case .song: return string("歌曲", "Song", "楽曲", "노래")
        case .performance: return string("演出", "Performance", "公演", "공연")
        case .character: return string("角色", "Character", "キャラクター", "캐릭터")
        }
    }

    private func sourceStatus(_ status: SongKnowledgeSourceStatus) -> String {
        switch status {
        case .bundled: return string("內建已核實資料", "Bundled verified data", "内蔵の確認済みデータ", "내장된 검증 자료")
        case .remote: return string("手動下載更新", "Manually downloaded update", "手動で取得した更新", "직접 다운로드한 업데이트")
        case .manual: return string("使用者手動匯入", "Manually imported by user", "ユーザーが手動で読み込み", "사용자가 직접 가져온 자료")
        case .online: return string("AIMCP 線上資料", "AIMCP online reference", "AIMCPのオンライン資料", "AIMCP 온라인 자료")
        }
    }

    private func string(_ traditionalChinese: String, _ english: String, _ japanese: String, _ korean: String) -> String {
        Self.text(language, traditionalChinese, english, japanese, korean)
    }

    private static func text(_ language: Language, _ traditionalChinese: String, _ english: String, _ japanese: String, _ korean: String) -> String {
        switch language {
        case .traditionalChinese: return traditionalChinese
        case .english: return english
        case .japanese: return japanese
        case .korean: return korean
        }
    }
}

// MARK: - In Miku's notebook

extension SongKnowledgeWindowController: NotebookPage {
    func notebookPageWillAppear() {
        refreshLocalization()
    }

    /// Laid out for a normal title bar; the notebook's is transparent.
    var notebookTopInset: CGFloat { 30 }
}
