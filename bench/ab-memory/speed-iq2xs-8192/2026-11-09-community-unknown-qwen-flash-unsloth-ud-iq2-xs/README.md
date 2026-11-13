# Community benchmark on AMD Radeon

Measured on 2026-11-09 with `tools/strata_bench.py` (suite 1, 3 runs per test, medians with ranges). Speeds are the engine's own timings; first-token times are measured by the client over HTTP. Speed only: no correctness check was run.

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
| short chat | 46 (43-51) | 0 | 100 (100-100) | 9 | not measured | 61.9 (50.1-68.1) | 0.46 (0.38-0.59) |
| 4K prompt, fresh | 4019 (4019-4019) | 0 (0-0) | 24 cap | 3 | 1163.4 (965.3-1170.0) | not measured | 3.47 (3.45-4.18) |
| 16K prompt, fresh | 16058 (16058-16058) | 0 (0-0) | 24 cap | 3 | 1675.5 (1568.4-1681.5) | not measured | 9.61 (9.58-10.27) |
| 32K prompt, fresh | 32049 (32049-32049) | 0 (0-0) | 24 cap | 3 | 1692.3 (1680.3-1705.4) | not measured | 18.97 (18.83-19.11) |
| agent session, follow-up turns | 14561 (14542-14584) at the last turn | see below | up to 64 | 3 | see below | 77.4 (58.3-96.6) | 3.35 (2.77-4.40) |

Ranges are the lowest and highest of the runs; `Runs` counts requests that returned a token.

### Agent session (conversation cache)

Cache hit over the follow-up turns: 69.6 % (69.5-69.6); earlier-turn tokens read again per session: 3 (2-5) (earlier turns that the cache did not hold; the 13752 (13752-13754) new tokens of the files are read once); first turn (nothing cached) first token: 2.52 s (2.48-2.66).

| Turn (run 1) | Prompt tokens | Reused | Read | Prompt tok/s | First token (s) | Decode tok/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 609 | 0 | 609 | 243.8 | 2.518 | 50.8 |
| 1 | 4113 | 619 | 3494 | 798.8 | 4.396 | 59.1 |
| 2 | 5646 | 4176 | 1470 | 432.4 | 3.42 | 60.3 |
| 3 | 9079 | 5709 | 3370 | 786.2 | 4.309 | 64.0 |
| 4 | 11802 | 9094 | 2708 | 631.2 | 4.313 | 67.5 |
| 5 | 14542 | 11825 | 2717 | 695.7 | 3.928 | 58.3 |

Per-request data: `results.json`. Engine log lines from the start: `engine-log-excerpt.txt` (when this run started the server).

## Correctness and limitations

Not measured: this is a speed suite. The conversation uses the model's own replies, so token counts differ a little between runs. Machine details come from the server, `nvidia-smi`/`rocm-smi` and the OS; background load and power limits are not recorded. Total time of the suite: 196 s.
