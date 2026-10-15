#!/usr/bin/env python3
"""
The recursive step, measured correctly: a project's week of day summaries → its
week summary.

`token_survival.py` compared ONE day's tokens against the week text and got a
retention of ~81–84%, which looks like the week step is nearly lossless. It is
not a valid comparison: the week summary covers 5–7 days (and for a busy project
runs 3–5x longer than a single day's), so it contains the measured day's content
*plus* five other days'. A token is far more likely to be present simply because
the target text is bigger and about more.

The recursive step that actually happens (see `summarizeWindowCore`) is:

    {that project's day summaries across the week}  →  {that project's week summary}

so both sides must be restricted to the same project AND the same time range.
That is what this script measures.

Read-only: `mem/recall` only.

Usage:
    python3 week_step.py --weeks 4 --out results/real-corpus/week-step.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sample_real import rpc                        # noqa: E402
from token_survival import (group_text, numeric_tokens, symbol_tokens,      # noqa: E402
                            causal_tokens, EXTRACTORS, DAY_MS, HOUR_MS, CST, TYPE)


def week_start(ms: int) -> int:
    shifted = ms + 8 * HOUR_MS
    ds = shifted - (shifted % DAY_MS)
    return (ds - (((ds // DAY_MS) + 3) % 7) * DAY_MS) - 8 * HOUR_MS


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8900/mcp")
    ap.add_argument("--weeks", type=int, default=4,
                    help="how many recent closed weeks to measure")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    s = rpc(args.url, "mem/summaries", {"type": TYPE, "limit": 500})
    wins = [(int(a), int(b)) for a, b in re.findall(r"窗口 (\d+)~(\d+)", s)]
    weeks = sorted({a for a, b in wins if 6 <= (b - a) / DAY_MS < 8}, reverse=True)
    if not weeks:
        print("no week summaries found", file=sys.stderr)
        return 1
    # Drop the most recent week if it is still in progress.
    now = datetime.now(CST)
    weeks = [w for w in weeks
             if datetime.fromtimestamp((w + 7 * DAY_MS) / 1000, CST) <= now]
    weeks = weeks[:args.weeks]
    print(f"measuring {len(weeks)} closed weeks\n")

    rows = []
    for w in weeks:
        wlabel = datetime.fromtimestamp(w / 1000, CST).strftime("%Y-%m-%d")
        week_groups = group_text(rpc(args.url, "mem/recall", {
            "type": TYPE, "granularity": "week", "mode": "summary",
            "windowStartMs": w}))

        # Gather this week's day summaries, per project.
        per_proj: dict[str, list[str]] = {}
        days_with_summary = 0
        for k in range(7):
            dms = w + k * DAY_MS
            txt = rpc(args.url, "mem/recall", {
                "type": TYPE, "granularity": "day", "mode": "summary",
                "windowStartMs": dms})
            if "尚无语义摘要" in txt:
                continue
            days_with_summary += 1
            for proj, body in group_text(txt).items():
                per_proj.setdefault(proj, []).append(body)

        for proj, day_bodies in per_proj.items():
            if proj not in week_groups:
                continue
            day_text = "\n".join(day_bodies)
            week_text = week_groups[proj]
            row = {"week": wlabel, "proj": proj,
                   "days_in_week": len(day_bodies),
                   "day_chars": len(day_text), "week_chars": len(week_text)}
            for kind, fn in EXTRACTORS.items():
                toks = fn(day_text)
                kept = {t for t in toks if t in week_text}
                row[kind] = {
                    "day_n": len(toks),
                    "kept": len(kept),
                    "rate": len(kept) / len(toks) if toks else None,
                }
            rows.append(row)

    print(f"{'week':11} {'proj':18} {'days':>4} {'day_ch':>7} {'week_ch':>8} "
          f"{'num':>8} {'sym':>8} {'cause':>8}")
    print("-" * 74)
    for r in sorted(rows, key=lambda x: (x["week"], x["proj"])):
        f = lambda k: (f"{r[k]['rate']:.0%}" if r[k]['rate'] is not None else "-")
        print(f"{r['week']:11} {r['proj'][:18]:18} {r['days_in_week']:>4} "
              f"{r['day_chars']:>7} {r['week_chars']:>8} "
              f"{f('numeric'):>8} {f('symbol'):>8} {f('causal'):>8}")

    agg = {}
    for kind in EXTRACTORS:
        vals = [r[kind]["rate"] for r in rows if r[kind]["rate"] is not None]
        agg[kind] = {
            "pairs": len(vals),
            "mean": statistics.fmean(vals) if vals else None,
            "std": statistics.stdev(vals) if len(vals) > 1 else 0.0,
        }

    print(f"\n=== week step: {{project's day summaries for the week}} -> "
          f"{{project's week summary}}  ({len(rows)} pairs) ===")
    for kind, a in agg.items():
        m = f"{a['mean']:.1%}" if a["mean"] is not None else "-"
        s_ = f"±{a['std']:.1%}" if a["std"] else ""
        print(f"  {kind:10} kept {m} {s_}")

    print(f"\ncompression: day {statistics.fmean([r['day_chars'] for r in rows]):.0f} "
          f"chars -> week {statistics.fmean([r['week_chars'] for r in rows]):.0f} chars")
    print("(both sides now cover the same project and the same 7-day window)")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump({"pairs": len(rows), "aggregate": agg, "rows": rows},
                  fh, ensure_ascii=False, indent=1)
    print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
