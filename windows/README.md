# Miku Desktop：Windows 外殼（第二階段骨架）

Tauri 2 + WebView2 的 Windows 外殼。Miku 本體網頁沿用 `Wallpaper/companion/`，兩個平台共用同一份，不複製。整體規劃見 [`docs/windows-port.md`](../docs/windows-port.md)。

> 狀態：Windows CI 的 11 項 Rust 測試及 .exe 連結已通過；Windows 11（10.0.26200）／RTX 3080 的單螢幕 RDP 環境已成功載入兩層頁面與私人匯入的 Tda 模型。桌面圖示保持可見，一般程式可覆蓋角色；觸碰、拖曳與焦點行為仍待完整驗收，NSIS 安裝檔尚未驗證。

## 建置

需要 Windows 10/11 x64：

1. [Rust](https://rustup.rs/)（MSVC 工具鏈，`x86_64-pc-windows-msvc`）及 Visual Studio Build Tools 的「使用 C++ 的桌面開發」。
2. WebView2 Runtime（Windows 11 內建；Windows 10 多半已隨 Edge 安裝）。
3. Tauri CLI：`cargo install tauri-cli --version "^2" --locked`。
4. 備用角色模型（Animasa，從 three.js 範例下載並校驗 SHA-256；已匯入 Tda 時自動優先選用 Tda）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File windows\scripts\fetch-model.ps1
   ```

然後：

```powershell
cd windows\src-tauri
cargo test              # 協定路徑與點穿邏輯的單元測試
cargo tauri dev         # 開發執行：直接讀取倉庫中的 Wallpaper/
cargo tauri build       # 產生 NSIS 安裝檔（target\release\bundle\nsis\）
```

在 Mac 上只能做型別檢查與單元測試，無法產生 .exe（完整連結需要 `cargo-xwin` 之類的工具）。需要 Homebrew 的 `rustup`、`x86_64-pc-windows-msvc` target，以及編譯 Windows 圖示資源用的 `llvm-rc`（Homebrew `llvm`）。也要先有預設模型（`scripts/fetch-model.sh`），因為打包清單會檢查檔案是否存在：

```bash
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/opt/llvm/bin:$PATH"
cd windows/src-tauri
cargo check --target x86_64-pc-windows-msvc
cargo test
```

## 結構

```
windows/
├─ src-tauri/
│  ├─ src/lib.rs          啟動、托盤選單、30 Hz 指標輪詢、螢幕變更檢查
│  ├─ src/protocol.rs     miku:// 協定：提供 Wallpaper/ 及使用者匯入的 Tda 模型
│  ├─ src/layers.rs       每個螢幕一組背景層與角色層視窗、頁面載入後的設定
│  ├─ src/passthrough.rs  點穿判定（對照 macOS updateMousePassthrough）
│  ├─ src/bridge.rs       miku_message / miku_hit_result 指令、原生 → 網頁呼叫
│  ├─ src/desktop.rs      背景層掛到 WorkerW、角色桌面層級與定位
│  ├─ src/settings.rs     settings.json、diagnostics.log
│  ├─ tauri.conf.json     打包資源只列出公開素材
│  └─ capabilities/       不開放任何 Tauri 核心 API 給網頁
├─ ui/                    之後的聊天、手帳、設定視窗（目前是空白頁）
└─ scripts/fetch-model.ps1
```

## 已完成（對照第二階段目標）

1. **共用網頁**：註冊 `miku://` 協定（WebView2 中為 `http://miku.localhost/`），沿用 `StaticHTTPServer.swift` 的規則：只接受 GET/HEAD，拒絕 `..`、反斜線、磁碟代號，並以 canonicalize 確認檔案沒有離開根目錄。
   - Debug 版直接讀倉庫的 `Wallpaper/`，修改網頁後重新載入即可看到；Release 版讀打包進安裝檔的資源。也可用 `MIKU_WALLPAPER_DIR` 指定位置。
   - `../assets/companion-model/` 由同一個根目錄提供。
   - `assets/companion-model/tda/*`：`%APPDATA%\MikuDesktop\CharacterModels\tda\miku.pmx` 存在時，改由該資料夾提供，與 macOS 相同。
2. **兩層視窗、每個螢幕一組**：
   - 背景層 `?layer=background`：先送 `0x052C` 給 Progman，再把視窗設成 WorkerW 的子視窗（`WS_CHILD`），放在桌面圖示後面。Windows 10 / 11 24H2 前後兩種視窗結構都有處理。掛載失敗時關閉背景層，不會留下一個蓋住桌面的全螢幕視窗。
   - 角色層 `?layer=character`：由桌面圖示所在的 Progman／WorkerW 擁有的透明頂層視窗，不全域置頂、不顯示在工作列，並設為不聚焦。一般 App 可遮蓋角色，桌面圖示保持可見；互動與焦點行為仍待完整驗收。
   - 每 2 秒檢查一次螢幕配置，有變更時整組重建。
3. **點穿**：每 1/30 秒依游標位置判斷。游標進入 `bounds` 框（外擴 0.01）時，才請網頁執行 `window.mikuCompanion.hitTest(x, y)`。命中時接收滑鼠，沒命中時點穿；拖曳中一律接收；離開範圍時呼叫 `endHover()`。
   - Windows 角色在主執行緒切換 `WS_EX_TRANSPARENT | WS_EX_LAYERED`，並維持桌面底層，不透過顯示或啟動視窗來更新樣式。背景層沿用 Tauri 的點穿 API。
   - `webview.eval` 沒有回傳值，所以 hit test 的腳本會把結果連同序號，回傳到 `miku_hit_result` 指令。同一時間只會有一個 hit test；500 ms 沒有回應就重送。
4. **橋接**：`bridge.js` 已支援 Tauri（`__TAURI_INTERNALS__.invoke`），**共用檔案完全沒有修改**。
   - `bounds`、`drag`：用於點穿判定。
   - `pin`：寫入 `settings.json` 的 `pinnedAnchor`。
   - `diag`：只保留純值，寫入 `%APPDATA%\MikuDesktop\diagnostics.log`。
   - `touch`（包含 `kind: "handHold"`）、`sleep`：目前只記錄到 diagnostics.log。
   - `haptic`、`hover-haptic`：Windows 沒有對應功能，忽略。
   - 原生 → 網頁：`call_page` / `eval_page` 執行 `window.mikuCompanion?.…`。頁面載入後執行與 macOS `configurePage` 相同的等待腳本（`setInteractive`、`setPinnedAnchor`、`setScene`）。
5. **托盤選單**：可以觸碰 Miku（開／關）、Miku 回到原位、重新載入桌面、結束。視窗沒有關閉鈕，結束 App 只能從托盤。

遠端桌面若回報 `prefers-reduced-motion`，角色會採用每秒一次的減少動畫模式。測試時須區分這項系統偏好、網路延遲與實際渲染效能。

### 公開版限制（AGENTS.md）

- `tauri.conf.json` 的 `bundle.resources` 逐項列出要打包的內容：`companion/`、`scenes/`、`miku.png`、Animasa 預設模型與說明檔、LICENSE。**不含** `companion-model/tda/`、`voice-training/`、任何語音模型、金鑰或 `tts-connection.json`。
- Tda 模型不打包，由使用者從作者原始 `Tda式デフォ服ミク_ver1.1.zip` 私人匯入，作者規約一併保留。程式會優先選用本機 Tda，圖形匯入介面尚未完成。

## 尚未完成

- 睡眠排程、天氣與日出日落、關係、特別日子、音樂：macOS 在頁面載入 1.5 秒後推送這些資料，Windows 版目前不推送，網頁會用預設值。
- `touch` 尚未寫入記憶檔，`sleep` 喚醒後背景層也不會跟著改變（第三到五階段）。
- Tda 匯入介面、聊天懸浮窗、Ollama、雲端模型、語音、感知（第三階段起）。
- Explorer 重新啟動後（`TaskbarCreated`）的桌面視窗恢復。
- 虛擬桌面（`IVirtualDesktopManager`）：目前沒有處理。
- 全螢幕程式或簡報時隱藏角色層（`SHQueryUserNotificationState`）。
- 單一執行個體、開機啟動、程式碼簽章、自動更新。

## 需要在 Windows 實機確認

已驗證的環境限於 Windows 11 10.0.26200／RTX 3080／單螢幕 RDP；Windows 10、11 23H2、多螢幕 DPI 與實體主控台尚未驗證。已確認桌面圖示、角色透明與一般 App 遮蓋；其餘項目仍須依序確認：

1. **安裝檔**：CI 已完成 .exe 連結；`cargo tauri build` 的 NSIS 打包與安裝仍待驗證。
2. **網頁載入**：兩層都顯示 Miku 網頁，DevTools 沒有 404 或 MIME 錯誤，`window.mikuCompanion.status()` 的 `nativeBridge` 為 `true`。
3. **IPC**：從 `http://miku.localhost` 呼叫 `miku_message` 可以成功。在 `diag` 訊息寫入 diagnostics.log 即表示正常。
4. **背景層**：在 Windows 10、Windows 11 23H2、Windows 11 24H2 以上分別確認，背景層位於桌面圖示後面，而且圖示仍可點擊。若 24H2 失敗，改試把視窗掛到 Progman 底下、`SHELLDLL_DefView` 之下。
5. **角色層透明**：WebView2 背景確實透明，沒有黑底或白底。
6. **點穿**：Miku 以外的透明區域可以點到桌面和其他視窗；游標移到 Miku 身上時游標會改變，可以摸頭、拖曳；拖曳中游標跑出 Miku 也不會斷開。
7. **搶焦點**：已使用 `focusable(false)` 維持 `WS_EX_NOACTIVATE`；仍須確認觸碰及拖曳不會讓正在打字的視窗失去焦點。
8. **多螢幕與 DPI**：在不同縮放比例（100%／150%）的雙螢幕上，每個螢幕的兩層都對齊；插拔螢幕約 2 秒後會重建。
9. **桌面層級**：角色應留在桌面、由一般 App 蓋住；桌面圖示須保持可見及可操作。每個螢幕一個角色的行為也須在多螢幕環境確認。
10. **效能**：背景、角色渲染與 30 Hz 輪詢時的 CPU／GPU 使用率。

CrossOver／Wine 頂多能測試 App 是否啟動；WorkerW、點穿、DWM 透明與 WebView2 的行為都和 Windows 不同，第 4 到 9 項一定要在實機確認。
