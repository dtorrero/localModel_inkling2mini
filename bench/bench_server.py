#!/usr/bin/env python3
"""End-to-end benchmark harness for the local Inkling 2 Mini llama-server.

Measures what a user actually feels: time to first token (TTFT), prefill
throughput and decode throughput, for several prompt sizes, and writes one CSV
row per request (medians are printed as a Markdown table).

Prompt caching is disabled per request (``cache_prompt: false``) and every
request carries a unique nonce, otherwise llama-server would answer later
repetitions straight from the KV cache and report a tiny ``prompt_n``.

Usage:
    python3 bench/bench_server.py --label iq3_xxs_draft \
        --prompt-tokens 128,512,2048,8192 --max-tokens 128 --reps 3 \
        --out bench/results.csv
    python3 bench/bench_server.py --label vision --vision --reps 3 \
        --out bench/results.csv
"""

from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import os
import statistics
import urllib.request
import uuid

# Recommended sampling for Inkling 2 Mini (Unsloth guide).
SAMPLING = {"temperature": 1.0, "top_p": 1.0, "top_k": 0, "min_p": 0.0}

FILLER = (
    "The quick brown fox jumps over the lazy dog while the calibration "
    "subroutine logs every sensor reading to the local ring buffer. "
)


def filler(target_tokens: int) -> str:
    # ~4 characters per token for English text.
    return FILLER * max(1, int(target_tokens * 4 / len(FILLER)))


def post(url: str, payload: dict, timeout: float = 3600.0) -> dict:
    req = urllib.request.Request(
        url + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def chat(url, content, max_tokens, cache_prompt=False):
    payload = {
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "cache_prompt": cache_prompt,
        **SAMPLING,
    }
    return post(url, payload)


def red_square_data_uri(size: int = 128) -> str:
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (size, size), (220, 30, 30)).save(buf, format="PNG")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


def vision_request(url, max_tokens=64):
    payload = {
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "What colour is this image? Answer with one word."},
                {"type": "image_url", "image_url": {"url": red_square_data_uri()}},
            ],
        }],
        "max_tokens": max_tokens,
        "cache_prompt": False,
        **SAMPLING,
    }
    return post(url, payload)



def measure(label, url, target_tokens, max_tokens, reps, vision=False):
    rows = []
    for i in range(reps):
        if vision:
            resp = vision_request(url, max_tokens)
        else:
            nonce = uuid.uuid4().hex[:8]
            text = f"[session {nonce}]\n{filler(target_tokens)}\nSummarise the passage above in one sentence."
            resp = chat(url, text, max_tokens)
        t = resp["timings"]
        row = {
            "label": label,
            "target_prompt_tokens": target_tokens,
            "rep": i + 1,
            "prompt_n": t["prompt_n"],
            "cache_n": t["cache_n"],
            "prompt_ms": round(t["prompt_ms"], 1),
            "ttft_ms": round(t["prompt_ms"] + t["predicted_per_token_ms"], 1),
            "prefill_tps": round(t["prompt_per_second"], 1),
            "decode_tps": round(t["predicted_per_second"], 1),
            "predicted_n": t["predicted_n"],
            "draft_accepted": t.get("draft_n_accepted", 0),
            "draft_n": t.get("draft_n", 0),
            "wall_s": round(t["prompt_ms"] / 1000.0 + t["predicted_ms"] / 1000.0, 2),
            "vision": int(vision),
        }
        rows.append(row)
        print(json.dumps(row), flush=True)
    return rows


def summarize(rows):
    out = []
    groups = []
    for r in rows:
        key = (r["label"], r["target_prompt_tokens"])
        if key not in groups:
            groups.append(key)
    for label, size in groups:
        group = [r for r in rows
                 if r["label"] == label and r["target_prompt_tokens"] == size]

        def med(k):
            return round(statistics.median([r[k] for r in group]), 1)

        accepted = sum(r["draft_accepted"] for r in group)
        drafted = sum(r["draft_n"] for r in group)
        out.append({
            "label": label,
            "target_prompt_tokens": size,
            "prompt_n": med("prompt_n"),
            "ttft_ms": med("ttft_ms"),
            "prefill_tps": med("prefill_tps"),
            "decode_tps": med("decode_tps"),
            "draft_accept_pct": round(100.0 * accepted / max(1, drafted), 1),
            "reps": len(group),
        })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--label", required=True, help="configuration label, e.g. iq3_xxs_draft")
    ap.add_argument("--prompt-tokens", default="128,512,2048")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--vision", action="store_true", help="run the image test instead of text")
    ap.add_argument("--warmup", type=int, default=1, help="discarded warm-up requests per size")
    ap.add_argument("--out", default="bench/results.csv")
    args = ap.parse_args()

    sizes = [0] if args.vision else [int(s) for s in args.prompt_tokens.split(",") if s.strip()]

    all_rows = []
    for size in sizes:
        for _ in range(args.warmup):
            if args.vision:
                vision_request(args.url, args.max_tokens)
            else:
                chat(args.url, f"[warmup {uuid.uuid4().hex[:8]}]\n{filler(size)}",
                     args.max_tokens, False)
        all_rows += measure(args.label, args.url, size, args.max_tokens, args.reps, args.vision)

    headers = list(all_rows[0].keys())
    write_header = not os.path.exists(args.out) or os.path.getsize(args.out) == 0
    with open(args.out, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=headers)
        if write_header:
            w.writeheader()
        w.writerows(all_rows)

    print("\n### summary: %s\n" % args.label)
    print("| config | prompt tok (actual) | TTFT ms | prefill tok/s | decode tok/s | draft accept | reps |")
    print("|---|---|---|---|---|---|---|")
    for s in summarize(all_rows):
        print("| {label} | {prompt_n:.0f} | {ttft_ms:.0f} | {prefill_tps:.1f} | "
              "{decode_tps:.1f} | {draft_accept_pct:.0f}% | {reps} |".format(**s))


if __name__ == "__main__":
    main()
