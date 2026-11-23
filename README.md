# Inkling 2 Mini on a Radeon Pro VII (gfx906) with llama.cpp

Local setup for [Inkling 2 Mini](https://huggingface.co/unsloth/Inkling-2-Mini-GGUF)
(Thinking Machines Lab, 26.4 B MoE / 5.4 B active, 1 M context, vision) on this
machine, following the [Unsloth run guide](https://unsloth.ai/docs/models/inkling-2-mini)
with the deviations the hardware forces.

## This machine

| | |
|---|---|
| GPU | AMD Radeon Pro VII (Vega 20), **gfx906**, 16 GiB HBM2 |
| ROCm | 7.2.4 in `/opt/rocm` (rocBLAS ships gfx906 kernels, hipcc/clang 22 targets gfx906) |
| CPU / RAM | Xeon E5-2690 v4 (14c/28t) / 62 GB, no swap |
| Vulkan | RADV (Mesa 26.2.4) on `AMD Radeon Pro VII (RADV VEGA20)` |

## Why this is not a copy-paste of the guide

* **No gfx906 prebuilt.** The Unsloth ROCm assets cover `gfx908`, `gfx90a`,
  `gfx103X`, `gfx110X`, `gfx1150`, `gfx1151`, `gfx120X`. The guide's AMD command
  pulls `...-rocm-gfx120X.tar.gz` (RDNA4) and cannot run here, so llama.cpp is
  built from source for `gfx906`.
* **Model needs the Unsloth fork.** `general.architecture = inkling2` with
  looped layers and per-expert NVFP4-style scales; upstream llama.cpp in the
  distro (`llama.cpp-hip-mtp` b9117) does not know the architecture nor the
  `draft-dspark` speculative type. Everything here uses tag
  `b12588-mix-c0c3de8` of `unslothai/llama.cpp`.
* **VRAM budget.** Measured straight from the GGUF tensor table:

  | Quant | File | Routed experts | Everything else |
  |---|---|---|---|
  | `UD-IQ3_XXS` | 11.66 GB | 10.30 GB | 1.35 GB |
  | `UD-Q4_K_XL`  | 17.63 GB | 15.80 GB | 1.82 GB |

  With ~1.5 GiB already used by the desktop, only ~14.5 GiB is free, so
  `UD-Q4_K_XL` **cannot** be fully offloaded. The default profile therefore uses
  `UD-IQ3_XXS`, which fits completely on the GPU (KLD 0.027 vs 0.011 for
  `UD-Q4_K_XL`, i.e. a small quality trade for a large speed gain).

## Files

```
llama.cpp/                     # unsloth fork @ b12588-mix-c0c3de8 + merged pins, HIP build in llama.cpp/build
models/Inkling-2-Mini-GGUF/    # UD-IQ3_XXS + UD-Q4_K_XL + mmproj-F16 + dspark drafter (29 GB)
scripts/merge-pins.sh          # merges the pinned PR commits (this is what enables `inkling2`)
scripts/pr-set.b12588.json     # the pin list, saved from the tag before checking out upstream
scripts/additive_merge.py      # the fork's add/add conflict resolver used by merge-pins.sh
scripts/build-hip-gfx906.sh    # cmake -DGGML_HIP=ON -DGPU_TARGETS=gfx906
scripts/download-models.sh     # hf download + size sanity check
scripts/run-inkling.sh         # launcher with env knobs
scripts/make-report-pdf.sh    # REPORT.md -> REPORT.pdf (WeasyPrint, A4 + page numbers)
scripts/md2html.py             # Markdown -> print-ready HTML (used by the PDF script)
bench/bench_server.py          # end-to-end benchmark harness (writes bench/results.csv)
bench/agent-test/              # the three files a Cline agent task produced (REPORT.md §7)
REPORT.md                      # hardware/software/build/benchmark report
REPORT.pdf                     # rendered report (6 pages, A4)
BENCHMARK.md                   # first measurement pass (superseded by REPORT.md)
```

> **Do not skip `merge-pins.sh`.** The `b<base>-mix-<hash>` tag is only the
> upstream base tree plus the pin list. The released binaries are built by
> merging all 30 pinned PR commits (`scripts/unsloth/pr-set.json`) on top of
> it. Building the bare tag produces a binary that fails with
> `unknown model architecture: 'inkling2'`.
>
> `llama.cpp/` is therefore left on a **detached HEAD** at the merged commit
> (currently `8094ad12f`, "base b12588 + 30 pins"). Re-running `merge-pins.sh`
> resets to the upstream tag and re-applies the pins.

## Usage

```bash
./scripts/merge-pins.sh                     # once: applies the 30 pinned PRs
./scripts/build-hip-gfx906.sh gfx906 24     # once, ~20-40 min
./scripts/download-models.sh                # UD-IQ3_XXS + vision + drafter (12.7 GB)
./scripts/run-inkling.sh                    # http://127.0.0.1:8080
```

Default launch (all of it in VRAM):

```bash
llama-server \
  -m models/Inkling-2-Mini-GGUF/Inkling-2-Mini-UD-IQ3_XXS.gguf \
  --mmproj models/Inkling-2-Mini-GGUF/mmproj-F16.gguf \
  -md models/Inkling-2-Mini-GGUF/dspark-Inkling-2-Mini-Q8_0.gguf \
  --spec-type draft-dspark --spec-draft-n-max 3 -ngld 99 \
  -ngl 99 -c 16384 -fa on -ctk q8_0 -ctv q8_0 \
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0 \
  --host 127.0.0.1 --port 8080
```

### Knobs (`scripts/run-inkling.sh`)

| Variable | Default | Meaning |
|---|---|---|
| `MODEL` | `UD-IQ3_XXS` | quant to load (must be downloaded first) |
| `CTX` | `16384` | context size — **always set it**, the model's native value is 1 M and would OOM |
| `NGL` | `99` | layers on GPU |
| `CTK` / `CTV` | `q8_0` | KV cache types (halves KV VRAM; use `f16` if you have headroom) |
| `NO_MMPROJ=1` | off | skip the 0.6 GiB vision projector |
| `NO_DRAFT=1` | off | skip DSpark speculative decoding |
| `NCMOE=N` | unset | keep experts of `N` layers in system RAM (`--n-cpu-moe`) |
| `CPU_MOE=1` | off | keep **all** experts in RAM (`--cpu-moe`) — for `UD-Q4_K_XL` |
| `HOST` / `PORT` | `127.0.0.1` / `8080` | bind address |

Running the guide's default quant instead:

```bash
./scripts/download-models.sh UD-Q4_K_XL
CPU_MOE=1 MODEL=UD-Q4_K_XL ./scripts/run-inkling.sh     # ~5-10 tok/s, 15.8 GB of experts in RAM
# or partially on the GPU: NCMOE=8 MODEL=UD-Q4_K_XL ./scripts/run-inkling.sh
```

Smoke test once it is listening:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"What is 17*23?"}],"max_tokens":600}' \
  | python3 -m json.tool | head -20
```

## Sampling

Temperature `1.0`, top-p `1.0`, top-k `0`, min-p `0.0` (as recommended by
Unsloth). The DSpark drafter caps `--spec-draft-n-max` at 7 (trained block size
8); never pin it with `-devd`, it borrows the target model's embeddings and
output head.

## Troubleshooting

* **`hipErrorNoBinaryForGpu` / "no kernel image"** — a prebuilt gfx120X/gfx103X
  binary was used; rebuild with `-DGPU_TARGETS=gfx906`.
* **OOM at load** — step down in this order: `CTX=8192`, then `NO_MMPROJ=1`, then
  `NCMOE=2`, then `NCMOE=8`.
* **`-fa on` issues on GCN** — try `-fa off`; on Vega the tile kernels fall back
  to a slower generic path.
* **Free desktop VRAM first.** The compositor/browser can hold >1.5 GiB; with
  `UD-IQ3_XXS` fully offloaded that headroom matters.

## Results

Full write-up in [`REPORT.md`](REPORT.md) (hardware and its age, software, build, method,
results, analysis); raw rows in `bench/results.csv`. Headline numbers on this box:

* `UD-IQ3_XXS` fully on GPU: **~282–312 tok/s prefill**, **~24–27 tok/s decode** at 16k
  context (llama-bench: pp512 **396 tok/s** with q8_0 KV, tg128 **28.5 tok/s**);
* `UD-Q4_K_XL` cannot fit: `CPU_MOE=1` gives **91–108 tok/s prefill / 7.5–11 tok/s decode**,
  `NCMOE=12` gives **133 / 13.4**;
* VRAM: **16.79 GB** at `CTX=16384`, 15.78 GB at 8192; **32k OOMs**;
* DSpark is roughly neutral at ~50% acceptance (+7% at 512 tokens, −4% at 2048);
* vision verified through `mmproj-F16.gguf` (62 tok/s prefill for a 128×128 image);
* the model is a reasoning model — answers land in `reasoning_content` first and in
  `content` once it stops thinking, so allow enough `max_tokens`;
* an agentic coding task through Cline (write code → run pytest → write notes)
  completed all five steps in 3 min 55 s on the first try — `REPORT.md` §7 has the
  per-turn token cost, and the transcript is archived under `bench/agent-test/`.

## Operating notes

* Stop the server with `pkill -x llama-server` (`pkill -f llama-server` also
  matches the shell that runs it).
* Detach it with `setsid nohup ./scripts/run-inkling.sh >/tmp/inkling.log 2>&1 &`.
* The launcher refuses to start while another `llama-server` is running
  (a second copy starves the first of VRAM): stop it with `pkill -x llama-server`,
  or pass `FORCE=1`.
* The embedded web UI is intentionally disabled (`-DLLAMA_USE_PREBUILT_UI=OFF`):
  this tag derives the HF asset version from `LLAMA_BUILD_NUMBER` (= `b1`, which
  does not exist) and the `latest` fallback fails validation. Use any
  OpenAI-compatible client against `http://127.0.0.1:8080`.
* Rebuild the PDF with `./scripts/make-report-pdf.sh` (WeasyPrint; install once
  with `pip install --user --break-system-packages weasyprint`).
