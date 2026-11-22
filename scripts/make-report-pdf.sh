#!/usr/bin/env bash
# Render a Markdown report to A4 PDF (with page numbers).
#
# Markdown -> self-contained HTML (scripts/md2html.py, print CSS embedded)
# then HTML -> PDF. The CSS uses @page margin boxes, so the renderer must
# support them:
#
#   weasyprint     : default. 100% CSS, real page counters, ~2 s. Install once:
#                    pip install --user --break-system-packages weasyprint
#                    (needs system pango/cairo, already present on a GTK desktop)
#   libreoffice    : fallback. Writer/Web drops some CSS, no page numbers.
#   firefox        : fallback. Headless print, no page numbers; can hang on
#                    large documents, so it is only tried last.
#
# Not usable on this machine (checked 2026-11-22): brave/chromium headless
# `--print-to-pdf` never writes a file, wkhtmltopdf 0.12.6 (Qt5) exits 0 with no
# output and aborts under Xvfb.
#
# Usage: ./scripts/make-report-pdf.sh [input.md] [output.pdf]
#        ./scripts/make-report-pdf.sh              # REPORT.md -> REPORT.pdf
#        PDF_RENDERER=libreoffice ./scripts/make-report-pdf.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${ROOT}/REPORT.md}"
OUT="${2:-${SRC%.md}.pdf}"
RENDERER="${PDF_RENDERER:-auto}"
OUT="$(realpath -m "${OUT}")"

[[ -f "${SRC}" ]] || { echo "error: ${SRC} not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
HTML="${WORK}/report.html"

python3 "${ROOT}/scripts/md2html.py" "${SRC}" "${HTML}" >/dev/null
echo "==> HTML: $(du -h "${HTML}" | cut -f1)"

render_weasyprint() {
    python3 -c 'import weasyprint' >/dev/null 2>&1 || return 1
    command -v weasyprint >/dev/null 2>&1 || return 1
    rm -f "${OUT}"
    weasyprint "${HTML}" "${OUT}" 2>/dev/null
    [[ -s "${OUT}" ]]
}

render_libreoffice() {
    command -v soffice >/dev/null 2>&1 || return 1
    rm -f "${OUT}"
    local stage="${WORK}/lo"
    mkdir -p "${stage}"
    cp "${HTML}" "${stage}/report.html"
    timeout 120 soffice --headless -env:UserInstallation="file://${WORK}/loprofile" \
        --convert-to pdf --outdir "${stage}" "${stage}/report.html" >/dev/null 2>&1
    [[ -f "${stage}/report.pdf" ]] && mv -f "${stage}/report.pdf" "${OUT}"
    [[ -s "${OUT}" ]]
}

render_firefox() {
    command -v firefox >/dev/null 2>&1 || return 1
    rm -f "${OUT}"
    mkdir -p "${WORK}/ff"
    MOZ_HEADLESS=1 timeout 120 firefox --headless --no-remote \
        --profile "${WORK}/ff" --print-to-pdf="${OUT}" "file://${HTML}" >/dev/null 2>&1
    [[ -s "${OUT}" ]]
}

try() {
    case "$1" in
        weasyprint)  render_weasyprint  ;;
        libreoffice) render_libreoffice ;;
        firefox)     render_firefox     ;;
        *) return 1 ;;
    esac
}

if [[ "${RENDERER}" == "auto" ]]; then
    for r in weasyprint libreoffice firefox; do
        if try "${r}"; then
            echo "==> rendered with ${r}"
            break
        fi
        echo "warning: ${r} did not produce a PDF, trying next renderer" >&2
    done
else
    try "${RENDERER}" || { echo "error: ${RENDERER} did not produce a PDF" >&2; exit 1; }
    echo "==> rendered with ${RENDERER}"
fi

[[ -s "${OUT}" ]] || { echo "error: PDF was not produced" >&2; exit 1; }

echo "==> ${OUT}"
if command -v pdfinfo >/dev/null 2>&1; then
    pdfinfo "${OUT}" | grep -E '^(Title|Pages|Page size|File size|PDF version)'
fi
