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
        "room": [.traditionalChinese: "Miku 的房間", .english: "Miku's Room", .japanese: "ミクの部屋"],
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
        "attachImage": [.traditionalChinese: "加入圖片（也可拖放或貼上）", .english: "Add a picture (or drag & drop / paste)", .japanese: "画像を追加（ドラッグ＆ドロップ・ペーストも可）"],
        "removeImage": [.traditionalChinese: "移除圖片", .english: "Remove picture", .japanese: "画像を外す"],
        "imagePrompt": [.traditionalChinese: "你看看這張圖片。", .english: "Take a look at this picture.", .japanese: "この画像を見て。"],
        "imageUnreadable": [.traditionalChinese: "讀不到這張圖片。", .english: "Couldn't read that picture.", .japanese: "この画像を読み込めませんでした。"],
        "errorImage": [.traditionalChinese: "目前的模型「%@」看不了圖片。請在設定改用支援圖片的模型（例如視覺版 VL 模型）。", .english: "The current model “%@” can't see pictures. Choose a vision (VL) model in Settings.", .japanese: "現在のモデル「%@」は画像を読めません。設定で画像対応（VL）モデルを選んでください。"],
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
        "sectionMemory": [.traditionalChinese: "記憶", .english: "Memory", .japanese: "記憶"],
        "memoryEnabled": [.traditionalChinese: "記住對話", .english: "Remember chats", .japanese: "会話を覚える"],
        "memoryHint": [.traditionalChinese: "只儲存在這部 Mac。", .english: "Stored only on this Mac.", .japanese: "このMacにだけ保存されます。"],
        "memoryFacts": [.traditionalChinese: "記得的事", .english: "Remembers", .japanese: "覚えていること"],
        "memoryNone": [.traditionalChinese: "還沒有記住任何事。", .english: "Nothing remembered yet.", .japanese: "まだ何も覚えていません。"],
        "memoryStatus": [.traditionalChinese: "記得 %@ 件事 · 好感度 %@/100（%@）", .english: "%@ things remembered · Affection %@/100 (%@)", .japanese: "覚えていること %@ 件 · 好感度 %@/100（%@）"],
        "relationshipDating": [.traditionalChinese: "交往中", .english: "dating", .japanese: "交際中"],
        "friendLevel0": [.traditionalChinese: "剛認識", .english: "just met", .japanese: "知り合ったばかり"],
        "friendLevel1": [.traditionalChinese: "朋友", .english: "friends", .japanese: "友だち"],
        "friendLevel2": [.traditionalChinese: "好朋友", .english: "good friends", .japanese: "仲良し"],
        "friendLevel3": [.traditionalChinese: "很要好的朋友", .english: "close friends", .japanese: "大の仲良し"],
        "memoryUpset": [.traditionalChinese: "她還在生你的氣——在聊天裡好好道歉吧。", .english: "She's still upset with you — apologise to her in the chat.", .japanese: "まだ怒っています。チャットでちゃんと謝ろう。"],
        "memoryDelete": [.traditionalChinese: "忘記這件事", .english: "Forget this", .japanese: "これを忘れる"],
        "memoryErase": [.traditionalChinese: "清除全部記憶", .english: "Erase all memories", .japanese: "すべての記憶を消去"],
        "memoryEraseConfirm": [.traditionalChinese: "要清除 Miku 的全部記憶嗎？", .english: "Erase all of Miku's memories?", .japanese: "ミクの記憶をすべて消去しますか？"],
        "memoryEraseDetail": [.traditionalChinese: "她的性格、界線和你的設定都會保留。", .english: "Her personality, her boundaries and your settings stay as they are.", .japanese: "性格、境界線、あなたの設定はそのまま残ります。"],
        "resetMemoryMenu": [.traditionalChinese: "重設 Miku 的記憶…", .english: "Reset Miku's Memory…", .japanese: "ミクの記憶をリセット…"],
        "sectionAwareness": [.traditionalChinese: "Miku 留意你在做什麼", .english: "What Miku notices", .japanese: "ミクが気づくこと"],
        "awareness_activity": [.traditionalChinese: "使用中的 App 與作息", .english: "Apps & breaks", .japanese: "使用中のアプリと休憩"],
        "awareness_media": [.traditionalChinese: "正在播放的音樂", .english: "Music playing", .japanese: "再生中の音楽"],
        "awareness_video": [.traditionalChinese: "YouTube・ニコニコ動画", .english: "YouTube / Niconico", .japanese: "YouTube・ニコニコ動画"],
        "awareness_screen": [.traditionalChinese: "定時看看畫面", .english: "Glance at the screen", .japanese: "ときどき画面を見る"],
        "everyMinutes": [.traditionalChinese: "每 %@ 分鐘", .english: "Every %@ min", .japanese: "%@ 分ごと"],
        "awarenessScreenUnavailable": [.traditionalChinese: "畫面功能需要 macOS 14 或以上。", .english: "Screen awareness requires macOS 14 or later.", .japanese: "画面を見る機能にはmacOS 14以降が必要です。"],
        "awarenessHint": [.traditionalChinese: "全部預設關閉，只在這部 Mac 處理。她大約二、三十分鐘才主動說一句；你回來或用了很久電腦時會提早。音樂和影片只讀歌名與 YouTube／ニコニコ的影片標題；畫面只交給本機模型看，不會儲存。第一次使用時 macOS 會詢問權限。", .english: "All off by default and handled on this Mac only. She speaks up on her own about every 20–30 minutes, sooner when you come back or have been at it a long time. Music and video only read the song and the YouTube / Niconico video title; the screen is shown only to the local model and never stored. macOS asks for permission the first time.", .japanese: "すべて初期設定はオフで、このMacの中だけで処理します。自分から話しかけるのは二、三十分に一度くらい（戻ってきたときや長時間作業しているときは早め）。音楽と動画は曲名とYouTube／ニコニコの動画タイトルだけを読み取り、画面はローカルモデルに見せるだけで保存しません。初回はmacOSが許可を求めます。"],
        "awarenessScreenPermission": [.traditionalChinese: "畫面：請在「系統設定 › 私隱與安全性 › 螢幕與系統錄音」允許 Miku Desktop，然後重新開啟 App。", .english: "Screen: allow Miku Desktop in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app.", .japanese: "画面：「システム設定 › プライバシーとセキュリティ › 画面収録とシステムオーディオ録音」で Miku Desktop を許可し、アプリを開き直してください。"],
        "memoryEraseSummary": [.traditionalChinese: "她會忘記：%@ 則對話、%@ 件記得關於你的事、友好度 %@/100、認識了 %@ 天的回憶，以及觸摸記錄。", .english: "She will forget: %@ messages, %@ things she remembers about you, friendship %@/100, %@ days of knowing you, and the touch history.", .japanese: "忘れてしまうもの：会話 %@ 件、あなたについて覚えていること %@ 件、仲良し度 %@/100、知り合って %@ 日分の思い出、ふれあいの記録。"],
        "memoryEraseContinue": [.traditionalChinese: "繼續…", .english: "Continue…", .japanese: "続ける…"],
        "memoryEraseWord": [.traditionalChinese: "重設", .english: "RESET", .japanese: "リセット"],
        "memoryEraseTypeTitle": [.traditionalChinese: "真的要重設嗎？", .english: "Are you really sure?", .japanese: "本当にリセットしますか？"],
        "memoryEraseTypeDetail": [.traditionalChinese: "請輸入「%@」以確認。重設後，可以在「設定 › 記憶」復原一次。", .english: "Type “%@” to confirm. You can undo it once from Settings › Memory.", .japanese: "確認のため「%@」と入力してください。リセット後、「設定 › 記憶」から一度だけ元に戻せます。"],
        "memoryEraseMismatch": [.traditionalChinese: "輸入的字不符，已取消，記憶沒有改變。", .english: "That didn't match, so nothing was reset.", .japanese: "入力が一致しないため、取り消しました。記憶はそのままです。"],
        "memoryOperationFailed": [.traditionalChinese: "未能完成操作，現有記憶已保留。請檢查儲存空間與檔案存取權限。", .english: "Couldn't complete the operation. Existing memories were kept. Check storage space and file permissions.", .japanese: "操作を完了できませんでした。現在の記憶は保持されています。空き容量とファイルへのアクセス権を確認してください。"],
        "memoryRestore": [.traditionalChinese: "復原重設前的記憶", .english: "Undo the reset", .japanese: "リセット前に戻す"],
        "memoryRestoreConfirm": [.traditionalChinese: "要復原重設前的記憶嗎？", .english: "Undo the last reset?", .japanese: "リセット前の記憶に戻しますか？"],
        "memoryRestoreDetail": [.traditionalChinese: "重設之後的新對話和改變會被重設前的記憶取代。", .english: "Anything new since the reset will be replaced by what she remembered before it.", .japanese: "リセット後の新しい会話や変化は、リセット前の記憶に置き換わります。"],
        "memoryBackupDelete": [.traditionalChinese: "永久刪除備份", .english: "Delete backup for good", .japanese: "バックアップを完全に削除"],
        "memoryBackupDeleteConfirm": [.traditionalChinese: "要永久刪除重設前的備份嗎？", .english: "Delete the backup for good?", .japanese: "バックアップを完全に削除しますか？"],
        "memoryBackupDeleteDetail": [.traditionalChinese: "刪除後就不能再復原重設前的記憶。", .english: "After this the reset can no longer be undone.", .japanese: "削除すると、リセット前の記憶には戻せなくなります。"],
        "cancel": [.traditionalChinese: "取消", .english: "Cancel", .japanese: "キャンセル"],
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
        "connectionOKNoList": [.traditionalChinese: "已連線 ♪", .english: "Connected ♪", .japanese: "接続 OK♪"],
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
        "ambientBackground": [.traditionalChinese: "動態背景", .english: "Living background", .japanese: "動く背景"],
        "ambientHint": [.traditionalChinese: "天氣、電車、車輛與光影", .english: "Weather, trains, traffic and light", .japanese: "天気・電車・車・光"],
        "weather": [.traditionalChinese: "天氣", .english: "Weather", .japanese: "天気"],
        "weatherCity": [.traditionalChinese: "城市", .english: "City", .japanese: "都市"],
        "weatherauto": [.traditionalChinese: "跟隨實際天氣", .english: "Follow real weather", .japanese: "実際の天気に合わせる"],
        "weatherclear": [.traditionalChinese: "晴朗", .english: "Clear", .japanese: "晴れ"],
        "weathercloudy": [.traditionalChinese: "多雲", .english: "Cloudy", .japanese: "くもり"],
        "weatherrain": [.traditionalChinese: "下雨", .english: "Rain", .japanese: "雨"],
        "weatherstorm": [.traditionalChinese: "雷雨", .english: "Thunderstorm", .japanese: "雷雨"],
        "weathersnow": [.traditionalChinese: "下雪", .english: "Snow", .japanese: "雪"],
        "weatherfog": [.traditionalChinese: "起霧", .english: "Fog", .japanese: "霧"],
        "weatherUnavailable": [.traditionalChinese: "暫時取得不到實際天氣，先用晴天。", .english: "Couldn't fetch live weather; using clear skies for now.", .japanese: "天気を取得できないため、晴れで表示中です。"],
        "weatherFixed": [.traditionalChinese: "固定天氣", .english: "Fixed weather", .japanese: "固定の天気"],
        "citytokyo": [.traditionalChinese: "東京", .english: "Tokyo", .japanese: "東京"],
        "cityyokohama": [.traditionalChinese: "橫濱", .english: "Yokohama", .japanese: "横浜"],
        "cityosaka": [.traditionalChinese: "大阪", .english: "Osaka", .japanese: "大阪"],
        "citykyoto": [.traditionalChinese: "京都", .english: "Kyoto", .japanese: "京都"],
        "citynagoya": [.traditionalChinese: "名古屋", .english: "Nagoya", .japanese: "名古屋"],
        "citysapporo": [.traditionalChinese: "札幌", .english: "Sapporo", .japanese: "札幌"],
        "cityfukuoka": [.traditionalChinese: "福岡", .english: "Fukuoka", .japanese: "福岡"],
        "cityhongkong": [.traditionalChinese: "香港", .english: "Hong Kong", .japanese: "香港"],
        "citytaipei": [.traditionalChinese: "台北", .english: "Taipei", .japanese: "台北"],
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
