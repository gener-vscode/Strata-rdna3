# Community benchmark on AMD Radeon

Measured on 2026-11-10 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

## Hardware and software

- GPU and VRAM: AMD Radeon, 20 GiB VRAM
- CPU: AMD Ryzen 7 7800X3D 8-Core Processor (8 cores, 16 threads); installed RAM: 46.4 GiB; storage: not measured
- OS: Linux 6.8.0-147-generic; GPU driver: 6.8.0-147-generic; CUDA: not read
- Strata: project 0.1.49.1, commit ce61f3b0; engine 0.1.49.1
- Background workloads and power limits: not recorded

## Model and configuration

- Model and quantization: qwen-flash-unsloth-ud-iq2_xs
- Context: 224000 tokens; parallel slots: 1
- Settings: the install's own configuration, unchanged; thinking off for the suite; temperature 0

## Method

Run by `python tools/strata_bench.py --long` against the HTTP API of a Strata server (already running); model loading is not timed. One warm-up chat and a 1K prompt are discarded first. Every prompt starts with a unique tag, so the conversation cache cannot help the fresh-prompt tests.

- short chat: the three questions of `tools/ab_engine.py`, up to 100 new tokens, 3 runs
- 4K / 16K prompts: generated word lists sized by a calibration request, 24 new tokens, 3 fresh prompts each
- agent session: system prompt and four tools, then 5 turns that each add about 1500 words of a project file and continue from the model's own earlier answers (the way agent clients resend a conversation), 64 new tokens per turn, 3 sessions; the cache numbers come from the answer's usage (`cached_tokens`) and timings (`prompt_n`)
- concurrency (when run): N requests sent at the same moment, total tokens over the wall time of the burst, latency over all requests

## Results

| Configuration | Actual prompt tokens | Reused tokens | Generated tokens | Runs | Prompt tok/s median and range | Decode tok/s median and range | TTFT seconds median and range |
| --- | ---: | ---: | ---: | ---: | --- | --- | --- |
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 68.6 (53.4-72.2) | 0.48 (0.41-0.59) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 1203.1 (988.1-1204.4) | not measured | 3.36 (3.36-4.09) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 1948.6 (1721.8-1951.7) | not measured | 8.27 (8.25-9.35) |
| 32K prompt, fresh | 32049 (32049-32049) | 0 (0-0) | 24 cap | 3 | 1950.5 (1942.3-1952.9) | not measured | 16.46 (16.44-16.53) |
| agent session, follow-up turns | 14558 (14550-14574) at the last turn | see below | up to 64 | 3 | see below | 75.4 (57.0-92.8) | 3.26 (2.70-4.37) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.6 % (69.6-69.6); earlier-turn tokens read again per session: 4 (3-4) (earlier turns that the cache did not hold; the 13753 (13752-13753) new tokens of the files are read once); first turn (nothing cached) first token: 2.23 s (2.23-2.26).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 271.7 | 2.262 | 60.6 |
| 1 | 4116 | 624 | 3492 | 805.1 | 4.373 | 58.1 |
| 2 | 5649 | 4179 | 1470 | 443.3 | 3.346 | 67.3 |
| 3 | 9082 | 5712 | 3370 | 789.9 | 4.295 | 61.6 |
| 4 | 11817 | 9109 | 2708 | 645.4 | 4.227 | 79.2 |
| 5 | 14558 | 11841 | 2717 | 705.0 | 3.878 | 70.7 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load and power limits are not recorded. Total time of the suite: 180 s.
