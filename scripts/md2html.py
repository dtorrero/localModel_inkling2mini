#!/usr/bin/env python3
"""Render REPORT.md (or any Markdown file) to a print-ready HTML document.

Kept separate from the PDF step so the HTML can be inspected or re-rendered with
any engine (Brave/Chromium headless, wkhtmltopdf). Print CSS is embedded, so the
output is self-contained.

Usage: python3 scripts/md2html.py REPORT.md build/REPORT.html
"""

from __future__ import annotations

import sys
from pathlib import Path

import markdown

CSS = """
@page {
  size: A4;
  margin: 15mm 13mm 16mm 13mm;
  @bottom-left {
    content: "Inkling 2 Mini on a Radeon Pro VII — build & benchmark report";
    font-family: "DejaVu Sans", sans-serif;
    font-size: 6.8pt;
    color: #7a8794;
  }
  @bottom-right {
    content: "page " counter(page) " / " counter(pages);
    font-family: "DejaVu Sans", sans-serif;
    font-size: 6.8pt;
    color: #7a8794;
  }
}

html { background: #ffffff; }

body {
  font-family: "DejaVu Sans", "Noto Sans", sans-serif;
  font-size: 9.6pt;
  line-height: 1.42;
  color: #1b1b1b;
  margin: 0;
}

h1 {
  font-size: 19pt;
  line-height: 1.2;
  margin: 0 0 4pt 0;
  padding-bottom: 6pt;
  border-bottom: 2pt solid #2a4d69;
  color: #16324a;
}
h1 + p { color: #555; font-size: 9pt; margin-top: 4pt; }

h2 {
  font-size: 13.5pt;
  margin: 16pt 0 5pt 0;
  padding-bottom: 2pt;
  border-bottom: 0.8pt solid #c9d3dc;
  color: #16324a;
  page-break-after: avoid;
}
h3 {
  font-size: 11pt;
  margin: 11pt 0 3pt 0;
  color: #254a68;
  page-break-after: avoid;
}

p { margin: 0 0 5pt 0; }
a { color: #1f5d8b; text-decoration: none; }

ul, ol { margin: 2pt 0 6pt 0; padding-left: 16pt; }
li { margin: 0 0 2.5pt 0; }

strong { color: #111; }

hr {
  border: 0;
  border-top: 0.8pt solid #d5dde4;
  margin: 12pt 0;
}

blockquote {
  margin: 8pt 0;
  padding: 5pt 9pt;
  border-left: 2.5pt solid #7fa8c9;
  background: #f3f7fa;
  color: #334;
}
blockquote p { margin: 0; }

table {
  width: 100%;
  border-collapse: collapse;
  margin: 6pt 0 9pt 0;
  font-size: 8.3pt;
  table-layout: auto;
}
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
th, td {
  border: 0.5pt solid #b9c4cd;
  padding: 2.6pt 4pt;
  vertical-align: top;
  text-align: left;
  word-wrap: break-word;
  overflow-wrap: break-word;
}
th { background: #e8eef4; font-weight: bold; color: #16324a; }
tbody tr:nth-child(even) td { background: #f8fafc; }

code {
  font-family: "DejaVu Sans Mono", monospace;
  font-size: 8.3pt;
  background: #f1f3f5;
  border: 0.4pt solid #e0e4e8;
  border-radius: 2pt;
  padding: 0 1.5pt;
}
pre {
  background: #f6f8fa;
  border: 0.5pt solid #dde3e8;
  border-radius: 2pt;
  padding: 5pt 7pt;
  margin: 6pt 0 8pt 0;
  white-space: pre-wrap;
  word-wrap: break-word;
  page-break-inside: avoid;
}
pre code {
  background: none;
  border: 0;
  padding: 0;
  font-size: 8.2pt;
  line-height: 1.35;
}
"""

TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<style>{css}</style>
</head>
<body>
{body}
</body>
</html>
"""


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    text = src.read_text(encoding="utf-8")

    title = "Report"
    for line in text.splitlines():
        if line.startswith("# "):
            title = line[2:].strip()
            break

    body = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list", "md_in_html"],
        output_format="html5",
    )

    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(TEMPLATE.format(title=title, css=CSS, body=body), encoding="utf-8")
    print(dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
