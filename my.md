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
.venv/bin/python rdna3/run.py iq1_m-1gpu --data /home/tommy/repo/Strata-data --gpus 0 --host 0.0.0.0 --port 8080 --log /tmp/rdna3-iq1_m.log

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

## 13. systemd service 行緊邊個 model + 兩份 log（2026-11-08 夜）

> §12 嗰份 `iq3_xxs-1gpu` 已經唔係 service 用緊嘅；而家 service = **`iq1_m-1gpu`**（呢個 fork）。

### 13.1 成條鏈
```
strata.service  →  drop-in override.conf  →  /home/tommy/repo/Strata-rdna3/run-iq1_m.sh
                  →  rdna3/run.py iq1_m-1gpu  →  serve/server.py  →  engine/strata --serve --pack packs/unsloth-ud-iq1_m
```
- 主 unit `/etc/systemd/system/strata.service` **完全冇郁過**；改嘅淨係 drop-in `/etc/systemd/system/strata.service.d/override.conf`。
- 而家：port **8080**、host `0.0.0.0`、**無 API key**（`run.py` 硬性加，見 §12 尾）、`--max-context 200000`。
- service 係 `enabled` → **開機自動起 IQ1_M**。

### 13.2 三個 switch（新 terminal；或者先 `source ~/.bashrc`）
| 做乜 | command |
|---|---|
| 切 / 重啟 **RDNA3 IQ1_M**（預設） | `ai-restart` |
| 切返舊 repo IQ3_S / IQ3_XXS | `ai-restart-s` / `ai-restart-x` |
| 狀態 / 停 / tail | `ai-status` / `ai-stop` / `ai-log` |
| 全部還原做返 `setup.sh` 預設 | `sudo rm -f /etc/systemd/system/strata.service.d/override.conf && sudo systemctl daemon-reload && sudo systemctl restart strata` |

### 13.3 ⚠️ 兩份 log 唔係同一份（睇錯度會以為冇警告）
| | `logs/rdna3-iq1_m.log` | `ai-log`（journalctl） |
|---|---|---|
| engine 自己嘅 `WARNING: only NNN MiB of VRAM free` | ✅ | ❌ |
| `strata serve: ... hit rate: ...%`、`decode waited ...` | ✅ | ❌ |
| `[strata] done: 903 tokens in 22 s (93.4 tok/s)` 呢類進度 | ❌ | ✅ |
| 時間戳、跨重啓/跨 profile 舊歷史 | ❌（每次新檔） | ✅（有幾日返嚟，仲有舊 repo） |

原因（`serve/server.py:1013`、`:1045`）：engine **stderr → log 檔案**；engine **stdout → pump → journal**。所以：
- **警告／統計**睇檔案，**即時 tok/s**睇 journal。
- 喺 journal 隨便 grep 唔等於「而家呢次 run」，要 `--since` 或者用檔案做分界。

### 13.4 一行健康檢查
```sh
cd /home/tommy/repo/Strata-rdna3
S=$(grep -an "engine started" logs/rdna3-iq1_m.log | tail -1 | cut -d: -f1)
tail -n +$S logs/rdna3-iq1_m.log | grep -aoE "WARNING.*|hit rate: [0-9.]+%|generated in [0-9]+ ms \([0-9.]+ tok/s\)" | tail -8
grep -E "MemAvailable|SwapFree" /proc/meminfo
```
**紅燈**：`MemAvailable < 1 GiB`、`below 512 MiB` 重複出現、decode < 60 tok/s。

### 13.5 要改 model 或 flags
1. 改 `rdna3/configs/iq1_m-1gpu.json`（呢啲係而家關鍵值：`--max-context 200000`、`--vram-reserve-mib 768`、`--conversation-cache-mib 2048`、`--pool-workers 8`）。
2. `ai-restart`。重啓要讀 32.42 GiB ≈ **62 秒**（實測 0.52 GiB/s）。
3. 換**新** model 要先 pack：
   ```sh
   STRATA_GGUF_PY=$PWD/third_party/llama.cpp/gguf-py .venv/bin/python tools/iq_pack.py \
     --gguf ../Strata-data/models/<新>/<shard1>.gguf --out ../Strata-data/packs/<新> --compat-bf16 --experts-bin
   ```

### 13.6 呢個 fork + IQ1_M 嘅實測（46 GB RAM / 20 GB VRAM 一張卡）
| | |
|---|---|
| experts 入 RAM | 32.42 GiB（`file tier 0`，唔讀 SSD） |
| engine RSS / swap | ~35 GiB / **0.00** |
| MemAvailable | ~8.3 GiB ✅（對照 IQ2_XS：曾得 0.7 GiB） |
| VRAM expert cache | 9282 slots / 12.19 GiB；free ≈ 336 MiB（`--vram-reserve-mib 768`） |
| 速度 | decode ~95 tok/s、hit rate ~83% |
| 唯一邊緣位 | 偶爾 `only 510 MiB of VRAM free`（閾值 512）→ 真係煩就 reserve 832 或者 `--max-context 160000` |

**⚠️ 檔名地雷**：`rdna3/run.py:45` 用 `int(setup.split("-")[1][0])` 由檔名讀 GPU 數 → `ud-iq2_xs-1gpu.json` 呢類**多一個 dash** 嘅名會報 `ValueError`。檔名要係 `iq1_m-1gpu.json`、`iq2_xs-1gpu.json` 呢個格式。

**未量證**：IQ1_M 嘅輸出质量（1-bit／IQ2_XXS／IQ2_S 混合 expert），要自己评。

---

## 14. Web page（`serve/web`）：裝做 app ＋ Monitor 版面（2026-11-28 呢輪改嘅）

> 呢節全部係 **`serve/web`**（即 `/ui/` 嗰個網頁）＋ `serve/server.py` 入面 serve 呢啲檔案嘅嗰條 route。
> **唔關 `apps/host`（Tauri 桌面版）事** —— 桌面版有自己一套 Monitor（`apps/host/src/screens/Monitor.tsx`，
> 包括佢自己嘅 `Show all (N)` 掣），**呢輪完全冇改佢**。

### 14.1 ⚠️ 改咗 `serve/server.py` 一定要重啟 server
`serve/server.py` 嗰條 `/web/` route 用一個 `types` dict 決定邊啲副檔名肯 serve。舊 dict 得 `.css` / `.js` /
`.svg`，所以 `.png` 同 `.webmanifest` 會行 `if ext not in types → _json(404)`，即 **404 但 Content-Type 係
`application/json`** —— 呢個係辨識「server 行緊舊 code」嘅特徵。

```sh
# 睇 server 有冇讀到新 code：
curl -sI http://127.0.0.1:8080/ui/web/manifest.webmanifest | head -1
# 舊：404 application/json   新：200 application/manifest+json; charset=utf-8
```

**兩個坑：**
1. 呢個 server 係 `BaseHTTP`，**HEAD 冇支援** —— 用 `curl -sI` grep header 係揾唔到嘢，要用 GET dump headers。
2. 你個 config 有 `"dashboard": "/ui"`，所以路徑要 `/ui/web/...`；用 `/web/...` 會 301 再 404，睇落好似成日壞。

### 14.2 裝做 app（PWA）
| 檔 | 做乜 |
|---|---|
| `serve/web/manifest.webmanifest` | 名稱、icon、`display: standalone`。**`start_url` 同 `scope` 都係 `"../"`**（相對）→ 預設裝喺 `/`，設咗 `"dashboard": "/ui"` 就自動裝喺 `/ui/`，manifest 入面唔使寫死 |
| `serve/web/sw.js` | Service worker。`VERSION`（而家 `strata-2`）改檔要 bump，先至清走舊 cache |
| `serve/web/icon-{192,512}.png`、`icon-maskable-512.png`、`apple-touch-icon-180.png` | 由 `tools/make_web_icons.py` 產生 |
| `serve/web/index.html` | `<link rel="manifest">`、`<link rel="apple-touch-icon">`、`<meta name="theme-color">` |
| `serve/web/app.js` | `setTheme()` 會跟住改 `meta[name=theme-color]`（dark `#0e1113` / light `#f9fafb`）；`window.isSecureContext && "serviceWorker" in navigator` 先註冊 |
| `serve/server.py` | `types` 加 `.png` / `.webmanifest`；`sw.js` 附上 **`Service-Worker-Allowed: /`**（worker 企喺 `/web/`，預設 scope 控制唔到 page，呢個 header 先闊到） |
| `serve/test_server.py` | `test_the_files_the_page_installs_with`：查 manifest content-type、每個 icon 200、四張 PNG 係 `image/png`、`sw.js` 有嗰個 header |

**SW 策略（呢個最要留意）：network-first，而且永遠唔碰 API。**
`fetch` handler 只處理 `GET` + 同 origin + 路徑喺 `<base>web/` 或 `<base>fonts/`。`/v1`、`/status`、`/metrics`、
`/health`、`/slots`、`/config`、`/mcp`、同所有 POST（包括 streaming chat）全部原路通過去 —— cache 一個舊
`/metrics` 或者 model 嘅答案，即係螢幕上一個錯嘅數。Cache 淨係「問唔到人」時 fallback（page 會 show 自己
嘅 offline veil，而唔係 browser 錯誤頁）。

**非安全環境自動唔做嘢**：`127.0.0.1` / `localhost` / https 先註冊；用 `http://192.168.x.x` 行 LAN 就跳過，
page 同以前一模一樣，唔會報錯。

### 14.3 icon 係點嚟嘅（可重現）
```sh
.venv/bin/python tools/make_web_icons.py      # ⚠️ 一定要 .venv，system python3 冇 PIL
```
- 幾何**直接抄自頁面嘅 Context fill gauge**（`index.html`：`r="50"`、`stroke-width="10"`、
  `stroke-dasharray="235.6 314.2"`、`transform="rotate(135 60 60)"`）→ **270° 圓弧、缺口喺下面**。
- 用 polyline + `joint="curve"` + 兩端圓 cap（唔靠 Pillow `arc` 嘅角度方向），8× 超取樣再 LANCZOS。
- 顏色：透明版 `--st-accent` light `#10b981`；深色底版 dark `#34d399` 配 `--st-bg` `#0e1113`。
- `serve/web/favicon.svg` 一齊改做同一個圓弧，等 **tab / 裝咗嘅 app / 頁面三者一致**。

**換 icon 要兩個動作先見到：** ① 改咗 `server.py` → 重啟 server；② **Chrome 喺「安裝嗰一刻」snapshot icon 落
`.app`，之後改 manifest 唔會自動換** → `chrome://apps` 右鍵 Uninstall → DevTools  unregister SW → 再 Install。

### 14.4 測試點樣跑
```sh
.venv/bin/python -m unittest serve.test_server serve.test_security      # 44 tests
.venv/bin/python -m unittest discover -s serve                          # 成個 354 tests
```
> ⚠️ **system `python3` 冇 pytest 亦冇 PIL**。之前我一度以為「呢部機跑唔到測試」，係 interpreter 揾錯。

### 14.5 Monitor 版面改動清單
#### 所有闊度都生效
| 改動 | 喺邊 |
|---|---|
| Speed tile 標題做 `Speed (t/s)`，兩個數後面**唔再寫 `t/s`** | `app.js` `TILE.speed` |
| 兩個數下面 sub 行淨返動態部分：`now` / `this request` / `last request`（冇就空白） | `app.js` `renderMonitor()` |
| **Prefill 左 / Decode 右**（跟 request 發生次序） | `app.js` `buildTiles()` |
| **唔係 running 嗰邊變暗 `opacity: .4`**（idle 時兩邊都唔會暗） | `app.css` `.speed-values .is-dim`；id `#side-prefill` / `#side-speed` |
| 兩個數嘅 tile 數字大細對齊單數 tile（走咗 `clamp()`，改用 `var(--st-fs-stat)`） | `app.css` |
| 表格標題：`Prefill` / `Decode` / `Hit rate`（走咗 `t/s`、`VRAM`） | `index.html` `<thead>` |
| **表格欄順序：Time, Status, Prefill, Decode, Prompt, Reused, Output, Hit rate, Duration** | `index.html` + `app.js` `requestCells()`（**兩邊必須一一對應**） |
| Model state 卡：「Model state」標題＋五個 badge **全部移除**，狀態由左邊 caption 畫做**一個 badge**（跟狀態變色） | `index.html` + `app.css` `#state-label[data-state=…]`（**base，唔係 media query**） |
| 「Experts」卡標題 → **模型名最後兩段大寫**（`qwen-flash-unsloth-ud-iq2_xs` → `UD-IQ2_XS`），hover 睇全名 | `app.js` `#ctx-title`；大寫靠 `app.css` `text-transform`（DOM 文字唔變，複製/搜尋照舊準） |

#### 得 ≤560px
| 改動 | 喺邊 |
|---|---|
| **頂欄永遠可見**，高 40px（原本 60）；**收埋「Strata」** | `app.css` `@media (max-width: 560px)` |
| Tabs **唔再係 bar 內嘅灰底 pill 面板**：全高、冇圓角、冇內距，揀中用 `--st-surface-2` 底 + `inset 0 -2px 0` 底線（**用 inset shadow 而唔係 border，因為 border 會食 height**） | `app.css` `.st-header .st-tabs` / `.st-tab` |
| Request 進度 bar 離開張卡，變做**視窗最頂 2px 固定細線**（GitHub loading 風格） | `app.css` `#state-progress { position: fixed }` |
| GPU load + Power **合併做一個「GPU」tile**（左 load %、右 power、chart 用 power）；**隱藏 GPU temp** → 得返 4 個 tile | `app.js` `buildTiles()` 嘅 `.tile-gpu`；`app.css` `[data-tile=…]` |
| Recent requests：**收標題**、**行欄倒轉**（一欄一個 request）、卡尾兩欄排版掣靠右 | `app.css` `.req-card` grid + `app.js` |
| Status 行移除，**顏色放咗去 time**；time **去秒**（`20:18:14` → `20:18`）；**TIME 右對齊** | `app.js` `REQ_STATUS`；`app.css` `#req-body .req-time` |
| Prompt / Reused **超過 1K 用 `k`**（`kfmt()`，同 `68k / 200k` 一致） | `app.js` `requestCells(r, narrow)` |
| Hover 高亮 **row → column**（CSS 冇欄 selector，JS 加 `.hover`） | `app.js` `highlightColumn()` |
| **預設欄數按實際寬度自動計算**，唔使橫 scroll（`requestFit()`）；resize 有 150ms debounce | `app.js` |
| 掣文字：`N more` / `Recent`（唔再係 `Show all (N)` / `Show fewer`） | `app.js` |
| cards 以外空白減半：**page padding 同 card gap 都係 8px**（`var(--st-s-2)`，兩者統一） | `app.css` `.monitor, .about` |

### 14.6 ⚠️ 呢輪踩過／要留意嘅地雷
1. **560px 呢條線要兩邊同步**：`app.js` 嘅 `matchMedia("(max-width: 560px)")`（`narrowScreen`）決定表格倒唔倒轉，
   `app.css` 條 `@media (max-width: 560px)` 決定樣式。改一邊唔改另一邊會出鬼 layout。
2. **`requestCells()` 順序必須等於 `<thead>` 順序**。倒轉版係 JS 由 `<thead>` 逐個讀標籤再按同一 index 配值，
   淨係改 HTML → 每個標籤下面都啱錯一欄。
3. **`REQ_STATUS = 1` 係硬 index**，改欄序要改返。
4. **`.req-head` 係四個 card 共用**（Recent requests、Conversation cache、MCP servers、Model settings）——
   任何規則都**要加 `.req-card` 前綴**，否則連其他三張卡標題一齊收埋。
5. **`buildTiles()` 入面唔好將 JS 註釋放進 template literal** —— 會被當 HTML 文字 render 出嚟（我犯過兩次）。
6. **JSON（manifest）唔容許 `<!-- -->` 註釋** —— 會整爛成個 manifest（我犯過一次）。
7. **掣顯示條件**：`all.hidden = !reqShowAll && kept <= shown.length`。展開時一定要留低個掣，否則撳完
   「N more」就冇返去嘅路（呢個係真 bug，已修）。
8. `#state-badges` 呢個元素**已經由 HTML 删走**：任何再 `querySelector("#state-badges …")` 嘅 code 都會靜靜郁空。
9. `.state-card` 而家**冇咗 `st-card` class**（用家自己改嘅），所以張卡冇邊框/底色。

### 14.7 未做／未證
- **全部呢輪改動都冇落瀏覽器實測渲染**，淨係做咗語法檢查、CSS 括號平衡、同 server 端 curl/單元測試。
  有幾處靠 `getBoundingClientRect()`（`requestFit`）同 media query 實際行為，**要拖下視窗先放心**。
- `apps/host`（Tauri 桌面版）完全冇郁。
- `docs/DETAILS.md` 冇寫呢啲行為（AGENTS.md 本來要求寫落去）；呢份 `my.md` §14 係目前唯一紀錄。
