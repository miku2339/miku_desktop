# Miku Desktop

**繁體中文** · [日本語](README.ja.md) · [English](README.en.md)

住在 macOS 桌面上的初音未來：她會在動態的東京街景裡走動、回應你的滑鼠，也能透過在本機執行的 AI 和你聊天，並記住你們的相處。

**網站**：[miku.qimake.com](https://miku.qimake.com/)（介紹與動態背景示範）

![黃昏的澀谷十字路口背景](Wallpaper/assets/scenes/shibuya-scramble-dusk.jpg)

## 特色

### 會動的場景

- **七個場景**：澀谷十字路口、池袋、秋葉原（GiGO）、新宿、校園走廊、音樂教室，以及 Miku 的房間。可以手動選擇，或依設定的間隔自動輪換（房間不參與輪換）。
- **時間與天氣**：日間、黃昏、夜晚隨本機時間漸變；雨、雪、霧、雷雨與日出日落都會反映在畫面上，角色的光線也會跟著場景與天氣改變。
- **街上的動態**：街景有車流與 JR 列車；澀谷十字路口有路人等紅燈、綠燈時從四面八方穿越，近處的行人號誌也會跟著亮燈。動態效果可以關閉以節省電力。

### 和她互動

- 滑鼠靠近、摸頭、戳臉、牽手（她會跟著游標走）、拖曳、抱起來再放手讓她落地。
- 拖曳後可以把她固定在原位，也可以讓她重新自由走動。
- 依場景、天氣、季節與活動拿透明雨傘、飲料、大蔥、扇子或螢光棒，節日會戴帽子；播放音樂時會扶著耳機跟著節拍擺動。

### 聊天與記憶

- **三種語言**：繁體中文、日本語、English。性格可選活潑、溫柔、安靜或自訂，也能設定她怎麼稱呼你。
- **像她本人的說話方式**：語氣開朗直率，聊到音樂會興奮起來；不會引用有版權的歌詞。回覆會配合表情、動作與嘴形。
- **看得懂圖片**：在聊天視窗選取、拖放或貼上圖片（需要支援圖片輸入的本機模型）。
- **長期記憶**：保存對話、摘要、偏好、互動記錄、好感度與關係狀態；記得的事可以逐條刪除。重設記憶需要確認兩次，並保留一份可以復原的備份。

### 她的日常

- **作息**：預設 01:00–07:00 睡覺。說晚安可以讓她早點休息，聊天或互動會把她叫醒。睡覺時會回到房間，側躺在床上蓋好棉被。
- **節日與紀念日**：記得 Miku 生日、Miku Day、聖誕節、新年、夏日祭典，以及你們第一次見面的紀念日。魔法未來與 SNOW MIKU 的日期每 3 天從官方網站確認一次。
- **手帳與日記**：她每晚睡前寫一篇日記，可以在「Miku 的手帳」閱讀或刪除；記憶關閉時不寫日記。
- **小遊戲**：猜拳、Vocaloid 歌曲問答與打拍子。在聊天輸入遊戲名稱，或從聊天視窗的小遊戲選單開始。

### 選擇性主動陪伴

以下五項可以個別開啟，**預設全部關閉**，而且只在這台 Mac 上處理：

| 項目 | 她會做什麼 |
| --- | --- |
| 使用中的 App 與作息 | 留意你在用什麼、用了多久，適時提醒休息 |
| 正在播放的音樂 | 讀取 Music／Spotify 的歌名，聊聊你在聽的歌 |
| YouTube・ニコニコ動画 | 讀取影片標題 |
| 定時看看畫面 | 偶爾把畫面交給本機模型看（不存檔，需要 macOS 14 以上） |
| 隨機小事件 | 不定時哼歌、問你問題、找你玩遊戲 |

### 桌面整合

獨立的「聊天／設定」浮動按鈕、選單列 **♪** 控制、透明區域滑鼠穿透、支援 Force Touch 觸控板回饋，以及登入時自動啟動。點 Miku 本身只會觸發角色互動，不會誤開視窗。

## 系統需求

- Apple silicon Mac，macOS 13 以上
- Xcode Command Line Tools（Swift 5.10 以上）
- 聊天功能需要另外執行本機 AI 服務；服務與模型可能需要更新的系統或更多記憶體

## 安裝與建置

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/fetch-model.sh
./scripts/build-app.sh
```

`fetch-model.sh` 會下載角色模型並核對校驗碼，使用前請先閱讀模型附帶的使用規約。

建置結果會放在**專案上一層**的 `outputs/` 資料夾：

| 檔案 | 用途 |
| --- | --- |
| `Miku Desktop.zip` | 解壓縮後，把 App 拖進「應用程式」資料夾執行 |
| `Miku Desktop.app` | 指向本機最新建置的捷徑 |

開啟後，用桌面上的 **聊天／設定** 按鈕或選單列的 **♪** 操作。程式內建本機桌布伺服器，不需要 Plash。場景與角色可以離線運作；聊天需要本機 AI 服務，天氣需要網路。

### 公開分享用的打包

```sh
./scripts/build-app.sh --public
```

會產生 `../outputs/Miku Desktop (Public).zip`，並排除選用的 Tda 模型。各項素材仍適用各自的授權條款。

### 選用：Tda 經典服裝模型

如果想使用 Tda／金子卵黄的經典服裝模型，請從[作者的配布頁](https://bowlroll.net/file/16344)下載 `Tda式デフォ服ミク_ver1.1.zip`，閱讀包內的規約後，用 Python 3 匯入：

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

沒有匯入時會使用 Animasa 模型。包含 Tda 模型的安裝包只限自己使用；模型與貼圖不會隨原始碼散布。

## 設定本機 AI

1. 安裝並啟動 [oMLX](https://github.com/jundot/omlx)，載入一個本機模型。
2. 打開 **設定 → 本機 AI**，填入端點與服務實際提供的模型 ID。
3. 按 **測試連線**，成功後就可以開始聊天。

預設端點是 `http://127.0.0.1:8000/v1`，模型名稱是 `Qwen3.5-0.8B-MLX-4bit`，可依你的本機服務修改。程式本身不附帶語言模型；小模型在知識、語言與維持性格上的能力有限，換用較大的模型效果會更好。

為了安全，端點只接受 loopback 位址（本機）。設定與 oMLX 一致時，程式會在執行時讀取 oMLX 既有的 API key，不會寫進專案。圖片聊天與「定時看看畫面」需要服務與載入的模型都支援視覺輸入。

## 隱私與網路連線

- 對話、記憶、日記與聊天圖片存放在 `~/Library/Application Support/MikuDesktop/`；性格、語言等偏好存放在 macOS 使用者設定。
- 聊天內容與你開啟的觀察資料只會交給本機 AI。畫面擷取不會存檔，需要「螢幕錄製」權限；音樂與影片功能可能需要 macOS「自動化」權限。
- 重設記憶會清除對話、摘要、記得的事、互動記錄與關係資料，但保留性格與其他設定。之後可以用備份復原，或永久刪除備份。
- 程式只會主動連線到以下網站：

| 連線對象 | 用途 | 頻率 |
| --- | --- | --- |
| Open-Meteo | 用所選城市的座標查詢天氣 | 定期 |
| magicalmirai.com、snowmiku.com | 讀取公開頁面，確認魔法未來與 SNOW MIKU 的活動日期 | 每 3 天，結果快取在本機 |

## 專案結構

| 路徑 | 內容 |
| --- | --- |
| `Sources/MikuDesktop/` | Swift 原生 App：視窗、聊天、設定、記憶、作息、節日、小遊戲 |
| `Wallpaper/companion/` | 角色（three.js／MMD）、背景動態、路人與車流、互動 |
| `Wallpaper/assets/scenes/` | 場景圖片與座標資料 |
| `Tests/` | JavaScript 與 Swift 測試 |
| `scripts/` | 建置、下載模型與測試腳本 |
| `website/`、`deploy/website/` | 官方網站原始碼與部署設定 |

## 開發與測試

修改後可以執行以下檢查（JavaScript 測試需要 Node.js）：

```sh
node --test Tests/*.test.mjs
./scripts/test-memory.sh
./scripts/test-relationship.sh
./scripts/test-awareness.sh
./scripts/test-sleep-schedule.sh
./scripts/test-special-days.sh
./scripts/test-mini-games.sh
```

歡迎提交 Issue 或 Pull Request。回報問題時請附上 macOS 版本、重現步驟與相關畫面；分享記錄前，請先移除私人對話、API key 與其他個人資料。

## 授權與素材

本專案是非官方的同人作品，與 Crypton Future Media、Project SEKAI、OTOIRO 或 JR East 沒有任何關係。

本專案的原創程式碼採用 [PolyForm Noncommercial 1.0.0 非商業授權](LICENSE)，可依條款進行非商業的使用、修改與散布。先前以 MIT 授權發布的版本，繼續適用原本的 MIT 授權。角色、MMD 模型、背景與第三方函式庫適用各自原有的條款；部分動畫風格背景限非商業使用。東京與校園場景並非官方 MV 的原始畫面。

詳細的來源與使用條件請見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 與[場景素材說明](Wallpaper/assets/scenes/ATTRIBUTION.md)。
