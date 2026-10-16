#!/usr/bin/env python3
"""
Structured micro-summary: does forcing a KEY:VALUE block recover what free-text loses?

The review's fifth recommendation, and the one that turns a measurement into design
guidance. We know from §4.2 that a summary drops the pairing between an item and its
value while keeping the item's name, and from the conservative-compaction arm that
preserving the pairing is what makes an answer findable. This asks the practical
follow-up: **if the summariser is required to emit a machine-parsable
`ref -> value` block alongside its prose, does retention recover?**

Design. Three summary variants over the same windows:

  free-text      the deployment's own prompt, as it runs today (control)
  structured     same content, plus a requirement to end with lines `REF: VALUE`
  structured+    structured, and the emitted block is what the reader is given
                 (i.e. the block is treated as the answer surface)

The third variant is the interesting one: it separates "the model *can* preserve
the pairing when asked" from "the reader can *use* it". Reporting only the second
would conflate the two.

Cost is also reported, because a mitigation that costs a lot of tokens is a
mitigation nobody adopts — the review asked for exactly this trade-off.

Runs against the bench instance, using its own summariser. Read-only against
production.

Usage:
    python3 structured_summary.py --out results/retention/structured-summary.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from backends import day_ms, day_window_start, JOB_ID_RE, est_tokens   # noqa: E402
from drift_eval import rpc                                            # noqa: E402
from run_eval import extract_answer                                   # noqa: E402

BENCH = "http://127.0.0.1:18900/mcp"
BTYPE = "bench/structured"

# The instruction that asks for the block. Kept explicit and small: the point is
# to measure the effect of *asking*, not to engineer the best possible prompt.
STRUCTURED_INSTRUCTION = (
    "After the usual prose sections, append a final section titled 键值对 containing "
    "one line per decision in exactly this form: `REF: VALUE`, where REF is the "
    "reference token (e.g. ZR01) and VALUE is the single option letter chosen. "
    "Do not paraphrase the tokens or the letters."
)


def wait(url: str, jid: int, timeout: int = 300) -> str:
    end = time.time() + timeout
    while time.time() < end:
        t = rpc(url, "mem/summarize_status", {"job_id": jid})
        if "done" in t or "failed" in t:
            return t
        time.sleep(2)
    return "timeout"


def summarize(url: str, anchor: int, instruction: str | None) -> str:
    args = {"type": BTYPE, "granularity": "day", "windowStartMs": anchor,
            "recompute": True}
    if instruction:
        args["instructions"] = instruction
    m = JOB_ID_RE.search(rpc(url, "mem/summarize", args))
    if m:
        wait(url, int(m.group(1)))
    raw = rpc(url, "mem/recall", {"type": BTYPE, "granularity": "day",
                                  "mode": "summary", "windowStartMs": anchor})
    blocks = [b for b in re.split(r"(?=【)", raw.strip()) if b.strip()]
    return blocks[0] if blocks else raw      # newest first


KV_LINE = re.compile(r"(Z[A-Z]\d{2})\s*[:=]\s*([A-D])")


def kv_block(text: str) -> dict[str, str]:
    return {m.group(1).upper(): m.group(2).upper() for m in KV_LINE.finditer(text)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default=BENCH)
    ap.add_argument("--days", type=int, default=6, help="how many day windows")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    trace = json.load(open(os.path.join(HERE, ".work", "trace-ref.json"),
                           encoding="utf-8"))
    days = sorted({e["day"] for e in trace["events"]})[: a.days]
    # A probe asks about an earlier day than the one it is asked on, so filtering
    # by `day_asked <= last_ingested_day` throws almost all of them away on a
    # short run (measured: 1 probe at --days 2). Filter by the day the FACT lives
    # on instead, which is what has to be summarized for the probe to be
    # answerable at all.
    def fact_day(p: dict) -> int | None:
        m = re.search(r"on day (\d+)", p["question"])
        return int(m.group(1)) if m else None
    probes = [p for p in trace["probes"]
              if (fd := fact_day(p)) is not None and fd <= days[-1]]

    # Ingest once.
    rpc(a.url, "mem/truncate", {"type": BTYPE})
    try:
        rpc(a.url, "mem/type_create",
            {"name": BTYPE, "levels": ["day"], "auto_summarize": False})
    except Exception:
        pass
    for e in trace["events"]:
        if e["day"] <= days[-1]:
            rpc(a.url, "mem/append",
                {"type": BTYPE, "payload": {"text": e["text"]},
                 "ts": day_ms(e["day"]) + e["seq"] * 1000})

    rows = []
    for variant, instruction in (("free-text", None),
                                 ("structured", STRUCTURED_INSTRUCTION)):
        for d in days:
            anchor = day_window_start(d)
            text = summarize(a.url, anchor, instruction)
            block = kv_block(text)
            rows.append({"variant": variant, "day": d, "chars": len(text),
                         "est_tokens": est_tokens(text),
                         "kv_pairs": len(block), "text": text})
            print(f"  {variant:10} day {d}: {len(text)} chars, "
                  f"{len(block)} kv pairs")

    # Score each variant two ways: reading the prose (as today) and reading the
    # structured block where one exists.
    print()
    print(f"{'variant':12} {'surface':10} {'correct':>8} {'acc':>7} {'chars':>7}")
    out = {"days": days, "n_probes": len(probes), "variants": {}}
    for variant in ("free-text", "structured"):
        by_day = {r["day"]: r for r in rows if r["variant"] == variant}
        for surface in ("prose", "block"):
            if surface == "block" and variant == "free-text":
                continue
            correct = 0
            for p in probes:
                m = re.search(r"on day (\d+)", p["question"])
                if not m:
                    continue
                r = by_day.get(int(m.group(1)))
                if not r:
                    continue
                if surface == "block":
                    mref = re.search(r"ref\s+(Z[A-Z]\d{2})", p["question"], re.I)
                    got = kv_block(r["text"]).get(mref.group(1).upper()) if mref else None
                    if got is None:      # fall back to the prose reader
                        got = extract_answer(r["text"], p["question"])
                else:
                    got = extract_answer(r["text"], p["question"])
                correct += (got == p["answer"])
            acc = correct / len(probes) if probes else 0.0
            chars = statistics.fmean(r["chars"] for r in by_day.values())
            key = f"{variant}/{surface}"
            if surface == "block":
                # Falls back to the prose reader on windows with no block, so it
                # is not an independent condition. Recorded with that caveat.
            out["variants"][key] = {"correct": correct, "total": len(probes),
                                    "accuracy": acc, "mean_chars": chars,
                                    "mean_tokens": statistics.fmean(
                                        r["est_tokens"] for r in by_day.values())}
            print(f"{variant:12} {surface:10} {correct:>4}/{len(probes):<3} "
                  f"{acc:>6.1%} {chars:>7.0f}")

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
