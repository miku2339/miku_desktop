# Miku Desktop

macOS 初音未來桌面陪伴程式。角色會眨眼、揮手、伸懶腰和休息，亦可拖曳位置、點按互動及文字聊天。

- 澀谷、池袋、秋葉原、新宿、校園走廊及音樂教室，隨本機時間漸變為日間、黃昏及夜晚。
- 繁體中文、English、日本語介面與聊天。
- 活潑、溫柔、安靜及自訂性格，可設定稱呼和回覆語言。
- 本機 AI，預設經 oMLX 使用 Qwen3.5 0.8B MLX 4-bit。
- 選單列控制、桌面滑鼠穿透、Force Touch 觸控板回饋及登入啟動。
- 桌面「聊天／設定」按鈕；設定內可選擇背景及開關自動輪換。

## 建置

需要 Apple silicon Mac、macOS 13 或以上及 Xcode Command Line Tools。請先閱讀下方的模型授權說明。

```sh
git clone https://github.com/miku2339/miku_desktop.git
cd miku_desktop
./scripts/fetch-model.sh
./scripts/build-app.sh
```

可攜建置結果位於專案上一層的 `outputs/Miku Desktop.zip`。解壓縮後將 `Miku Desktop.app` 放入「應用程式」並開啟，使用桌面右下的 **聊天／設定** 按鈕，亦可從選單列 **♪** 操作。點按 Miku 會觸發角色互動。`outputs/Miku Desktop.app` 是指向本機最新建置的捷徑，供直接測試使用。

程式以本機臨時連接埠載入內附桌布，無需 Plash 或獨立網頁伺服器。場景與角色可離線運作；文字聊天需要本機 AI 服務。

### 經典服裝精細模型

可從[金子卵黄的作者配布頁](https://bowlroll.net/file/16344)下載 `Tda式デフォ服ミク_ver1.1.zip`，閱讀原包附帶的 Tda 及金子卵黄規約後，於建置前匯入：

```sh
python3 scripts/import-tda-model.py /path/to/Tda式デフォ服ミク_ver1.1.zip
./scripts/build-app.sh
```

匯入後會使用 Tda／金子卵黄的經典服裝模型；未匯入時使用 Animasa 模型。模型及貼圖只供本機建置，原始素材不得隨公開倉庫或公開安裝包再散布。

## 本機 AI

安裝及啟動 [oMLX](https://github.com/jundot/omlx)，載入 `mlx-community/Qwen3.5-0.8B-MLX-4bit`。預設端點為 `http://127.0.0.1:8000/v1`，模型名稱為 `Qwen3.5-0.8B-MLX-4bit`；可在設定中配合本機服務調整。

端點只接受 loopback 位址。oMLX 的端點與本機設定相符時，程式會於執行時讀取既有 API key，並不儲存於專案。聊天記錄僅保留在本次執行的記憶體；性格與語言偏好儲存於 macOS 使用者設定。

小模型的語言表現及性格遵循程度會有差異，可改用本機服務內的其他聊天模型。角色動作只接受固定的表情及動作清單。

## 素材與授權

本專案為非官方同人作品，與 Crypton Future Media、Project SEKAI、OTOIRO 或 JR East 無隸屬關係。

程式碼採 MIT 授權。初音未來、Animasa 及 Tda／金子卵黄 MMD 模型、JR 標誌及第三方程式庫不包含於本專案 MIT 授權範圍。模型二進位不隨原始碼發布；使用及再散布前請閱讀原始授權。

背景為依照東京街景及〈セカイ〉MV 氛圍製作的圖像，並非官方 MV 原始畫格。詳細來源見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
