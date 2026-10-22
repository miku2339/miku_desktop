# Miku Desktop

**繁體中文** · [日本語](README.ja.md) · [English](README.en.md)

macOS 初音未來桌面陪伴程式：動態場景、3D 角色互動，以及由本機 AI 驅動的聊天與記憶。

## 功能

- **場景與光線**：澀谷、池袋、秋葉原、新宿、校園走廊、音樂教室及 Miku 的房間。日間、黃昏與夜晚隨本機時間漸變，角色光線跟隨場景與天氣；可選背景、自動輪換及輪換間隔。房間不參與自動輪換。
- **動態背景**：雨雪、霧、雷雨、日出日落與室內光影；適用街景有車輛和 JR 列車，可關閉動態效果以省電。
- **角色互動**：滑鼠靠近、摸頭、戳臉、牽手、拖曳、拎起及放手落地；聊天回覆可配合表情、動作與嘴形。拖曳後可固定位置，亦可讓她重新自由走動。
- **三語聊天與性格**：繁體中文、日本語、English；活潑、溫柔、安靜或自訂性格，可設定稱呼。回覆會取得當地日期時間，並注入相關初音與歌曲資料。
- **圖片理解**：選取、拖放或貼上圖片到聊天視窗，需要支援圖片輸入的本機模型。
- **長期記憶**：儲存對話、摘要、偏好、互動記錄、好感度與關係狀態；可逐條刪除記得的事。重設記憶需確認兩次，並保留一份可復原的重設備份。
- **作息與叫醒**：預設 01:00–07:00 睡覺，說晚安可提早休息，聊天或互動可叫醒。入睡時會切換到房間、側躺在床上並蓋上被冚；缺少必要素材時會先站著打瞌睡。
- **選擇性主動陪伴**：可分別開啟使用中的 App 與作息、Music／Spotify、YouTube／ニコニコ影片標題，以及定時畫面理解；四項預設皆關閉。
- **桌面控制**：獨立「聊天／設定」浮動按鈕、選單列控制、透明區域滑鼠穿透、相容 Force Touch 觸控板回饋及登入啟動。點按 Miku 只觸發角色互動。

![Miku 的房間夜景背景](Wallpaper/assets/scenes/room-night.jpg)

## 建置與啟動

需要 Apple silicon Mac、macOS 13 或以上，以及提供 Swift 5.10 或以上版本的 Xcode Command Line Tools。本機 AI 服務及模型可能有更高的系統或記憶體需求。

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/fetch-model.sh
./scripts/build-app.sh
```

`fetch-model.sh` 會下載角色模型並核對校驗碼；使用前請閱讀模型附帶的規約。

Release 建置結果位於**專案上一層**的 `outputs/`：

| 檔案 | 用途 |
| --- | --- |
| `Miku Desktop.zip` | 解壓縮後，把 App 放入「應用程式」執行 |
| `Miku Desktop.app` | 指向本機最新建置的捷徑 |

開啟後使用桌面 **聊天／設定** 按鈕或選單列 **♪**。程式內附本機桌布伺服器，無需 Plash。場景與角色可離線運作；聊天需要另外啟動本機 AI 服務，天氣資料需要網路。

### 公開打包與選用模型

```sh
./scripts/build-app.sh --public
```

公開打包產生 `../outputs/Miku Desktop (Public).zip`，排除選用的 Tda 模型及整套 GiGO 秋葉原圖片；缺少 GiGO 圖片時會略過該秋葉原場景。各素材仍適用個別授權。

如需 Tda／金子卵黄的經典服裝模型，從[作者配布頁](https://bowlroll.net/file/16344)取得 `Tda式デフォ服ミク_ver1.1.zip`，閱讀包內規約，再以 Python 3 匯入：

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

未匯入時使用 Animasa 模型。包含 Tda 的本機安裝包只供自己使用；模型與貼圖不隨原始碼發布。

## 本機 AI

1. 安裝及啟動 [oMLX](https://github.com/jundot/omlx)，載入本機模型。
2. 在 **設定 → 本機 AI** 填入端點與服務實際提供的模型 ID。
3. 按 **測試連線**，再開啟聊天。

初次設定的端點是 `http://127.0.0.1:8000/v1`，模型名稱是 `Qwen3.5-0.8B-MLX-4bit`，可配合本機服務修改。程式不附帶語言模型權重；小模型的知識、語言及性格遵循能力有限。

端點只接受 loopback 位址。設定與 oMLX 相符時，程式會於執行時讀取既有 API key，不寫入專案。圖片聊天與定時畫面理解需要服務和已載入的模型轉換版本都支援視覺輸入，只有文字模型不能使用。

## 資料與權限

- 對話、記憶及聊天圖片儲存在 `~/Library/Application Support/MikuDesktop/`，性格與語言等偏好儲存在 macOS 使用者設定。
- 重設會清除對話、摘要、記得的事、互動記錄及關係資料，保留性格與其他設定。復原會以重設前備份覆蓋重設後的新記憶；亦可永久刪除備份。
- 聊天內容與啟用後取得的觀察資料交給本機 AI。定時畫面擷取不存檔，需要 macOS 14 或以上及螢幕錄製權限；音樂與影片功能可能需要 macOS 自動化權限。
- 天氣服務會連線至 Open-Meteo，以所選城市的座標查詢天氣。畫面觀察與天氣是不同功能。

## 開發與貢獻

Swift 原生介面位於 `Sources/MikuDesktop/`；角色、背景及互動程式位於 `Wallpaper/companion/`，場景圖片位於 `Wallpaper/assets/scenes/`。

修改相關功能後，可執行以下檢查；JavaScript 測試需要 Node.js：

```sh
node --test Tests/*.test.mjs
./scripts/test-memory.sh
./scripts/test-relationship.sh
./scripts/test-awareness.sh
./scripts/test-sleep-schedule.sh
```

歡迎提交 Issue 或 Pull Request。回報問題時請附上 macOS 版本、重現步驟及相關畫面；分享記錄前請移除私人對話、API key 與其他個人資料。

## 素材與授權

本專案為非官方同人作品，與 Crypton Future Media、Project SEKAI、OTOIRO 或 JR East 無隸屬關係。

程式碼採 [MIT 授權](LICENSE)。角色、MMD 模型、背景與第三方程式庫適用各自授權；部分動漫化背景含非商業使用限制。東京及校園場景並非官方 MV 原始畫格。

詳細來源與使用條件見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 及[場景素材說明](Wallpaper/assets/scenes/ATTRIBUTION.md)。
