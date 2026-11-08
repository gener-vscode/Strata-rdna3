# 喺呢部機（7900xt）build 同 start 呢個 fork —— 自用筆記

> 呢份文件係 2026-11-08 由 Gener 檢查你呢部機之後寫嘅自用 runbook。只講**呢部機**：
> RX 7900 XT（**gfx1100**、20 GiB VRAM、**一張卡**）、Ryzen 7 7800X3D（16 threads）、
> **46 GiB RAM**、system **ROCm 7.2.1** 喺 `/opt/rocm`（有 `hipcc`、`libhipblas`、`libhipblaslt`、
> `/opt/rocm/include/rocwmma`）。模型**已經 download 咗喺** `/home/tommy/repo/Strata-data`。
> 呢個 fork 嘅 `rdna3/README.md` 假設 1–2 張 **24 GB XTX + 128 GB RAM**，所以佢啲数字你**唔會**喺呢部機重現到（下面「3. RAM 嘅現實」講解）。

---

## 0. 一次過 copy-paste（得低 build 個 engine）

```bash
cd /home/tommy/repo/Strata-rdna3
export XDG_CONFIG_HOME=$PWD/.config          # ⚠️ 一定要：唔然 setup.py 會 move 你現有模型

# 1) 停咗而家行緊嗰個 server（佢食晒 20 GB VRAM + ~41 GB RAM；亦即係 Gener 連緊嗰個 backend）
pkill -f 'serve/server.py --engine strata --config /home/tommy/repo/Strata/strata-iq3_s.json'

# 2) build engine（重用你已經 download 咗嘅 GGUF；10–20 分鐘 compile）
./setup.sh --setup --build --backend hip --family qwen --model IQ3_S \
           --data-dir /home/tommy/repo/Strata-data --no-start --yes

# 3) 睇下佢會用咩 command line（唔start）
.venv/bin/python rdna3/run.py iq3-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --print-config

# 4) 起佢（⚠️ 想出 LAN 一定要喺呢度傳 --host，見 §8；port 唔可以撞，見 §9）
# browser: http://127.0.0.1:18087/ui/
.venv/bin/python rdna3/run.py iq3_xxs-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --host 0.0.0.0 --port 8080 --log /tmp/rdna3-iq3-xxs.log

# 5) 快速量速度（唔使成 20 分鐘）
.venv/bin/python rdna3/bench.py iq3-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --lengths 8192,32768
```

用咗嘅 model 檔案名 / pack 路徑同你現有嘅 `Strata-data` **一模一樣**，所以唔使重新 download，亦唔使再做 `iq_pack`（見第 2 步）。

---

## 1. 點解 `XDG_CONFIG_HOME` 一定要 set

你呢部機 `~/.config/strata/settings.json` 入面寫住：

```json
{ "data_dir": "/home/tommy/repo/Strata-data", "installs": ["/home/tommy/repo/Strata"] }
```

`setup.py` 嘅 upstream 行為（fork 保留咗）係：**將呢個檔列出嚟嘅舊 install 嘅模型檔案 move 去你今次俾佢嘅 data dir**（`rdna3/README.md` 個 WARNING）。我哋今次 `-data-dir` 指返同一個 dir，理論上 move 係 no-op，但 set 咗 `XDG_CONFIG_HOME=$PWD/.config` 就徹底隔離，兩份 install 唔會 mutate 對方。**之後每一次 `./setup.sh` 都要帶同一個 `XDG_CONFIG_HOME`**（或者寫落你嘅 shell profile）。

## 2. Build（佢會做乜）

`./setup.sh --setup --build --backend hip --family qwen --model IQ3_S --vision cpu --data-dir <絕對路徑> --no-start --yes`

- `.venv`：呢個 repo 自己嘅 venv（第一次先整）。你 `/home/tommy/repo/Strata/.venv` 同佢分開，唔使擔心。
- **ROCm**：`setup.py` 會用 system ROCm（佢 check `/opt/rocm/bin/hipcc` + `/opt/rocm/lib/libhipblas.so*` —— 你呢部機**兩樣都有**），所以唔會落 pip ROCm wheels。
- 佢會 fetch **llama.cpp `3cf03257`** 同 **rocWMMA `1ab208f4`（tag rocm-7.1.1）** 去 `third_party/`（要 networking，~幾 MB）。
- 因為你張卡係 gfx1100，`setup.py:rdna3_defs()` 會自動加：
  `-DSTRATA_MMQ_KQUANTS=ON -DSTRATA_ROCWMMA_INCLUDE_DIR=$PWD/third_party/rocwmma/library/include`
  → 呢兩條先至係「K-quant MMQ prompt kernels」同「matrix-core QSA selection」會 compile 入去嘅關鍵。
  （如果你想用 system 嘅 rocWMMA headers，`/opt/rocm/include` 都符合要求；不過用佢 pin 咗嗰份最稳。）
- 驗證 build 成功：

  ```bash
  python3 -c "import json;b=json.load(open('engine/BUILD.json'));print(b.get('backend'),b.get('lib_dirs'))"
  # 要 print: hip ['/opt/rocm/lib']  ← run.py 係靠呢個檔搃 lib_dirs
  ```

- **Step 4（`tools/iq_pack.py … --experts-bin`）你唔使做**：
  `/home/tommy/repo/Strata-data/packs/iq3_s/experts.bin`（50.29 GB）、`dense.bin`、`index.txt`、`tokenizer/`、
  `models/IQ3_S/*.gguf`、`mtp/rt/experts.bin`、`models/mmproj-…-BF16.gguf` **全部已經喺度**，
  名字同 `rdna3/run.py` 期望嘅完全一致。`run.py` 會 check 呢啲 path，缺咗先會 report。

## 3. RAM 嘅現實 —— 呢個係最大嘅落差

`rdna3/README.md` 自己寫：1-GPU 配置要 `experts.bin` **完全放喺 RAM** 再加 ~15 GB：

| 模型 | 佢要求嘅 expert RAM |
|---|---|
| IQ3_S | 50 GB |
| UD-IQ4_XS | 60 GB |
| UD-Q4_K_XL | 77 GB |

你呢部機**總 RAM 得 46 GiB**。所以：

- `iq3-1gpu` 係唯一有可能嘅（50 GB 已經超過 46 GB），engine 會 by design 將一部分 expert 留喺 SSD，**過 PCIe 讀，明顯慢過佢張表**。呢個唔係 bug，`--expert-cache auto` 嘅正常行為。
- `iq4-1gpu` / `q4-1gpu` 千祈唔好指望，60/77 GB 一定 overflow。
- `-2gpu` 全部用唔到（你得一張卡），而 README 最靚嗰啲数字（7,060 tok/s prefill、189 tok/s decode）**全部都係兩張 XTX 嘅 tensor-parallel 結果**。
- 慳 RAM 嘅做法：
  - `--no-vision`（`run.py` 嘅 flag）—— 唔起 image encoder，慳佢嗰份 RAM 同 start 時間。
  - 將 config 複出嚟自己改，唔好用 `run.py` 直接起：
    ```bash
    mkdir -p rdna3/state
    .venv/bin/python rdna3/run.py iq3-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --no-vision --print-config \
        > rdna3/state/iq3-1gpu-8080.json
    # 喺呢個 json 改："--conversation-cache-mib" 8192 → 0、"--max-context" 262144 → 你实际用得嘅值、
    # 想試更慳 VRAM 可以跟返你自己嗰份 config 嘅 "--kv" q4_0 / "--vram-reserve-mib" 384
    .venv/bin/python serve/server.py --engine strata --config rdna3/state/iq3-1gpu-8080.json \
        --host 127.0.0.1 --port 8080
    ```
  - 你已經有 `packs/iq3_xxs/experts.bin`（42.9 GB）同 `models/IQ3_XXS/`。冇現成嘅 rdna3 config 畀 IQ3_XXS，
    但改一個 `iq3-1gpu.json` 複本嘅 pack/model 路徑就可能喺 46 GB 之內跑得番（**我未实測，屬建議**）。

## 4. Start 咗之後

- 睇 log：`tail -f /tmp/rdna3-iq3-1gpu.log`（engine 自己嘅 prefill/decode tok/s 會印喺度）。
- 健康檢查：

  ```bash
  curl -s http://127.0.0.1:8080/v1/models
  curl -s http://127.0.0.1:8080/v1/chat/completions -H 'content-type: application/json' \
    -d '{"model":"qwen-flash-iq3","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'
  ```
- **唔好同時跑兩個 server**：`bench.py` 要求張卡 idle（佢自己起 server）。
- 对比基準係 `rdna3/reference.json`（production 2026-11-02、24 GB XTX + 128 GB RAM）。你呢部機預期**會低好多**，主要因為 expert streaming。

## 5. 呢個 fork 嘅開關邊啲先至真係新嘢（重要，免得你白試）

我將 `rdna3/configs/*-1gpu.json` 入面全部 env 對照咗你 `/home/tommy/repo/Strata`（engine **0.1.57**，比你呢個 fork 嘅 **0.1.49.1 更新**）嘅源碼同你 build 好嘅 `engine/strata` binary：

- **30 個你 0.1.57 已經實装**（包括 `STRATA_HIP_WMMA`、`STRATA_SELECT_WMMA`、`STRATA_PF_FUSED`、`STRATA_PF_F16`、`STRATA_QFUSE`、`STRATA_QSA_ROWS`、`STRATA_ADAPT_OVERLAP`、`STRATA_GDN_*`、`STRATA_PA_FAST`、`STRATA_HIPBLASLT_TUNING` …）。
  → 呢啲**唔需要 fork**，喺你自己份 `strata-iq3_s.json` 加 env 就得。你而家嗰份只開咗 5 個。
- **13 個真係 fork 先至有 code**：`STRATA_GR_RDNA` `GR_RDNA_Q8` `GR_RDNA_A8` `RDNA_Q6K` `RDNA_MMVQ_WAVE`
  `GR_FUSED` `GR_INJ_UP` `COMBINE_CPU` `WAIT_FUSE` `ROUTE_PUBLISH` `TOPK_SPLIT_MIN` `PREFILL_MMQ_TILE_ROWS` `GDN_CHUNK_GDV`。
- **擺落去都冇用**：`STRATA_PA_KLDS`、`STRATA_PF_GROUP_RES`（fork 自己註明「now a no-op」）、
  `STRATA_ENGINE_NICE`（`serve/server.py` 讀，唔係 engine）、`STRATA_PEER_TRANSPORT`（多卡 diagnostics）。
- 相反，**你嗰邊有呢個 fork 冇嘅**：`STRATA_WMMA_GEMM=1`（`CMakeLists.txt:965`：gfx11 上 `gemm()` 偏好它多過 hipBLAS）。
  呢條同 `STRATA_HIP_WMMA=1` / `STRATA_SELECT_WMMA=1` 係**唔使 build 就可以 A/B**嘅單卡实验。
- K-quant GEMV 你已經有：你 `build-hip/CMakeCache.txt` 寫住 `STRATA_MMQ_KQUANTS:BOOL=ON`。

### Plan B（唔起 fork，5 分鐘開始）

喺 `/home/tommy/repo/Strata/strata-iq3_s.json` 嘅 `env` 加，逐個加、逐個量：

```json
"STRATA_HIP_WMMA": "1",
"STRATA_SELECT_WMMA": "1",
"STRATA_WMMA_GEMM": "1"
```

再用你自己嘅 `bench.sh` 做 A/B。（我未实測呢三個嘅增幅。）

---

## 6. 遇到錯點樣診斷

| 報錯 / 現象 | 點解 / 點處理 |
|---|---|
| `no HIP engine: run ./setup.sh --build first` | `engine/BUILD.json` 唔存在或者 `backend != hip` → 第 2 步未成功（睇 `build-hip/` 入面 cmake 嘅 output） |
| `missing (rdna3/README.md, step 3/4): <path>` | 缺 model / pack / tokenizer / MTP。你大部分都有，睇下係咪漏咗 `--data` 或者路徑唔啱 |
| `<pack>/experts.bin is missing; write it once with …` | 先至需要 `tools/iq_pack.py --gguf <shard> --out <pack> --experts-bin`（IQ 唔使 `--compat-bf16`，Unsloth 先要） |
| `UD-Q4_K_XL` 話 AMD 卡唔支援嘅 warning | upstream 舊文，`--yes` 接受就得（fork 已加 K-quant prompt kernels） |
| 起咗但好慢 / `engine stopped` / VRAM 唔夠 | config 寫住 `--max-context 262144 --kv int8 --kv-resident 32768`（為 24 GB 卡寫）→ 改用第 3 節嘅方法改 config，跟你現有那份用 `--max-context 160000 --kv q4_0 --vram-reserve-mib 384` |
| 想肯定有冇用 matrix-core | 引擎 start 時會 print `… the prompt attention on matrix cores …` / `STRATA_HIP_WMMA:` 呢類 log 行；冇就係 fallback 咗去 FP32 kernel |
| 想清掉 build 重新黎 | `rm -rf engine build-hip third_party/llama.cpp third_party/rocwmma` 再 run 第 2 步 |

## 7. 停佢

```bash
pkill -f 'rdna3/state/iq3-1gpu-8080.json'   # 或者喺緊個 terminal 按 Ctrl+C
rocm-smi --showmeminfo vram                 # 確認 VRAM 返返晒（你 20 GiB）
free -h                                      # 確認 RAM 返返晒（46 GiB）
```

要返自己個日常環境：`cd /home/tommy/repo/Strata && ./run-iq3_s.sh`。

---

## 8. ⚠️ 改咗 config 入面嘅 `"host"` 係冇作用 —— `run.py` 會蓋住佢（已查明）

我將 `rdna3/configs/iq3-1gpu.json` 改做 `"host": "0.0.0.0"` 之後：`--print-config` 真係 print `0.0.0.0`，
但起嘅時候 server 仲係話 `ready: http://127.0.0.1:8080/v1`。原因係两处代码：

| 位 | 內容 |
|---|---|
| `rdna3/run.py:74` | `ap.add_argument("--host", default="127.0.0.1")` ← **有 default** |
| `rdna3/run.py:90-91` | **一定**會將 `--host <值>` 加落 `serve/server.py` 嘅 command line |
| `serve/server.py:8302` | `a.host = a.host or cfg.get("host") or "127.0.0.1"` → **有 CLI `--host` 就用 CLI**；config 嘅 `host` 淨係 fallback（嗰行註明 issue #26：upstream 嘅 run script 唔傳 `--host`，先至靠 config）|

所以经 `run.py` 起，`cfg["host"]` 寫乜都會变返 `127.0.0.1`（除非你自己傳 `--host`）。呢個唔係 upstream bug —— 係佢有意嘅 precedence，只係 `rdna3/run.py` 傳咗個 default 遮住咗 config。

要 LAN access 有三個做法：

```bash
# A. 最簡單：喺 run.py 傳 --host
.venv/bin/python rdna3/run.py iq3-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --no-vision \
    --host 0.0.0.0 --port 8080

# B. 用 run.py 已經寫出嚟嘅 state file，自己行 server.py —— 呢個先會尊重 config 入面嘅 host
.venv/bin/python serve/server.py --engine strata --config rdna3/state/iq3-1gpu-8080.json --port 8080

# C. 改 fork 自己：run.py:74 改做 default=None，再喺 90-91 得 a.host 有值先加 --host
```

（**B 而家即用得**：`rdna3/state/iq3-1gpu-8080.json:11` 已經係 `"host": "0.0.0.0"` —— 因為 state file 係照住你嘅 config 寫落去嘅，
只有 `run.py` 加嘅嗰個 `--host` CLI 開關會蓋住佢。所以改 config 並非全無作用，只係经唔经 `run.py` 分別。）

⚠️ 兩樣嘢要注意：
1. 呢份 config **冇 set `--api-key`**，所以 `0.0.0.0` = 全個 LAN 免 key 直接用（AGENTS.md 嘅建議係 keep 127.0.0.1，要出 LAN 應加 `--api-key`）。
2. 而家 `0.0.0.0:8080` 聽緊嗰個係**另一個 install**：`pid 50929 = /home/tommy/repo/Strata/serve/server.py --config /home/tommy/repo/Strata/strata-iq3_s.json`（你自己嗰份，唔係 fork）。兩個都要 8080 就係搶 port / 你連錯咗那個。`run.py` 會按 port 寫 `rdna3/state/<setup>-<port>.json`，所以試另一个 port（例如 `--port 18087`）係得嘅。

## 9. 呢部機嘅實測記録（2026-11-08）

| 試咗乜 | 結果 |
|---|---|
| `iq3-1gpu` **原版（git HEAD）** —— 注意：fork 入面呢個 config 其實 run 嘅係 **IQ3_XXS**（`--native models/IQ3_XXS/…`、`--max-context 262144`、`--kv int8`、`--spec-min-p 0.5`、`--kv-resident`、`--ple-row-cache`） | ✅ **成功**，約 100 s 至 ready：`experts loaded: 39.97 GiB at 0.50 GiB/s (99 s)` → `filling the GPU's expert cache (8828 experts, 14.29 GiB of VRAM)` → ready。**呢個先係喺 46 GiB RAM 上面順住嘅配置。** |
| 自己將 config 轉做 **IQ3_S**（`--max-context 64000`、`--kv q4_0`、冇 `--ple-row-cache`） | ⚠️ 引擎 print `loading the experts the GPU does not hold into RAM (of about 55 GB)` —— **55 GB > 46 GiB 總 RAM**，137 s+ 先至 ready（期間 swap）。「stuck」係 expert loading，唔係 hang。 |

教訓：
1. `--print-config` 一定要睇清楚**实际用咗邊個 model**：`run.py` 檢查檔案用嘅係 `PACKS["iq3"] = iq3_s`（`run.py:19-21,52-55`），但 config 入面嘅 `--native/--pack` 可以指住 IQ3_XXS —— 兩邊唔一致都得。
2. 呢部機得 46 GiB RAM：IQ3_XXS（~40 GiB experts）啱啱好；IQ3_S（~50-55 GB）超過，要由 SSD 補，慢到唔值得試 speed。
3. 想同 `rdna3/reference.json` 比 speed，必須用返同一個 setup/model 嘅 baseline，換咗 quant 就唔係同一個對照。
   佢入面 `iq3-1gpu` 嘅 baseline（`reference.json`，24 GB XTX）：

   | prompt tokens | prefill t/s | decode t/s（code） |
   |---|---:|---:|
   | 1,024 | 808.3 | 146.6 |
   | 4,096 | 1,560.4 | 154.3 |
   | 8,192 | 2,435.6 | 144.4 |
   | 16,384 | 3,149.9 | — |

   ⚠️ 呢個 baseline 對應嘅係 **git HEAD 嗰份 `iq3-1gpu.json`（即 IQ3_XXS + `--max-context 262144 --kv int8 --kv-resident`）**——
   即係 README 嗰句「single 7900xtx prefill 3500+」用嘅係 IQ3_XXS，唔係 IQ3_S。
   （呢一句係我從 checked-in config 推斷，佢無喺 `reference.json` 入面標明 model，屬 unconfirmed。）
      你改咗做 IQ3_S 之後，呢啲数字就**唔可以做對照**；你真正可比嘅只係「同一份 config 自己前后 run 兩次」。

---

## 10. `/ui` path prefix + 「Strata is not reachable」遮罩（已 port 入呢個 fork，2026-11-08）

由 `feat/ui-bridge` 分支 port 自你 own 嘅 `Strata` commits `a28bcd81`（dashboard path）、`54422dea`（`/` redirect）、`638563a3`（offline veil）。**照你要求：docs（README*、docs/DETAILS.md …）一律冇郁。**

### 點用

```bash
# 你已經喺 config 加咗 —— 呢個就夠（你呢部機而家係 rdna3/configs/iq3_xxs-1gpu.json，見 §12）
 "dashboard": "/ui",

# 或者一次性喺 command line（會覆写 config）
.venv/bin/python rdna3/run.py iq3-1gpu --data /home/tommy/repo/Strata-data --gpus 0 \
    --host 0.0.0.0 --port 18087 --dashboard /ui --log /tmp/rdna3-iq3-1gpu.log
```

Browser 開 **`http://127.0.0.1:<port>/ui/`**。

| 路徑 | `/ui` 設咗之後 |
|---|---|
| `/ui/` | ✅ 網頁 |
| `/ui/web/app.js`、`/ui/web/app.css`、`/ui/web/tokens.css`、`/ui/web/sprite.svg`、`/ui/fonts/…` | ✅ 網頁自己 load 嘅檔案 |
| `/ui` （冇斜線）、`/` 、`/?q=hi` | **301** → `/ui/`（`/?q=` 保留）；所以舊 bookmark 照用得 |
| `/v1/…`、`/health`、`/metrics`、`/status`、`/models`、`/props`、`/slots`、`/mcp`、`/settings`、`/api-monitor` | ✅ **完全冇郁**，client base URL 唔使改（`/ui/v1/…` 因為網頁用 relative URL，都照用得） |
| `/web/app.js`、`/` 嘅 POST | 404（錯誤訊息會講「網頁喺 `/ui/`，API 照舊喺 `/`」） |

`dashboard_of()` 會喺 start 之前拒絕唔合理嘅 path：一定要 `/` 開頭、只可以字母/數字/`-`/`_`、唔可以撞 `/web`、`/v1`、`/health` 等 16 條 server 自己用嘅 path（`SERVED_PATHS`）。

### 遮罩（veil）

engine 超過 60 秒無回應 → 成頁變灰、上面一块 dark veil、`⚠ Strata is not reachable`；
engine 返嚟 → 遮罩自己消失，**你打咗嘅字冇_lost_**（净 input 清咗）。
佢净係睇 `fetch` 得唔得到 server 嘅回應，**唔使 engine 特殊支援、亦唔郁 API**：所以 engine 0.1.49.1 照用得。
（呢個净係主頁 `serve/web/index.html` + `app.js` + `app.css`；`monitor.html` 冇呢塊遮罩。）

### 改咗邊啲檔案

| 檔案 | 改動 |
|---|---|
| `serve/server.py` | `SERVED_PATHS` / `APP_PATHS` / `dashboard_of()`（`vision_log_tail` 之前）；`Service.dashboard`；handler 加 `_route()` / `_not_our_app()`，`do_GET`/`_post`/`_cors` 改用 `_route()`；`--dashboard` 旗 + config 驗證；`svc.dashboard = dashboard` 再 `serve(svc…)` |
| `rdna3/run.py` | `--dashboard` 旗 → 寫入 cfg（會照落 `rdna3/state/<setup>-<port>.json`，即 §8 方法 B 亦用得） |
| `serve/web/app.js`、`app.css`、`index.html` | offline veil（port 自 `638563a3`，改用 fork 現有嘅 `setOffline`/`i-warning`，冇 ref upstream-only helper） |
| `serve/test_server.py` | 新增 `WebApp.test_the_whole_app_can_move_to_another_path` |

### 驗證做咗乜 / 未做咗乜

- ✅ `.venv/bin/python -m py_compile serve/server.py serve/test_server.py rdna3/run.py`
- ✅ `.venv/bin/python -m unittest serve.test_server.WebApp` → **15 tests OK**（包括新 port 嗰個）。呢個 venv **冇装 pytest**，所以用 `unittest`；想 pytest 要自己 `pip install pytest`。
- ✅ `node --check serve/web/app.js`
- ❌ **未做**：開 browser 實測 veil（要 stop 你 port 8080 個服務先至唔會撞）；`serve/test_monitor.py` 未 run；其他 test class 未 run。
- ⚠️ 記住 §8：`run.py` 一定会傳 `--host`，而 fork 打印嗰行用 `here`（`0.0.0.0` 會顯示成 `127.0.0.1`）—— 即 log 寫 `127.0.0.1` **唔代表**冇 bind 到 LAN。

### 想 revert

```bash
cd /home/tommy/repo/Strata-rdna3 && git checkout -- serve rdna3/run.py   # configs 你嗰啲改動自己決定
```

---

## 11. Git remotes 嘅現況（2026-11-08 改過）

```
origin    https://github.com/gener-vscode/Strata-rdna3.git     ← 你而家推去呢個
upstream  git@github.com:nicejunjie/Strata-rdna3.git           ← 舊個，改名保留，照 pull 得
```

`main` 同 `feat/ui-bridge` 而家 **track `upstream/main`**（所以 VS Code 個 sync 計數仍然係對住舊倉；`git remote rename` 自動改過 branch 設定，我亦 `--set-upstream-to=upstream/main` 明確肯定咗）。

第一次推去新倉之後，想轉返 tracking 去 origin：

```bash
git push -u origin feat/ui-bridge          # 建立 origin/feat/ui-bridge 同 tracking
git push -u origin main                    # 新倉冇 main 之前
```

⚠️ 兩樣嘢：
1. 新 `origin` 係 **HTTPS**：push 會要你嘅 credential（PAT 或 `gh auth login`）。如果你prefer SSH：
   `git remote set-url origin git@github.com:gener-vscode/Strata-rdna3.git`
2. `upstream` 用 SSH（`git@github.com:nicejunjie/…`），即係舊倉要嘅係你 SSH key；想 pull upstream 更新：`git fetch upstream && git merge upstream/main`。
3. 未做任何 push/fetch，亦未改你任何 commit（HEAD 仍然 `7df6538d`）；`feat/ui-bridge` 入面 `/ui` + 遮罩嘅改動而家仲係 **working tree 未 commit**。

---

## 12. 跟住執咗嘅嘢（2026-11-08 下晝）+ ⚠️ 更正 §9

### 更正 §9（我之前講反咗，對唔住）
- `rdna3/configs/iq3-1gpu.json` **喺 git HEAD 本身 run 嘅係 IQ3_S**：`@DATA@/packs/iq3_s`、`models/IQ3_S/…`、`--max-context 262144`、`--kv int8`、`--kv-resident 32768`。我 §9 寫「原版 run IQ3_XXS」係**錯**。
- 12:38 成功嗰次（`experts loaded: 39.97 GiB at 0.50 GiB/s (99 s)` → 8,828 experts / 14.29 GiB VRAM）用嘅係**你自己手改嘅 IQ3_XXS 版 config**。13:44 那次（137 s+、`of about 55 GB`）係 IQ3_S。
- 所以 `reference.json` 嘅 `iq3-1gpu` baseline 對應 HEAD 嗰份 = **IQ3_S**（262144 context、int8 KV、24 GB XTX + 128 GB RAM）；你換 IQ3_XXS 之後仍然唔可以直接比啲数字。

### `rdna3/run.py` 兩處改動（我執，回应你 #1 同 #2）
1. **`--no-vision` 恢復咗**（之前俾删走，我 §0/§10 寫嘅 command 會報 `unrecognized arguments`）。你 prefer 視覺 encoder 唔用 GPU —— 正確寫法係照 config 入面：
   ```json
   "vision": { "exe": "@STRATA@/engine/strata-vision", "mmproj": …, "model": …, "gpu": false, … }
   ```
   `"gpu": false` = encoder 行 CPU（images 照用得）。`--no-vision` = 完全唔起 encoder（慳 RAM 同 start 時間，images 用唔到）。兩樣唔一樣，唔好用 `--no-vision` 代替 `"gpu": false`。
2. **setup 名唔再係 hard-coded enum**（你呢個就係卡住嘅位）：拿走 `SETUPS` 同 `PACKS`，setup 名 = `rdna3/configs/<name>.json` 個檔名；pack 同 first shard 直接讀 config 入面嘅 `--pack` / `--native`（缺咗會清楚报错，唔再 KeyError）。之前 `iq3_xxs-1gpu` 俾 `choices=SETUPS` 拒掉、`PACKS["iq3_xxs"]` 又冇呢個 key，所以你必須改 Python —— 而家**只需要一個新 json**。GPU 數仍然由檔名 `-1gpu`/`-2gpu` 嚟。

### 分拆咗兩份 run config
| 檔 | 內容 |
|---|---|
| `rdna3/configs/iq3_xxs-1gpu.json`（**新增**） | 你而家實際用得嗰份（照你改過嘅內容 copy 過嚟）：IQ3_XXS、`--max-context 160000`、`--kv q4_0`、`"dashboard": "/ui"`、vision `"gpu": false` |
| `rdna3/configs/iq3-1gpu.json`（還原） | 還原返 HEAD 嘅 IQ3_S measured 版 + 淨係加 `"dashboard": "/ui"`。你呢部機 RAM 唔够（engine 話 `of about 55 GB`），想同 `reference.json` 对照先用呢份 |

你之後嘅 command：
```bash
.venv/bin/python rdna3/run.py iq3_xxs-1gpu --data /home/tommy/repo/Strata-data --gpus 0 \
    --host 0.0.0.0 --port 18087 --log /tmp/rdna3-iq3-xxs.log          # browser: http://127.0.0.1:18087/ui/
# 完全唔要 images：加 --no-vision
```

### `.config/` + `.gitignore`
`.config/strata/settings.json` 出返 stage，`.gitignore` 加咗 `/.config/`（內容淨係你呢部機嘅 folder 名加 timestamp，唔屬於 repo）。檔案照喺度，start 行為完全冇變。

### ⚠️ 你自己喺 `run.py` 嘅兩項改動仍然喺度
`argv` 硬寫 `--no-api-key --parallel 1`，而 `--host` default 係 `0.0.0.0` —— 即經 `run.py` 起嚟必定係 **LAN 上無 API key**。想有 key：拿走 `--no-api-key`，或者直接用 `serve/server.py --config rdna3/state/iq3_xxs-1gpu-<port>.json --api-key …`。
