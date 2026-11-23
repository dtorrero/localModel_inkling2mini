# Inkling 2 Mini on a 2020 Radeon Pro VII — build & benchmark report

Date: 2026-11-22 · Host: `sprinter-machine` · Author: local measurement run

## Summary

A six-and-a-half-year-old AMD **Radeon Pro VII** (Vega 20, **gfx906**, 16 GB HBM2) runs
Thinking Machines Lab's **Inkling 2 Mini** — a 26.4 B-parameter mixture-of-experts with
5.4 B active parameters, 1 M context and image input — **entirely on the GPU** at 16k
context. Unsloth publishes no gfx906 binary and the published `-mix-` tag does not
contain the `inkling2` architecture, so the runtime had to be reproduced locally: upstream
tag `b12588` plus **30 pinned PR commits** merged in the order their CI uses (final commit
`8094ad12f`), compiled with `-DGGML_HIP=ON -DGPU_TARGETS=gfx906` against ROCm 7.2.4 in
about **5 minutes** on the machine's 2016 Xeon. On the 11.66 GB `UD-IQ3_XXS` quant it
delivers **~210–320 tok/s prefill** and **~24–28 tok/s decode**, uses **16.8 of 17.2 GB** of
VRAM at 16k context, and handles images through `mmproj-F16`. The guide's default
`UD-Q4_K_XL` does not fit in 16 GB: with its 15.8 GB of experts in system RAM it still runs at
**~91–108 tok/s prefill / 7.5–11 tok/s decode**, and **133 / 13.4 tok/s** with half of them on
the GPU. The ceiling here is GCN's lack of matrix cores and the missing flash-attention path,
not the 1 TB/s HBM2 bus: decode uses roughly **52 GB/s (~5% of peak bandwidth) and ~280 GFLOPS
(~2% of FP32 peak)**.
It is comfortably usable for local chat, coding help and image Q&A with no cloud dependency.
An end-to-end agent test through Cline — write code, run pytest, write the notes — completed
all five steps in 3 min 55 s (§7), with the transcript archived in `bench/agent-test/`.

---

## 1. Hardware

| Component | Specification | Introduced | Age at 2026-11 |
|---|---|---|---|
| **GPU** | AMD Radeon Pro VII — Vega 20 (**gfx906**), 7 nm, 60 CU / 3840 SP, 16 GiB HBM2, 1024 GB/s, 13.4 TFLOPS FP32 / 26.8 TFLOPS FP16, 300 W | **Announced May 2020** (June 2020 availability) | **~6.5 years** |
| GPU silicon | Vega 20 first shipped as Radeon Instinct MI50 (Nov 2018) / Radeon VII (Feb 2019) | **Nov 2018** | **~8 years** |
| **CPU** | Intel Xeon E5-2690 v4 (Broadwell-EP, 14 nm), 14 cores / 28 threads, 2.6 GHz base / 3.5 GHz turbo, 35 MB L3, 135 W, LGA2011-v3 | **Q1 2016** | **~10.8 years** |
| **RAM** | 62 GiB DDR4 ECC, quad-channel, **no swap** | 2016 platform | ~10 years |
| **Storage** | NVMe Crucial P310 2 TB (`CT2000P310SSD8`), WD60EDAZ 6 TB HDD | — | — |
| **Link** | GPU on **PCIe 3.0 x16** (8 GT/s, `rocm-smi` reports `8.0GT/s x16`); the card itself is PCIe 4.0 | — | — |
| Power / thermal | 160 W cap in `manual` perf level; 64–73 °C edge, up to 95 °C junction under load | — | — |

Age matters here in three concrete ways:

1. **gfx906 is a legacy ROCm target.** ROCm 7.2.4 still ships gfx906 kernels and compiles for
   it, but AMD no longer lists it as supported and Unsloth does not build for it, hence the
   local build (§3).
2. **No matrix cores.** MFMA arrived with gfx908/gfx90a and WMMA with RDNA 3; Vega 20 only has
   packed FP16 (`V_DOT2/4`, `v_pk_fma_f16`), which the current HIP kernels use poorly for
   quantized MoE matmuls.
3. **Old power management.** The card idles at `Performance Level: manual`, ~860 MHz and 25 W
   during decode, and only reaches 1700 MHz on heavier prefill. `rocm-smi --setperflevel high`
   (root) is the obvious knob; it was not available in this session.

---

## 2. Software stack

| Layer | Version | Notes |
|---|---|---|
| OS | Manjaro Linux (rolling), kernel **7.2.9-1-MANJARO** | `amdgpu` in-kernel |
| ROCm | **7.2.4** (`rocm-core`, `hip-runtime-amd`, `rocblas` 7.2.4-3, `hipblas` 7.2.4-1) | `/opt/rocm`, hipcc = AMD clang 22, gfx906 codegen verified |
| Vulkan (fallback) | Mesa **26.2.4**, RADV VEGA20 | unused in the final setup |
| Compiler / build | GCC **16.2.1**, CMake **4.4.4**, Ninja **1.13.2** | no ccache |
| Python | **3.14.7**, `huggingface_hub` **2.1.1** (`hf` CLI), Pillow **12.3.0** (vision test) | |
| Inference | llama.cpp, Unsloth fork: **`1.0.0-dev`, build 12893, commit `8094ad12f`** | base `b12588` + 30 pins |
| Backend | `GGML_HIP` (hipBLAS/rocBLAS), `-DGPU_TARGETS=gfx906` | 70 MB `libggml-hip.so`, linked against `librocblas.so.5`, `libamdhip64.so.7` |
| Model | `unsloth/Inkling-2-Mini-GGUF` | `UD-IQ3_XXS` 11 663 309 504 B · `mmproj-F16` 639 348 160 B · `dspark-…-Q8_0` 402 278 560 B |

Nothing had to be installed: the distribution already provided ROCm, the HIP toolchain,
CMake/Ninja/GCC, Python and the `hf` CLI. The distro's `llama.cpp-hip-mtp` package was left
untouched (it cannot load `inkling2`).

---

## 3. How it was built

The guide's AMD command downloads `app-…-linux-x64-rocm-gfx120X.tar.gz`. On gfx906 that
binary cannot even initialise, and two further problems only appear once you try to
reproduce the build. All three are encoded in the scripts under `scripts/`.

**Step 1 — get the source.** The fork's tag is a snapshot of the base tree, not the binary:

```bash
git clone --depth 1 --branch b12588-mix-c0c3de8 https://github.com/unslothai/llama.cpp
```

**Step 2 — merge the 30 pins (this is the step that adds `inkling2`).**
`.github/workflows/unsloth-prebuilt.yml` checks out the **upstream `ggml-org` tag `b12588`**
and then `git merge`s every pinned PR commit in `scripts/unsloth/pr-set.json` in order,
falling back to `scripts/unsloth/additive_merge.py` when two pins merely append to the same
table. The tag's own tree is pruned (vendor blobs, examples) and merging onto it conflicts
everywhere, so the base must be upstream:

```bash
./scripts/merge-pins.sh          # 30/30 pins merged -> commit 8094ad12f
```

Without it the binary fails with `unknown model architecture: 'inkling2'`; the build script
now refuses to start if `LLM_ARCH_INKLING2` is absent.

**Step 3 — build for gfx906** (the UI toggle is the third deviation: this tag derives the
Hugging Face UI asset version from `LLAMA_BUILD_NUMBER` → `b1`, which does not exist, and the
`latest` fallback fails asset validation, so the API-only path is used):

```bash
cmake -S llama.cpp -B llama.cpp/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON -DGPU_TARGETS=gfx906 \
      -DLLAMA_CURL=ON -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
cmake --build llama.cpp/build --target llama-server llama-cli llama-bench llama-mtmd-cli -j 24
```

**Measured build cost** (log timestamps, 28-thread Xeon):

| Phase | Wall clock | Notes |
|---|---|---|
| Shallow clone | ~1 min | 221 MB |
| Compile (387 targets, `-j 24`) | **4 min 57 s** | includes one failed UI-asset target and the resume; HIP objects dominate |
| Pin merge (30 merges, 3 additive resolutions) | ~1 min | network-bound (fetches 30 commits + history) |
| Rebuild after pins (348 targets) | **3 min 30 s** | |
| Download of the 3 GGUF files | 6 min (12.7 GB) | ~35 MB/s burst, later throttled to ~1 MB/s per connection |

Resulting binaries: `llama.cpp/build/bin/llama-server` (HIP), reporting
`1.0.0-dev (build 12893, commit 8094ad12f)` and initialising
`AMD Radeon Pro VII, gfx906:sramecc+:xnack- (0x906), Wave Size: 64`.

---

## 4. Benchmark method

**End-to-end** (`bench/bench_server.py`, raw rows in `bench/results.csv`):

* `llama-server` over HTTP, OpenAI-compatible `/v1/chat/completions`;
* Unsloth's recommended sampling: `temperature 1.0, top_p 1.0, top_k 0, min_p 0.0`;
* prompt sizes 128 / 512 / 2048 / 8192 tokens (repeated filler text, ~4 chars/token),
  128 output tokens, 1 discarded warm-up + **3 measured repetitions, median reported**;
* `cache_prompt: false` plus a unique nonce per request, otherwise llama-server answers
  repeats from the KV cache and reports a tiny `prompt_n`;
* TTFT = `prompt_ms` + one decode step; prefill/decode rates come from the server's own
  `timings` block (`prompt_per_second`, `predicted_per_second`);
* vision: 128×128 PNG as `image_url` data URI, 3 repetitions;
* configuration labels: `iq3_xxs_draft`, `iq3_xxs_nodraft`, `iq3_xxs_vision`,
  `q4_k_xl_cpumoe`, `q4_ncmoe{12,24}`.

**Kernel-level** (`llama-bench`, no server, no speculative decoding):

```bash
llama-bench -m …/Inkling-2-Mini-UD-IQ3_XXS.gguf -ngl 99 -fa auto -p 512 -n 128 -r 5
llama-bench … -p 128,512,2048,8192 -n 128 -r 3          # context scaling
llama-bench … -ctk q8_0 -ctv q8_0 -p 512 -n 128 -r 3    # KV cache type
llama-bench … -fa off -p 512 -n 128 -r 3                # flash attention off
```

**VRAM ladder**: server started at `CTX=4096/8192/16384/32768`, resident VRAM sampled with
`rocm-smi --showmeminfo vram` once it reported `listening`.

**Telemetry**: `rocm-smi --showclocks --showtemp --showpower --csv` sampled every 2 s during
generation.

All runs used the same default launch (`-ngl 99`, q8_0 K/V, mmproj + DSpark drafter) except
where a row says otherwise.

---

## 5. Results

### 5.1 End-to-end, `UD-IQ3_XXS` fully on GPU (server, median of 3)

| Config | Prompt tokens | TTFT | Prefill tok/s | Decode tok/s | Draft acceptance |
|---|---|---|---|---|---|
| default (DSpark on) | 112 | 0.78 s | 152.0 | 25.5 | 51% |
| default | 424 | 1.54 s | 282.0 | **27.2** | 51% |
| default | 1672 | 5.41 s | **311.5** | 23.5 | 43% |
| default | 6638 | 22.8 s | 291.2 | 24.4 | 51% |
| vision (image + question) | 45 | 0.76 s | 61.8 | **28.8** | 54% |
| no drafter (`NO_DRAFT=1`) | 425 | 1.48 s | 294.2 | 25.4 | — |
| no drafter | 1672 | 5.21 s | 323.7 | 24.6 | — |

**DSpark is a wash on this GPU**: +7% decode at 512 tokens (27.2 vs 25.4), −4% at 2048
(23.5 vs 24.6). On a listing task with 79% acceptance it reached 34.3 tok/s, but median
acceptance here is ~50%, so the drafter's own compute eats the gain. It costs 0.37 GiB of
VRAM; keep it only if VRAM is not the constraint.

**Vision costs prefill, not decode**: image encoding drops prefill from ~280 to 62 tok/s for
a 128×128 PNG, while decode stays at ~29 tok/s.

### 5.2 Kernel-level (`llama-bench`, no server, no drafter, `-r 5`/`-r 3`)

| Configuration | pp128 | pp512 | pp2048 | pp8192 | tg128 |
|---|---|---|---|---|---|
| f16 KV, `-fa auto` | 248.3 | 322.5 ± 1.1 | 245.3 | 210.5 | **28.5 ± 0.2** |
| **q8_0 KV, `-fa auto`** (default) | — | **396.0 ± 1.5** | — | — | 27.5 ± 0.2 |
| f16 KV, `-fa off` | — | 394.3 ± 2.7 | — | — | 27.8 ± 0.2 |

Two useful findings: prefill falls with context length (322 → 210 tok/s from 512 to 8192
tokens, the cost of attending over a longer KV without a working flash-attention kernel), and
**f16 KV is ~22% slower than q8_0 KV**. That is consistent with the f16 path actually taking
the flash-attention branch (the explicit `-fa off` run lands at 394 tok/s, matching q8_0),
and on gfx906 that branch is slower than the fallback. The default (q8_0 K/V) is therefore
both the smallest and the fastest option here.

### 5.3 The guide's default quant: `UD-Q4_K_XL` (17.63 GB, experts in RAM)

| Expert placement | VRAM used | Prefill tok/s | Decode tok/s | Draft acc. |
|---|---|---|---|---|
| `--cpu-moe` (all 15.8 GB in RAM) | 6.90 GB | 91.4 / 107.9 | 11.0 / 7.5 | 66 / 40% |
| `--n-cpu-moe 12` (half the blocks) | 15.95 GB | **133.4** | **13.4** | 57% |
| `--n-cpu-moe 24` (effectively all) | 7.02 GB | 88.7 | 10.1 | 58% |
| `--n-cpu-moe 36` | 7.10 GB | 87.5 | 10.9 | 71% |

`--n-cpu-moe N` counts blocks (24 in this model), not the 48 layers, which is why 24 and 36
behave identically. Moving half the experts to the GPU buys ~46% prefill and ~22% decode over
the all-CPU split, but nothing comes close to `UD-IQ3_XXS` fully resident: the guide's default
quant is **~2.5× slower to decode** and **~3× slower on prefill** than the 3.06 bpw quant.

### 5.4 VRAM and context

| `--ctx-size` | VRAM after load | Result |
|---|---|---|
| 4096 | 15.22 GB | ok |
| 8192 | 15.78 GB | ok |
| **16384** | **16.79 GB** | ok (default) |
| 32768 | — | **OOM**: `failed to allocate ROCm0 buffer of size 880425984` |

KV cost is ~**128 KiB/token** with q8_0 K/V (≈0.56 GB per 4k tokens), of which the desktop
session holds ~1.5 GB before the model loads. 16k is the practical ceiling with the vision
projector and drafter resident; 32k would need ~2 GB more than the card has.

### 5.5 Telemetry while serving

| State | SCLK | MCLK | Power | Edge temp |
|---|---|---|---|---|
| decoding (860 MHz level 1) | 860 MHz | 800–1000 MHz | 25–26 W | 64–68 °C |
| prefill burst | up to 1700 MHz | 1000 MHz | 37 W | 73 °C (junction 95 °C) |

The card spends decode at its **lowest clock level** (`Performance Level: manual`, 25 W of a
160 W cap). Raising it needs root — `sudo rocm-smi --setperflevel high` — and was not possible
in this session; it is the single most promising unexplored knob.

### 5.6 Functional checks

| Check | Result |
|---|---|
| `GET /health` | 200 |
| `What is 17*23?` | `17 × 23 = 391` ✓ (twice, incl. the README smoke test) |
| Self-description | "I'm Inkling, made by Thinking Machines Lab." ✓ |
| Vision, red 128×128 PNG | described as red ✓ (via `mmproj-F16`) |
| DSpark init | `block_size=8, n_extract=4, markov_rank=256` ✓ |

The model is a reasoning model: with small `max_tokens` the answer stays inside
`reasoning_content` and `content` is empty. Give it room (≥400 tokens for short questions).

---

## 6. Analysis: why 24–28 tok/s

Inkling 2 Mini is a 26.07 B-parameter MoE at 3.0625 bpw (10.85 GiB) with 8 of 128 experts
active per token, so a single token reads roughly:

* dense weights (attention, embeddings, output head, shared expert): **~1.35 GB**;
* routed experts actually touched: 8/128 × 10.30 GB ≈ **0.64 GB**;
* total ≈ **2.0 GB per token**.

At 24–28 tok/s that is **48–56 GB/s**, about **5% of the card's 1024 GB/s** HBM2 peak, while
the arithmetic side is 5.4 B active × 2 FLOP × 26 tok/s ≈ **280 GFLOPS**, about **2% of the
13.4 TFLOPS FP32** peak. Neither the memory bus nor the ALUs are saturated: decode is
**latency/occupancy-bound**. The causes, in order of likely impact:

1. **No matrix cores.** gfx906 predates MFMA (gfx908+) and WMMA (RDNA 3). Quantized MoE
   matmuls run on wave64 vector code paths with 1 token per step, so each of the 48 layer
   launches is a string of small kernels with little work per dispatch.
2. **No usable flash attention.** `resolve_fused_ops` reports *Flash Attention over K/V rows
   is not supported* for the drafter, and `llama-bench` shows the f16/FA path is **22% slower
   on prefill** than the fallback. Attention over long KV therefore costs more, which is why
   prefill falls from 322 to 210 tok/s between 512 and 8192 tokens.
3. **Clock policy.** Decode runs at 860 MHz / 25 W (lowest level) rather than 1700 MHz.
4. **Looped layers.** The model runs its middle layers several times per token (24 blocks →
   48 layer executions) and per-expert scale sidecars add a second tensor read per expert.

The same analysis explains the Q4_K_XL numbers: with experts in DDR4 the token touches
~1.0 GB of expert weights from RAM, so 11 tok/s is bounded by host memory latency and the
PCIe 3.0 x16 link (15.75 GB/s theoretical), not by the GPU at all.

For context, one would expect a modern RDNA 3/CDNA 3 card to run the same quant at several
times this rate; the Vega 20 result is what a 2020 GCN part with no matrix units and no
flash attention can do — and it is still 2–3× faster than running the model on this CPU alone.

---

## 7. Use test: agentic coding through Cline

Cline 4.1.27 (`saoudrizwan.claude-dev`, run inside VS Code) driving this server over the
OpenAI-compatible API (`http://127.0.0.1:8080/v1`, context 16384, max output 4096,
temperature 1.0) in `/home/sprinter/CodebergProjects/inkling2_testing`. Version 4.1.27 keeps
its session store under `~/.cline/data/sessions/`; the transcript of this run (session
`1795440466571_ki4p2`, 23 messages, 11 tool calls) is archived in
`bench/agent-test/session.md` and `session.json`.

**Task given to the agent** (verbatim, five ordered steps): create `math_utils.py` with
`add(a, b)` and `divide(a, b)` (`ValueError` on a zero divisor, type hints, docstrings);
create `test_math_utils.py` with four pytest cases; run `pytest -q` and fix the
*implementation* (not the tests) until green; write `NOTES.md` with the verbatim pytest
output, one sentence on the zero-divisor behaviour and the number of pytest runs; print a
directory listing. Constraints: stdlib + pytest only, exactly three files, stop if impossible.

**Outcome: all five steps completed** — 5 055 generated tokens, 3 min 55 s of model time.

| Artefact | Lines | Verified |
|---|---|---|
| `math_utils.py` | 17 | `divide(1, 0)` raises `ValueError("cannot divide by zero")`; both functions typed and documented |
| `test_math_utils.py` | 21 | the four requested cases, left unmodified |
| `NOTES.md` | 16 | verbatim `4 passed in 0.01s`, zero-divisor sentence, "3 pytest runs" |

Independent re-run of the suite, with caches disabled so nothing new is written:

```
$ PYTHONDONTWRITEBYTECODE=1 pytest -q -p no:cacheprovider
....                                                                     [100%]
4 passed in 0.01s
```

The directory holds exactly the three requested files, so the "no extra files" constraint
held as well — the `__pycache__`/`.pytest_cache` directories pytest normally leaves behind
were removed. The three artefacts are archived verbatim in `bench/agent-test/`, so the run
can be re-checked from this repository.

**What the agent actually did** — 11 tool calls, every one a native `tool_call`:

| # | Tool | Action |
|---|---|---|
| 1 | `run_commands` | `pwd && ls -la` — confirm the directory is empty |
| 2 | `run_commands` | `which python3 && python3 --version && python3 -c 'import pytest; …'` |
| 3–4 | `editor` | create `math_utils.py` and `test_math_utils.py` |
| 5 | `run_commands` | `pytest test_math_utils.py -q` — **4 passed on the first attempt** |
| 6–8 | `run_commands` | re-run pytest through `cat -A`, then a `subprocess` capture, then a string check, to copy the output byte-exactly into `NOTES.md` |
| 9 | `run_commands` | write `NOTES.md` from a heredoc |
| 10 | `run_commands` | `ls -la` and `cat NOTES.md` — verify steps 4 and 5 |
| 11 | `run_commands` | `rm -rf __pycache__ .pytest_cache && ls -la` — drop the caches pytest had created |

So the "3 pytest runs" recorded in `NOTES.md` are **one verification run plus two re-runs to
satisfy step 4's "copy it verbatim"** — not a fix cycle; the implementation never needed
changing. The model also flagged, unprompted, that the exact spacing of the progress-dots
line depends on terminal width, so a "verbatim" copy can differ in whitespace elsewhere.

**Per-request cost of the run** (reconstructed from the `slot print_timing` lines in the
server log; turn 1 is Cline's system prompt plus tool schemas):

| Turn | Wall clock | Prompt tok | Prefill tok/s | Gen tok | Decode tok/s | Draft acc |
|---|---|---|---|---|---|---|
| 1 | 13:27:51 | **3637** | 304 | 75 | 30.6 | 74% |
| 2 | 13:28:04 | 111 | 133 | 100 | 28.6 | 67% |
| 3 | 13:28:09 | 81 | 131 | 513 | 33.0 | 86% |
| 4 | 13:28:29 | 157 | 166 | 100 | 28.3 | 67% |
| 5 | 13:28:34 | 83 | 126 | **1823** | 20.1 | 45% |
| 6 | 13:30:08 | 89 | 40 | 258 | 26.2 | 60% |
| 7 | 13:30:19 | 152 | 160 | 190 | 31.3 | 79% |
| 8 | 13:30:26 | 109 | 141 | 674 | 26.5 | 60% |
| 9 | 13:30:54 | 219 | 184 | 131 | 28.8 | 70% |
| 10 | 13:31:00 | 407 | 219 | 326 | 25.3 | 56% |
| 11 | 13:31:15 | 215 | 179 | 865 | 24.6 | 58% |

11 turns · 5 260 prompt tokens prefilled · median decode 26.5 tok/s.

**What it shows.** Native OpenAI tool calling is enough for a real multi-step agent loop:
file creation, terminal work and verification all ran through `tool_calls`, with no custom
prompting or XML parsing fallback. The two behaviours beyond the literal instructions are the
interesting part — re-running the suite twice so the copied output is byte-exact, and deleting
the `__pycache__`/`.pytest_cache` directories it had itself caused to keep the "exactly three
files" constraint. The 3 637-token system prompt is the dominant prefill cost (≈12 s to first
token); KV reuse made the ten follow-up turns cheap (40–220 tok/s on their small deltas). At a
median 26.5 tok/s a turn takes 5–85 s, so a task of this size lands in the "slow but usable"
bracket rather than the interactive one.

**Caveats.** A single run of a single task, so this is an anecdote, not a pass rate. Because
the suite passed on the first attempt, the run also says nothing about how the model recovers
from failing tests: the prompt's explicit "fix the implementation, do not modify the tests"
branch was never exercised. And Cline's system prompt plus tool schemas (3 637 tokens) consume
a quarter of the 16k window before any user input arrives.

---

## 8. Limitations and next steps

* **Perf level is untested.** `sudo rocm-smi --setperflevel high` could move decode from
  860 MHz to 1700 MHz; it needs root and was not available here. This is the first thing to
  try on a machine where `sudo` works.
* **Concurrency not measured.** The server runs 4 slots (`n_slots = 4`, unified KV); all
  numbers here are single-request. Batched serving would raise aggregate prefill throughput.
* **Drafter tuning not explored.** `--spec-draft-n-max` was left at Unsloth's default 3
  (max 7); acceptance hovers at ~50%, so a larger draft may or may not pay off.
* **Vision evaluated only qualitatively** (one generated image, colour question). No OCR or
  chart benchmark.
* **No quality benchmark.** Only spot checks (`17*23`, self-description, image). A proper
  comparison of `UD-IQ3_XXS` vs `UD-Q4_K_XL` would need a task suite.
* **32k+ context is impossible** with 16 GB VRAM; the largest usable setting is 16k with the
  projector and drafter loaded, or ~20k without them (extrapolated from 128 KiB/token).
* The GPU's 95 °C junction temperature under prefill is high; the card is stable but a
  fan-curve or power cap (`--setpoweroverdrive`) may be worth setting.

---

## Appendix A — Reproduce

```bash
./scripts/merge-pins.sh                     # upstream b12588 + 30 pins (adds `inkling2`)
./scripts/build-hip-gfx906.sh gfx906 24     # HIP build for gfx906, ~5 min
./scripts/download-models.sh                # UD-IQ3_XXS + mmproj + drafter (12.7 GB)
./scripts/run-inkling.sh                    # http://127.0.0.1:8080

python3 bench/bench_server.py --label iq3_xxs_draft \
    --prompt-tokens 128,512,2048,8192 --max-tokens 128 --reps 3 --out bench/results.csv
```

Other profiles: `MODEL=UD-Q4_K_XL CPU_MOE=1`, `NCMOE=12 MODEL=UD-Q4_K_XL`, `NO_DRAFT=1`,
`CTX=8192`, `NO_MMPROJ=1`.

## Appendix B — Raw data

| Artifact | Content |
|---|---|
| `bench/results.csv` | every end-to-end request: label, prompt size, `prompt_n`, `cache_n`, TTFT, prefill/decode rates, draft acceptance, wall time |
| `BENCHMARK.md` | earlier summary of the first measurement pass |
| `README.md` | setup, deviations from the Unsloth guide, operating notes |
| `/tmp/llamabench.log` | `llama-bench` tables (baseline, context scaling, KV types, FA off) |
| `/tmp/ctxladder.log`, `/tmp/hybrid.csv` | VRAM ladder and `--n-cpu-moe` sweep |
| `/tmp/inkling.log` | per-request `slot print_timing` blocks, including the 11-turn Cline session of §7 |
| `bench/agent-test/` | the three artefacts the agent produced in that Cline run, plus `session.md` / `session.json` (the archived transcript) |
