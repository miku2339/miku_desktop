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
        "chat": [.traditionalChinese: "聊天", .english: "Chat", .japanese: "チャット"],
        "interaction": [.traditionalChinese: "互動模式", .english: "Interaction Mode", .japanese: "インタラクション"],
        "scene": [.traditionalChinese: "場景", .english: "Scene", .japanese: "シーン"],
        "autoScene": [.traditionalChinese: "自動換場景", .english: "Automatic", .japanese: "自動切替"],
        "shibuya": [.traditionalChinese: "澀谷", .english: "Shibuya", .japanese: "渋谷"],
        "ikebukuro": [.traditionalChinese: "池袋", .english: "Ikebukuro", .japanese: "池袋"],
        "akihabara": [.traditionalChinese: "秋葉原", .english: "Akihabara", .japanese: "秋葉原"],
        "shinjuku": [.traditionalChinese: "新宿", .english: "Shinjuku", .japanese: "新宿"],
        "hallway": [.traditionalChinese: "校園走廊", .english: "School Hallway", .japanese: "学校の廊下"],
        "musicroom": [.traditionalChinese: "音樂教室", .english: "Music Room", .japanese: "音楽室"],
        "settings": [.traditionalChinese: "設定…", .english: "Settings…", .japanese: "設定…"],
        "edit": [.traditionalChinese: "編輯", .english: "Edit", .japanese: "編集"],
        "undo": [.traditionalChinese: "還原", .english: "Undo", .japanese: "取り消す"],
        "redo": [.traditionalChinese: "重做", .english: "Redo", .japanese: "やり直す"],
        "cut": [.traditionalChinese: "剪下", .english: "Cut", .japanese: "カット"],
        "copy": [.traditionalChinese: "複製", .english: "Copy", .japanese: "コピー"],
        "paste": [.traditionalChinese: "貼上", .english: "Paste", .japanese: "ペースト"],
        "selectAll": [.traditionalChinese: "全選", .english: "Select All", .japanese: "すべてを選択"],
        "quit": [.traditionalChinese: "退出 Miku Desktop", .english: "Quit Miku Desktop", .japanese: "Miku Desktop を終了"],
        "send": [.traditionalChinese: "發送", .english: "Send", .japanese: "送信"],
        "sending": [.traditionalChinese: "Miku 正在回覆…", .english: "Miku is replying…", .japanese: "ミクが返信中…"],
        "retry": [.traditionalChinese: "重試", .english: "Retry", .japanese: "再試行"],
        "messagePlaceholder": [.traditionalChinese: "同 Miku 講啲嘢…", .english: "Say something to Miku…", .japanese: "ミクに話しかける…"],
        "replyFailed": [.traditionalChinese: "暫時未能取得回覆，請重試。", .english: "Could not get a reply. Please try again.", .japanese: "返信を取得できませんでした。もう一度お試しください。"],
        "personality": [.traditionalChinese: "性格", .english: "Personality", .japanese: "性格"],
        "lively": [.traditionalChinese: "活潑", .english: "Lively", .japanese: "元気"],
        "gentle": [.traditionalChinese: "溫柔", .english: "Gentle", .japanese: "優しい"],
        "quiet": [.traditionalChinese: "安靜", .english: "Quiet", .japanese: "静か"],
        "custom": [.traditionalChinese: "自訂", .english: "Custom", .japanese: "カスタム"],
        "customPersonality": [.traditionalChinese: "自訂描述", .english: "Custom description", .japanese: "カスタム説明"],
        "nickname": [.traditionalChinese: "你的稱呼", .english: "Your nickname", .japanese: "あなたの呼び名"],
        "replyLanguage": [.traditionalChinese: "回覆語言", .english: "Reply language", .japanese: "返信言語"],
        "interfaceLanguage": [.traditionalChinese: "介面語言", .english: "Interface language", .japanese: "表示言語"],
        "aiEndpoint": [.traditionalChinese: "本機 AI 端點", .english: "Local AI endpoint", .japanese: "ローカル AI エンドポイント"],
        "aiModel": [.traditionalChinese: "AI 模型", .english: "AI model", .japanese: "AI モデル"],
        "launchAtLogin": [.traditionalChinese: "登入時啟動", .english: "Launch at login", .japanese: "ログイン時に起動"],
        "automatic": [.traditionalChinese: "自動", .english: "Automatic", .japanese: "自動"],
        "traditionalChinese": [.traditionalChinese: "繁體中文", .english: "Traditional Chinese", .japanese: "繁体字中国語"],
        "english": [.traditionalChinese: "English", .english: "English", .japanese: "English"],
        "japanese": [.traditionalChinese: "日本語", .english: "Japanese", .japanese: "日本語"],
        "loginItemError": [.traditionalChinese: "未能更新登入項目。", .english: "Could not update the login item.", .japanese: "ログイン項目を更新できませんでした。"]
    ]

    static func text(_ key: String) -> String {
        strings[key]?[AppLanguage.resolved] ?? strings[key]?[.english] ?? key
    }
}
