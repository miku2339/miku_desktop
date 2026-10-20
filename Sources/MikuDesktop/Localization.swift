import Foundation

enum AppLanguage: String, CaseIterable {
    case auto
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"

    static var resolved: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "auto"
        if let chosen = AppLanguage(rawValue: stored), chosen != .auto {
            return chosen
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return .traditionalChinese }
        if preferred.hasPrefix("ja") { return .japanese }
        return .english
    }
}

enum L10n {
    private static let strings: [String: [AppLanguage: String]] = [
        // Menus
        "chat": [.traditionalChinese: "聊天", .english: "Chat", .japanese: "チャット"],
        "interaction": [.traditionalChinese: "互動模式", .english: "Interaction Mode", .japanese: "インタラクション"],
        "scene": [.traditionalChinese: "場景", .english: "Scene", .japanese: "シーン"],
        "background": [.traditionalChinese: "背景", .english: "Background", .japanese: "背景"],
        "autoSceneRotation": [.traditionalChinese: "自動輪換", .english: "Auto-rotate", .japanese: "自動切替"],
        "autoScene": [.traditionalChinese: "自動換場景", .english: "Automatic", .japanese: "自動切替"],
        "shibuya": [.traditionalChinese: "澀谷", .english: "Shibuya", .japanese: "渋谷"],
        "ikebukuro": [.traditionalChinese: "池袋", .english: "Ikebukuro", .japanese: "池袋"],
        "akihabara": [.traditionalChinese: "秋葉原", .english: "Akihabara", .japanese: "秋葉原"],
        "shinjuku": [.traditionalChinese: "新宿", .english: "Shinjuku", .japanese: "新宿"],
        "hallway": [.traditionalChinese: "校園走廊", .english: "School Hallway", .japanese: "学校の廊下"],
        "musicroom": [.traditionalChinese: "音樂教室", .english: "Music Room", .japanese: "音楽室"],
        "settings": [.traditionalChinese: "設定…", .english: "Settings…", .japanese: "設定…"],
        "settingsButton": [.traditionalChinese: "設定", .english: "Settings", .japanese: "設定"],
        "resetPositionMenu": [.traditionalChinese: "讓 Miku 自由走動", .english: "Let Miku Roam Freely", .japanese: "ミクを自由に歩かせる"],
        "edit": [.traditionalChinese: "編輯", .english: "Edit", .japanese: "編集"],
        "undo": [.traditionalChinese: "還原", .english: "Undo", .japanese: "取り消す"],
        "redo": [.traditionalChinese: "重做", .english: "Redo", .japanese: "やり直す"],
        "cut": [.traditionalChinese: "剪下", .english: "Cut", .japanese: "カット"],
        "copy": [.traditionalChinese: "複製", .english: "Copy", .japanese: "コピー"],
        "paste": [.traditionalChinese: "貼上", .english: "Paste", .japanese: "ペースト"],
        "selectAll": [.traditionalChinese: "全選", .english: "Select All", .japanese: "すべてを選択"],
        "quit": [.traditionalChinese: "退出 Miku Desktop", .english: "Quit Miku Desktop", .japanese: "Miku Desktop を終了"],

        // Chat
        "send": [.traditionalChinese: "發送", .english: "Send", .japanese: "送信"],
        "sending": [.traditionalChinese: "Miku 正在回覆…", .english: "Miku is replying…", .japanese: "ミクが返信中…"],
        "retry": [.traditionalChinese: "重試", .english: "Retry", .japanese: "再試行"],
        "messagePlaceholder": [.traditionalChinese: "和 Miku 聊聊天…", .english: "Say something to Miku…", .japanese: "ミクに話しかける…"],
        "chatGreetingTitle": [.traditionalChinese: "嗨！我是 Miku ♪", .english: "Hi! I'm Miku ♪", .japanese: "やっほー！ミクだよ♪"],
        "chatGreetingBody": [.traditionalChinese: "想聊什麼都可以，我會在桌面上回應你。", .english: "Talk to me about anything — I'll answer right on your desktop.", .japanese: "なんでも話してね。デスクトップでお返事するよ。"],
        "suggestion1": [.traditionalChinese: "今天過得怎樣？", .english: "How's your day going?", .japanese: "今日はどうだった？"],
        "suggestion2": [.traditionalChinese: "推薦一首歌給我", .english: "Recommend me a song", .japanese: "おすすめの曲を教えて"],
        "suggestion3": [.traditionalChinese: "陪我專心工作一下", .english: "Keep me company while I work", .japanese: "作業中そばにいてね"],
        "statusOnline": [.traditionalChinese: "在線", .english: "Online", .japanese: "オンライン"],
        "statusOffline": [.traditionalChinese: "離線 · 未連上本機 AI", .english: "Offline · local AI unreachable", .japanese: "オフライン · ローカル AI 未接続"],
        "statusChecking": [.traditionalChinese: "連線中…", .english: "Connecting…", .japanese: "接続中…"],
        "clearChat": [.traditionalChinese: "清除對話", .english: "Clear chat", .japanese: "会話を消去"],

        // Errors
        "replyFailed": [.traditionalChinese: "暫時未能取得回覆，請重試。", .english: "Could not get a reply. Please try again.", .japanese: "返信を取得できませんでした。もう一度お試しください。"],
        "errorConnect": [.traditionalChinese: "連不上本機 AI（%@）。請確認 oMLX 已啟動。", .english: "Can't reach the local AI at %@. Make sure oMLX is running.", .japanese: "ローカル AI（%@）に接続できません。oMLX が起動しているか確認してください。"],
        "errorTimeout": [.traditionalChinese: "本機 AI 回覆逾時，模型可能仍在載入。", .english: "The local AI timed out — the model may still be loading.", .japanese: "ローカル AI の応答がタイムアウトしました。モデルを読み込み中かもしれません。"],
        "errorAuth": [.traditionalChinese: "本機 AI 拒絕了請求（API key 不符）。", .english: "The local AI rejected the request (API key mismatch).", .japanese: "ローカル AI にリクエストを拒否されました（API キー不一致）。"],
        "errorNotFound": [.traditionalChinese: "找不到模型「%@」，請在設定中檢查模型名稱。", .english: "Model “%@” was not found. Check the model name in Settings.", .japanese: "モデル「%@」が見つかりません。設定でモデル名を確認してください。"],
        "errorHTTP": [.traditionalChinese: "本機 AI 回傳錯誤（HTTP %@）。", .english: "The local AI returned an error (HTTP %@).", .japanese: "ローカル AI がエラーを返しました（HTTP %@）。"],
        "errorEndpoint": [.traditionalChinese: "端點必須是本機位址（127.0.0.1、localhost 或 ::1）。", .english: "The endpoint must be a loopback address (127.0.0.1, localhost or ::1).", .japanese: "エンドポイントはループバックアドレス（127.0.0.1、localhost、::1）にしてください。"],
        "errorReply": [.traditionalChinese: "Miku 一時語塞了（模型回覆格式不正確），請再試一次。", .english: "Miku got tongue-tied (the model's reply was malformed). Please try again.", .japanese: "ミクが言葉に詰まっちゃった（返答の形式が不正）。もう一度試してね。"],
        "errorUnknown": [.traditionalChinese: "暫時未能取得回覆：%@", .english: "Could not get a reply: %@", .japanese: "返信を取得できませんでした：%@"],

        // Settings
        "settingsTitle": [.traditionalChinese: "Miku 設定", .english: "Miku Settings", .japanese: "ミクの設定"],
        "settingsSubtitle": [.traditionalChinese: "調整她的性格、場景和本機 AI。", .english: "Tune her personality, scenery and local AI.", .japanese: "性格・背景・ローカル AI を調整できます。"],
        "sectionScene": [.traditionalChinese: "場景", .english: "Scenery", .japanese: "シーン"],
        "sectionCharacter": [.traditionalChinese: "角色", .english: "Character", .japanese: "キャラクター"],
        "sectionLanguage": [.traditionalChinese: "語言", .english: "Language", .japanese: "言語"],
        "sectionAI": [.traditionalChinese: "本機 AI", .english: "Local AI", .japanese: "ローカル AI"],
        "sectionGeneral": [.traditionalChinese: "一般", .english: "General", .japanese: "一般"],
        "rotationInterval": [.traditionalChinese: "輪換間隔", .english: "Rotate every", .japanese: "切替間隔"],
        "minutes5": [.traditionalChinese: "5 分鐘", .english: "5 minutes", .japanese: "5 分"],
        "minutes15": [.traditionalChinese: "15 分鐘", .english: "15 minutes", .japanese: "15 分"],
        "minutes30": [.traditionalChinese: "30 分鐘", .english: "30 minutes", .japanese: "30 分"],
        "hour1": [.traditionalChinese: "1 小時", .english: "1 hour", .japanese: "1 時間"],
        "position": [.traditionalChinese: "站立位置", .english: "Standing spot", .japanese: "立ち位置"],
        "positionPinned": [.traditionalChinese: "固定在你拖放的位置", .english: "Pinned where you dropped her", .japanese: "ドラッグした場所に固定中"],
        "positionFree": [.traditionalChinese: "自由走動中（拖曳她即可固定）", .english: "Roaming freely (drag her to pin)", .japanese: "自由に歩き回り中（ドラッグで固定）"],
        "resetPosition": [.traditionalChinese: "讓她自由走動", .english: "Let her roam", .japanese: "自由に歩かせる"],
        "personality": [.traditionalChinese: "性格", .english: "Personality", .japanese: "性格"],
        "lively": [.traditionalChinese: "活潑", .english: "Lively", .japanese: "元気"],
        "gentle": [.traditionalChinese: "溫柔", .english: "Gentle", .japanese: "優しい"],
        "quiet": [.traditionalChinese: "安靜", .english: "Quiet", .japanese: "静か"],
        "custom": [.traditionalChinese: "自訂", .english: "Custom", .japanese: "カスタム"],
        "customPersonality": [.traditionalChinese: "額外描述", .english: "Extra traits", .japanese: "追加の設定"],
        "customPlaceholder": [.traditionalChinese: "例如：喜歡甜食，說話時偶爾哼歌", .english: "e.g. loves sweets, hums while talking", .japanese: "例：甘いものが好きで、時々鼻歌を歌う"],
        "nickname": [.traditionalChinese: "你的稱呼", .english: "Your nickname", .japanese: "あなたの呼び名"],
        "nicknamePlaceholder": [.traditionalChinese: "Miku 會怎樣稱呼你", .english: "What Miku calls you", .japanese: "ミクからの呼ばれ方"],
        "replyLanguage": [.traditionalChinese: "回覆語言", .english: "Reply language", .japanese: "返信言語"],
        "interfaceLanguage": [.traditionalChinese: "介面語言", .english: "Interface language", .japanese: "表示言語"],
        "aiEndpoint": [.traditionalChinese: "端點", .english: "Endpoint", .japanese: "エンドポイント"],
        "aiModel": [.traditionalChinese: "模型", .english: "Model", .japanese: "モデル"],
        "testConnection": [.traditionalChinese: "測試連線", .english: "Test connection", .japanese: "接続テスト"],
        "connectionOK": [.traditionalChinese: "已連線，找到模型 ♪", .english: "Connected — model found ♪", .japanese: "接続 OK・モデルあり♪"],
        "connectionOKNoList": [.traditionalChinese: "伺服器可連線，但未能驗證模型。", .english: "Server reachable, but the model could not be verified.", .japanese: "サーバーに接続できましたが、モデルは確認できませんでした。"],
        "connectionModelMissing": [.traditionalChinese: "已連線，但找不到模型「%@」。", .english: "Connected, but model “%@” is not available.", .japanese: "接続できましたが、モデル「%@」がありません。"],
        "launchAtLogin": [.traditionalChinese: "登入時啟動", .english: "Launch at login", .japanese: "ログイン時に起動"],
        "interactionHint": [.traditionalChinese: "點按、摸頭及拖曳 Miku", .english: "Tap, pat and drag Miku", .japanese: "タップ・なでなで・ドラッグ"],
        "automatic": [.traditionalChinese: "自動", .english: "Automatic", .japanese: "自動"],
        "traditionalChinese": [.traditionalChinese: "繁體中文", .english: "Traditional Chinese", .japanese: "繁体字中国語"],
        "english": [.traditionalChinese: "English", .english: "English", .japanese: "English"],
        "japanese": [.traditionalChinese: "日本語", .english: "Japanese", .japanese: "日本語"],
        "loginItemError": [.traditionalChinese: "未能更新登入項目。", .english: "Could not update the login item.", .japanese: "ログイン項目を更新できませんでした。"],
        "loginItemApproval": [.traditionalChinese: "需要在「系統設定 › 一般 › 登入項目」中允許。", .english: "Allow it in System Settings › General › Login Items.", .japanese: "「システム設定 › 一般 › ログイン項目」で許可してください。"],
        "openSystemSettings": [.traditionalChinese: "開啟系統設定", .english: "Open System Settings", .japanese: "システム設定を開く"],
        "footer": [.traditionalChinese: "Miku Desktop %@ · 非官方同人作品", .english: "Miku Desktop %@ · Unofficial fan project", .japanese: "Miku Desktop %@ · 非公式ファンメイド"]
    ]

    static func text(_ key: String) -> String {
        strings[key]?[AppLanguage.resolved] ?? strings[key]?[.english] ?? key
    }

    /// Replaces each `%@` in order. Avoids `String(format:)` so user text containing `%` is safe.
    static func format(_ key: String, _ arguments: String...) -> String {
        var result = text(key)
        var searchStart = result.startIndex
        for argument in arguments {
            guard let range = result.range(of: "%@", range: searchStart..<result.endIndex) else { break }
            result.replaceSubrange(range, with: argument)
            searchStart = result.index(range.lowerBound, offsetBy: argument.count)
        }
        return result
    }
}
