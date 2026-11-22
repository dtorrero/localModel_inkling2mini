# Measured on this machine

> **Superseded.** The full write-up is in [`REPORT.md`](REPORT.md) (hardware, software,
> build, method, results, analysis). This file is kept as the first measurement pass; the
> numbers below came from single runs before the systematic sweep. Where they differ,
> `REPORT.md` §5 and `bench/results.csv` are authoritative.

Radeon Pro VII (gfx906, 16 GiB HBM2, sclk 1700 MHz / mclk 1000 MHz), ROCm 7.2.4,
local HIP build `1.0.0-dev (build 12893, commit 8094ad12f)` = upstream `b12588` +
the 30 pins from `pr-set.b12588.json`.

Model: `Inkling-2-Mini-UD-IQ3_XXS.gguf` (11.65 GB), `mmproj-F16.gguf`,
`dspark-Inkling-2-Mini-Q8_0.gguf`. Context 16384, KV `q8_0`/`q8_0`, `-ngl 99`.

## Throughput (llama-server `timings`)

| Test | Prompt | Decode | Draft acceptance |
|---|---|---|---|
| long prompt, 1473 tokens | **306 tok/s** | 15.6 tok/s | 7/18 (39%) |
| short prompt, 32 tokens (cold) | 27.6 tok/s | 16.2 tok/s | 71/140 (51%) |
| short prompt, 11 tokens | 49.4 tok/s | 26.2 tok/s | 34/72 (47%) |
| `17*23`, 600 max tokens | — | 29.1 tok/s | — |
| image + question | 41.1 tok/s | 27.5 tok/s | 24/44 (55%) |

Drafter A/B, 100 output tokens, same prompt:

| Drafter | Run 1 | Run 2 |
|---|---|---|
| `--spec-type draft-dspark` | **34.3 tok/s** (79% acceptance) | 24.8 tok/s (46%) |
| none (`NO_DRAFT=1`) | 25.6 tok/s | 25.8 tok/s |

So DSpark is a real win when the block drafter is confident and roughly neutral
when it is not; keep it enabled (`NO_DRAFT=1` frees 0.37 GiB if VRAM matters more).

Steady-state expectation: **~25-35 tok/s decode, ~300 tok/s prefill** at 16k
context. First request after load is slower (kernel module compile/warm-up).

## VRAM

| Context | VRAM used | Free |
|---|---|---|
| 16384 | 16.99 GB of 17.16 GB | ~0.17 GB |
| 8192 | 16.22 GB | ~0.94 GB |

The 16k figure includes ~1.58 GB held by the desktop session. KV costs
~48 KiB/token with `q8_0` (0.77 GB difference between 8k and 16k), so
`CTX=16384` is the maximum that fits with the vision projector loaded; drop to
`CTX=8192` (or `NO_MMPROJ=1`) if another GPU application needs memory.
`UD-Q4_K_XL` (15.8 GB of experts) cannot be fully offloaded here.

## Functional checks

* `GET /health` → 200.
* Chat completion returns correct text (`17 × 23 = 391`); the model is a
  reasoning model, so thinking tokens arrive in `reasoning_content` and the final
  answer in `content` once it stops thinking. Give `max_tokens` room for both.
* Vision: a generated red 128×128 PNG is described correctly as red
  (mmproj + `image_url` data URI).
* `draft-dspark` initialises with `block_size=8, n_extract=4, markov_rank=256`.

## Known limitations

* `resolve_fused_ops` reports *Flash Attention over K/V rows is not supported*
  on gfx906, so the K/V-row FA path of the DSpark drafter falls back to CPU.
  llama-server logs it and continues; do not expect FA speed-ups on Vega.
* ROCm prints "AMD GPU device(s) is/are in a low-power state" while idle; clocks
  do reach 1700 MHz under load.
