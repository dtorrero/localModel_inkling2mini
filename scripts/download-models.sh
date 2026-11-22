#!/usr/bin/env bash
# Download the Inkling 2 Mini GGUF files used by run-inkling.sh.
#
# Default profile: UD-IQ3_XXS (11.66 GB) -- fits fully in the 16 GB HBM2 of a
# Radeon Pro VII, see README.md.
#
# Usage:
#   ./scripts/download-models.sh                 # IQ3_XXS + vision + DSpark drafter
#   ./scripts/download-models.sh UD-Q4_K_XL      # guide's default quant (17.63 GB)
#   ./scripts/download-models.sh UD-Q4_K_XL UD-IQ3_XXS

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/models/Inkling-2-Mini-GGUF"
REPO="unsloth/Inkling-2-Mini-GGUF"

# Always fetched: vision projector + DSpark speculative drafter.
FILES=(mmproj-F16.gguf dspark-Inkling-2-Mini-Q8_0.gguf)

# Quants requested on the command line, IQ3_XXS by default.
if [[ $# -eq 0 ]]; then
    QUANTS=(UD-IQ3_XXS)
else
    QUANTS=("$@")
fi

for q in "${QUANTS[@]}"; do
    FILES+=("Inkling-2-Mini-${q}.gguf")
done

mkdir -p "${DEST}"

echo "==> downloading into ${DEST}"
echo "    ${FILES[*]}"
hf download "${REPO}" "${FILES[@]}" --local-dir "${DEST}"

echo
echo "==> local files"
for f in "${FILES[@]}"; do
    if [[ -f "${DEST}/${f}" ]]; then
        printf '  %-45s %s\n' "${f}" "$(du -h "${DEST}/${f}" | cut -f1)"
    else
        printf '  %-45s MISSING\n' "${f}"
        exit 1
    fi
done

echo
echo "==> expected sizes (bytes)"
echo "    UD-IQ3_XXS                         11663309504"
echo "    UD-Q4_K_XL                         17629759456"
echo "    mmproj-F16.gguf                      639348160"
echo "    dspark-Inkling-2-Mini-Q8_0.gguf      402278560"
