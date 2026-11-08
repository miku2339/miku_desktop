# Windows 版架構規劃

狀態：共用橋接層與 macOS 雲端 AI 設定已完成；Windows 外殼尚未合入 main。

## 1. 結論

- **同一個倉庫、同一條 main**，新增 `windows/` 目錄放 Windows 外殼。
- **不 fork、不開長期分支**：Miku 本體網頁 `Wallpaper/companion` 是兩個平台共用的，只能有一份。fork 或長期分支會讓睡姿、表情、場景等每次修改都要搬兩次，越久衝突越多。
- 開發時照常開**短期功能分支**（例如 `windows/shell-skeleton`），做完一段就合回 main。
- 外殼用 **Tauri 2（Rust）+ WebView2**：安裝檔小（約 10 MB 級，Electron 約 100 MB 以上），WebView2 是 Windows 10/11 內建，Rust 呼叫 Win32 API 方便。

## 2. 現況：哪些能共用

| 部分 | 規模 | Windows 版 |
| --- | --- | --- |
| `Wallpaper/companion`（three.js、場景、睡眠、手勢、小遊戲畫面） | 約 1.2 萬行 JS | **直接共用** |
| `Wallpaper/assets`（場景圖、模型、被子圖層） | — | 直接共用，Tda 模型仍由使用者自行匯入 |
| 曲庫、人格設定（`docs/miku-persona.md`）、提示詞規則 | — | 共用內容，邏輯需移植 |
| `Sources/MikuDesktop`（AppKit 外殼） | 53 檔、約 2.1 萬行 Swift | **重寫** |

網頁和原生之間的介面目前很乾淨，這是能共用的關鍵：

- 網頁 → 原生：只有一個 `window.webkit.messageHandlers.miku.postMessage(...)`，訊息類型有 `bounds`、`drag`、`pin`、`touch`、`handHold`、`haptic`、`sleep`、`diag`。
- 原生 → 網頁：只呼叫 `window.mikuCompanion.*`（`setInteractive`、`startVoice`、`receiveReply`、`setSleep`、`setScene`、`hitTest`、`status` 等約 25 個方法）。

## 3. 架構

```
miku_desktop/
├─ Wallpaper/companion/      ← 共用網頁（兩平台同一份）
│   └─ bridge.js             ← 新增：平台橋接層
├─ Sources/MikuDesktop/      ← macOS 外殼（Swift，不變）
├─ windows/                  ← 新增：Windows 外殼
│   ├─ src-tauri/            ← Rust：視窗、系統 API、資料存取
│   ├─ ui/                   ← 聊天、手帳、設定等視窗（網頁 UI）
│   └─ scripts/              ← 建置、打包（MSI / NSIS）
└─ shared/                   ← 視情況新增：兩邊共用的規則資料（JSON）
```

### 3.1 橋接層 `bridge.js`

把 `companion.js` 裡直接用到 `window.webkit` 的兩處（`hasNativeBridge`、送訊息）改成呼叫 `bridge.js`：

- macOS：轉給 `webkit.messageHandlers.miku`（行為不變）。
- Windows：轉給 Tauri 的 `invoke('miku_message', { message })`，Windows 外殼要註冊這個指令。
- 原生 → 網頁仍維持 `window.mikuCompanion.*`，Tauri 端用 `webview.eval(...)` 呼叫，與 Swift 端 `evaluate(...)` 對應。

這是**第一步、而且唯一要動共用程式碼的地方**，改完 macOS 版要能照常通過全部測試。

### 3.2 各模組對照

| 功能 | macOS 現在 | Windows 做法 | 難度 |
| --- | --- | --- | --- |
| 桌布層（背景 + 角色兩個 WebView） | 桌面層級 `NSPanel` | 把視窗掛到 `WorkerW`（桌面圖示後面），角色層用無邊框透明置頂視窗 | 高 |
| 點穿與點擊判定 | `ignoresMouseEvents` + `hitTest` 輪詢 | `WS_EX_TRANSPARENT` / `WS_EX_LAYERED` 動態切換，同樣用 `mikuCompanion.hitTest` 判定 | 高 |
| 多螢幕、所有桌面都顯示 | `canJoinAllSpaces` | 每個螢幕一組視窗；虛擬桌面用 `IVirtualDesktopManager` 固定 | 中 |
| 本機網頁伺服器 | `StaticHTTPServer` | Tauri 自訂協定（`asset://`）或內建小型 HTTP 服務，同樣要能讀匯入的模型目錄 | 低 |
| 聊天 AI | OpenAI 相容端點（預設 oMLX `127.0.0.1:8000/v1`） | **Ollama**，見 3.3 | 低 |
| 提示詞、記憶、主動說話規則 | Swift（`LocalAI`、`AwarenessPolicy` 等） | 移植到 Rust 或 TS；可把規則資料抽成 `shared/` JSON 兩邊共用 | 中 |
| 語音合成（TTS） | HTTP 端點 + `AVAudioPlayer` | 同樣的 HTTP 端點，播放用 WebView 的 Web Audio 或 Rust 音訊庫 | 低 |
| 語音辨識 | `SFSpeechRecognizer` / SpeechAnalyzer | Windows.Media.SpeechRecognition，或本機 whisper.cpp | 中 |
| 通話音訊、語音活動偵測 | AVFoundation、SoundAnalysis | WASAPI（`cpal`）+ 簡單能量偵測或 Silero VAD | 中 |
| 讀取正在播放的影音 | AppleScript + Automation 權限 | `GlobalSystemMediaTransportControlsSessionManager`（SMTC），不需另外授權 | 中 |
| 前景程式、全螢幕、專注模式 | `NSWorkspace`、Focus | `GetForegroundWindow`、`SHQueryUserNotificationState`（勿擾 / 全螢幕簡報） | 中 |
| 播歌（YouTube / Spotify / Apple Music） | 開 URL | 同樣開 URL；Apple Music 改為網頁版 | 低 |
| 回憶相簿截圖 | `MemoryPhotoCapture` | WebView2 `CapturePreview` | 低 |
| 資料存放 | `~/Library/Application Support/MikuDesktop`、`UserDefaults` | `%APPDATA%\MikuDesktop`，格式沿用 `memory.json`、`album.json`、`events.json`，方便跨平台搬資料 | 低 |
| 金鑰 | Keychain | Windows Credential Manager | 低 |
| 開機啟動 | `LoginItemManager` | 登錄機碼 `Run` 或 Tauri autostart 外掛 | 低 |
| 自動更新 | `AppUpdate` | Tauri updater（需簽章） | 中 |
| 聊天、手帳、設定視窗 | AppKit | 網頁 UI（`windows/ui/`），視覺沿用 Miku 主題 | 中，工作量最大 |

### 3.3 本機 AI：Ollama

oMLX 只能在 Apple Silicon 上跑，Windows 版預設用 Ollama：

- 端點預設 `http://127.0.0.1:11434/v1`。Ollama 提供 OpenAI 相容的 `/v1/chat/completions`，現有的請求格式（`LocalAI` 的 `chat/completions`）可以照搬。
- Ollama 本機服務不需要 API 金鑰；macOS 版讀 `~/.omlx/settings.json` 取金鑰的邏輯，Windows 版不用移植。
- 設定頁保留自訂端點，讓使用者也能改用 LM Studio 等其他 OpenAI 相容服務。
- 首次啟動檢查：Ollama 是否有在跑（`GET /api/version`）、設定的模型是否已下載（`GET /api/tags`）。缺少時在設定頁提示安裝或執行 `ollama pull <模型>`，不自動下載。
- 聊天圖片：選用支援影像輸入的模型時才開放傳圖。
- 預設模型與顯示卡需求要先在 Windows 實機測過再決定，寫進下載頁。

### 3.4 雲端模型（macOS、Windows 都支援）

本機模型之外，使用者可改用雲端模型，**API 金鑰由使用者自己填**：

- 設定頁選「本機」或「雲端」。雲端填端點、模型名稱、API 金鑰，走同一個 OpenAI 相容的 `chat/completions` 介面。
- 金鑰只存在系統的安全儲存：macOS 用 Keychain，Windows 用 Credential Manager。不寫進設定檔、記錄檔或診斷檔，也不隨 App 發佈任何預設金鑰。
- 只在請求標頭 `Authorization: Bearer …` 送給使用者設定的那個端點，不送去其他地方。
- 切到雲端時清楚提示：聊天內容、記憶摘要、正在看的影音名稱等會送到該服務。感知相關內容（前景程式、影音標題）另設開關，預設不送雲端。
- 連線失敗、金鑰無效、額度用完時，在聊天中用 Miku 的口吻簡短說明，並把錯誤類型（不含金鑰）寫進 `diagnostics.log`。
- macOS 版已完成（`AIConfiguration` 的 `aiProvider`、`cloudEndpoint`、`cloudModel`、`cloudSharesAwareness`，金鑰在 Keychain 的 `com.qimake.MikuDesktop.cloudAI`）。Windows 版沿用同一套設定名稱。

## 4. 規則與限制（沿用 AGENTS.md）

- GPT-SoVITS Miku 聲音只供擁有者使用：Windows 版公開建置**不得包含**任何語音模型、金鑰或語音素材，`voice-training/` 維持在 `.gitignore`。
- 公開版不附 Tda 模型，維持使用者自行匯入。
- 修改提示詞、主動說話、日記、小遊戲台詞時，對照 `docs/miku-persona.md`，兩個平台行為要一致。
- 歌曲知識庫只放曲名、作者與來源連結。

## 5. 分階段

1. **橋接層**（已完成）：新增 `bridge.js`，`companion.js` 改走橋接；macOS 版測試全部通過、行為不變。
   - macOS 版加入雲端模型設定（3.4，已完成）。
2. **Windows 外殼骨架**：Tauri 專案，能在 Windows 上顯示背景 + 角色兩層、點穿、拖曳、多螢幕。
3. **聊天**：聊天視窗、接 Ollama、記憶檔、提示詞與人格規則。
4. **語音**：TTS 播放與嘴型同步、語音辨識、通話。
5. **感知與主動說話**：前景程式、全螢幕 / 勿擾、SMTC 讀取影音、安靜時段。
6. **其他視窗與功能**：手帳、設定、回憶相簿、特別日子、小遊戲、曲庫。
7. **打包發佈**：安裝檔、程式碼簽章、自動更新、網站下載頁。

第 1 步在 Mac 上就能做和驗證；第 2 步起需要 Windows 10/11 實機或虛擬機（Apple Silicon 可用 Parallels 的 Windows 11 ARM，但最終要在 x64 實機測過）。

## 6. 測試

- 共用網頁：現有 `node --test Tests/*.test.mjs` 繼續跑，兩平台共用。
- Windows 外殼：Rust 單元測試（`cargo test`）涵蓋提示詞、記憶、主動說話規則；可移植的規則用同一組測試資料對照 Swift 版結果。
- CI：GitHub Actions 加 `windows-latest` 建置與測試。

## 7. 待決定

- 外殼框架：Tauri（建議）還是 Electron（全用 JS、開發較快，但體積大、記憶體高）。
- 規則邏輯：各平台各寫一份，還是抽成共用資料 / 共用核心。
- 是否支援 Windows 10，或只支援 Windows 11。
- Ollama 預設模型與最低硬體需求（顯示卡、記憶體）。
