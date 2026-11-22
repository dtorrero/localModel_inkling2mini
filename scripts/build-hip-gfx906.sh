#!/usr/bin/env bash
# Build the Unsloth llama.cpp fork (looped-layer + DSpark support) for AMD gfx906.
#
# The Unsloth prebuilt ROCm bundles ship gfx908 / gfx90a / gfx103X / gfx110X /
# gfx1150 / gfx1151 / gfx120X only -- there is no gfx906 (Vega 20 / Radeon Pro VII,
# MI50) asset, so this machine needs a local HIP build.
#
# Usage: ./scripts/build-hip-gfx906.sh [gfx_target] [jobs]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/llama.cpp"
BUILD="${SRC}/build"
GPU_TARGETS="${1:-gfx906}"
JOBS="${2:-$(nproc)}"

TAG="b12588-mix-c0c3de8"

if [[ ! -d "${SRC}/.git" ]]; then
    echo "==> cloning unslothai/llama.cpp @ ${TAG}"
    git clone --depth 1 --branch "${TAG}" https://github.com/unslothai/llama.cpp "${SRC}"
fi

echo "==> source: $(git -C "${SRC}" log --oneline -1)"
echo "==> target: ${GPU_TARGETS}   jobs: ${JOBS}"

# ROCm from the distro packages lives in /opt/rocm.
export PATH="/opt/rocm/bin:${PATH}"
export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"

if ! command -v hipcc >/dev/null 2>&1; then
    echo "error: hipcc not found (install rocm-hip-sdk / hip-runtime-amd)" >&2
    exit 1
fi

# The b<base>-mix-<hash> tag alone has no `inkling2` architecture; the pins must
# be merged first, exactly like the release CI does.
if ! grep -q 'LLM_ARCH_INKLING2' "${SRC}/src/llama-arch.h"; then
    echo "error: ${SRC} has no inkling2 support yet -- run scripts/merge-pins.sh first" >&2
    exit 1
fi

# LLAMA_USE_PREBUILT_UI=OFF: this tag derives the HF UI asset version from
# LLAMA_BUILD_NUMBER (=> "b1", which does not exist in the ggml-org/llama-ui
# bucket) and the "latest" fallback fails asset validation. We only need the
# OpenAI-compatible HTTP API, so llama-server is built with an empty UI table.
cmake -S "${SRC}" -B "${BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_HIP=ON \
    -DGPU_TARGETS="${GPU_TARGETS}" \
    -DLLAMA_CURL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF

cmake --build "${BUILD}" --target \
    llama-server llama-cli llama-bench llama-mtmd-cli \
    -j "${JOBS}"

echo
echo "==> build finished"
"${BUILD}/bin/llama-server" --version
