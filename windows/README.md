# Miku Desktop：Windows

Tauri 2 + WebView2 版本，與 macOS 共用 `Wallpaper/companion/` 的角色、動畫與場景。背景位於桌面圖示後，角色及控制列留在桌面，一般程式可覆蓋。

目前為預覽版。已在 Windows 11（10.0.26200）／RTX 3080／單螢幕 RDP 環境驗證桌面透明合成、控制列與聊天入口、Ollama 繁體中文回覆及相簿拍照。麥克風與通話音訊尚未實測；Windows 10、多螢幕不同 DPI、實體主控台與 NSIS 安裝仍需驗收。

## 使用

從托盤或桌面控制列開啟聊天、手帳、設定、相簿與歌曲知識。拖動控制列的 ♪ 可移動位置，重新開啟時會恢復。

- **AI**：在設定選擇 Ollama 本機模型，預設端點 `http://127.0.0.1:11434/v1`；先在此電腦的 Ollama 下載模型，再重新整理模型清單。亦可設定相容 OpenAI API 的 HTTPS 雲端端點、模型與自己的金鑰。金鑰存於 Windows Credential Manager。
- **角色**：設定中選取作者原始 `Tda式デフォ服ミク_ver1.1.zip`，經完整校驗後匯入 `%APPDATA%\MikuDesktop\CharacterModels\tda`，保留作者規約。已匯入時優先載入 Tda；公開套件只附 Animasa 備用角色。
- **動畫**：「正常播放動畫」只調整此 App，重新啟動後生效；不改動 Windows 的減少動畫設定。
- **語音**：可使用此電腦已安裝的 Windows 語音，或使用者自備、位於 localhost 的相容 `/audio/speech` TTS。只有按下麥克風或開始通話才啟用辨識；停止或關閉通話視窗會結束收音。
- **資料**：聊天記憶、關係、個人資料、日記、記事、相簿與收藏存於 `%APPDATA%\MikuDesktop`。停用記憶後的新對話與附件只留在記憶體；重設記憶需輸入 `RESET`，保留一份可還原備份。
- **感知**：前景程式、媒體、畫面觀察皆須自行開啟。使用雲模型時另需允許分享感知內容；畫面觀察不保存截圖。相簿只擷取 App 自己的背景與角色，不拍攝其他程式。
- **天氣**：填入想查詢地點的經緯度後啟用，無自動定位。睡眠排程、安靜時段與只朗讀聊天回覆可分別設定。

內含猜拳、歌曲問答、節奏遊戲、特殊日子與官方活動查詢；歌曲知識可搜尋、更新、收藏及匯入自己的條目，不收錄歌詞。開機啟動預設關閉，更新檢查只讀取官方 GitHub Release。

擁有者的私人 Miku 聲線、語音模型與訓練素材不對外提供，公開版不預載、下載或連接該私人服務。語音及辨識語言依 Windows 已安裝引擎／使用者自備服務而定。

## 建置

需要 Windows 10/11 x64、WebView2 Runtime、Rust stable MSVC，以及 Visual Studio Build Tools 的「使用 C++ 的桌面開發」。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/fetch-model.ps1
cd windows/src-tauri
cargo test --locked --lib
cargo build --locked
```

開發版可直接執行 `target/debug/miku-desktop.exe`；可攜套件必須一起帶上相鄰的 `Wallpaper/`、`LICENSE` 與 `THIRD_PARTY_NOTICES.md`。Tauri UI 已嵌入執行檔，不需要 npm 套件。

建立 NSIS 安裝檔：

```powershell
cargo install tauri-cli --version "^2" --locked
cargo tauri build
```

輸出位於 `target/release/bundle/nsis/`。公開資源清單只包含共用頁面、場景及 Animasa 模型；不包含 Tda、語音素材、金鑰或 `tts-connection.json`。目前未做程式碼簽章。

Mac 可進行跨平台型別檢查及 Rust 單元測試，需要 Homebrew `rustup`、`llvm`、Windows MSVC target，以及已下載的 Animasa 備用模型：

```bash
export PATH="/opt/homebrew/opt/rustup/bin:/opt/homebrew/opt/llvm/bin:$PATH"
cd windows/src-tauri
cargo check --locked --target x86_64-pc-windows-msvc
cargo test --locked --lib
node --test ../ui/tests/*.test.mjs
```

完整 `.exe` 連結與 Win32 行為須在 Windows 驗證；CrossOver 無法取代實機。已安裝後的驗收應涵蓋透明背景、點穿、摸頭與拖曳不搶焦點、全螢幕與鎖屏、語音啟停、睡眠／喚醒、Explorer 重啟、螢幕插拔及不同 DPI。
