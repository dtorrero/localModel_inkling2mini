#!/usr/bin/env bash
# Reproduce the "mix" build the Unsloth CI ships.
#
# The published prebuilt for tag b<base>-mix-<hash> is NOT that tag's tree.
# .github/workflows/unsloth-prebuilt.yml fetches the *upstream ggml-org* tag
# (here b12588), checks it out, and then `git merge`s every pinned PR commit
# listed in scripts/unsloth/pr-set.json, in file order, falling back to
# scripts/unsloth/additive_merge.py when two pins merely append to the same
# table (keep both).
#
# Unsloth's own tag tree is pruned (vendor blobs, examples) and merging the
# pins onto it conflicts everywhere; the base must be the upstream tag.
#
# Without this step the build has no `inkling2` architecture and llama-server
# dies with "unknown model architecture: 'inkling2'".
#
# Usage: ./scripts/merge-pins.sh [repo_dir] [base_tag]
#   repo_dir  default ./llama.cpp
#   base_tag  default b12588 (must match the -mix- tag you cloned)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${ROOT}/llama.cpp}"
BASE_TAG="${2:-b12588}"

# Saved before the checkout: the upstream tag does not carry these files.
PINSET="${ROOT}/scripts/pr-set.${BASE_TAG}.json"
ADDITIVE_MERGE="${ROOT}/scripts/additive_merge.py"

[[ -f "${PINSET}" ]] || { echo "missing pin set: ${PINSET}" >&2; exit 1; }
[[ -f "${ADDITIVE_MERGE}" ]] || { echo "missing ${ADDITIVE_MERGE}" >&2; exit 1; }

cd "${SRC}"

git config user.name  "local-mix-build"
git config user.email "local-mix-build@localhost"

echo "==> fetching upstream ${BASE_TAG} from ggml-org/llama.cpp"
git fetch -q --no-tags https://github.com/ggml-org/llama.cpp \
    "refs/tags/${BASE_TAG}:refs/tags/base-${BASE_TAG}"

git checkout -q --detach "refs/tags/base-${BASE_TAG}"
echo "==> base: $(git rev-parse --short HEAD) (${BASE_TAG})"

mapfile -t PINS < <(python3 - "${PINSET}" <<'EOF'
import json, sys
for p in json.load(open(sys.argv[1]))["prs"]:
    print(p if isinstance(p, str) else p["url"])
EOF
)

TOTAL=${#PINS[@]}
i=0

for url in "${PINS[@]}"; do
    i=$((i + 1))
    src="$(sed -E 's#https://github.com/([^/]+)/llama\.cpp/pull/.*#\1#' <<<"${url}")"
    num="$(sed -E 's#.*/pull/([0-9]+)/commits/.*#\1#' <<<"${url}")"
    sha="$(sed -E 's#.*/commits/([0-9a-f]{40}).*#\1#' <<<"${url}")"

    if ! git rev-parse --verify -q "${sha}^{commit}" >/dev/null; then
        git fetch -q --no-tags "https://github.com/${src}/llama.cpp.git" "${sha}" 2>/dev/null \
            || git fetch -q --no-tags origin "refs/pins/${sha}" 2>/dev/null \
            || { echo "FAILED to fetch ${src}#${num} (${sha})" >&2; exit 1; }
    fi

    if git -c merge.conflictStyle=diff3 merge --no-ff --no-edit \
            -m "Merge ${src}#${num} @ ${sha}" "${sha}" >/dev/null 2>&1; then
        echo "[${i}/${TOTAL}] ${src}#${num}"
        continue
    fi

    echo "[${i}/${TOTAL}] ${src}#${num} conflicted -> additive_merge.py"
    if python3 "${ADDITIVE_MERGE}" \
        && [[ -z "$(git diff --name-only --diff-filter=U)" ]]; then
        git commit -q --no-edit
        echo "         resolved (both sides kept)"
    else
        git merge --abort 2>/dev/null || true
        echo "FAILED ${src}#${num} does not merge cleanly; see pin order in pr-set" >&2
        exit 1
    fi
done

echo "ALL_PINS_MERGED $(git rev-parse --short HEAD)"
echo -n "inkling2 arch registered: "
grep -c 'LLM_ARCH_INKLING2' src/llama-arch.h
echo -n "dspark speculative type: "
grep -c 'draft-dspark' common/speculative.cpp
