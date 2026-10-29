# Miku 人格訓練

同一人格供文字與語音使用。DGX 做主要 LoRA 訓練，Mac 做短輪校準、完整 VLM 匯出與實機評估；現有 oMLX 和私人 TTS 環境保持獨立。

`manifest.json` 是訓練參數的單一來源。資料、權重、環境與報告預設放在 `~/Library/Application Support/MikuTraining/`；DGX 用 `MIKU_TRAINING_ROOT` 指定私人工作目錄。任何模型、參考音訊、私人語料都不進 Git。

## 資料

- `data/calibration.jsonl`、`校準選擇.md`：50 題風格校準。A／B／都喜歡／都不喜歡，結果不會自動把候選語料批准。
- `data/candidates.jsonl`：新寫的多輪候選。`pending` 必須經風格校準與品質審核才改成 `accepted`／`rejected`。沒有讀取私人聊天。
- 先按情境家族切 85／5／10，同家族的五語永遠在同一 split；再展開成歷史→最後一則 assistant 的 completion-only 樣本。
- `data/heldout-cases.jsonl`／`data/heldout-spec.jsonl`：50 個獨立情境 × 五語，共 250 題；每題包含一輪前文、當前問題、模式、App 狀態與核對準則。125 題文字、125 題語音，與校準／候選情境分開，不能拿來訓練或挑 checkpoint。目前是 `ready_pending_evaluation`，尚未跑實模盲測。

```sh
python3 scripts/persona_training/persona.py prepare
"$HOME/Library/Application Support/MikuTraining/envs/mac/bin/python" scripts/persona_training/persona.py tokenize
python3 -m unittest discover -s Tests/persona_training -v
```

## Mac

`bootstrap_mac.sh` 安裝隔離 Python 3.12 環境。固定 MLX-VLM commit、MLX 0.32.4、Transformers 5.14.0，並保存環境 lock。`environment_check.py` 只檢查 import/API，不載入權重。

GPU 前要求：接電、閒置至少 10 分鐘、可用 RAM 至少 40 GiB、磁碟至少 30 GiB、系統記憶體壓力正常，並有 App 30 秒內的無通話 heartbeat、PID 仍存活。缺一項就拒絕。執行中每兩秒監看條件，在目前微步完成後保存 adapter、optimizer、累積梯度、RNG 與資料游標；重新閒置後從剩餘步數續訓。RAM 保留至少 10 GiB，MLX 記憶體上限 60 GiB。

```sh
python3 scripts/persona_training/persona.py gate
python3 scripts/persona_training/persona.py train-mac --probe --dry-run --run-id mac-probe-v1
"$HOME/Library/Application Support/MikuTraining/envs/mac/bin/python" scripts/persona_training/persona.py train-mac --probe --run-id mac-probe-v1
```

Probe 是 20 步，rank 8／alpha 16、最後 8 層的語言投影，凍結 vision／experts／router／embedding／head。正式小輪最多 300 步，要求校準完成且語料已審核。Probe 成功只證明技術可行，不代表人格或聽感驗收。

## DGX 與完整匯出

DGX 獨立環境以完整 HF `Qwen3_5MoeForConditionalGeneration` 的 BF16 底座做 LoRA。rank 16／alpha 32、lr 5e-5、batch 1；技術 probe 先 1 步、再 50 步，accumulation 1／context 512／30 分鐘上限。正式 accumulation 16、最多 2 epochs。嚴格核對 190 個語言 attention／DeltaNet 投影，凍結視覺與 MoE experts。BF16 候選路徑先在 CPU 循序載入，再逐參數移到 CUDA，整段由獨立程序監看至少 16 GiB 系統記憶體餘裕；完整模型仍需實測。`--precision nf4` 是需另備實測預算的明確候選選項。

預設使用原生 BF16 底座；NF4 只量化部分 Linear，MoE experts 仍為 BF16，須另外提供實測預算才允許使用。BF16 的 meta 底座約 65.4 GiB，並非載入或訓練峰值。載入前啟動獨立 RAM 監控，提前在低於 18 GiB 時終止自有訓練程序，為 16 GiB 系統保留留下反應空間。小型 probe 可用綁定完整配置的保守分析預算；正式訓練須有當前模型與配置的實測峰值，另留 16 GiB、GPU 低繁忙度且沒有其他訓練程序。常駐推論服務只會在擁有者核准的時段內暫停。

正式上下文上限為 4,096 tokens，技術 probe 保持 512。先用真實 App 請求建構器與合成測例量測提示詞；資料驗證不會截斷人格、當前狀態、最後問題或完整答案。超出上限的樣本必須重新整理舊歷史／引用或調整已驗證的配置。

`run_when_idle.py` 可排入一次最多六小時的 Mac probe 等待佇列。`training_window.py` 只接受擁有者核准的 DGX probe，先建立獨立恢復計時器再暫停指定服務；重試不能延長原截止時間。

```sh
MIKU_TRAINING_ROOT=/private/training python persona.py train-dgx --probe --smoke --model /private/models/Qwen3.6-35B-A3B-HF --run-id dgx-smoke-v1
python export_model.py merge-hf --model /private/models/Qwen3.6-35B-A3B-HF --adapter /private/training/runs/dgx-probe-v1/adapter --output /private/exports/miku-persona-hf
python export_model.py convert-mlx --model /Volumes/ModelHub/miku-persona-hf --output "$HOME/Library/Application Support/MikuTraining/candidates/miku-persona-mlx"
```

Mac adapter 可用 `export_model.py fuse-mac` 匯出完整 VLM。正式轉換只用 `mlx_vlm`，保留 vision、processor、chat template；不把純文字 `mlx_lm` 匯出當正式候選。目的地必須全新，不能覆蓋原模型。HF BF16 原權重放 DGX／NAS，Mac 只保留現役、一個量化候選與必要 adapter。

切換前比較：原版、只調提示版、微調版；驗證多輪人格、五語、關係／記憶、JSON、圖片理解與實際 Voice 聽感。全程本機正式推論，未驗收前保留原模型。

## 獨立盲測

`evaluation.py` 只接受 HTTP loopback 端點，不使用系統代理或允許重新導向。設定檔需列出 `baseline` 與 `candidate`，可另加提示詞版本；每個版本都要有 `endpoint`、明確的 `model` 和完整 `system_prompt`。模型名稱先對 `/models` 核對，不自動換模型。設定檔與輸出都放私人目錄。

```json
{
  "baseline": {
    "endpoint": "http://127.0.0.1:8000/v1",
    "model": "現有完整 VLM 的確切名稱",
    "system_prompt": "現行人格提示詞的完整快照"
  },
  "candidate": {
    "endpoint": "http://127.0.0.1:8000/v1",
    "model": "候選完整 VLM 的確切名稱",
    "system_prompt": "候選人格提示詞的完整快照"
  }
}
```

```sh
python3 scripts/persona_training/evaluation.py validate
python3 scripts/persona_training/evaluation.py run --variants "$HOME/Library/Application Support/MikuTraining/data/evaluation-variants.json" --output "$HOME/Library/Application Support/MikuTraining/evaluations/release-v1"
```

`run` 預設只檢查資料與設定；加 `--execute` 才會呼叫模型，且每次請求前都要通過 Mac 資源與無通話閘門。`--limit` 僅做管線測試，不能算完整驗收。輸出含合成情境的回覆、JSON 結果、語言線索、關係／誠實疑點與完成時間；不讀私人對話。15 題程式產生的色塊圖片會另算前後正確率差，僅屬圖片回歸的基本檢查，仍需實際圖片盲評。

`blind-review.jsonl` 的答案會隨機排列 A／B／C，`blind-map.json` 分開保存版本對照。由評閱者填入 `preferred`（A／B／C 或 `tie`）及其餘核對欄；若有三個版本，另填 `pairwise_preferences` 的各組 A:B／A:C／B:C 選擇，不能從第三個版本勝出就推定其他兩個平手。再跑：

```sh
python3 scripts/persona_training/evaluation.py review-summary --output "$HOME/Library/Application Support/MikuTraining/evaluations/release-v1" --baseline baseline --candidate candidate
```

65% 偏好門檻只會從全部 250 題的人工選擇計算，勝出 1 分、平手 0.5 分，未評完不給通過結果；正規表示式不判定人格、關係或誠實已通過。語音情境尚須用實際 TTS 盲聽，這個 runner 不生成音訊，也不驗證首段語音延遲。任何自動報告都不會自行宣告完整驗收成功。
