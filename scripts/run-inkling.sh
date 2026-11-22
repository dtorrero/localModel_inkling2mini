#!/usr/bin/env bash
# Serve Inkling 2 Mini (Inkling-2-Mini-GGUF) with llama.cpp on AMD gfx906.
#
# Defaults target a 16 GB Radeon Pro VII: the UD-IQ3_XXS quant (11.65 GB of
# weights, 10.30 GB of that is routed experts) is kept fully on the GPU.
#
# Everything can be overridden with environment variables:
#
#   MODEL=UD-Q4_K_XL   ./scripts/run-inkling.sh        # 17.63 GB quant
#   CTX=8192           ./scripts/run-inkling.sh        # smaller KV cache
#   NO_MMPROJ=1        ./scripts/run-inkling.sh        # text only (saves ~0.6 GiB)
#   NO_DRAFT=1         ./scripts/run-inkling.sh        # no DSpark speculative decoding
#   CPU_MOE=1          ./scripts/run-inkling.sh        # keep all experts in system RAM
#   NCMOE=8            ./scripts/run-inkling.sh        # keep 8 layers of experts in RAM
#   CTK=q8_0 CTV=q8_0  ./scripts/run-inkling.sh        # (default) quantized KV cache
#   HOST=0.0.0.0 PORT=8080 ./scripts/run-inkling.sh    # serve on the LAN
#   NGL=99 CTX=32768   ./scripts/run-inkling.sh        # if VRAM allows

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${MODEL_DIR:-${ROOT}/models/Inkling-2-Mini-GGUF}"
MODEL="${MODEL:-UD-IQ3_XXS}"

# Prefer the locally built HIP binary, fall back to a Vulkan build if present.
if [[ -x "${ROOT}/llama.cpp/build/bin/llama-server" ]]; then
    SERVER="${ROOT}/llama.cpp/build/bin/llama-server"
elif [[ -x "${ROOT}/llama-vulkan/llama-server" ]]; then
    SERVER="${ROOT}/llama-vulkan/llama-server"
elif [[ -x /usr/bin/llama-server ]]; then
    SERVER="/usr/bin/llama-server"
else
    echo "error: no llama-server found (run scripts/build-hip-gfx906.sh)" >&2
    exit 1
fi

CTX="${CTX:-16384}"
NGL="${NGL:-99}"
CTK="${CTK:-q8_0}"
CTV="${CTV:-q8_0}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"

MAIN="${MODEL_DIR}/Inkling-2-Mini-${MODEL}.gguf"
if [[ ! -f "${MAIN}" ]]; then
    echo "error: ${MAIN} not found (run scripts/download-models.sh ${MODEL})" >&2
    exit 1
fi

ARGS=(
    --model "${MAIN}"
    --n-gpu-layers "${NGL}"
    --ctx-size "${CTX}"
    --flash-attn on
    --cache-type-k "${CTK}"
    --cache-type-v "${CTV}"
    # Recommended sampling for Inkling 2 Mini
    --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.0
    --host "${HOST}"
    --port "${PORT}"
)

# Vision projector (~0.6 GiB VRAM). Disable with NO_MMPROJ=1.
if [[ "${NO_MMPROJ:-0}" != "1" && -f "${MODEL_DIR}/mmproj-F16.gguf" ]]; then
    ARGS+=(--mmproj "${MODEL_DIR}/mmproj-F16.gguf")
fi

# DSpark block drafter (repo root file). ~0.4 GiB VRAM.
# Note: never pin it to a device with -devd, it borrows the target embeddings.
if [[ "${NO_DRAFT:-0}" != "1" && -f "${MODEL_DIR}/dspark-Inkling-2-Mini-Q8_0.gguf" ]]; then
    ARGS+=(
        -md "${MODEL_DIR}/dspark-Inkling-2-Mini-Q8_0.gguf"
        --spec-type draft-dspark
        --spec-draft-n-max 3
        -ngld 99
    )
fi

# Expert placement. Options only make sense when the quant does not fit in VRAM.
if [[ -n "${NCMOE:-}" ]]; then
    ARGS+=(--n-cpu-moe "${NCMOE}")
elif [[ "${CPU_MOE:-0}" == "1" ]]; then
    ARGS+=(--cpu-moe)
fi

echo "==> ${SERVER}"
echo "==> model: ${MAIN}"
echo "==> ctx ${CTX}, ngl ${NGL}, kv ${CTK}/${CTV}, http://${HOST}:${PORT}"
echo

exec "${SERVER}" "${ARGS[@]}"
